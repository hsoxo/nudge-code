use std::io::{Write, stdout};
use std::process::Stdio;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use crossterm::cursor::{Hide, MoveTo, Show};
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{
    Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode,
    enable_raw_mode, size,
};
use nudge_daemon::{BindingState, BindingStatus, DaemonConfig};
use nudge_protocol::v1;
use serde::{Deserialize, Serialize};
use tokio::process::Command as TokioCommand;

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
enum BindCommand {
    /// Start phone binding and print the pairing code.
    Phone {
        /// Relay HTTP base URL.
        #[arg(long, default_value = "http://127.0.0.1:8787")]
        relay_url: String,
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
        Some(Command::Bind { command }) => match command {
            BindCommand::Phone { relay_url } => bind_phone(&relay_url).await?,
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
    let mut last_frame = String::new();

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
                Event::Key(key) if should_detach(key) => break,
                Event::Key(key) if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    handle_control_key(key, &mut selected_tab_id).await?;
                    last_frame.clear();
                }
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

async fn bind_phone(relay_url: &str) -> Result<()> {
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

    let client = reqwest::Client::new();
    let daemon_device = register_device(
        &client,
        &relay_url,
        "daemon",
        &format!("nudge-daemon-dev-key-{}", now_millis()),
    )
    .await?;
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
    println!(
        "pairing_url={}/pair?code={}",
        binding.relay_url, binding.code
    );
    println!("expires_at={}", binding.expires_at);
    println!("waiting for phone claim; computer confirmation is required after claim");
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
    let binding_response = post_json::<ConfirmBindingRequest, BindingResponse>(
        &client,
        &relay_url,
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
    active.relay_url = relay_url;
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
        execute!(stdout(), EnterAlternateScreen, Hide, Clear(ClearType::All))
            .context("failed to enter alternate screen")?;
        Ok(Self)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = execute!(stdout(), Show, LeaveAlternateScreen);
        let _ = disable_raw_mode();
    }
}

struct ClientFrame {
    rows: u32,
    cols: u32,
    text: String,
    width_mode: String,
    tab_status: String,
}

impl ClientFrame {
    fn fingerprint(&self) -> String {
        format!(
            "{}:{}:{}:{}:{}",
            self.rows, self.cols, self.width_mode, self.tab_status, self.text
        )
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
    write!(output, "{}", tab_bar(state, selected_tab_id))?;
    let content_rows = terminal_rows.saturating_sub(2) as usize;
    for (index, line) in render.text.lines().take(content_rows).enumerate() {
        execute!(output, MoveTo(0, (index + 1) as u16))?;
        write!(output, "{}", fit_line(line, terminal_cols as usize))?;
    }
    execute!(output, MoveTo(0, terminal_rows.saturating_sub(1)))?;
    write!(
        output,
        "{}",
        status_line(
            &render.width_mode,
            &render.tab_status,
            render.rows,
            render.cols,
        )
    )?;
    output.flush().context("failed to flush terminal frame")?;
    Ok(())
}

fn tab_bar(state: &v1::SessionState, selected_tab_id: &str) -> String {
    let mut parts = Vec::new();
    for tab in &state.tabs {
        if tab.id == selected_tab_id {
            parts.push(format!("[{}]", tab.title));
        } else {
            parts.push(format!(" {} ", tab.title));
        }
    }
    format!("Nudge {}", parts.join(" "))
}

fn status_line(width_mode: &str, tab_status: &str, rows: u32, cols: u32) -> String {
    format!(
        "Ctrl-d detach | Ctrl-r restart | Ctrl-n next | Ctrl-p previous | status={tab_status} width={width_mode} size={rows}x{cols}"
    )
}

fn fit_line(line: &str, max_cols: usize) -> String {
    line.chars().take(max_cols).collect()
}

async fn handle_control_key(key: KeyEvent, selected_tab_id: &mut String) -> Result<()> {
    match key.code {
        KeyCode::Char('n') => {
            let state = get_session_state().await?;
            if let Some(index) = state.tabs.iter().position(|tab| tab.id == *selected_tab_id) {
                let next = (index + 1) % state.tabs.len();
                *selected_tab_id = state.tabs[next].id.clone();
                if !selected_tab_needs_restart(&state, selected_tab_id) {
                    resize_selected_tab(selected_tab_id).await?;
                }
            }
        }
        KeyCode::Char('p') => {
            let state = get_session_state().await?;
            if let Some(index) = state.tabs.iter().position(|tab| tab.id == *selected_tab_id) {
                let next = if index == 0 {
                    state.tabs.len() - 1
                } else {
                    index - 1
                };
                *selected_tab_id = state.tabs[next].id.clone();
                if !selected_tab_needs_restart(&state, selected_tab_id) {
                    resize_selected_tab(selected_tab_id).await?;
                }
            }
        }
        KeyCode::Char('r') => {
            restart_tab(selected_tab_id).await?;
            resize_selected_tab(selected_tab_id).await?;
        }
        _ => {
            if let Some(bytes) = control_key_to_pty_bytes(key) {
                send_terminal_input(selected_tab_id, bytes).await?;
            }
        }
    }
    Ok(())
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
    let response = nudge_daemon::request(envelope(v1::envelope::Payload::TerminalSnapshotRequest(
        v1::TerminalSnapshotRequest {
            tab_id: tab_id.to_string(),
        },
    )))
    .await?;
    match response.payload {
        Some(v1::envelope::Payload::TerminalSnapshot(snapshot)) => Ok(ClientFrame {
            rows: snapshot.rows,
            cols: snapshot.cols,
            text: snapshot.text,
            width_mode: state
                .tabs
                .iter()
                .find(|tab| tab.id == tab_id)
                .map(|tab| tab.width_mode.clone())
                .unwrap_or_else(|| "computer".to_string()),
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
        _ => anyhow::bail!("daemon returned an unexpected snapshot response"),
    }
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
