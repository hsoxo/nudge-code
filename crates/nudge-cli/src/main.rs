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
