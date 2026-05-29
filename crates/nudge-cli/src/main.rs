use anyhow::Result;
use clap::{Parser, Subcommand};
use nudge_daemon::DaemonConfig;

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
    /// Run daemon/server mode.
    Daemon {
        /// Start placeholder daemon logic for Phase 0 verification.
        #[arg(long)]
        placeholder: bool,
    },
    /// Print current placeholder entitlement.
    Entitlement,
    /// Print persisted session metadata.
    SessionState,
    /// Create a tab in the persisted session metadata.
    CreateTab {
        /// Tab title.
        #[arg(long, default_value = "shell")]
        title: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Some(Command::Daemon { placeholder }) => {
            nudge_daemon::run_placeholder(DaemonConfig { placeholder }).await?;
        }
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
            println!("nudge Phase 0 placeholder: interactive attach is implemented in Phase 3");
        }
    }

    Ok(())
}
