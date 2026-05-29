use std::fs;
use std::io::{Write, stdout};
use std::path::{Path, PathBuf};
use std::process::{Command as StdCommand, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use crossterm::cursor::{Hide, MoveTo, RestorePosition, SavePosition, Show};
use crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEvent, KeyModifiers,
    MouseEvent, MouseEventKind,
};
use crossterm::execute;
use crossterm::terminal::{
    Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode,
    enable_raw_mode, size,
};
use nudge_daemon::{BindingState, BindingStatus, DaemonConfig};
use nudge_protocol::v1;
use qrcode::{QrCode, render::unicode};
use serde::{Deserialize, Serialize};
use tokio::process::Command as TokioCommand;
use unicode_width::UnicodeWidthStr;

#[derive(Debug, Parser)]
#[command(
    name = "nudge",
    version,
    about = "Single-session remote shell workspace"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Daemon management commands.
    Daemon {
        /// Run daemon mode directly; kept for Phase 0 verification compatibility.
        #[arg(long, hide = true)]
        placeholder: bool,
        #[command(subcommand)]
        command: Option<DaemonCommand>,
    },
    /// Install, inspect, or remove the user-level daemon service.
    Service {
        #[command(subcommand)]
        command: ServiceCommand,
    },
    /// Re-run the native installer to update this binary.
    Update {
        /// Print the installer URL and environment without running it.
        #[arg(long)]
        dry_run: bool,
        /// Installer script URL or local path.
        #[arg(long, default_value = DEFAULT_INSTALL_SCRIPT_URL)]
        install_script_url: String,
        /// Release version to install; defaults to the installer default.
        #[arg(long)]
        version: Option<String>,
        /// Install directory override.
        #[arg(long)]
        install_dir: Option<PathBuf>,
        /// Skip installer checksum verification.
        #[arg(long)]
        skip_checksum: bool,
    },
    /// Bind or revoke a phone through the relay.
    Bind {
        #[command(subcommand)]
        command: BindCommand,
    },
    /// Print current placeholder entitlement.
    #[command(hide = true)]
    Entitlement,
    /// Print persisted session metadata.
    #[command(hide = true)]
    SessionState,
    /// Print daemon signing public key for relay smoke tests.
    #[command(hide = true)]
    DevicePublicKey,
    /// Create a tab in the persisted session metadata.
    #[command(hide = true)]
    CreateTab {
        /// Tab title.
        #[arg(long, default_value = "shell")]
        title: String,
    },
    /// Rename a tab through daemon IPC.
    #[command(hide = true)]
    RenameTab {
        /// Tab id.
        #[arg(long, default_value = "default")]
        tab_id: String,
        /// New tab title.
        title: String,
    },
    /// Close a tab through daemon IPC.
    #[command(hide = true)]
    CloseTab {
        /// Tab id.
        #[arg(long, default_value = "default")]
        tab_id: String,
    },
    /// Send bytes to a tab pty.
    #[command(hide = true)]
    PtyInput {
        /// Tab id.
        #[arg(long, default_value = "default")]
        tab_id: String,
        /// Append carriage return after the text.
        #[arg(long)]
        enter: bool,
        /// Text to write to the PTY.
        text: String,
    },
    /// Print recent bytes from a tab pty.
    #[command(hide = true)]
    PtyOutput {
        /// Tab id.
        #[arg(long, default_value = "default")]
        tab_id: String,
        /// Maximum bytes to print.
        #[arg(long, default_value_t = 4096)]
        max_bytes: u32,
    },
    /// Print daemon-owned terminal snapshot text.
    #[command(hide = true)]
    Snapshot {
        /// Tab id.
        #[arg(long, default_value = "default")]
        tab_id: String,
    },
    /// Print daemon-produced terminal render frame.
    #[command(hide = true)]
    RenderFrame {
        /// Tab id.
        #[arg(long, default_value = "default")]
        tab_id: String,
    },
    /// Save phone terminal profile in daemon state.
    #[command(hide = true)]
    SetPhoneProfile {
        /// Terminal rows.
        #[arg(long)]
        rows: u32,
        /// Terminal columns.
        #[arg(long)]
        cols: u32,
    },
    /// Switch tab width mode.
    #[command(hide = true)]
    SetWidthMode {
        /// Tab id.
        #[arg(long, default_value = "default")]
        tab_id: String,
        /// Width mode: phone or computer.
        mode: String,
        /// Current computer rows.
        #[arg(long, default_value_t = 24)]
        computer_rows: u32,
        /// Current computer columns.
        #[arg(long, default_value_t = 80)]
        computer_cols: u32,
    },
    /// Resize a tab pty.
    #[command(hide = true)]
    ResizeTab {
        /// Tab id.
        #[arg(long, default_value = "default")]
        tab_id: String,
        /// Terminal rows.
        #[arg(long)]
        rows: u32,
        /// Terminal columns.
        #[arg(long)]
        cols: u32,
    },
    /// Restart a tab pty after daemon restart.
    #[command(hide = true)]
    RestartTab {
        /// Tab id.
        #[arg(long, default_value = "default")]
        tab_id: String,
    },
    /// Persist binding state for relay smoke tests.
    #[command(hide = true)]
    SetBindingState {
        #[arg(long)]
        relay_url: String,
        #[arg(long)]
        daemon_device_id: String,
        #[arg(long)]
        binding_id: String,
        #[arg(long)]
        code: String,
        #[arg(long)]
        status: String,
        #[arg(long)]
        bound_phone_id: Option<String>,
    },
}

const DEFAULT_INSTALL_SCRIPT_URL: &str = "https://nudgecode.dev/install.sh";

#[derive(Debug, Subcommand)]
enum DaemonCommand {
    /// Run daemon/server mode.
    #[command(hide = true)]
    Run {
        /// Print startup details for local verification.
        #[arg(long)]
        placeholder: bool,
    },
    /// Print daemon status through the private local IPC socket.
    Status,
    /// Ask the daemon to stop.
    Stop,
}

#[derive(Debug, Subcommand)]
enum ServiceCommand {
    /// Install a launchd/systemd user service that keeps the daemon running.
    Install {
        /// Print files and commands without changing the machine.
        #[arg(long)]
        dry_run: bool,
        /// Do not start or restart the service after installing it.
        #[arg(long)]
        no_start: bool,
        /// Binary path to use in the service file.
        #[arg(long)]
        binary: Option<PathBuf>,
    },
    /// Stop and remove the launchd/systemd user service.
    Uninstall {
        /// Print commands without changing the machine.
        #[arg(long)]
        dry_run: bool,
    },
    /// Print OS service manager status for the daemon service.
    Status,
    /// Print recent daemon service logs.
    Logs {
        /// Number of recent lines to print.
        #[arg(long, default_value_t = 100)]
        lines: usize,
    },
}

#[derive(Debug, Subcommand)]
enum BindCommand {
    /// Start phone binding and print the pairing code.
    Phone {
        /// Relay HTTP base URL.
        #[arg(long, default_value = "http://127.0.0.1:8787")]
        relay_url: String,
        /// Wait for a phone claim and confirm it when seen.
        #[arg(long)]
        wait: bool,
        /// Do not prompt before confirming a claimed phone.
        #[arg(long)]
        yes: bool,
        /// Seconds to wait for phone claim when --wait is set.
        #[arg(long, default_value_t = 120)]
        timeout_seconds: u64,
    },
    /// Revoke the currently stored phone binding.
    Revoke {
        /// Relay HTTP base URL override.
        #[arg(long)]
        relay_url: Option<String>,
    },
    /// Simulate phone-side pairing code claim.
    #[command(hide = true)]
    Claim {
        /// Relay HTTP base URL.
        #[arg(long, default_value = "http://127.0.0.1:8787")]
        relay_url: String,
        /// Pairing code printed by `nudge bind phone`.
        #[arg(long)]
        code: String,
        /// Development phone public key placeholder.
        #[arg(long, default_value = "nudge-smoke-phone-key")]
        phone_public_key: String,
    },
    /// Confirm a claimed binding from the computer side.
    #[command(hide = true)]
    Confirm {
        /// Relay HTTP base URL override.
        #[arg(long)]
        relay_url: Option<String>,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Some(Command::Daemon { command: None, .. }) => {
            print_daemon_status().await?;
        }
        Some(Command::Daemon {
            command: Some(DaemonCommand::Run { placeholder }),
            ..
        }) => {
            nudge_daemon::run_server(DaemonConfig {
                placeholder,
                foreground: true,
            })
            .await?;
        }
        Some(Command::Daemon {
            command: Some(DaemonCommand::Status),
            ..
        }) => print_daemon_status().await?,
        Some(Command::Daemon {
            command: Some(DaemonCommand::Stop),
            ..
        }) => stop_daemon().await?,
        Some(Command::Service { command }) => match command {
            ServiceCommand::Install {
                dry_run,
                no_start,
                binary,
            } => service_install(dry_run, no_start, binary.as_deref()).await?,
            ServiceCommand::Uninstall { dry_run } => service_uninstall(dry_run).await?,
            ServiceCommand::Status => service_status()?,
            ServiceCommand::Logs { lines } => service_logs(lines)?,
        },
        Some(Command::Update {
            dry_run,
            install_script_url,
            version,
            install_dir,
            skip_checksum,
        }) => {
            update_nudge(
                dry_run,
                &install_script_url,
                version.as_deref(),
                install_dir.as_deref(),
                skip_checksum,
            )
            .await?
        }
        Some(Command::Bind { command }) => match command {
            BindCommand::Phone {
                relay_url,
                wait,
                yes,
                timeout_seconds,
            } => bind_phone(&relay_url, wait, yes, timeout_seconds).await?,
            BindCommand::Revoke { relay_url } => revoke_binding(relay_url.as_deref()).await?,
            BindCommand::Claim {
                relay_url,
                code,
                phone_public_key,
            } => claim_binding(&relay_url, &code, &phone_public_key).await?,
            BindCommand::Confirm { relay_url } => confirm_binding(relay_url.as_deref()).await?,
        },
        Some(Command::Entitlement) => {
            let entitlement = nudge_protocol::free_entitlement();
            println!(
                "plan={} max_bound_computers={} max_tabs_per_computer={}",
                entitlement.plan,
                entitlement.max_bound_computers,
                entitlement.max_tabs_per_computer
            );
        }
        Some(Command::SessionState) => {
            ensure_daemon().await?;
            let state = get_session_state().await?;
            print_session_state(&state);
        }
        Some(Command::DevicePublicKey) => {
            println!("{}", daemon_public_key()?);
        }
        Some(Command::CreateTab { title }) => {
            ensure_daemon().await?;
            let response =
                nudge_daemon::request(envelope(v1::envelope::Payload::CreateTab(v1::CreateTab {
                    title,
                })))
                .await?;
            print_session_response(response, "tab created")?;
        }
        Some(Command::RenameTab { tab_id, title }) => {
            ensure_daemon().await?;
            let response =
                nudge_daemon::request(envelope(v1::envelope::Payload::RenameTab(v1::RenameTab {
                    tab_id,
                    title,
                })))
                .await?;
            print_session_response(response, "tab renamed")?;
        }
        Some(Command::CloseTab { tab_id }) => {
            ensure_daemon().await?;
            let response =
                nudge_daemon::request(envelope(v1::envelope::Payload::CloseTab(v1::CloseTab {
                    tab_id,
                })))
                .await?;
            print_session_response(response, "tab closed")?;
        }
        Some(Command::PtyInput {
            tab_id,
            enter,
            mut text,
        }) => {
            ensure_daemon().await?;
            if enter {
                text.push('\r');
            }
            let response = nudge_daemon::request(envelope(v1::envelope::Payload::TerminalInput(
                v1::TerminalInput {
                    tab_id,
                    data: text.into_bytes(),
                },
            )))
            .await?;
            match response.payload {
                Some(v1::envelope::Payload::Ack(ack)) => println!("{}", ack.message),
                Some(v1::envelope::Payload::Error(error)) => {
                    anyhow::bail!("daemon returned {}: {}", error.code, error.message);
                }
                _ => anyhow::bail!("daemon returned an unexpected terminal input response"),
            }
        }
        Some(Command::PtyOutput { tab_id, max_bytes }) => {
            ensure_daemon().await?;
            let response =
                nudge_daemon::request(envelope(v1::envelope::Payload::TerminalOutputRequest(
                    v1::TerminalOutputRequest { tab_id, max_bytes },
                )))
                .await?;
            match response.payload {
                Some(v1::envelope::Payload::TerminalOutput(output)) => {
                    print!("{}", String::from_utf8_lossy(&output.data));
                }
                Some(v1::envelope::Payload::Error(error)) => {
                    anyhow::bail!("daemon returned {}: {}", error.code, error.message);
                }
                _ => anyhow::bail!("daemon returned an unexpected terminal output response"),
            }
        }
        Some(Command::Snapshot { tab_id }) => {
            ensure_daemon().await?;
            let response =
                nudge_daemon::request(envelope(v1::envelope::Payload::TerminalSnapshotRequest(
                    v1::TerminalSnapshotRequest { tab_id },
                )))
                .await?;
            match response.payload {
                Some(v1::envelope::Payload::TerminalSnapshot(snapshot)) => {
                    println!(
                        "snapshot tab={} rows={} cols={}",
                        snapshot.tab_id, snapshot.rows, snapshot.cols
                    );
                    print!("{}", snapshot.text);
                }
                Some(v1::envelope::Payload::Error(error)) => {
                    anyhow::bail!("daemon returned {}: {}", error.code, error.message);
                }
                _ => anyhow::bail!("daemon returned an unexpected snapshot response"),
            }
        }
        Some(Command::RenderFrame { tab_id }) => {
            ensure_daemon().await?;
            let response = nudge_daemon::request(envelope(
                v1::envelope::Payload::TerminalRenderRequest(v1::TerminalRenderRequest { tab_id }),
            ))
            .await?;
            match response.payload {
                Some(v1::envelope::Payload::TerminalRender(render)) => {
                    println!(
                        "render tab={} rows={} cols={} width_mode={} bytes={}",
                        render.tab_id,
                        render.rows,
                        render.cols,
                        render.width_mode,
                        render.frame.len()
                    );
                    print!("{}", String::from_utf8_lossy(&render.frame));
                }
                Some(v1::envelope::Payload::Error(error)) => {
                    anyhow::bail!("daemon returned {}: {}", error.code, error.message);
                }
                _ => anyhow::bail!("daemon returned an unexpected render response"),
            }
        }
        Some(Command::SetPhoneProfile { rows, cols }) => {
            ensure_daemon().await?;
            let response = nudge_daemon::request(envelope(v1::envelope::Payload::SetPhoneProfile(
                v1::SetPhoneProfile { rows, cols },
            )))
            .await?;
            print_session_response(response, "phone profile saved")?;
        }
        Some(Command::SetWidthMode {
            tab_id,
            mode,
            computer_rows,
            computer_cols,
        }) => {
            ensure_daemon().await?;
            let response = nudge_daemon::request(envelope(v1::envelope::Payload::SetWidthMode(
                v1::SetWidthMode {
                    tab_id,
                    mode,
                    computer_rows,
                    computer_cols,
                },
            )))
            .await?;
            print_session_response(response, "width mode updated")?;
        }
        Some(Command::ResizeTab { tab_id, rows, cols }) => {
            ensure_daemon().await?;
            let response =
                nudge_daemon::request(envelope(v1::envelope::Payload::ResizeTab(v1::ResizeTab {
                    tab_id,
                    rows,
                    cols,
                })))
                .await?;
            match response.payload {
                Some(v1::envelope::Payload::Ack(ack)) => println!("{}", ack.message),
                Some(v1::envelope::Payload::Error(error)) => {
                    anyhow::bail!("daemon returned {}: {}", error.code, error.message);
                }
                _ => anyhow::bail!("daemon returned an unexpected resize response"),
            }
        }
        Some(Command::RestartTab { tab_id }) => {
            ensure_daemon().await?;
            let response = nudge_daemon::request(envelope(v1::envelope::Payload::RestartTab(
                v1::RestartTab { tab_id },
            )))
            .await?;
            print_session_response(response, "tab restarted")?;
        }
        Some(Command::SetBindingState {
            relay_url,
            daemon_device_id,
            binding_id,
            code,
            status,
            bound_phone_id,
        }) => {
            ensure_daemon().await?;
            let binding = BindingState {
                relay_url,
                daemon_device_id,
                binding_id,
                code,
                expires_at: String::new(),
                status: parse_binding_status(&status)?,
                bound_phone_id,
                updated_at: now_millis().to_string(),
            };
            set_binding_state(binding).await?;
            println!("binding state saved");
        }
        None => {
            ensure_daemon().await?;
            let response = nudge_daemon::request(envelope(v1::envelope::Payload::AttachClient(
                v1::AttachClient {
                    client_id: format!("cli-{}", std::process::id()),
                },
            )))
            .await?;
            match response.payload {
                Some(v1::envelope::Payload::SessionState(state)) => {
                    run_interactive_client(state).await?;
                }
                Some(v1::envelope::Payload::Error(error)) => {
                    anyhow::bail!("daemon returned {}: {}", error.code, error.message);
                }
                _ => anyhow::bail!("daemon returned an unexpected attach response"),
            }
        }
    }

    Ok(())
}

async fn run_interactive_client(mut state: v1::SessionState) -> Result<()> {
    let mut terminal = TerminalGuard::enter()?;
    let mut selected_tab_id = state
        .tabs
        .first()
        .map(|tab| tab.id.clone())
        .context("daemon session has no tabs")?;
    if !selected_tab_needs_restart(&state, &selected_tab_id) {
        resize_selected_tab(&selected_tab_id).await?;
    }
    let mut last_frame = Vec::new();
    let mut prefix_active = false;

    loop {
        state = get_session_state().await?;
        if !state.tabs.iter().any(|tab| tab.id == selected_tab_id) {
            selected_tab_id = state
                .tabs
                .first()
                .map(|tab| tab.id.clone())
                .context("daemon session has no tabs")?;
        }
        let render = render_tab(&selected_tab_id, &state).await?;
        let fingerprint = render.fingerprint();
        if fingerprint != last_frame {
            draw_frame(&mut terminal, &state, &selected_tab_id, &render).await?;
            last_frame = fingerprint;
        }

        if event::poll(Duration::from_millis(60)).context("failed to poll terminal input")? {
            match event::read().context("failed to read terminal input")? {
                Event::Key(key) if is_prefix_key(key) => {
                    prefix_active = true;
                    last_frame.clear();
                }
                Event::Key(key) if prefix_active => {
                    if handle_prefix_key(key, &mut selected_tab_id).await? {
                        break;
                    }
                    prefix_active = false;
                    last_frame.clear();
                }
                Event::Key(key) if should_detach(key) => break,
                Event::Key(key) => {
                    if !selected_tab_needs_restart(&state, &selected_tab_id)
                        && let Some(bytes) = key_to_pty_bytes(key)
                    {
                        send_terminal_input(&selected_tab_id, bytes).await?;
                    }
                }
                Event::Resize(cols, rows) => {
                    if !selected_tab_needs_restart(&state, &selected_tab_id) {
                        resize_tab(&selected_tab_id, rows, cols).await?;
                    }
                    last_frame.clear();
                }
                Event::Mouse(mouse) => {
                    if let Some(tab_id) = clicked_tab_id(&state, &selected_tab_id, mouse) {
                        selected_tab_id = tab_id;
                        if !selected_tab_needs_restart(&state, &selected_tab_id) {
                            resize_selected_tab(&selected_tab_id).await?;
                        }
                        last_frame.clear();
                    }
                }
                _ => {}
            }
        }
    }

    let _ = nudge_daemon::request(envelope(v1::envelope::Payload::ClientExited(
        v1::ClientExited {
            client_id: format!("cli-{}", std::process::id()),
        },
    )))
    .await;
    Ok(())
}

async fn bind_phone(relay_url: &str, wait: bool, yes: bool, timeout_seconds: u64) -> Result<()> {
    let relay_url = normalize_relay_url(relay_url);
    ensure_daemon().await?;
    let session = nudge_daemon::load_session()?;
    if let Some(binding) = session.binding.as_ref() {
        if binding.status != BindingStatus::Revoked {
            anyhow::bail!(
                "this computer already has a {} binding; run `nudge bind revoke` first",
                binding.status.as_str()
            );
        }
    }

    let daemon_public_key = daemon_public_key()?;
    let client = reqwest::Client::new();
    let daemon_device = register_device(&client, &relay_url, "daemon", &daemon_public_key).await?;
    let binding_response = post_json::<StartBindingRequest, BindingResponse>(
        &client,
        &relay_url,
        "/api/bind/start",
        &StartBindingRequest {
            daemon_device_id: daemon_device.device.id.clone(),
        },
    )
    .await?;
    let binding = BindingState::pending(
        relay_url.clone(),
        daemon_device.device.id,
        binding_response.binding.id,
        binding_response.binding.code,
        binding_response.binding.expires_at,
    );
    set_binding_state(binding.clone()).await?;

    println!("binding pending");
    println!("relay_url={}", binding.relay_url);
    println!("daemon_device_id={}", binding.daemon_device_id);
    println!("binding_id={}", binding.binding_id);
    println!("pairing_code={}", binding.code);
    let pairing_url = format!("{}/pair?code={}", binding.relay_url, binding.code);
    println!("pairing_url={pairing_url}");
    println!("expires_at={}", binding.expires_at);
    print_qr_code(&pairing_url)?;
    if wait {
        wait_for_claim_and_confirm(&client, binding, yes, timeout_seconds).await?;
    } else {
        println!("run `nudge bind phone --wait` to wait for phone claim and confirm it");
    }
    Ok(())
}

async fn claim_binding(relay_url: &str, code: &str, phone_public_key: &str) -> Result<()> {
    let relay_url = normalize_relay_url(relay_url);
    let client = reqwest::Client::new();
    let phone = register_device(&client, &relay_url, "phone", phone_public_key).await?;
    let binding_response = post_json::<ClaimBindingRequest, BindingResponse>(
        &client,
        &relay_url,
        "/api/bind/claim",
        &ClaimBindingRequest {
            code: code.to_string(),
            phone_device_id: phone.device.id.clone(),
        },
    )
    .await?;
    println!("phone claimed");
    println!("phone_device_id={}", phone.device.id);
    println!("binding_id={}", binding_response.binding.id);
    println!("status={}", binding_response.binding.status);
    Ok(())
}

async fn wait_for_claim_and_confirm(
    client: &reqwest::Client,
    pending: BindingState,
    yes: bool,
    timeout_seconds: u64,
) -> Result<()> {
    println!("waiting for phone claim...");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(timeout_seconds);
    loop {
        let binding_response = get_json::<BindingResponse>(
            client,
            &pending.relay_url,
            &format!(
                "/api/bind/status?bindingId={}&deviceId={}",
                pending.binding_id, pending.daemon_device_id
            ),
        )
        .await?;
        match binding_response.binding.status.as_str() {
            "claimed" => {
                let phone_id = binding_response
                    .binding
                    .phone_device_id
                    .clone()
                    .unwrap_or_else(|| "unknown".to_string());
                println!("phone claimed");
                println!("phone_device_id={phone_id}");
                if !yes && !confirm_prompt("Confirm this phone binding?")? {
                    anyhow::bail!("binding confirmation cancelled");
                }
                confirm_binding_with_pending(client, pending).await?;
                return Ok(());
            }
            "active" => {
                confirm_binding_with_pending(client, pending).await?;
                return Ok(());
            }
            "revoked" => anyhow::bail!("binding was revoked before confirmation"),
            _ => {}
        }
        if tokio::time::Instant::now() >= deadline {
            anyhow::bail!("timed out waiting for phone claim");
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

async fn confirm_binding(relay_url: Option<&str>) -> Result<()> {
    ensure_daemon().await?;
    let pending = current_binding()?;
    if pending.status == BindingStatus::Active {
        println!("binding already active");
        println!("binding_id={}", pending.binding_id);
        if let Some(phone_id) = pending.bound_phone_id {
            println!("bound_phone_id={phone_id}");
        }
        return Ok(());
    }
    if pending.status != BindingStatus::Pending {
        anyhow::bail!("stored binding is not pending");
    }
    let relay_url = relay_url
        .map(normalize_relay_url)
        .unwrap_or_else(|| pending.relay_url.clone());
    let client = reqwest::Client::new();
    confirm_binding_with_client(&client, pending, &relay_url).await
}

async fn confirm_binding_with_pending(
    client: &reqwest::Client,
    pending: BindingState,
) -> Result<()> {
    let relay_url = pending.relay_url.clone();
    confirm_binding_with_client(client, pending, &relay_url).await
}

async fn confirm_binding_with_client(
    client: &reqwest::Client,
    pending: BindingState,
    relay_url: &str,
) -> Result<()> {
    let binding_response = post_json::<ConfirmBindingRequest, BindingResponse>(
        client,
        relay_url,
        "/api/bind/confirm",
        &ConfirmBindingRequest {
            binding_id: pending.binding_id.clone(),
            daemon_device_id: pending.daemon_device_id.clone(),
        },
    )
    .await?;
    let phone_id = binding_response
        .binding
        .phone_device_id
        .context("relay confirmed binding without phone device id")?;
    let mut active = pending.active(phone_id.clone());
    active.relay_url = relay_url.to_string();
    active.binding_id = binding_response.binding.id;
    active.expires_at = binding_response.binding.expires_at;
    set_binding_state(active.clone()).await?;
    println!("binding active");
    println!("binding_id={}", active.binding_id);
    println!("bound_phone_id={phone_id}");
    Ok(())
}

async fn revoke_binding(relay_url: Option<&str>) -> Result<()> {
    ensure_daemon().await?;
    let binding = current_binding()?;
    let relay_url = relay_url
        .map(normalize_relay_url)
        .unwrap_or_else(|| binding.relay_url.clone());
    let client = reqwest::Client::new();
    let binding_response = post_json::<RevokeBindingRequest, BindingResponse>(
        &client,
        &relay_url,
        "/api/bind/revoke",
        &RevokeBindingRequest {
            binding_id: binding.binding_id.clone(),
            device_id: binding.daemon_device_id.clone(),
        },
    )
    .await?;
    clear_binding_state().await?;
    println!("binding revoked");
    println!("binding_id={}", binding_response.binding.id);
    println!("status={}", binding_response.binding.status);
    Ok(())
}

#[derive(Debug, Deserialize)]
struct DeviceResponse {
    device: RelayDevice,
}

#[derive(Debug, Deserialize)]
struct RelayDevice {
    id: String,
}

#[derive(Debug, Deserialize)]
struct BindingResponse {
    binding: RelayBinding,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RelayBinding {
    id: String,
    code: String,
    phone_device_id: Option<String>,
    status: String,
    expires_at: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RegisterDeviceRequest {
    kind: String,
    public_key: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct StartBindingRequest {
    daemon_device_id: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ClaimBindingRequest {
    code: String,
    phone_device_id: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ConfirmBindingRequest {
    binding_id: String,
    daemon_device_id: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RevokeBindingRequest {
    binding_id: String,
    device_id: String,
}

async fn register_device(
    client: &reqwest::Client,
    relay_url: &str,
    kind: &str,
    public_key: &str,
) -> Result<DeviceResponse> {
    post_json::<RegisterDeviceRequest, DeviceResponse>(
        client,
        relay_url,
        "/api/devices/register",
        &RegisterDeviceRequest {
            kind: kind.to_string(),
            public_key: public_key.to_string(),
        },
    )
    .await
}

async fn post_json<Request, Response>(
    client: &reqwest::Client,
    relay_url: &str,
    path: &str,
    body: &Request,
) -> Result<Response>
where
    Request: Serialize + ?Sized,
    Response: for<'de> Deserialize<'de>,
{
    let url = format!("{relay_url}{path}");
    let response = client
        .post(&url)
        .json(body)
        .send()
        .await
        .with_context(|| format!("failed to call {url}"))?;
    let status = response.status();
    let bytes = response
        .bytes()
        .await
        .with_context(|| format!("failed to read response from {url}"))?;
    if !status.is_success() {
        let body = String::from_utf8_lossy(&bytes);
        anyhow::bail!("relay returned HTTP {status} from {path}: {body}");
    }
    serde_json::from_slice(&bytes).with_context(|| format!("failed to parse response from {url}"))
}

async fn get_json<Response>(
    client: &reqwest::Client,
    relay_url: &str,
    path: &str,
) -> Result<Response>
where
    Response: for<'de> Deserialize<'de>,
{
    let url = format!("{relay_url}{path}");
    let response = client
        .get(&url)
        .send()
        .await
        .with_context(|| format!("failed to call {url}"))?;
    let status = response.status();
    let bytes = response
        .bytes()
        .await
        .with_context(|| format!("failed to read response from {url}"))?;
    if !status.is_success() {
        let body = String::from_utf8_lossy(&bytes);
        anyhow::bail!("relay returned HTTP {status} from {path}: {body}");
    }
    serde_json::from_slice(&bytes).with_context(|| format!("failed to parse response from {url}"))
}

async fn set_binding_state(binding: BindingState) -> Result<v1::SessionState> {
    let response = nudge_daemon::request(envelope(v1::envelope::Payload::SetBindingState(
        v1::SetBindingState {
            binding: Some(binding.to_proto()),
        },
    )))
    .await?;
    session_from_response(response)
}

async fn clear_binding_state() -> Result<v1::SessionState> {
    let response = nudge_daemon::request(envelope(v1::envelope::Payload::ClearBindingState(
        v1::ClearBindingState {},
    )))
    .await?;
    session_from_response(response)
}

fn session_from_response(response: v1::Envelope) -> Result<v1::SessionState> {
    match response.payload {
        Some(v1::envelope::Payload::SessionState(state)) => Ok(state),
        Some(v1::envelope::Payload::Error(error)) => {
            anyhow::bail!("daemon returned {}: {}", error.code, error.message);
        }
        _ => anyhow::bail!("daemon returned an unexpected session response"),
    }
}

fn current_binding() -> Result<BindingState> {
    nudge_daemon::load_session()?
        .binding
        .context("no phone binding is stored; run `nudge bind phone` first")
}

fn normalize_relay_url(relay_url: &str) -> String {
    relay_url.trim_end_matches('/').to_string()
}

fn daemon_public_key() -> Result<String> {
    let mut session = nudge_daemon::load_session()?;
    let identity = session.device_identity()?;
    Ok(identity.public_key().to_string())
}

fn print_qr_code(value: &str) -> Result<()> {
    let code = QrCode::new(value.as_bytes()).context("failed to generate pairing QR code")?;
    let image = code
        .render::<unicode::Dense1x2>()
        .quiet_zone(true)
        .module_dimensions(2, 1)
        .build();
    println!("{image}");
    Ok(())
}

fn confirm_prompt(prompt: &str) -> Result<bool> {
    use std::io::{Write, stdin, stdout};

    print!("{prompt} [y/N] ");
    stdout()
        .flush()
        .context("failed to flush confirmation prompt")?;
    let mut answer = String::new();
    stdin()
        .read_line(&mut answer)
        .context("failed to read confirmation prompt")?;
    Ok(matches!(answer.trim().to_lowercase().as_str(), "y" | "yes"))
}

fn parse_binding_status(status: &str) -> Result<BindingStatus> {
    match status {
        "pending" => Ok(BindingStatus::Pending),
        "active" => Ok(BindingStatus::Active),
        "revoked" => Ok(BindingStatus::Revoked),
        other => anyhow::bail!("unsupported binding status {other}"),
    }
}

struct TerminalGuard;

impl TerminalGuard {
    fn enter() -> Result<Self> {
        enable_raw_mode().context("failed to enable raw terminal mode")?;
        execute!(
            stdout(),
            EnterAlternateScreen,
            EnableMouseCapture,
            Hide,
            Clear(ClearType::All)
        )
        .context("failed to enter alternate screen")?;
        Ok(Self)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = execute!(stdout(), Show, DisableMouseCapture, LeaveAlternateScreen);
        let _ = disable_raw_mode();
    }
}

struct ClientFrame {
    rows: u32,
    cols: u32,
    frame: Vec<u8>,
    width_mode: String,
    tab_status: String,
}

impl ClientFrame {
    fn fingerprint(&self) -> Vec<u8> {
        let mut fingerprint = format!(
            "{}:{}:{}:{}:",
            self.rows, self.cols, self.width_mode, self.tab_status
        )
        .into_bytes();
        fingerprint.extend_from_slice(&self.frame);
        fingerprint
    }
}

async fn draw_frame(
    _terminal: &mut TerminalGuard,
    state: &v1::SessionState,
    selected_tab_id: &str,
    render: &ClientFrame,
) -> Result<()> {
    let mut output = stdout();
    let (terminal_cols, terminal_rows) = size().unwrap_or((80, 24));
    execute!(output, MoveTo(0, 0), Clear(ClearType::All)).context("failed to clear terminal")?;
    output
        .write_all(&render.frame)
        .context("failed to write terminal render frame")?;
    execute!(output, SavePosition)?;
    execute!(output, MoveTo(0, 0), Clear(ClearType::CurrentLine))?;
    write!(
        output,
        "{}",
        fit_line(
            &tab_bar_layout(state, selected_tab_id).text,
            terminal_cols as usize
        )
    )?;
    execute!(
        output,
        MoveTo(0, terminal_rows.saturating_sub(1)),
        Clear(ClearType::CurrentLine)
    )?;
    write!(
        output,
        "{}",
        fit_line(
            &status_line(
                &render.width_mode,
                &render.tab_status,
                render.rows,
                render.cols,
            ),
            terminal_cols as usize,
        )
    )?;
    execute!(output, RestorePosition)?;
    output.flush().context("failed to flush terminal frame")?;
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct TabHitBox {
    tab_id: String,
    start_col: u16,
    end_col: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct TabBarLayout {
    text: String,
    hit_boxes: Vec<TabHitBox>,
}

fn tab_bar_layout(state: &v1::SessionState, selected_tab_id: &str) -> TabBarLayout {
    let mut text = String::from("Nudge ");
    let mut hit_boxes = Vec::new();
    for tab in &state.tabs {
        if text != "Nudge " {
            text.push(' ');
        }
        let start_col = char_count_as_u16(&text);
        if tab.id == selected_tab_id {
            text.push_str(&format!("[{}]", tab.title));
        } else {
            text.push_str(&format!(" {} ", tab.title));
        }
        let end_col = char_count_as_u16(&text);
        hit_boxes.push(TabHitBox {
            tab_id: tab.id.clone(),
            start_col,
            end_col,
        });
    }
    TabBarLayout { text, hit_boxes }
}

fn char_count_as_u16(text: &str) -> u16 {
    UnicodeWidthStr::width(text).min(u16::MAX as usize) as u16
}

fn clicked_tab_id(
    state: &v1::SessionState,
    selected_tab_id: &str,
    mouse: MouseEvent,
) -> Option<String> {
    if !matches!(mouse.kind, MouseEventKind::Down(_)) || mouse.row != 0 {
        return None;
    }
    tab_bar_layout(state, selected_tab_id)
        .hit_boxes
        .into_iter()
        .find(|hit_box| mouse.column >= hit_box.start_col && mouse.column < hit_box.end_col)
        .map(|hit_box| hit_box.tab_id)
}

fn status_line(width_mode: &str, tab_status: &str, rows: u32, cols: u32) -> String {
    format!(
        "Ctrl-g c new | x close | n/p switch | r rename | R restart | w width | d detach | status={tab_status} width={width_mode} size={rows}x{cols}"
    )
}

fn fit_line(line: &str, max_cols: usize) -> String {
    line.chars().take(max_cols).collect()
}

async fn handle_prefix_key(key: KeyEvent, selected_tab_id: &mut String) -> Result<bool> {
    match key.code {
        KeyCode::Char('n') => {
            select_relative_tab(selected_tab_id, 1).await?;
        }
        KeyCode::Char('p') => {
            select_relative_tab(selected_tab_id, -1).await?;
        }
        KeyCode::Char('c') => {
            let state = create_tab("shell").await?;
            if let Some(tab) = state.tabs.last() {
                *selected_tab_id = tab.id.clone();
                resize_selected_tab(selected_tab_id).await?;
            }
        }
        KeyCode::Char('x') => {
            let state = close_tab(selected_tab_id).await?;
            *selected_tab_id = state
                .tabs
                .first()
                .map(|tab| tab.id.clone())
                .context("daemon session has no tabs")?;
        }
        KeyCode::Char('r') => {
            rename_selected_tab(selected_tab_id).await?;
        }
        KeyCode::Char('R') => {
            restart_tab(selected_tab_id).await?;
            resize_selected_tab(selected_tab_id).await?;
        }
        KeyCode::Char('w') => {
            toggle_width_mode(selected_tab_id).await?;
        }
        KeyCode::Char('d') => return Ok(true),
        _ => {
            if let Some(bytes) = control_key_to_pty_bytes(key) {
                send_terminal_input(selected_tab_id, bytes).await?;
            }
        }
    }
    Ok(false)
}

fn is_prefix_key(key: KeyEvent) -> bool {
    key.modifiers.contains(KeyModifiers::CONTROL) && matches!(key.code, KeyCode::Char('g'))
}

fn should_detach(key: KeyEvent) -> bool {
    key.modifiers.contains(KeyModifiers::CONTROL) && matches!(key.code, KeyCode::Char('d'))
}

fn control_key_to_pty_bytes(key: KeyEvent) -> Option<Vec<u8>> {
    match key.code {
        KeyCode::Char(c) if c.is_ascii_alphabetic() => {
            let upper = c.to_ascii_uppercase() as u8;
            Some(vec![upper - b'A' + 1])
        }
        _ => None,
    }
}

fn key_to_pty_bytes(key: KeyEvent) -> Option<Vec<u8>> {
    match key.code {
        KeyCode::Char(c) => Some(c.to_string().into_bytes()),
        KeyCode::Enter => Some(b"\r".to_vec()),
        KeyCode::Backspace => Some(vec![0x7f]),
        KeyCode::Tab => Some(b"\t".to_vec()),
        KeyCode::Esc => Some(vec![0x1b]),
        KeyCode::Left => Some(b"\x1b[D".to_vec()),
        KeyCode::Right => Some(b"\x1b[C".to_vec()),
        KeyCode::Up => Some(b"\x1b[A".to_vec()),
        KeyCode::Down => Some(b"\x1b[B".to_vec()),
        KeyCode::Home => Some(b"\x1b[H".to_vec()),
        KeyCode::End => Some(b"\x1b[F".to_vec()),
        KeyCode::Delete => Some(b"\x1b[3~".to_vec()),
        _ => None,
    }
}

async fn get_session_state() -> Result<v1::SessionState> {
    let response =
        nudge_daemon::request(envelope(v1::envelope::Payload::GetState(v1::GetState {}))).await?;
    session_from_response(response)
}

async fn render_tab(tab_id: &str, state: &v1::SessionState) -> Result<ClientFrame> {
    let response = nudge_daemon::request(envelope(v1::envelope::Payload::TerminalRenderRequest(
        v1::TerminalRenderRequest {
            tab_id: tab_id.to_string(),
        },
    )))
    .await?;
    match response.payload {
        Some(v1::envelope::Payload::TerminalRender(render)) => Ok(ClientFrame {
            rows: render.rows,
            cols: render.cols,
            frame: render.frame,
            width_mode: render.width_mode,
            tab_status: state
                .tabs
                .iter()
                .find(|tab| tab.id == tab_id)
                .map(|tab| tab.status.clone())
                .unwrap_or_else(|| "unknown".to_string()),
        }),
        Some(v1::envelope::Payload::Error(error)) => {
            anyhow::bail!("daemon returned {}: {}", error.code, error.message);
        }
        _ => anyhow::bail!("daemon returned an unexpected render response"),
    }
}

async fn select_relative_tab(selected_tab_id: &mut String, delta: isize) -> Result<()> {
    let state = get_session_state().await?;
    if state.tabs.is_empty() {
        anyhow::bail!("daemon session has no tabs");
    }
    if let Some(index) = state.tabs.iter().position(|tab| tab.id == *selected_tab_id) {
        let tab_count = state.tabs.len() as isize;
        let next = (index as isize + delta).rem_euclid(tab_count) as usize;
        *selected_tab_id = state.tabs[next].id.clone();
        if !selected_tab_needs_restart(&state, selected_tab_id) {
            resize_selected_tab(selected_tab_id).await?;
        }
    }
    Ok(())
}

async fn create_tab(title: &str) -> Result<v1::SessionState> {
    let response =
        nudge_daemon::request(envelope(v1::envelope::Payload::CreateTab(v1::CreateTab {
            title: title.to_string(),
        })))
        .await?;
    session_from_response(response)
}

async fn close_tab(tab_id: &str) -> Result<v1::SessionState> {
    let response = nudge_daemon::request(envelope(v1::envelope::Payload::CloseTab(v1::CloseTab {
        tab_id: tab_id.to_string(),
    })))
    .await?;
    session_from_response(response)
}

async fn rename_selected_tab(tab_id: &str) -> Result<()> {
    let state = get_session_state().await?;
    let tab = state
        .tabs
        .iter()
        .find(|tab| tab.id == tab_id)
        .with_context(|| format!("tab {tab_id} was not found"))?;
    if let Some(title) = prompt_tab_title(&tab.title)? {
        if title != tab.title {
            let response =
                nudge_daemon::request(envelope(v1::envelope::Payload::RenameTab(v1::RenameTab {
                    tab_id: tab_id.to_string(),
                    title,
                })))
                .await?;
            let _ = session_from_response(response)?;
        }
    }
    Ok(())
}

fn prompt_tab_title(current_title: &str) -> Result<Option<String>> {
    let mut title = current_title.to_string();
    loop {
        draw_rename_prompt(&title)?;
        if let Event::Key(key) = event::read().context("failed to read rename prompt input")? {
            match key.code {
                KeyCode::Enter => {
                    let title = title.trim().to_string();
                    return Ok(if title.is_empty() { None } else { Some(title) });
                }
                KeyCode::Esc => return Ok(None),
                KeyCode::Backspace => {
                    title.pop();
                }
                KeyCode::Char('c') | KeyCode::Char('g')
                    if key.modifiers.contains(KeyModifiers::CONTROL) =>
                {
                    return Ok(None);
                }
                KeyCode::Char(character)
                    if key.modifiers.is_empty() || key.modifiers == KeyModifiers::SHIFT =>
                {
                    title.push(character);
                }
                _ => {}
            }
        }
    }
}

fn draw_rename_prompt(title: &str) -> Result<()> {
    let mut output = stdout();
    let (_, terminal_rows) = size().unwrap_or((80, 24));
    execute!(
        output,
        MoveTo(0, terminal_rows.saturating_sub(1)),
        Clear(ClearType::CurrentLine)
    )?;
    write!(output, "Rename tab: {title}")?;
    output.flush().context("failed to flush rename prompt")?;
    Ok(())
}

async fn restart_tab(tab_id: &str) -> Result<()> {
    let response = nudge_daemon::request(envelope(v1::envelope::Payload::RestartTab(
        v1::RestartTab {
            tab_id: tab_id.to_string(),
        },
    )))
    .await?;
    let _ = session_from_response(response)?;
    Ok(())
}

async fn toggle_width_mode(tab_id: &str) -> Result<()> {
    let state = get_session_state().await?;
    let tab = state
        .tabs
        .iter()
        .find(|tab| tab.id == tab_id)
        .with_context(|| format!("tab {tab_id} was not found"))?;
    let next_mode = if tab.width_mode == "phone" {
        "computer"
    } else {
        "phone"
    };
    let (cols, rows) = size().unwrap_or((80, 24));
    let response = nudge_daemon::request(envelope(v1::envelope::Payload::SetWidthMode(
        v1::SetWidthMode {
            tab_id: tab_id.to_string(),
            mode: next_mode.to_string(),
            computer_rows: rows.saturating_sub(2).max(1) as u32,
            computer_cols: cols as u32,
        },
    )))
    .await?;
    let _ = session_from_response(response)?;
    Ok(())
}

async fn send_terminal_input(tab_id: &str, data: Vec<u8>) -> Result<()> {
    let response = nudge_daemon::request(envelope(v1::envelope::Payload::TerminalInput(
        v1::TerminalInput {
            tab_id: tab_id.to_string(),
            data,
        },
    )))
    .await?;
    match response.payload {
        Some(v1::envelope::Payload::Ack(_)) => Ok(()),
        Some(v1::envelope::Payload::Error(error)) => {
            anyhow::bail!("daemon returned {}: {}", error.code, error.message);
        }
        _ => anyhow::bail!("daemon returned an unexpected input response"),
    }
}

fn selected_tab_needs_restart(state: &v1::SessionState, selected_tab_id: &str) -> bool {
    state
        .tabs
        .iter()
        .find(|tab| tab.id == selected_tab_id)
        .map(|tab| tab.status == "needs_restart")
        .unwrap_or(false)
}

async fn resize_selected_tab(tab_id: &str) -> Result<()> {
    let (cols, rows) = size().unwrap_or((80, 24));
    resize_tab(tab_id, rows.saturating_sub(2).max(1), cols).await
}

async fn resize_tab(tab_id: &str, rows: u16, cols: u16) -> Result<()> {
    let response =
        nudge_daemon::request(envelope(v1::envelope::Payload::ResizeTab(v1::ResizeTab {
            tab_id: tab_id.to_string(),
            rows: rows as u32,
            cols: cols as u32,
        })))
        .await?;
    match response.payload {
        Some(v1::envelope::Payload::Ack(_)) => Ok(()),
        Some(v1::envelope::Payload::Error(error)) => {
            anyhow::bail!("daemon returned {}: {}", error.code, error.message);
        }
        _ => anyhow::bail!("daemon returned an unexpected resize response"),
    }
}

fn print_session_response(response: v1::Envelope, ok_message: &str) -> Result<()> {
    match response.payload {
        Some(v1::envelope::Payload::SessionState(state)) => {
            println!("{ok_message}");
            print_session_state(&state);
            Ok(())
        }
        Some(v1::envelope::Payload::Error(error)) => {
            anyhow::bail!("daemon returned {}: {}", error.code, error.message);
        }
        _ => anyhow::bail!("daemon returned an unexpected session response"),
    }
}

async fn ensure_daemon() -> Result<()> {
    if nudge_daemon::ping_socket().await.is_ok() {
        return Ok(());
    }

    let current_exe = std::env::current_exe().context("failed to locate current executable")?;
    TokioCommand::new(current_exe)
        .args(["daemon", "run"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("failed to start nudge daemon")?;

    nudge_daemon::wait_for_socket(Duration::from_secs(3)).await
}

async fn print_daemon_status() -> Result<()> {
    let response = nudge_daemon::request(envelope(v1::envelope::Payload::DaemonStatusRequest(
        v1::DaemonStatusRequest {},
    )))
    .await?;
    match response.payload {
        Some(v1::envelope::Payload::DaemonStatus(status)) => {
            println!(
                "daemon socket={} state={} clients={} uptime={}s tabs={} plan={} relay_status={} relay_url={} relay_binding_id={} relay_last_error={} relay_connected_at={} relay_last_message_at={}",
                status.socket_path,
                status.state_path,
                status.connected_clients,
                status.uptime_seconds,
                status.tabs,
                status.plan,
                status.relay_status,
                status.relay_url,
                status.relay_binding_id,
                status.relay_last_error,
                status.relay_connected_at,
                status.relay_last_message_at
            );
            Ok(())
        }
        Some(v1::envelope::Payload::Error(error)) => {
            anyhow::bail!("daemon returned {}: {}", error.code, error.message);
        }
        _ => anyhow::bail!("daemon returned an unexpected status response"),
    }
}

async fn stop_daemon() -> Result<()> {
    let response = nudge_daemon::request(envelope(v1::envelope::Payload::StopDaemon(
        v1::StopDaemon {},
    )))
    .await?;
    match response.payload {
        Some(v1::envelope::Payload::Ack(ack)) => {
            println!("{}", ack.message);
            Ok(())
        }
        Some(v1::envelope::Payload::Error(error)) => {
            anyhow::bail!("daemon returned {}: {}", error.code, error.message);
        }
        _ => anyhow::bail!("daemon returned an unexpected stop response"),
    }
}

async fn service_install(dry_run: bool, no_start: bool, binary: Option<&Path>) -> Result<()> {
    let executable = match binary {
        Some(path) => path.to_path_buf(),
        None => std::env::current_exe().context("failed to locate current executable")?,
    };
    let service = ServiceSpec::detect(&executable)?;
    if dry_run {
        println!("nudge service install dry run");
        println!("platform={}", service.platform_name());
        println!("service_file={}", service.path.display());
        println!("binary={}", service.binary.display());
        println!("{}", service.contents);
        if !no_start {
            for command in service.install_commands() {
                let prefix = if command.ignore_failure {
                    "would try"
                } else {
                    "would run"
                };
                println!("{prefix}: {}", shell_words(&command));
            }
        }
        return Ok(());
    }

    if let Some(parent) = service.path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    fs::write(&service.path, service.contents.as_bytes())
        .with_context(|| format!("failed to write {}", service.path.display()))?;
    println!("service file installed at {}", service.path.display());

    if !no_start {
        for command in service.install_commands() {
            run_status_command(&command)?;
        }
    }
    Ok(())
}

async fn service_uninstall(dry_run: bool) -> Result<()> {
    let executable = std::env::current_exe().context("failed to locate current executable")?;
    let service = ServiceSpec::detect(&executable)?;
    if dry_run {
        println!("nudge service uninstall dry run");
        println!("platform={}", service.platform_name());
        println!("service_file={}", service.path.display());
        for command in service.uninstall_commands() {
            let prefix = if command.ignore_failure {
                "would try"
            } else {
                "would run"
            };
            println!("{prefix}: {}", shell_words(&command));
        }
        println!("would remove: {}", service.path.display());
        return Ok(());
    }

    for command in service.uninstall_commands() {
        let status = StdCommand::new(&command.program)
            .args(&command.args)
            .status()
            .with_context(|| format!("failed to run {}", shell_words(&command)))?;
        if !status.success() {
            eprintln!("command exited with {status}: {}", shell_words(&command));
        }
    }
    match fs::remove_file(&service.path) {
        Ok(()) => println!("removed {}", service.path.display()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            println!("service file already absent: {}", service.path.display());
        }
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to remove {}", service.path.display()));
        }
    }
    Ok(())
}

fn service_status() -> Result<()> {
    let executable = std::env::current_exe().context("failed to locate current executable")?;
    let service = ServiceSpec::detect(&executable)?;
    println!("platform={}", service.platform_name());
    println!("service_file={}", service.path.display());
    run_inherited_command(&service.status_command())
}

fn service_logs(lines: usize) -> Result<()> {
    let executable = std::env::current_exe().context("failed to locate current executable")?;
    let service = ServiceSpec::detect(&executable)?;
    run_inherited_command(&service.logs_command(lines))
}

async fn update_nudge(
    dry_run: bool,
    install_script_url: &str,
    version: Option<&str>,
    install_dir: Option<&Path>,
    skip_checksum: bool,
) -> Result<()> {
    let script = install_script_url.trim();
    if script.is_empty() {
        anyhow::bail!("install script URL cannot be empty");
    }
    let command = update_shell_command(script);
    if dry_run {
        println!("nudge update dry run");
        println!("install_script_url={script}");
        if let Some(version) = version {
            println!("NUDGE_VERSION={version}");
        }
        if let Some(install_dir) = install_dir {
            println!("NUDGE_INSTALL_DIR={}", install_dir.display());
        }
        if skip_checksum {
            println!("NUDGE_SKIP_CHECKSUM=1");
        }
        println!("command=sh -c {}", shell_quote(&command));
        return Ok(());
    }

    let mut process = TokioCommand::new("sh");
    process.arg("-c").arg(&command);
    if let Some(version) = version {
        process.env("NUDGE_VERSION", version);
    }
    if let Some(install_dir) = install_dir {
        process.env("NUDGE_INSTALL_DIR", install_dir);
    }
    if skip_checksum {
        process.env("NUDGE_SKIP_CHECKSUM", "1");
    }
    let status = process
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .await
        .context("failed to run update installer")?;
    if !status.success() {
        anyhow::bail!("update installer exited with {status}");
    }
    Ok(())
}

fn update_shell_command(script: &str) -> String {
    if script.starts_with("http://") || script.starts_with("https://") {
        format!(
            "if command -v curl >/dev/null 2>&1; then curl -fsSL {} | sh; elif command -v wget >/dev/null 2>&1; then wget -qO- {} | sh; else echo 'curl or wget is required to download {}' >&2; exit 1; fi",
            shell_quote(script),
            shell_quote(script),
            script.replace('\'', "'\\''"),
        )
    } else {
        format!("sh {}", shell_quote(script))
    }
}

#[derive(Debug, Clone, Copy)]
enum ServicePlatform {
    MacosLaunchd,
    LinuxSystemd,
}

#[derive(Debug, Clone)]
struct ServiceSpec {
    platform: ServicePlatform,
    path: PathBuf,
    binary: PathBuf,
    contents: String,
}

impl ServiceSpec {
    fn detect(binary: &Path) -> Result<Self> {
        let binary = binary.to_path_buf();
        let home = dirs::home_dir().context("failed to locate home directory")?;
        match std::env::consts::OS {
            "macos" => {
                let path = home
                    .join("Library")
                    .join("LaunchAgents")
                    .join("dev.nudgecode.nudge.daemon.plist");
                Ok(Self {
                    platform: ServicePlatform::MacosLaunchd,
                    contents: launchd_plist(&binary),
                    path,
                    binary,
                })
            }
            "linux" => {
                let path = home
                    .join(".config")
                    .join("systemd")
                    .join("user")
                    .join("nudge.service");
                Ok(Self {
                    platform: ServicePlatform::LinuxSystemd,
                    contents: systemd_unit(&binary),
                    path,
                    binary,
                })
            }
            other => anyhow::bail!("unsupported service platform: {other}"),
        }
    }

    fn platform_name(&self) -> &'static str {
        match self.platform {
            ServicePlatform::MacosLaunchd => "macos-launchd",
            ServicePlatform::LinuxSystemd => "linux-systemd-user",
        }
    }

    fn install_commands(&self) -> Vec<OsCommand> {
        match self.platform {
            ServicePlatform::MacosLaunchd => vec![
                OsCommand::new_optional(
                    "launchctl",
                    [
                        "bootout".to_string(),
                        format!("gui/{}", unsafe { libc_getuid() }),
                        self.path.display().to_string(),
                    ],
                ),
                OsCommand::new_required(
                    "launchctl",
                    [
                        "bootstrap".to_string(),
                        format!("gui/{}", unsafe { libc_getuid() }),
                        self.path.display().to_string(),
                    ],
                ),
                OsCommand::new_required(
                    "launchctl",
                    [
                        "kickstart".to_string(),
                        "-k".to_string(),
                        format!("gui/{}/dev.nudgecode.nudge.daemon", unsafe {
                            libc_getuid()
                        }),
                    ],
                ),
            ],
            ServicePlatform::LinuxSystemd => vec![
                OsCommand::new_required("systemctl", ["--user", "daemon-reload"]),
                OsCommand::new_required(
                    "systemctl",
                    ["--user", "enable", "--now", "nudge.service"],
                ),
            ],
        }
    }

    fn uninstall_commands(&self) -> Vec<OsCommand> {
        match self.platform {
            ServicePlatform::MacosLaunchd => vec![OsCommand::new_optional(
                "launchctl",
                [
                    "bootout".to_string(),
                    format!("gui/{}", unsafe { libc_getuid() }),
                    self.path.display().to_string(),
                ],
            )],
            ServicePlatform::LinuxSystemd => vec![
                OsCommand::new_optional(
                    "systemctl",
                    ["--user", "disable", "--now", "nudge.service"],
                ),
                OsCommand::new_required("systemctl", ["--user", "daemon-reload"]),
            ],
        }
    }

    fn status_command(&self) -> OsCommand {
        match self.platform {
            ServicePlatform::MacosLaunchd => OsCommand::new_required(
                "launchctl",
                [
                    "print".to_string(),
                    format!("gui/{}/dev.nudgecode.nudge.daemon", unsafe {
                        libc_getuid()
                    }),
                ],
            ),
            ServicePlatform::LinuxSystemd => {
                OsCommand::new_required("systemctl", ["--user", "status", "nudge.service"])
            }
        }
    }

    fn logs_command(&self, lines: usize) -> OsCommand {
        match self.platform {
            ServicePlatform::MacosLaunchd => OsCommand::new_required(
                "tail",
                [
                    "-n".to_string(),
                    lines.to_string(),
                    launchd_log_path().display().to_string(),
                ],
            ),
            ServicePlatform::LinuxSystemd => OsCommand::new_required(
                "journalctl",
                [
                    "--user".to_string(),
                    "-u".to_string(),
                    "nudge.service".to_string(),
                    "-n".to_string(),
                    lines.to_string(),
                    "--no-pager".to_string(),
                ],
            ),
        }
    }
}

#[derive(Debug, Clone)]
struct OsCommand {
    program: String,
    args: Vec<String>,
    ignore_failure: bool,
}

impl OsCommand {
    fn new_required<I, S>(program: &str, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self {
            program: program.to_string(),
            args: args.into_iter().map(Into::into).collect(),
            ignore_failure: false,
        }
    }

    fn new_optional<I, S>(program: &str, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self {
            program: program.to_string(),
            args: args.into_iter().map(Into::into).collect(),
            ignore_failure: true,
        }
    }
}

fn run_status_command(command: &OsCommand) -> Result<()> {
    let status = StdCommand::new(&command.program)
        .args(&command.args)
        .status()
        .with_context(|| format!("failed to run {}", shell_words(command)))?;
    if !status.success() && !command.ignore_failure {
        anyhow::bail!("command exited with {status}: {}", shell_words(command));
    }
    Ok(())
}

fn run_inherited_command(command: &OsCommand) -> Result<()> {
    let status = StdCommand::new(&command.program)
        .args(&command.args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .with_context(|| format!("failed to run {}", shell_words(command)))?;
    if !status.success() {
        anyhow::bail!("command exited with {status}: {}", shell_words(command));
    }
    Ok(())
}

fn shell_words(command: &OsCommand) -> String {
    std::iter::once(command.program.as_str())
        .chain(command.args.iter().map(String::as_str))
        .map(shell_quote)
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_quote(value: &str) -> String {
    if value
        .chars()
        .all(|character| character.is_ascii_alphanumeric() || "-_./:@".contains(character))
    {
        value.to_string()
    } else {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
}

fn launchd_plist(binary: &Path) -> String {
    let binary = xml_escape(&binary.display().to_string());
    let stdout = xml_escape(&launchd_log_path().display().to_string());
    let stderr = xml_escape(&launchd_error_log_path().display().to_string());
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.nudgecode.nudge.daemon</string>
  <key>ProgramArguments</key>
  <array>
    <string>{binary}</string>
    <string>daemon</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
</dict>
</plist>
"#
    )
}

fn systemd_unit(binary: &Path) -> String {
    let binary = systemd_escape_path(binary);
    format!(
        r#"[Unit]
Description=Nudge daemon
After=network-online.target

[Service]
ExecStart={binary} daemon run
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
"#
    )
}

fn launchd_log_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Library")
        .join("Logs")
        .join("nudge.log")
}

fn launchd_error_log_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Library")
        .join("Logs")
        .join("nudge.err.log")
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn systemd_escape_path(path: &Path) -> String {
    let path = path.display().to_string();
    if path.contains(char::is_whitespace) {
        format!("\"{}\"", path.replace('"', "\\\""))
    } else {
        path
    }
}

#[cfg(unix)]
unsafe fn libc_getuid() -> u32 {
    unsafe extern "C" {
        fn getuid() -> u32;
    }
    unsafe { getuid() }
}

fn print_session_state(state: &v1::SessionState) {
    let plan = state
        .entitlement
        .as_ref()
        .map(|entitlement| entitlement.plan.as_str())
        .unwrap_or("unknown");
    println!("session tabs={} plan={}", state.tabs.len(), plan);
    for tab in &state.tabs {
        println!(
            "tab id={} title={} status={} width_mode={} size={}x{} agent_kind={} agent_state={} agent_confidence={:.2}",
            tab.id,
            tab.title,
            tab.status,
            tab.width_mode,
            tab.rows,
            tab.cols,
            tab.agent_status
                .as_ref()
                .map(|status| status.kind.as_str())
                .unwrap_or("unknown"),
            tab.agent_status
                .as_ref()
                .map(|status| status.state.as_str())
                .unwrap_or("unknown"),
            tab.agent_status
                .as_ref()
                .map(|status| status.confidence)
                .unwrap_or_default()
        );
    }
}

fn envelope(payload: v1::envelope::Payload) -> v1::Envelope {
    v1::Envelope {
        message_id: format!("msg-{}", now_millis()),
        payload: Some(payload),
    }
}

fn now_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::{MouseButton, MouseEventKind};

    fn test_state() -> v1::SessionState {
        v1::SessionState {
            tabs: vec![
                test_tab("tab-1", "one"),
                test_tab("tab-2", "two"),
                test_tab("tab-3", "three"),
            ],
            entitlement: None,
            phone_profile: None,
            binding: None,
        }
    }

    fn test_tab(id: &str, title: &str) -> v1::Tab {
        v1::Tab {
            id: id.to_string(),
            title: title.to_string(),
            status: "running".to_string(),
            width_mode: "computer".to_string(),
            rows: 24,
            cols: 80,
            agent_status: None,
        }
    }

    fn mouse_down(column: u16, row: u16) -> MouseEvent {
        MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column,
            row,
            modifiers: KeyModifiers::NONE,
        }
    }

    #[test]
    fn tab_bar_layout_exposes_clickable_hit_boxes() {
        let layout = tab_bar_layout(&test_state(), "tab-2");

        assert_eq!(layout.text, "Nudge  one  [two]  three ");
        assert_eq!(
            layout.hit_boxes,
            vec![
                TabHitBox {
                    tab_id: "tab-1".to_string(),
                    start_col: 6,
                    end_col: 11,
                },
                TabHitBox {
                    tab_id: "tab-2".to_string(),
                    start_col: 12,
                    end_col: 17,
                },
                TabHitBox {
                    tab_id: "tab-3".to_string(),
                    start_col: 18,
                    end_col: 25,
                },
            ]
        );
    }

    #[test]
    fn clicked_tab_id_selects_tab_from_top_row_only() {
        let state = test_state();

        assert_eq!(
            clicked_tab_id(&state, "tab-2", mouse_down(13, 0)),
            Some("tab-2".to_string())
        );
        assert_eq!(clicked_tab_id(&state, "tab-2", mouse_down(13, 1)), None);
        assert_eq!(clicked_tab_id(&state, "tab-2", mouse_down(5, 0)), None);
    }

    #[test]
    fn status_line_documents_rename_and_restart_keys() {
        let line = status_line("computer", "running", 24, 80);

        assert!(line.contains("r rename"));
        assert!(line.contains("R restart"));
    }
}
