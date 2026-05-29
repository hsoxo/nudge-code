use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use nudge_protocol::v1;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone)]
pub struct DaemonConfig {
    pub placeholder: bool,
}

#[derive(Debug, Clone)]
pub struct StateStore {
    path: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MachineSession {
    pub id: String,
    pub tabs: Vec<TerminalTab>,
    pub entitlement: Entitlement,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalTab {
    pub id: String,
    pub title: String,
    pub status: TabStatus,
    pub created_at: String,
    pub last_activity_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TabStatus {
    Running,
    Exited,
    NeedsAttention,
    NeedsRestart,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entitlement {
    pub plan: String,
    pub max_bound_computers: u32,
    pub max_tabs_per_computer: u32,
    pub updated_at: String,
}

#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error("free entitlement allows {max} tab; close a tab or upgrade to create more")]
    TabLimitReached { max: u32 },
}

impl StateStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn default_path() -> Result<PathBuf> {
        let data_dir = dirs::home_dir()
            .context("failed to locate home directory")?
            .join(".nudge")
            .join("state");
        Ok(data_dir.join("session.json"))
    }

    pub fn from_env_or_default() -> Result<Self> {
        let path = match std::env::var_os("NUDGE_STATE_PATH") {
            Some(path) => PathBuf::from(path),
            None => Self::default_path()?,
        };
        Ok(Self::new(path))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load_or_create(&self) -> Result<MachineSession> {
        if self.path.exists() {
            let bytes = fs::read(&self.path)
                .with_context(|| format!("failed to read {}", self.path.display()))?;
            let session = serde_json::from_slice(&bytes)
                .with_context(|| format!("failed to parse {}", self.path.display()))?;
            return Ok(session);
        }

        let session = MachineSession::new_default();
        self.save(&session)?;
        Ok(session)
    }

    pub fn save(&self, session: &MachineSession) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        let bytes = serde_json::to_vec_pretty(session)?;
        fs::write(&self.path, bytes)
            .with_context(|| format!("failed to write {}", self.path.display()))?;
        Ok(())
    }
}

impl MachineSession {
    pub fn new_default() -> Self {
        let now = now_string();
        Self {
            id: "default".to_string(),
            tabs: vec![TerminalTab::new("default".to_string(), "shell".to_string())],
            entitlement: Entitlement::free(),
            created_at: now.clone(),
            updated_at: now,
        }
    }

    pub fn create_tab(&mut self, title: String) -> std::result::Result<&TerminalTab, SessionError> {
        let max_tabs = self.entitlement.max_tabs_per_computer as usize;
        if self.tabs.len() >= max_tabs {
            return Err(SessionError::TabLimitReached {
                max: self.entitlement.max_tabs_per_computer,
            });
        }

        let next_index = self.tabs.len() + 1;
        let tab = TerminalTab::new(format!("tab-{next_index}"), title);
        self.tabs.push(tab);
        self.updated_at = now_string();
        Ok(self.tabs.last().expect("tab was just pushed"))
    }

    pub fn to_proto(&self) -> v1::SessionState {
        v1::SessionState {
            tabs: self.tabs.iter().map(TerminalTab::to_proto).collect(),
            entitlement: Some(self.entitlement.to_proto()),
        }
    }
}

impl TerminalTab {
    pub fn new(id: String, title: String) -> Self {
        let now = now_string();
        Self {
            id,
            title,
            status: TabStatus::Running,
            created_at: now.clone(),
            last_activity_at: now,
        }
    }

    pub fn to_proto(&self) -> v1::Tab {
        v1::Tab {
            id: self.id.clone(),
            title: self.title.clone(),
            status: self.status.as_str().to_string(),
        }
    }
}

impl TabStatus {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Exited => "exited",
            Self::NeedsAttention => "needs_attention",
            Self::NeedsRestart => "needs_restart",
        }
    }
}

impl Entitlement {
    pub fn free() -> Self {
        Self {
            plan: "free".to_string(),
            max_bound_computers: 1,
            max_tabs_per_computer: 1,
            updated_at: now_string(),
        }
    }

    pub fn to_proto(&self) -> v1::Entitlement {
        v1::Entitlement {
            plan: self.plan.clone(),
            max_bound_computers: self.max_bound_computers,
            max_tabs_per_computer: self.max_tabs_per_computer,
        }
    }
}

pub fn placeholder_state() -> v1::SessionState {
    MachineSession::new_default().to_proto()
}

pub fn load_session() -> Result<MachineSession> {
    StateStore::from_env_or_default()?.load_or_create()
}

pub fn create_tab(title: String) -> Result<MachineSession> {
    let store = StateStore::from_env_or_default()?;
    let mut session = store.load_or_create()?;
    session.create_tab(title)?;
    store.save(&session)?;
    Ok(session)
}

pub async fn run_placeholder(config: DaemonConfig) -> Result<()> {
    let store = StateStore::from_env_or_default()?;
    let session = store.load_or_create()?;
    let state = session.to_proto();
    println!(
        "nudge daemon placeholder running (placeholder={}, tabs={}, plan={}, state_path={})",
        config.placeholder,
        state.tabs.len(),
        state
            .entitlement
            .as_ref()
            .map(|entitlement| entitlement.plan.as_str())
            .unwrap_or("unknown"),
        store.path().display()
    );
    Ok(())
}

fn now_string() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn free_entitlement_allows_only_one_tab() {
        let mut session = MachineSession::new_default();
        let error = session
            .create_tab("second".to_string())
            .expect_err("second tab should be rejected for free entitlement");
        assert!(matches!(error, SessionError::TabLimitReached { max: 1 }));
    }

    #[test]
    fn default_session_matches_free_proto_entitlement() {
        let session = MachineSession::new_default();
        let proto = session.to_proto();
        assert_eq!(proto.tabs.len(), 1);
        assert_eq!(proto.entitlement, Some(nudge_protocol::free_entitlement()));
    }
}
