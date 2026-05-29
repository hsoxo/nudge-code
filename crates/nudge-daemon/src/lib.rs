use anyhow::Result;
use nudge_protocol::{free_entitlement, v1};

#[derive(Debug, Clone)]
pub struct DaemonConfig {
    pub placeholder: bool,
}

pub fn placeholder_state() -> v1::SessionState {
    v1::SessionState {
        tabs: vec![v1::Tab {
            id: "default".to_string(),
            title: "shell".to_string(),
            status: "running".to_string(),
        }],
        entitlement: Some(free_entitlement()),
    }
}

pub async fn run_placeholder(config: DaemonConfig) -> Result<()> {
    let state = placeholder_state();
    println!(
        "nudge daemon placeholder running (placeholder={}, tabs={}, plan={})",
        config.placeholder,
        state.tabs.len(),
        state
            .entitlement
            .as_ref()
            .map(|entitlement| entitlement.plan.as_str())
            .unwrap_or("unknown")
    );
    Ok(())
}
