use std::process::Stdio;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use nudge_daemon::DaemonConfig;
use nudge_protocol::v1;
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

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Some(Command::Daemon {
            placeholder,
            command: None,
        }) => {
            nudge_daemon::run_server(DaemonConfig {
                placeholder,
                foreground: true,
            })
            .await?;
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
            let session = nudge_daemon::create_tab(title)?;
            println!("tab created; tabs={}", session.tabs.len());
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
            "tab id={} title={} status={}",
            tab.id, tab.title, tab.status
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
