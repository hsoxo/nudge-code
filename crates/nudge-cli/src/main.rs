use std::process::Stdio;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
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
            let session = nudge_daemon::load_session()?;
            println!(
                "session={} tabs={} plan={}",
                session.id,
                session.tabs.len(),
                session.entitlement.plan
            );
            for tab in session.tabs {
                println!(
                    "tab id={} title={} status={:?}",
                    tab.id, tab.title, tab.status
                );
            }
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
                    print_session_state(&state);
                    println!("attached to daemon; interactive terminal UI is next");
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
                "daemon socket={} state={} clients={} uptime={}s tabs={} plan={}",
                status.socket_path,
                status.state_path,
                status.connected_clients,
                status.uptime_seconds,
                status.tabs,
                status.plan
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
            "tab id={} title={} status={} width_mode={} size={}x{}",
            tab.id, tab.title, tab.status, tab.width_mode, tab.rows, tab.cols
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
