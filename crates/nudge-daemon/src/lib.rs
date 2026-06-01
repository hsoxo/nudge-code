use std::collections::{BTreeMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use futures_util::{Sink, SinkExt, StreamExt};
use nudge_protocol::v1;
use nudge_pty::{PtyTab, TerminalSize};
use nudge_terminal::{TerminalGrid, TerminalSize as GridSize};
use prost::Message;
use reqwest::Client as HttpClient;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{Mutex, Notify, broadcast};
use tokio::task;
use tokio::time::{MissedTickBehavior, interval, sleep};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message as WebSocketMessage;
use url::Url;

mod e2e;

#[derive(Debug, Clone)]
pub struct DaemonConfig {
    pub placeholder: bool,
    pub foreground: bool,
}

#[derive(Debug, Clone)]
pub struct StateStore {
    path: PathBuf,
}

#[derive(Debug, Clone)]
struct DaemonAuditSink {
    path: PathBuf,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ApprovalAuditAction {
    Approve,
    Reject,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ApprovalAuditSource {
    LocalIpc,
    RelayControl,
}

#[derive(Debug, Serialize)]
struct ApprovalAuditEvent<'a> {
    timestamp: String,
    #[serde(rename = "type")]
    event_type: &'static str,
    tab_id: &'a str,
    agent_kind: &'static str,
    action: ApprovalAuditAction,
    source: ApprovalAuditSource,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MachineSession {
    pub id: String,
    pub tabs: Vec<TerminalTab>,
    pub entitlement: Entitlement,
    #[serde(default)]
    pub phone_profile: Option<PhoneProfile>,
    #[serde(default)]
    pub binding: Option<BindingState>,
    #[serde(default)]
    pub device_identity: Option<DeviceIdentity>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalTab {
    pub id: String,
    pub title: String,
    pub status: TabStatus,
    #[serde(default)]
    pub agent_status: AgentStatus,
    #[serde(default)]
    pub width_mode: WidthMode,
    #[serde(default = "default_rows")]
    pub rows: u16,
    #[serde(default = "default_cols")]
    pub cols: u16,
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

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum WidthMode {
    Computer,
    Phone,
}

impl Default for WidthMode {
    fn default() -> Self {
        Self::Computer
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AgentStatus {
    pub kind: AgentKind,
    pub state: AgentInteractionState,
    pub confidence: f64,
    pub source: AgentDetectionSource,
}

impl Default for AgentStatus {
    fn default() -> Self {
        Self {
            kind: AgentKind::Shell,
            state: AgentInteractionState::Running,
            confidence: 0.5,
            source: AgentDetectionSource::Heuristic,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentKind {
    Claude,
    Codex,
    Opencode,
    Openclaw,
    Shell,
    Unknown,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentInteractionState {
    Running,
    Idle,
    WaitingForInput,
    NeedsApproval,
    NeedsAttention,
    Exited,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentDetectionSource {
    Process,
    Screen,
    Title,
    Heuristic,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PhoneProfile {
    pub rows: u16,
    pub cols: u16,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BindingState {
    pub relay_url: String,
    pub daemon_device_id: String,
    pub binding_id: String,
    pub code: String,
    pub expires_at: String,
    pub status: BindingStatus,
    #[serde(default)]
    pub bound_phone_id: Option<String>,
    #[serde(default)]
    pub daemon_public_key: Option<String>,
    #[serde(default)]
    pub phone_public_key: Option<String>,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceIdentity {
    pub public_key: String,
    pub signing_key: String,
    pub created_at: String,
}

#[derive(Debug, Clone)]
pub struct DeviceKeyRotation {
    pub identity: DeviceIdentity,
    pub signed_at: String,
    pub nonce: String,
    pub signature: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BindingStatus {
    Pending,
    Active,
    Revoked,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelayConnectionState {
    pub status: RelayConnectionStatus,
    pub relay_url: String,
    pub binding_id: String,
    pub last_error: Option<String>,
    pub connected_at: Option<String>,
    pub last_message_at: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RelaySocketMessage {
    #[serde(rename = "type")]
    message_type: String,
    message: Option<RelayRoutedMessage>,
    error: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RelayRoutedMessage {
    id: String,
    from_device_id: String,
    payload: Value,
}

#[derive(Debug, Clone)]
struct TerminalChange {
    tab_id: String,
    /// Absolute start offset of `data` in the tab's byte stream (the grid's
    /// `total_bytes` before these bytes were applied), stamped under the grid
    /// lock so it stays coherent with snapshots.
    offset: u64,
    data: Vec<u8>,
}

#[derive(Debug, Clone)]
struct AgentStatusChange {
    tab_id: String,
    status: AgentStatus,
}

struct RelayE2ESession {
    keys: e2e::SessionKeys,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum RelayControlRequest {
    GetState {
        #[serde(rename = "requestId")]
        request_id: String,
    },
    TerminalSnapshot {
        #[serde(rename = "requestId")]
        request_id: String,
        #[serde(rename = "tabId")]
        tab_id: String,
    },
    TerminalOutput {
        #[serde(rename = "requestId")]
        request_id: String,
        #[serde(rename = "tabId")]
        tab_id: String,
        #[serde(rename = "maxBytes", default)]
        max_bytes: u32,
    },
    TerminalInput {
        #[serde(rename = "requestId")]
        request_id: String,
        #[serde(rename = "tabId")]
        tab_id: String,
        text: String,
        #[serde(default)]
        enter: bool,
    },
    SetPhoneProfile {
        #[serde(rename = "requestId")]
        request_id: String,
        rows: u32,
        cols: u32,
        /// Phone capability hint (Phase 4.1 Level A): when true, the daemon may
        /// stream live terminal deltas as a binary E2E plaintext instead of
        /// base64-in-JSON. Optional + `default` so it is backward compatible
        /// (legacy phones never send it → JSON) and forward compatible (an older
        /// daemon decoding a newer phone ignores the unknown field → JSON). Only
        /// honored when an E2E session is active.
        #[serde(rename = "supportsBinaryTerminal", default)]
        supports_binary_terminal: bool,
    },
    SetWidthMode {
        #[serde(rename = "requestId")]
        request_id: String,
        #[serde(rename = "tabId")]
        tab_id: String,
        mode: String,
        #[serde(rename = "computerRows")]
        computer_rows: u32,
        #[serde(rename = "computerCols")]
        computer_cols: u32,
    },
    SetFocusedTab {
        #[serde(rename = "requestId")]
        request_id: String,
        /// The tab the phone is currently viewing. `None` clears the focus, which
        /// reverts to streaming every tab (legacy phones never send this).
        #[serde(rename = "tabId", default)]
        tab_id: Option<String>,
    },
    CreateTab {
        #[serde(rename = "requestId")]
        request_id: String,
        title: String,
        /// Optional working directory the new tab's shell should start in.
        #[serde(default)]
        cwd: Option<String>,
        /// Optional agent to auto-launch: "shell" | "claude" | "codex".
        #[serde(default)]
        launch: Option<String>,
    },
    RenameTab {
        #[serde(rename = "requestId")]
        request_id: String,
        #[serde(rename = "tabId")]
        tab_id: String,
        title: String,
    },
    CloseTab {
        #[serde(rename = "requestId")]
        request_id: String,
        #[serde(rename = "tabId")]
        tab_id: String,
    },
    RestartTab {
        #[serde(rename = "requestId")]
        request_id: String,
        #[serde(rename = "tabId")]
        tab_id: String,
    },
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RelayConnectionStatus {
    Unbound,
    Connecting,
    Connected,
    Disconnected,
    Error,
}

impl Default for RelayConnectionState {
    fn default() -> Self {
        Self {
            status: RelayConnectionStatus::Unbound,
            relay_url: String::new(),
            binding_id: String::new(),
            last_error: None,
            connected_at: None,
            last_message_at: None,
        }
    }
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
    #[error("tab {tab_id} was not found")]
    TabNotFound { tab_id: String },
    #[error("cannot close the last tab in the session")]
    CannotCloseLastTab,
    #[error("phone profile is required before switching a tab to phone width")]
    MissingPhoneProfile,
    #[error("unsupported width mode {mode}")]
    UnsupportedWidthMode { mode: String },
    #[error("unsupported binding status {status}")]
    UnsupportedBindingStatus { status: String },
    #[error("relay binding was revoked")]
    RelayBindingRevoked,
}

#[derive(Debug, thiserror::Error)]
pub enum IpcError {
    #[error("message frame is too large: {0} bytes")]
    FrameTooLarge(usize),
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
            let mut session: MachineSession = serde_json::from_slice(&bytes)
                .with_context(|| format!("failed to parse {}", self.path.display()))?;
            let identity_changed = session.ensure_device_identity()?;
            let mut dirty = identity_changed;
            dirty |= session.apply_entitlement_override_if_changed();
            if dirty {
                self.save(&session)?;
            } else {
                self.secure_file_permissions()?;
            }
            return Ok(session);
        }

        let mut session = MachineSession::new_default();
        session.ensure_device_identity()?;
        session.apply_entitlement_override();
        self.save(&session)?;
        Ok(session)
    }

    pub fn load_or_create_with_status(&self) -> Result<(MachineSession, bool)> {
        if self.path.exists() {
            let bytes = fs::read(&self.path)
                .with_context(|| format!("failed to read {}", self.path.display()))?;
            let mut session: MachineSession = serde_json::from_slice(&bytes)
                .with_context(|| format!("failed to parse {}", self.path.display()))?;
            let identity_changed = session.ensure_device_identity()?;
            let mut dirty = identity_changed;
            dirty |= session.apply_entitlement_override_if_changed();
            if dirty {
                self.save(&session)?;
            } else {
                self.secure_file_permissions()?;
            }
            return Ok((session, true));
        }

        let mut session = MachineSession::new_default();
        session.ensure_device_identity()?;
        session.apply_entitlement_override();
        self.save(&session)?;
        Ok((session, false))
    }

    pub fn save(&self, session: &MachineSession) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            let parent_existed = parent.exists();
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
            if !parent_existed {
                fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).with_context(
                    || format!("failed to set permissions on {}", parent.display()),
                )?;
            }
        }
        let bytes = serde_json::to_vec_pretty(session)?;
        let mut file = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(0o600)
            .open(&self.path)
            .with_context(|| format!("failed to open {}", self.path.display()))?;
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to set permissions on {}", self.path.display()))?;
        file.write_all(&bytes)
            .with_context(|| format!("failed to write {}", self.path.display()))?;
        Ok(())
    }

    fn secure_file_permissions(&self) -> Result<()> {
        fs::set_permissions(&self.path, fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to set permissions on {}", self.path.display()))
    }
}

impl DaemonAuditSink {
    fn from_env() -> Option<Self> {
        std::env::var_os("NUDGE_DAEMON_AUDIT_PATH").map(|path| Self {
            path: PathBuf::from(path),
        })
    }

    fn write_approval_action(
        &self,
        tab_id: &str,
        agent_status: &AgentStatus,
        action: ApprovalAuditAction,
        source: ApprovalAuditSource,
    ) -> Result<()> {
        if let Some(parent) = self
            .path
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
        {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        let event = ApprovalAuditEvent {
            timestamp: now_string(),
            event_type: "approval_action",
            tab_id,
            agent_kind: agent_status.kind.as_str(),
            action,
            source,
        };
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(&self.path)
            .with_context(|| format!("failed to open {}", self.path.display()))?;
        file.write_all(serde_json::to_string(&event)?.as_bytes())
            .with_context(|| format!("failed to write {}", self.path.display()))?;
        file.write_all(b"\n")
            .with_context(|| format!("failed to write {}", self.path.display()))?;
        fs::set_permissions(&self.path, fs::Permissions::from_mode(0o600))
            .with_context(|| format!("failed to secure {}", self.path.display()))?;
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
            phone_profile: None,
            binding: None,
            device_identity: None,
            created_at: now.clone(),
            updated_at: now,
        }
    }

    pub fn ensure_device_identity(&mut self) -> Result<bool> {
        if self.device_identity.is_some() {
            return Ok(false);
        }
        self.device_identity = Some(DeviceIdentity::generate()?);
        self.updated_at = now_string();
        Ok(true)
    }

    pub fn device_identity(&mut self) -> Result<&DeviceIdentity> {
        self.ensure_device_identity()?;
        self.device_identity
            .as_ref()
            .context("device identity should exist")
    }

    pub fn rotate_device_identity(&mut self, identity: DeviceIdentity) -> Result<DeviceIdentity> {
        self.ensure_device_identity()?;
        let previous = self
            .device_identity
            .replace(identity.clone())
            .context("device identity is required before rotation")?;
        if let Some(binding) = self.binding.as_mut() {
            binding.daemon_public_key = Some(identity.public_key.clone());
            binding.updated_at = now_string();
        }
        self.updated_at = now_string();
        Ok(previous)
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

    pub fn rename_tab(
        &mut self,
        tab_id: &str,
        title: String,
    ) -> std::result::Result<(), SessionError> {
        let tab = self
            .tabs
            .iter_mut()
            .find(|tab| tab.id == tab_id)
            .ok_or_else(|| SessionError::TabNotFound {
                tab_id: tab_id.to_string(),
            })?;
        tab.title = title;
        tab.last_activity_at = now_string();
        self.updated_at = now_string();
        Ok(())
    }

    pub fn close_tab(&mut self, tab_id: &str) -> std::result::Result<(), SessionError> {
        if self.tabs.len() <= 1 {
            return Err(SessionError::CannotCloseLastTab);
        }
        let index = self
            .tabs
            .iter()
            .position(|tab| tab.id == tab_id)
            .ok_or_else(|| SessionError::TabNotFound {
                tab_id: tab_id.to_string(),
            })?;
        self.tabs.remove(index);
        self.updated_at = now_string();
        Ok(())
    }

    pub fn mark_all_tabs_needs_restart(&mut self) {
        let now = now_string();
        for tab in &mut self.tabs {
            tab.status = TabStatus::NeedsRestart;
            tab.last_activity_at = now.clone();
        }
        self.updated_at = now;
    }

    pub fn mark_tab_running(&mut self, tab_id: &str) -> std::result::Result<(), SessionError> {
        let tab = self
            .tabs
            .iter_mut()
            .find(|tab| tab.id == tab_id)
            .ok_or_else(|| SessionError::TabNotFound {
                tab_id: tab_id.to_string(),
            })?;
        tab.status = TabStatus::Running;
        tab.last_activity_at = now_string();
        self.updated_at = now_string();
        Ok(())
    }

    pub fn set_phone_profile(&mut self, rows: u16, cols: u16) {
        self.phone_profile = Some(PhoneProfile {
            rows,
            cols,
            updated_at: now_string(),
        });
        // Phone-first: once the phone reports its size, size every tab to it so
        // tabs default to (and stay at) the phone's width instead of computer width.
        let now = now_string();
        for tab in self.tabs.iter_mut() {
            tab.width_mode = WidthMode::Phone;
            tab.rows = rows;
            tab.cols = cols;
            tab.last_activity_at = now.clone();
        }
        self.updated_at = now;
    }

    pub fn set_width_mode(
        &mut self,
        tab_id: &str,
        mode: WidthMode,
        computer_size: TerminalSize,
    ) -> std::result::Result<TerminalSize, SessionError> {
        let target_size = match mode {
            WidthMode::Computer => computer_size,
            WidthMode::Phone => {
                let phone_profile = self
                    .phone_profile
                    .as_ref()
                    .ok_or(SessionError::MissingPhoneProfile)?;
                TerminalSize {
                    rows: phone_profile.rows,
                    cols: phone_profile.cols,
                }
            }
        };
        let tab = self
            .tabs
            .iter_mut()
            .find(|tab| tab.id == tab_id)
            .ok_or_else(|| SessionError::TabNotFound {
                tab_id: tab_id.to_string(),
            })?;
        tab.width_mode = mode;
        tab.rows = target_size.rows;
        tab.cols = target_size.cols;
        tab.last_activity_at = now_string();
        self.updated_at = now_string();
        Ok(target_size)
    }

    pub fn set_binding(&mut self, binding: BindingState) {
        self.binding = Some(binding);
        self.updated_at = now_string();
    }

    /// Apply the local/dev paid override (env `NUDGE_DAEMON_PLAN`) to this
    /// session if it is set, so a dev daemon is paid even before the relay
    /// reports an entitlement. No-op in production (variable unset).
    pub fn apply_entitlement_override(&mut self) {
        let _ = self.apply_entitlement_override_if_changed();
    }

    /// Like [`Self::apply_entitlement_override`] but returns `true` only when
    /// the override actually raised the entitlement, so callers can avoid an
    /// unnecessary state-file write on load.
    pub fn apply_entitlement_override_if_changed(&mut self) -> bool {
        let Some(entitlement) = entitlement_override() else {
            return false;
        };
        if self.entitlement.plan == entitlement.plan
            && self.entitlement.max_tabs_per_computer == entitlement.max_tabs_per_computer
            && self.entitlement.max_bound_computers == entitlement.max_bound_computers
        {
            return false;
        }
        self.entitlement = entitlement;
        self.updated_at = now_string();
        true
    }

    pub fn set_entitlement(&mut self, mut entitlement: Entitlement) -> Vec<String> {
        // Dev override wins: never downgrade a locally-paid daemon below the
        // override when the relay reports a smaller (e.g. FREE) entitlement.
        if let Some(override_entitlement) = entitlement_override() {
            entitlement = override_entitlement;
        }
        let allowed_tabs = entitlement.max_tabs_per_computer.max(1) as usize;
        let now = now_string();
        let mut suspended_tab_ids = Vec::new();
        for tab in self.tabs.iter_mut().skip(allowed_tabs) {
            suspended_tab_ids.push(tab.id.clone());
            if !matches!(tab.status, TabStatus::NeedsRestart) {
                tab.status = TabStatus::NeedsRestart;
                tab.agent_status = AgentStatus {
                    kind: AgentKind::Unknown,
                    state: AgentInteractionState::Exited,
                    confidence: 0.6,
                    source: AgentDetectionSource::Heuristic,
                };
                tab.last_activity_at = now.clone();
            }
        }
        self.entitlement = entitlement;
        self.updated_at = now;
        suspended_tab_ids
    }

    pub fn clear_binding(&mut self) {
        self.binding = None;
        self.updated_at = now_string();
    }

    pub fn to_proto(&self) -> v1::SessionState {
        v1::SessionState {
            tabs: self.tabs.iter().map(TerminalTab::to_proto).collect(),
            entitlement: Some(self.entitlement.to_proto()),
            phone_profile: self.phone_profile.as_ref().map(PhoneProfile::to_proto),
            binding: self.binding.as_ref().map(BindingState::to_proto),
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
            agent_status: AgentStatus::default(),
            width_mode: WidthMode::Computer,
            rows: 24,
            cols: 80,
            created_at: now.clone(),
            last_activity_at: now,
        }
    }

    pub fn to_proto(&self) -> v1::Tab {
        v1::Tab {
            id: self.id.clone(),
            title: self.title.clone(),
            status: self.status.as_str().to_string(),
            width_mode: self.width_mode.as_str().to_string(),
            rows: self.rows as u32,
            cols: self.cols as u32,
            agent_status: Some(self.agent_status.to_proto()),
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

impl WidthMode {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Computer => "computer",
            Self::Phone => "phone",
        }
    }
}

impl AgentStatus {
    pub fn to_proto(&self) -> v1::AgentStatus {
        v1::AgentStatus {
            kind: self.kind.as_str().to_string(),
            state: self.state.as_str().to_string(),
            confidence: self.confidence,
            source: self.source.as_str().to_string(),
        }
    }
}

impl AgentKind {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Opencode => "opencode",
            Self::Openclaw => "openclaw",
            Self::Shell => "shell",
            Self::Unknown => "unknown",
        }
    }
}

impl AgentInteractionState {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Idle => "idle",
            Self::WaitingForInput => "waiting_for_input",
            Self::NeedsApproval => "needs_approval",
            Self::NeedsAttention => "needs_attention",
            Self::Exited => "exited",
        }
    }
}

impl AgentDetectionSource {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Process => "process",
            Self::Screen => "screen",
            Self::Title => "title",
            Self::Heuristic => "heuristic",
            Self::Unknown => "unknown",
        }
    }
}

impl std::str::FromStr for WidthMode {
    type Err = SessionError;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        match value {
            "computer" => Ok(Self::Computer),
            "phone" => Ok(Self::Phone),
            other => Err(SessionError::UnsupportedWidthMode {
                mode: other.to_string(),
            }),
        }
    }
}

impl PhoneProfile {
    pub fn to_proto(&self) -> v1::PhoneProfile {
        v1::PhoneProfile {
            rows: self.rows as u32,
            cols: self.cols as u32,
        }
    }
}

impl BindingState {
    pub fn pending(
        relay_url: String,
        daemon_device_id: String,
        binding_id: String,
        code: String,
        expires_at: String,
    ) -> Self {
        Self {
            relay_url,
            daemon_device_id,
            binding_id,
            code,
            expires_at,
            status: BindingStatus::Pending,
            bound_phone_id: None,
            daemon_public_key: None,
            phone_public_key: None,
            updated_at: now_string(),
        }
    }

    pub fn active(mut self, bound_phone_id: String, phone_public_key: Option<String>) -> Self {
        self.status = BindingStatus::Active;
        self.bound_phone_id = Some(bound_phone_id);
        self.phone_public_key = phone_public_key;
        self.updated_at = now_string();
        self
    }

    pub fn revoked(mut self) -> Self {
        self.status = BindingStatus::Revoked;
        self.updated_at = now_string();
        self
    }

    pub fn to_proto(&self) -> v1::BindingState {
        v1::BindingState {
            relay_url: self.relay_url.clone(),
            daemon_device_id: self.daemon_device_id.clone(),
            binding_id: self.binding_id.clone(),
            code: self.code.clone(),
            expires_at: self.expires_at.clone(),
            status: self.status.as_str().to_string(),
            bound_phone_id: self.bound_phone_id.clone().unwrap_or_default(),
            daemon_public_key: self.daemon_public_key.clone().unwrap_or_default(),
            phone_public_key: self.phone_public_key.clone().unwrap_or_default(),
        }
    }
}

impl DeviceIdentity {
    pub fn generate() -> Result<Self> {
        let mut secret_key = [0u8; 32];
        getrandom::fill(&mut secret_key).context("failed to generate daemon signing key")?;
        let signing_key = SigningKey::from_bytes(&secret_key);
        Ok(Self::from_signing_key(&signing_key))
    }

    pub fn from_secret_key(secret_key: [u8; 32]) -> Self {
        let signing_key = SigningKey::from_bytes(&secret_key);
        Self::from_signing_key(&signing_key)
    }

    pub fn public_key(&self) -> &str {
        &self.public_key
    }

    pub fn sign(&self, message: &[u8]) -> Result<String> {
        let signing_key = SigningKey::from_bytes(&self.secret_key_bytes()?);
        Ok(BASE64_STANDARD.encode(signing_key.sign(message).to_bytes()))
    }

    pub fn verify(&self, message: &[u8], signature: &str) -> Result<()> {
        let verifying_key = VerifyingKey::from_bytes(&decode_fixed_base64::<32>(&self.public_key)?)
            .context("stored daemon public key is invalid")?;
        let signature_bytes: [u8; 64] = BASE64_STANDARD
            .decode(signature)?
            .try_into()
            .map_err(|_| anyhow::anyhow!("stored daemon signature must be 64 bytes"))?;
        let signature = Signature::from_bytes(&signature_bytes);
        verifying_key
            .verify(message, &signature)
            .context("daemon signature verification failed")
    }

    pub(crate) fn secret_key_bytes(&self) -> Result<[u8; 32]> {
        decode_fixed_base64::<32>(&self.signing_key).context("stored daemon signing key is invalid")
    }

    fn from_signing_key(signing_key: &SigningKey) -> Self {
        Self {
            public_key: BASE64_STANDARD.encode(signing_key.verifying_key().to_bytes()),
            signing_key: BASE64_STANDARD.encode(signing_key.to_bytes()),
            created_at: now_string(),
        }
    }
}

impl BindingStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Active => "active",
            Self::Revoked => "revoked",
        }
    }
}

impl RelayConnectionState {
    fn unbound() -> Self {
        Self::default()
    }

    fn connecting(binding: &BindingState) -> Self {
        Self {
            status: RelayConnectionStatus::Connecting,
            relay_url: binding.relay_url.clone(),
            binding_id: binding.binding_id.clone(),
            last_error: None,
            connected_at: None,
            last_message_at: None,
        }
    }

    fn connected(binding: &BindingState) -> Self {
        let now = now_string();
        Self {
            status: RelayConnectionStatus::Connected,
            relay_url: binding.relay_url.clone(),
            binding_id: binding.binding_id.clone(),
            last_error: None,
            connected_at: Some(now.clone()),
            last_message_at: Some(now),
        }
    }

    fn disconnected(binding: &BindingState) -> Self {
        Self {
            status: RelayConnectionStatus::Disconnected,
            relay_url: binding.relay_url.clone(),
            binding_id: binding.binding_id.clone(),
            last_error: None,
            connected_at: None,
            last_message_at: None,
        }
    }

    fn error(binding: &BindingState, error: String) -> Self {
        Self {
            status: RelayConnectionStatus::Error,
            relay_url: binding.relay_url.clone(),
            binding_id: binding.binding_id.clone(),
            last_error: Some(error),
            connected_at: None,
            last_message_at: None,
        }
    }
}

impl RelayConnectionStatus {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Unbound => "unbound",
            Self::Connecting => "connecting",
            Self::Connected => "connected",
            Self::Disconnected => "disconnected",
            Self::Error => "error",
        }
    }
}

impl std::str::FromStr for BindingStatus {
    type Err = SessionError;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        match value {
            "pending" => Ok(Self::Pending),
            "active" => Ok(Self::Active),
            "revoked" => Ok(Self::Revoked),
            other => Err(SessionError::UnsupportedBindingStatus {
                status: other.to_string(),
            }),
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

    fn pro() -> Self {
        Self {
            plan: "pro".to_string(),
            max_bound_computers: 8,
            max_tabs_per_computer: 16,
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

fn entitlement_from_proto(entitlement: v1::Entitlement) -> Entitlement {
    Entitlement {
        plan: entitlement.plan,
        max_bound_computers: entitlement.max_bound_computers,
        max_tabs_per_computer: entitlement.max_tabs_per_computer,
        updated_at: now_string(),
    }
}

/// Local/dev escape hatch: when `NUDGE_DAEMON_PLAN` names a paid plan
/// (`pro`/`paid`/`max`, case-insensitive), the daemon behaves as paid
/// regardless of the entitlement the relay reports. Production leaves the
/// variable unset and stays on the FREE entitlement.
fn entitlement_override() -> Option<Entitlement> {
    let plan = std::env::var("NUDGE_DAEMON_PLAN").ok()?;
    match plan.trim().to_ascii_lowercase().as_str() {
        "pro" | "paid" | "max" => Some(Entitlement::pro()),
        _ => None,
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

pub fn rename_tab(tab_id: &str, title: String) -> Result<MachineSession> {
    let store = StateStore::from_env_or_default()?;
    let mut session = store.load_or_create()?;
    session.rename_tab(tab_id, title)?;
    store.save(&session)?;
    Ok(session)
}

pub fn close_tab(tab_id: &str) -> Result<MachineSession> {
    let store = StateStore::from_env_or_default()?;
    let mut session = store.load_or_create()?;
    session.close_tab(tab_id)?;
    store.save(&session)?;
    Ok(session)
}

pub fn save_binding_state(binding: BindingState) -> Result<MachineSession> {
    let store = StateStore::from_env_or_default()?;
    let mut session = store.load_or_create()?;
    session.set_binding(binding);
    store.save(&session)?;
    Ok(session)
}

pub fn clear_binding_state() -> Result<MachineSession> {
    let store = StateStore::from_env_or_default()?;
    let mut session = store.load_or_create()?;
    session.clear_binding();
    store.save(&session)?;
    Ok(session)
}

fn binding_from_proto(binding: v1::BindingState) -> Result<BindingState> {
    let bound_phone_id = if binding.bound_phone_id.is_empty() {
        None
    } else {
        Some(binding.bound_phone_id)
    };
    Ok(BindingState {
        relay_url: binding.relay_url,
        daemon_device_id: binding.daemon_device_id,
        binding_id: binding.binding_id,
        code: binding.code,
        expires_at: binding.expires_at,
        status: binding.status.parse()?,
        bound_phone_id,
        daemon_public_key: if binding.daemon_public_key.is_empty() {
            None
        } else {
            Some(binding.daemon_public_key)
        },
        phone_public_key: if binding.phone_public_key.is_empty() {
            None
        } else {
            Some(binding.phone_public_key)
        },
        updated_at: now_string(),
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ProcessSignal {
    command: String,
    pid: Option<u32>,
}

impl ProcessSignal {
    fn new(command: impl Into<String>, pid: Option<u32>) -> Self {
        Self {
            command: command.into(),
            pid,
        }
    }
}

fn detect_agent_status(
    title: &str,
    screen_text: &str,
    process_signal: Option<&ProcessSignal>,
    tab_status: &TabStatus,
) -> AgentStatus {
    if matches!(tab_status, TabStatus::Exited | TabStatus::NeedsRestart) {
        return AgentStatus {
            kind: AgentKind::Unknown,
            state: AgentInteractionState::Exited,
            confidence: 0.6,
            source: AgentDetectionSource::Heuristic,
        };
    }

    let process = process_signal.map(|signal| signal.command.to_lowercase());
    let title_lower = title.to_lowercase();
    let text_lower = screen_text.to_lowercase();
    let combined = format!("{title_lower}\n{text_lower}");
    let (kind, source, mut confidence): (AgentKind, AgentDetectionSource, f64) = if process
        .as_deref()
        .is_some_and(|name| is_command_name(name, &["claude"]))
    {
        (AgentKind::Claude, AgentDetectionSource::Process, 0.9)
    } else if process
        .as_deref()
        .is_some_and(|name| is_command_name(name, &["codex"]))
    {
        (AgentKind::Codex, AgentDetectionSource::Process, 0.9)
    } else if process
        .as_deref()
        .is_some_and(|name| is_command_name(name, &["opencode"]))
    {
        (AgentKind::Opencode, AgentDetectionSource::Process, 0.86)
    } else if process
        .as_deref()
        .is_some_and(|name| is_command_name(name, &["openclaw"]))
    {
        (AgentKind::Openclaw, AgentDetectionSource::Process, 0.86)
    } else if process
        .as_deref()
        .is_some_and(|name| is_shell_command_name(name))
    {
        (AgentKind::Shell, AgentDetectionSource::Process, 0.7)
    } else if contains_any(&title_lower, &["claude"]) {
        (AgentKind::Claude, AgentDetectionSource::Title, 0.78)
    } else if contains_any(&title_lower, &["codex"]) {
        (AgentKind::Codex, AgentDetectionSource::Title, 0.78)
    } else if contains_any(&title_lower, &["opencode"]) {
        (AgentKind::Opencode, AgentDetectionSource::Title, 0.72)
    } else if contains_any(&title_lower, &["openclaw"]) {
        (AgentKind::Openclaw, AgentDetectionSource::Title, 0.72)
    } else if contains_any(
        &text_lower,
        &["claude code", "claude>", "claude >", "anthropic"],
    ) {
        (AgentKind::Claude, AgentDetectionSource::Screen, 0.72)
    } else if contains_any(&text_lower, &["codex", "openai codex"]) {
        (AgentKind::Codex, AgentDetectionSource::Screen, 0.72)
    } else if contains_any(&text_lower, &["opencode"]) {
        (AgentKind::Opencode, AgentDetectionSource::Screen, 0.68)
    } else if contains_any(&text_lower, &["openclaw"]) {
        (AgentKind::Openclaw, AgentDetectionSource::Screen, 0.68)
    } else if looks_like_shell_prompt(&text_lower) {
        (AgentKind::Shell, AgentDetectionSource::Screen, 0.62)
    } else {
        (AgentKind::Unknown, AgentDetectionSource::Unknown, 0.3)
    };

    let state = if looks_like_approval_prompt(&combined) {
        confidence = confidence.max(0.82);
        AgentInteractionState::NeedsApproval
    } else if looks_like_waiting_prompt(&combined) {
        confidence = confidence.max(0.78);
        AgentInteractionState::WaitingForInput
    } else {
        AgentInteractionState::Running
    };

    AgentStatus {
        kind,
        state,
        confidence,
        source,
    }
}

fn contains_any(haystack: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| haystack.contains(needle))
}

fn looks_like_approval_prompt(text: &str) -> bool {
    contains_any(
        text,
        &[
            "approve?",
            "approval required",
            "allow this command",
            "allow command",
            "confirm command",
            "confirm this command",
            "do you want to proceed",
            "permission required",
            "requires permission",
            "needs your permission",
            "grant permission",
            "review permissions",
            "是否允许",
            "允许此命令",
            "需要你确认权限",
            "确认权限",
        ],
    )
}

fn looks_like_waiting_prompt(text: &str) -> bool {
    contains_any(
        text,
        &[
            "waiting for input",
            "waiting for user input",
            "press enter",
            "enter your prompt",
            "send a message",
            "type your message",
            "what would you like",
            "waiting for your response",
            "等待输入",
            "等待用户输入",
            "请输入",
            "输入你的提示",
        ],
    )
}

fn is_command_name(command_name: &str, expected_names: &[&str]) -> bool {
    let normalized = command_name
        .rsplit('/')
        .next()
        .unwrap_or(command_name)
        .trim_start_matches('-');
    expected_names
        .iter()
        .any(|expected| normalized == *expected || normalized.starts_with(&format!("{expected}-")))
}

fn is_shell_command_name(command_name: &str) -> bool {
    is_command_name(
        command_name,
        &["sh", "bash", "zsh", "fish", "nu", "xonsh", "elvish"],
    )
}

fn looks_like_shell_prompt(text: &str) -> bool {
    text.contains("$ ") || text.contains("% ") || text.contains("# ")
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ProcessEntry {
    pid: u32,
    parent_pid: u32,
    process_group: u32,
    foreground: bool,
    command: String,
}

fn foreground_process_signal(
    child_pid: Option<u32>,
    foreground_process_group: Option<u32>,
    fallback_command: Option<&str>,
) -> Option<ProcessSignal> {
    let fallback = fallback_command.map(|command| ProcessSignal::new(command, child_pid));
    let Some(child_pid) = child_pid else {
        return fallback;
    };
    let Ok(entries) = process_entries() else {
        return fallback;
    };
    process_signal_from_entries(child_pid, foreground_process_group, &entries).or(fallback)
}

fn process_signal_from_entries(
    root_pid: u32,
    foreground_process_group: Option<u32>,
    entries: &[ProcessEntry],
) -> Option<ProcessSignal> {
    let descendants = process_descendants(root_pid, entries);
    let direct_foreground_process_group = matching_foreground_process_group(
        root_pid,
        &descendants,
        entries,
        foreground_process_group,
    );
    let is_foreground = |entry: &ProcessEntry| match direct_foreground_process_group {
        Some(process_group) => entry.process_group == process_group,
        None => entry.foreground,
    };
    let foreground_signal = descendants
        .iter()
        .rev()
        .find(|entry| is_foreground(entry) && is_agent_command_name(&entry.command))
        .map(|entry| ProcessSignal::new(entry.command.clone(), Some(entry.pid)))
        .or_else(|| {
            descendants
                .iter()
                .rev()
                .find(|entry| is_foreground(entry) && !is_shell_command_name(&entry.command))
                .map(|entry| ProcessSignal::new(entry.command.clone(), Some(entry.pid)))
        })
        .or_else(|| {
            descendants
                .iter()
                .rev()
                .find(|entry| is_foreground(entry))
                .map(|entry| ProcessSignal::new(entry.command.clone(), Some(entry.pid)))
        });

    if let Some(process_group) = direct_foreground_process_group {
        return foreground_signal.or_else(|| {
            entries
                .iter()
                .find(|entry| entry.pid == root_pid && entry.process_group == process_group)
                .map(|entry| ProcessSignal::new(entry.command.clone(), Some(entry.pid)))
        });
    }

    foreground_signal
        .or_else(|| {
            descendants
                .iter()
                .rev()
                .find(|entry| is_agent_command_name(&entry.command))
                .map(|entry| ProcessSignal::new(entry.command.clone(), Some(entry.pid)))
        })
        .or_else(|| {
            descendants
                .iter()
                .rev()
                .find(|entry| !is_shell_command_name(&entry.command))
                .map(|entry| ProcessSignal::new(entry.command.clone(), Some(entry.pid)))
        })
        .or_else(|| {
            entries
                .iter()
                .find(|entry| entry.pid == root_pid)
                .map(|entry| ProcessSignal::new(entry.command.clone(), Some(entry.pid)))
        })
}

fn matching_foreground_process_group(
    root_pid: u32,
    descendants: &[ProcessEntry],
    entries: &[ProcessEntry],
    foreground_process_group: Option<u32>,
) -> Option<u32> {
    let foreground_process_group = foreground_process_group?;
    let root_matches = entries
        .iter()
        .any(|entry| entry.pid == root_pid && entry.process_group == foreground_process_group);
    let descendant_matches = descendants
        .iter()
        .any(|entry| entry.process_group == foreground_process_group);
    (root_matches || descendant_matches).then_some(foreground_process_group)
}

fn process_descendants(root_pid: u32, entries: &[ProcessEntry]) -> Vec<ProcessEntry> {
    let mut result = Vec::new();
    let mut stack = vec![root_pid];
    while let Some(parent_pid) = stack.pop() {
        for entry in entries
            .iter()
            .filter(|entry| entry.parent_pid == parent_pid)
        {
            result.push(entry.clone());
            stack.push(entry.pid);
        }
    }
    result
}

fn process_entries() -> Result<Vec<ProcessEntry>> {
    let output = Command::new("ps")
        .args(["-axo", "pid=,ppid=,pgid=,stat=,comm="])
        .output()
        .context("failed to run ps for process detection")?;
    if !output.status.success() {
        anyhow::bail!("ps exited with {}", output.status);
    }
    parse_process_entries(&String::from_utf8_lossy(&output.stdout))
}

fn parse_process_entries(output: &str) -> Result<Vec<ProcessEntry>> {
    output
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(parse_process_entry)
        .collect()
}

fn parse_process_entry(line: &str) -> Result<ProcessEntry> {
    let trimmed = line.trim_start();
    let Some((pid, rest)) = trimmed.split_once(char::is_whitespace) else {
        anyhow::bail!("missing process pid in ps row: {line}");
    };
    let rest = rest.trim_start();
    let Some((parent_pid, rest)) = rest.split_once(char::is_whitespace) else {
        anyhow::bail!("missing process parent pid in ps row: {line}");
    };
    let rest = rest.trim_start();
    let Some((process_group, rest)) = rest.split_once(char::is_whitespace) else {
        anyhow::bail!("missing process group in ps row: {line}");
    };
    let rest = rest.trim_start();
    let Some((stat, command)) = rest.split_once(char::is_whitespace) else {
        anyhow::bail!("missing process stat in ps row: {line}");
    };
    let command = command.trim();
    if command.is_empty() {
        anyhow::bail!("missing process command in ps row: {line}");
    }
    Ok(ProcessEntry {
        pid: pid
            .parse()
            .with_context(|| format!("invalid process pid in ps row: {line}"))?,
        parent_pid: parent_pid
            .parse()
            .with_context(|| format!("invalid process parent pid in ps row: {line}"))?,
        process_group: process_group
            .parse()
            .with_context(|| format!("invalid process group in ps row: {line}"))?,
        foreground: stat.contains('+'),
        command: command.to_string(),
    })
}

fn is_agent_command_name(command_name: &str) -> bool {
    is_command_name(command_name, &["claude", "codex", "opencode", "openclaw"])
}

#[derive(Debug, Clone)]
pub struct IpcPaths {
    runtime_dir: PathBuf,
    socket_path: PathBuf,
}

impl IpcPaths {
    pub fn from_env_or_default() -> Result<Self> {
        let runtime_dir = match std::env::var_os("NUDGE_RUNTIME_DIR") {
            Some(path) => PathBuf::from(path),
            None => dirs::home_dir()
                .context("failed to locate home directory")?
                .join(".nudge")
                .join("run"),
        };
        Ok(Self {
            socket_path: runtime_dir.join("daemon.sock"),
            runtime_dir,
        })
    }

    pub fn runtime_dir(&self) -> &Path {
        &self.runtime_dir
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    pub fn prepare_runtime_dir(&self) -> Result<()> {
        fs::create_dir_all(&self.runtime_dir)
            .with_context(|| format!("failed to create {}", self.runtime_dir.display()))?;
        fs::set_permissions(&self.runtime_dir, fs::Permissions::from_mode(0o700))
            .with_context(|| format!("failed to secure {}", self.runtime_dir.display()))?;
        Ok(())
    }

    pub fn remove_stale_socket(&self) -> Result<()> {
        match fs::remove_file(&self.socket_path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error)
                .with_context(|| format!("failed to remove {}", self.socket_path.display())),
        }
    }
}

#[derive(Clone)]
struct DaemonRuntime {
    state_store: StateStore,
    session: Arc<Mutex<MachineSession>>,
    ptys: Arc<Mutex<Vec<RuntimeTab>>>,
    shutdown: Arc<Notify>,
    connected_clients: Arc<AtomicU32>,
    relay_state: Arc<Mutex<RelayConnectionState>>,
    terminal_changes: broadcast::Sender<TerminalChange>,
    agent_status_changes: broadcast::Sender<AgentStatusChange>,
    audit_sink: Option<DaemonAuditSink>,
    started_at: Instant,
    socket_path: PathBuf,
    // The tab the phone is currently viewing, if it told us. The relay loop only
    // streams live terminal output for this tab; background tabs re-baseline via
    // a snapshot when they regain focus (their phone-side offset goes stale).
    // `None` means stream every tab (legacy phones never set it).
    focused_tab: Arc<Mutex<Option<String>>>,
    /// Phone-advertised capability (Phase 4.1 Level A): stream terminal deltas as
    /// a binary E2E plaintext rather than base64-in-JSON. Negotiated via
    /// `set_phone_profile`'s `supportsBinaryTerminal`; reset to false on each new
    /// relay connection so a reconnect re-negotiates.
    terminal_binary_supported: Arc<Mutex<bool>>,
}

impl DaemonRuntime {
    fn new(state_store: StateStore, session: MachineSession, socket_path: PathBuf) -> Self {
        let ptys = session
            .tabs
            .iter()
            .map(|tab| RuntimeTab {
                tab_id: tab.id.clone(),
                pty: None,
                grid: Arc::new(std::sync::Mutex::new(TerminalGrid::default())),
            })
            .collect();
        Self {
            state_store,
            session: Arc::new(Mutex::new(session)),
            ptys: Arc::new(Mutex::new(ptys)),
            shutdown: Arc::new(Notify::new()),
            connected_clients: Arc::new(AtomicU32::new(0)),
            relay_state: Arc::new(Mutex::new(RelayConnectionState::default())),
            terminal_changes: broadcast::channel(512).0,
            agent_status_changes: broadcast::channel(512).0,
            audit_sink: DaemonAuditSink::from_env(),
            started_at: Instant::now(),
            socket_path,
            focused_tab: Arc::new(Mutex::new(None)),
            terminal_binary_supported: Arc::new(Mutex::new(false)),
        }
    }

    async fn status(&self) -> v1::DaemonStatus {
        let session = self.session.lock().await;
        let relay = self.relay_state.lock().await.clone();
        v1::DaemonStatus {
            socket_path: self.socket_path.display().to_string(),
            state_path: self.state_store.path().display().to_string(),
            connected_clients: self.connected_clients.load(Ordering::Relaxed),
            uptime_seconds: self.started_at.elapsed().as_secs(),
            tabs: session.tabs.len() as u32,
            plan: session.entitlement.plan.clone(),
            relay_status: relay.status.as_str().to_string(),
            relay_url: relay.relay_url,
            relay_binding_id: relay.binding_id,
            relay_last_error: relay.last_error.unwrap_or_default(),
            relay_connected_at: relay.connected_at.unwrap_or_default(),
            relay_last_message_at: relay.last_message_at.unwrap_or_default(),
        }
    }

    async fn session_state(&self) -> v1::SessionState {
        let _ = self.refresh_all_agent_statuses().await;
        self.session.lock().await.to_proto()
    }

    async fn create_tab(&self, title: String) -> Result<v1::SessionState> {
        self.create_tab_with(title, None, None).await
    }

    async fn create_tab_with(
        &self,
        title: String,
        cwd: Option<String>,
        launch: Option<String>,
    ) -> Result<v1::SessionState> {
        let launch_kind = TabLaunch::parse(launch.as_deref());
        let new_tab_id = {
            let mut session = self.session.lock().await;
            let tab = session.create_tab(launch_kind.tab_title(&title))?;
            let tab_id = tab.id.clone();
            self.ptys.lock().await.push(RuntimeTab {
                tab_id: tab_id.clone(),
                pty: None,
                grid: Arc::new(std::sync::Mutex::new(TerminalGrid::default())),
            });
            self.state_store.save(&session)?;
            tab_id
        };
        self.ensure_ptys().await?;
        // Pre-trust the folder so the agent does not show its first-run
        // directory-trust dialog (the user explicitly chose this folder when
        // launching the agent).
        match launch_kind {
            TabLaunch::Claude => pretrust_claude_folder(cwd.as_deref()),
            TabLaunch::Codex => pretrust_codex_folder(cwd.as_deref()),
            TabLaunch::Shell => {}
        }
        if let Some(command) = launch_kind.initial_command(cwd.as_deref()) {
            self.write_input(&new_tab_id, command.into_bytes()).await?;
        }
        Ok(self.session_state().await)
    }

    async fn rename_tab(&self, tab_id: &str, title: String) -> Result<v1::SessionState> {
        {
            let mut session = self.session.lock().await;
            session.rename_tab(tab_id, title)?;
            self.state_store.save(&session)?;
        }
        Ok(self.session_state().await)
    }

    async fn close_tab(&self, tab_id: &str) -> Result<v1::SessionState> {
        {
            let mut session = self.session.lock().await;
            session.close_tab(tab_id)?;
            self.state_store.save(&session)?;
        }
        {
            let mut ptys = self.ptys.lock().await;
            if let Some(index) = ptys.iter().position(|tab| tab.tab_id == tab_id) {
                ptys.remove(index);
            }
        }
        // Don't leave focus pointing at a closed tab: tab_is_focus_filtered would
        // then skip EVERY surviving tab and black-hole all live output until the
        // phone re-sends focus. Clearing reverts to stream-all, which self-heals.
        {
            let mut focused = self.focused_tab.lock().await;
            if focused.as_deref() == Some(tab_id) {
                *focused = None;
            }
        }
        Ok(self.session_state().await)
    }

    async fn restart_tab(&self, tab_id: &str) -> Result<v1::SessionState> {
        {
            let session = self.session.lock().await;
            if !session.tabs.iter().any(|tab| tab.id == tab_id) {
                anyhow::bail!("tab {tab_id} was not found");
            }
        }
        {
            let mut ptys = self.ptys.lock().await;
            if let Some(runtime_tab) = ptys.iter_mut().find(|tab| tab.tab_id == tab_id) {
                runtime_tab
                    .grid
                    .lock()
                    .expect("terminal grid lock poisoned")
                    .resize(GridSize::default());
                runtime_tab.pty = Some(
                    self.spawn_pty_for_runtime_tab(tab_id, runtime_tab.grid.clone())
                        .await?,
                );
            }
        }
        {
            let mut session = self.session.lock().await;
            session.mark_tab_running(tab_id)?;
            self.state_store.save(&session)?;
        }
        Ok(self.session_state().await)
    }

    async fn ensure_ptys(&self) -> Result<()> {
        let running_tab_ids = self.running_tab_ids().await;
        let mut ptys = self.ptys.lock().await;
        for runtime_tab in ptys.iter_mut() {
            if runtime_tab.pty.is_none() && running_tab_ids.contains(&runtime_tab.tab_id) {
                runtime_tab.pty = Some(
                    self.spawn_pty_for_runtime_tab(&runtime_tab.tab_id, runtime_tab.grid.clone())
                        .await?,
                );
            }
        }
        Ok(())
    }

    async fn spawn_pty_for_runtime_tab(
        &self,
        tab_id: &str,
        grid: Arc<std::sync::Mutex<TerminalGrid>>,
    ) -> Result<PtyTab> {
        spawn_pty_for_tab(tab_id, grid, self.terminal_changes.clone()).await
    }

    async fn write_input(&self, tab_id: &str, data: Vec<u8>) -> Result<()> {
        let ptys = self.ptys.lock().await;
        let pty = ptys
            .iter()
            .find(|tab| tab.tab_id == tab_id)
            .and_then(|tab| tab.pty.as_ref())
            .with_context(|| format!("tab {tab_id} does not have a pty"))?;
        pty.write_input(&data)
    }

    async fn write_input_from(
        &self,
        tab_id: &str,
        data: Vec<u8>,
        source: ApprovalAuditSource,
    ) -> Result<()> {
        let audit_event = self.approval_audit_event(tab_id, &data, source).await;
        self.write_input(tab_id, data).await?;
        if let Some((agent_status, action, source)) = audit_event {
            if let Some(audit_sink) = &self.audit_sink {
                let _ = audit_sink.write_approval_action(tab_id, &agent_status, action, source);
            }
        }
        Ok(())
    }

    async fn approval_audit_event(
        &self,
        tab_id: &str,
        data: &[u8],
        source: ApprovalAuditSource,
    ) -> Option<(AgentStatus, ApprovalAuditAction, ApprovalAuditSource)> {
        self.audit_sink.as_ref()?;
        let action = approval_action_from_input(data)?;
        let agent_status = {
            let session = self.session.lock().await;
            session
                .tabs
                .iter()
                .find(|tab| tab.id == tab_id)
                .map(|tab| tab.agent_status.clone())
        };
        let agent_status = agent_status?;
        if agent_status.state == AgentInteractionState::NeedsApproval {
            Some((agent_status, action, source))
        } else {
            None
        }
    }

    async fn output_tail(&self, tab_id: &str, max_bytes: usize) -> Result<Vec<u8>> {
        let ptys = self.ptys.lock().await;
        let tab = ptys
            .iter()
            .find(|tab| tab.tab_id == tab_id)
            .with_context(|| format!("tab {tab_id} was not found"))?;
        // A tab whose process has exited (needs_restart) has no live PTY. That
        // is a valid state, not an error: return an empty tail so the phone's
        // per-tab output request still succeeds. Erroring here made the daemon
        // reply ok=false, which the phone treats as fatal — wedging it in a
        // relay-reconnect loop after a daemon restart left every tab dead.
        Ok(tab
            .pty
            .as_ref()
            .map(|pty| pty.output_tail(max_bytes))
            .unwrap_or_default())
    }

    /// Returns the tab's grid snapshot together with the absolute stream
    /// `offset` it represents, read under the same grid lock as the contents so
    /// the offset is coherent with the live delta stream (no snapshot↔delta
    /// race). Callers that don't need the offset (local IPC) ignore it.
    async fn terminal_snapshot(&self, tab_id: &str) -> Result<(v1::TerminalSnapshot, u64)> {
        // First pass reads only the plain text to refresh agent status; the
        // authoritative snapshot (contents + offset + state_frame, all coherent)
        // is taken under a fresh lock below.
        let agent_text = {
            let ptys = self.ptys.lock().await;
            let runtime_tab = ptys
                .iter()
                .find(|tab| tab.tab_id == tab_id)
                .with_context(|| format!("tab {tab_id} was not found"))?;
            runtime_tab
                .grid
                .lock()
                .expect("terminal grid lock poisoned")
                .snapshot()
                .text
        };
        self.refresh_agent_status(tab_id, &agent_text).await?;

        let ptys = self.ptys.lock().await;
        let runtime_tab = ptys
            .iter()
            .find(|tab| tab.tab_id == tab_id)
            .with_context(|| format!("tab {tab_id} was not found"))?;
        let (snapshot, state_frame) = {
            let grid = runtime_tab
                .grid
                .lock()
                .expect("terminal grid lock poisoned");
            // Both read under one lock so the offset, contents, and modes are a
            // single coherent point in the stream.
            (grid.snapshot(), grid.state_frame())
        };
        let offset = snapshot.offset;
        Ok((
            v1::TerminalSnapshot {
                tab_id: tab_id.to_string(),
                rows: snapshot.rows as u32,
                cols: snapshot.cols as u32,
                text: snapshot.text,
                // Full restorable state (reset + modes + contents), not just the
                // visible cells, so a resync reconstructs alt-screen / SGR /
                // cursor and post-resync deltas are read in the right mode (R3).
                formatted: state_frame,
            },
            offset,
        ))
    }

    async fn terminal_render(&self, tab_id: &str) -> Result<v1::TerminalRender> {
        let agent_text = {
            let ptys = self.ptys.lock().await;
            let runtime_tab = ptys
                .iter()
                .find(|tab| tab.tab_id == tab_id)
                .with_context(|| format!("tab {tab_id} was not found"))?;
            runtime_tab
                .grid
                .lock()
                .expect("terminal grid lock poisoned")
                .snapshot()
                .text
        };
        self.refresh_agent_status(tab_id, &agent_text).await?;

        let ptys = self.ptys.lock().await;
        let runtime_tab = ptys
            .iter()
            .find(|tab| tab.tab_id == tab_id)
            .with_context(|| format!("tab {tab_id} was not found"))?;
        let (snapshot, frame) = {
            let grid = runtime_tab
                .grid
                .lock()
                .expect("terminal grid lock poisoned");
            (grid.snapshot(), grid.render_frame(1))
        };
        let width_mode = {
            let session = self.session.lock().await;
            session
                .tabs
                .iter()
                .find(|tab| tab.id == tab_id)
                .map(|tab| tab.width_mode.as_str().to_string())
                .unwrap_or_else(|| "computer".to_string())
        };
        Ok(v1::TerminalRender {
            tab_id: tab_id.to_string(),
            rows: snapshot.rows as u32,
            cols: snapshot.cols as u32,
            frame,
            width_mode,
        })
    }

    async fn refresh_agent_status_from_grid(&self, tab_id: &str) -> Result<AgentStatus> {
        let agent_text = {
            let ptys = self.ptys.lock().await;
            let runtime_tab = ptys
                .iter()
                .find(|tab| tab.tab_id == tab_id)
                .with_context(|| format!("tab {tab_id} was not found"))?;
            runtime_tab
                .grid
                .lock()
                .expect("terminal grid lock poisoned")
                .snapshot()
                .text
        };
        self.refresh_agent_status(tab_id, &agent_text).await
    }

    async fn refresh_agent_status(&self, tab_id: &str, screen_text: &str) -> Result<AgentStatus> {
        let process_signal = self.runtime_tab_process_signal(tab_id).await;
        let mut session = self.session.lock().await;
        let tab = session
            .tabs
            .iter_mut()
            .find(|tab| tab.id == tab_id)
            .ok_or_else(|| SessionError::TabNotFound {
                tab_id: tab_id.to_string(),
            })?;
        let detected = detect_agent_status(
            &tab.title,
            screen_text,
            process_signal.as_ref(),
            &tab.status,
        );
        if tab.agent_status != detected {
            tab.agent_status = detected.clone();
            tab.last_activity_at = now_string();
            session.updated_at = now_string();
            self.state_store.save(&session)?;
            let _ = self.agent_status_changes.send(AgentStatusChange {
                tab_id: tab_id.to_string(),
                status: detected.clone(),
            });
        }
        Ok(detected)
    }

    async fn refresh_all_agent_statuses(&self) -> Result<()> {
        let snapshots = {
            let ptys = self.ptys.lock().await;
            ptys.iter()
                .map(|runtime_tab| {
                    let text = runtime_tab
                        .grid
                        .lock()
                        .expect("terminal grid lock poisoned")
                        .snapshot()
                        .text;
                    (
                        runtime_tab.tab_id.clone(),
                        text,
                        runtime_tab.pty.as_ref().and_then(|pty| {
                            foreground_process_signal(
                                pty.child_pid(),
                                pty.foreground_process_group(),
                                Some(pty.command_name()),
                            )
                        }),
                    )
                })
                .collect::<Vec<_>>()
        };

        let mut session = self.session.lock().await;
        let mut changed = false;
        for (tab_id, text, process_signal) in snapshots {
            if let Some(tab) = session.tabs.iter_mut().find(|tab| tab.id == tab_id) {
                let detected =
                    detect_agent_status(&tab.title, &text, process_signal.as_ref(), &tab.status);
                if tab.agent_status != detected {
                    tab.agent_status = detected.clone();
                    tab.last_activity_at = now_string();
                    let _ = self.agent_status_changes.send(AgentStatusChange {
                        tab_id: tab_id.clone(),
                        status: detected,
                    });
                    changed = true;
                }
            }
        }
        if changed {
            session.updated_at = now_string();
            self.state_store.save(&session)?;
        }
        Ok(())
    }

    async fn runtime_tab_process_signal(&self, tab_id: &str) -> Option<ProcessSignal> {
        let ptys = self.ptys.lock().await;
        ptys.iter()
            .find(|runtime_tab| runtime_tab.tab_id == tab_id)
            .and_then(|runtime_tab| {
                runtime_tab.pty.as_ref().and_then(|pty| {
                    foreground_process_signal(
                        pty.child_pid(),
                        pty.foreground_process_group(),
                        Some(pty.command_name()),
                    )
                })
            })
    }

    async fn set_phone_profile(&self, rows: u16, cols: u16) -> Result<v1::SessionState> {
        let tab_ids: Vec<String> = {
            let mut session = self.session.lock().await;
            session.set_phone_profile(rows, cols);
            self.state_store.save(&session)?;
            session.tabs.iter().map(|tab| tab.id.clone()).collect()
        };
        // Resize each tab's PTY to the phone so running programs reflow to fit.
        let size = TerminalSize { rows, cols };
        for tab_id in tab_ids {
            let _ = self.resize_tab(&tab_id, size).await;
        }
        Ok(self.session_state().await)
    }

    async fn set_width_mode(
        &self,
        tab_id: &str,
        mode: WidthMode,
        computer_size: TerminalSize,
    ) -> Result<v1::SessionState> {
        let target_size = {
            let mut session = self.session.lock().await;
            let target_size = session.set_width_mode(tab_id, mode, computer_size)?;
            self.state_store.save(&session)?;
            target_size
        };
        self.resize_tab(tab_id, target_size).await?;
        Ok(self.session_state().await)
    }

    async fn set_binding(&self, binding: BindingState) -> Result<v1::SessionState> {
        {
            let mut session = self.session.lock().await;
            session.set_binding(binding);
            self.state_store.save(&session)?;
        }
        Ok(self.session_state().await)
    }

    async fn set_entitlement(&self, entitlement: Entitlement) -> Result<v1::SessionState> {
        let suspended_tab_ids = {
            let mut session = self.session.lock().await;
            let suspended_tab_ids = session.set_entitlement(entitlement);
            self.state_store.save(&session)?;
            suspended_tab_ids
        };
        if !suspended_tab_ids.is_empty() {
            let mut ptys = self.ptys.lock().await;
            for tab_id in &suspended_tab_ids {
                if let Some(runtime_tab) = ptys.iter_mut().find(|tab| &tab.tab_id == tab_id) {
                    runtime_tab.pty = None;
                    runtime_tab
                        .grid
                        .lock()
                        .expect("terminal grid lock poisoned")
                        .resize(GridSize::default());
                }
                let _ = self.agent_status_changes.send(AgentStatusChange {
                    tab_id: tab_id.clone(),
                    status: AgentStatus {
                        kind: AgentKind::Unknown,
                        state: AgentInteractionState::Exited,
                        confidence: 0.6,
                        source: AgentDetectionSource::Heuristic,
                    },
                });
            }
        }
        Ok(self.session_state().await)
    }

    async fn clear_binding(&self) -> Result<v1::SessionState> {
        {
            let mut session = self.session.lock().await;
            session.clear_binding();
            self.state_store.save(&session)?;
        }
        self.set_relay_state(RelayConnectionState::unbound()).await;
        Ok(self.session_state().await)
    }

    async fn mark_binding_revoked(&self, binding_id: &str) -> Result<()> {
        let revoked_binding = {
            let mut session = self.session.lock().await;
            let Some(binding) = session.binding.clone() else {
                return Ok(());
            };
            if binding.binding_id != binding_id {
                return Ok(());
            }
            let revoked = binding.revoked();
            session.set_binding(revoked.clone());
            self.state_store.save(&session)?;
            revoked
        };
        self.set_relay_state(RelayConnectionState::error(
            &revoked_binding,
            "binding_revoked".to_string(),
        ))
        .await;
        Ok(())
    }

    async fn device_identity(&self) -> Result<DeviceIdentity> {
        let mut session = self.session.lock().await;
        if session.ensure_device_identity()? {
            self.state_store.save(&session)?;
        }
        session
            .device_identity
            .clone()
            .context("device identity should exist")
    }

    async fn rotate_device_key(&self) -> Result<v1::SessionState> {
        let (binding, current_identity) = {
            let mut session = self.session.lock().await;
            if session.ensure_device_identity()? {
                self.state_store.save(&session)?;
            }
            let binding = session
                .binding
                .clone()
                .filter(|binding| binding.status == BindingStatus::Active)
                .context("active binding is required before rotating device key")?;
            let current_identity = session
                .device_identity
                .clone()
                .context("device identity should exist")?;
            (binding, current_identity)
        };
        let rotation = prepare_device_key_rotation(&binding.daemon_device_id, &current_identity)?;
        rotate_relay_device_key(&HttpClient::new(), &binding, &rotation).await?;
        {
            let mut session = self.session.lock().await;
            let Some(current_binding) = session.binding.as_ref() else {
                anyhow::bail!("binding disappeared during device key rotation");
            };
            if current_binding.binding_id != binding.binding_id
                || current_binding.daemon_device_id != binding.daemon_device_id
                || current_binding.status != BindingStatus::Active
            {
                anyhow::bail!("binding changed during device key rotation");
            }
            session.rotate_device_identity(rotation.identity)?;
            self.state_store.save(&session)?;
        }
        Ok(self.session_state().await)
    }

    async fn current_active_binding(&self) -> Option<BindingState> {
        self.session
            .lock()
            .await
            .binding
            .clone()
            .filter(|binding| binding.status == BindingStatus::Active)
    }

    async fn current_binding(&self) -> Option<BindingState> {
        self.session.lock().await.binding.clone()
    }

    async fn running_tab_ids(&self) -> Vec<String> {
        self.session
            .lock()
            .await
            .tabs
            .iter()
            .filter(|tab| matches!(tab.status, TabStatus::Running))
            .map(|tab| tab.id.clone())
            .collect()
    }

    async fn tab_agent_status(&self, tab_id: &str) -> Option<AgentStatus> {
        self.session
            .lock()
            .await
            .tabs
            .iter()
            .find(|tab| tab.id == tab_id)
            .map(|tab| tab.agent_status.clone())
    }

    async fn set_relay_state(&self, state: RelayConnectionState) {
        *self.relay_state.lock().await = state;
    }

    async fn set_focused_tab(&self, tab_id: Option<String>) {
        *self.focused_tab.lock().await = tab_id;
    }

    async fn focused_tab(&self) -> Option<String> {
        self.focused_tab.lock().await.clone()
    }

    async fn set_terminal_binary_supported(&self, supported: bool) {
        *self.terminal_binary_supported.lock().await = supported;
    }

    async fn terminal_binary_supported(&self) -> bool {
        *self.terminal_binary_supported.lock().await
    }

    async fn mark_relay_message(&self) {
        let mut relay_state = self.relay_state.lock().await;
        relay_state.last_message_at = Some(now_string());
    }

    async fn resize_tab(&self, tab_id: &str, size: TerminalSize) -> Result<()> {
        let ptys = self.ptys.lock().await;
        let pty = ptys
            .iter()
            .find(|tab| tab.tab_id == tab_id)
            .and_then(|tab| tab.pty.as_ref())
            .with_context(|| format!("tab {tab_id} does not have a pty"))?;
        if let Some(runtime_tab) = ptys.iter().find(|tab| tab.tab_id == tab_id) {
            runtime_tab
                .grid
                .lock()
                .expect("terminal grid lock poisoned")
                .resize(GridSize::new(size.cols, size.rows));
        }
        pty.resize(size)
    }

    fn subscribe_terminal_changes(&self) -> broadcast::Receiver<TerminalChange> {
        self.terminal_changes.subscribe()
    }

    fn subscribe_agent_status_changes(&self) -> broadcast::Receiver<AgentStatusChange> {
        self.agent_status_changes.subscribe()
    }
}

struct RuntimeTab {
    tab_id: String,
    pty: Option<PtyTab>,
    grid: Arc<std::sync::Mutex<TerminalGrid>>,
}

/// Agent the phone asked us to launch in a freshly created tab. The command
/// run in the PTY is always constructed on the daemon side; the phone only
/// chooses which agent and which directory, never an arbitrary command.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TabLaunch {
    Shell,
    Claude,
    Codex,
}

impl TabLaunch {
    fn parse(value: Option<&str>) -> Self {
        match value.map(|raw| raw.trim().to_ascii_lowercase()).as_deref() {
            Some("claude") => Self::Claude,
            Some("codex") => Self::Codex,
            _ => Self::Shell,
        }
    }

    /// Tab title to use when this launch is requested. `requested_title`
    /// is the title the phone sent (used only for the plain shell).
    fn tab_title(self, requested_title: &str) -> String {
        match self {
            Self::Claude => "claude".to_string(),
            Self::Codex => "codex".to_string(),
            Self::Shell => {
                let trimmed = requested_title.trim();
                if trimmed.is_empty() {
                    "shell".to_string()
                } else {
                    requested_title.to_string()
                }
            }
        }
    }

    /// Initial command to feed the new tab's shell, or `None` when nothing
    /// needs to run (a plain shell without a starting directory).
    fn initial_command(self, cwd: Option<&str>) -> Option<String> {
        let cwd = cwd
            .map(str::trim)
            .filter(|dir| !dir.is_empty())
            .map(shell_single_quote);
        match self {
            Self::Shell => cwd.map(|dir| format!("cd {dir}\n")),
            Self::Claude => Some(match cwd {
                Some(dir) => format!("cd {dir} && claude --dangerously-skip-permissions\n"),
                None => "claude --dangerously-skip-permissions\n".to_string(),
            }),
            Self::Codex => Some(match cwd {
                Some(dir) => {
                    format!("cd {dir} && codex --dangerously-bypass-approvals-and-sandbox\n")
                }
                None => "codex --dangerously-bypass-approvals-and-sandbox\n".to_string(),
            }),
        }
    }
}

/// Wrap `value` in single quotes for safe use in a POSIX shell command,
/// escaping any embedded single quotes via the `'\''` idiom.
/// Best-effort: mark the folder as trusted in ~/.claude.json so Claude skips
/// its workspace-trust dialog. Writes atomically (temp + rename) so a concurrent
/// Claude process can never read a torn file. Silently no-ops on any error.
/// Resolve a launch directory to the canonical, symlink-free absolute path that
/// Claude and Codex compute for their own directory-trust lookups (e.g. on macOS
/// `/tmp` resolves to `/private/tmp`). The trust entry must be keyed by this
/// resolved path or the agent's runtime lookup misses it and still prompts.
/// Falls back to the path as-given when it cannot be resolved (e.g. it does not
/// exist yet), preserving best-effort behavior.
fn canonical_launch_dir(dir: std::path::PathBuf) -> std::path::PathBuf {
    std::fs::canonicalize(&dir).unwrap_or(dir)
}

fn pretrust_claude_folder(cwd: Option<&str>) {
    let Some(home) = dirs::home_dir() else {
        return;
    };
    let dir = cwd
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| home.clone());
    let dir = canonical_launch_dir(dir);
    let key = dir.to_string_lossy().to_string();
    let config_path = home.join(".claude.json");
    let mut root: serde_json::Value = std::fs::read(&config_path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_else(|| serde_json::json!({}));
    let Some(root_obj) = root.as_object_mut() else {
        return;
    };
    let projects = root_obj
        .entry("projects".to_string())
        .or_insert_with(|| serde_json::json!({}));
    let Some(projects_obj) = projects.as_object_mut() else {
        return;
    };
    let project = projects_obj
        .entry(key)
        .or_insert_with(|| serde_json::json!({}));
    let Some(project_obj) = project.as_object_mut() else {
        return;
    };
    project_obj.insert(
        "hasTrustDialogAccepted".to_string(),
        serde_json::Value::Bool(true),
    );
    if let Ok(serialized) = serde_json::to_vec_pretty(&root) {
        let tmp_path = home.join(".claude.json.nudge-tmp");
        if std::fs::write(&tmp_path, serialized).is_ok() {
            let _ = std::fs::rename(&tmp_path, &config_path);
        }
    }
}

/// Best-effort: mark the folder as trusted in ~/.codex/config.toml so Codex
/// skips its first-run directory-trust prompt ("allow Codex to work here").
/// Codex keys trust off a `[projects."<abs-path>"]` table with
/// `trust_level = "trusted"`; the `--dangerously-bypass-approvals-and-sandbox`
/// flag only disables per-command approval/sandboxing, not this directory gate.
/// Writes atomically (temp + rename) so a concurrent Codex process can never
/// read a torn file. Silently no-ops on any error.
fn pretrust_codex_folder(cwd: Option<&str>) {
    let Some(home) = dirs::home_dir() else {
        return;
    };
    let dir = cwd
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| home.clone());
    let dir = canonical_launch_dir(dir);
    let config_path = home.join(".codex").join("config.toml");
    let existing = std::fs::read_to_string(&config_path).unwrap_or_default();
    let Some(updated) = codex_config_with_trusted_project(&existing, &dir.to_string_lossy())
    else {
        return;
    };
    let tmp_path = home.join(".codex").join("config.toml.nudge-tmp");
    if std::fs::write(&tmp_path, updated).is_ok() {
        let _ = std::fs::rename(&tmp_path, &config_path);
    }
}

/// Returns the contents of a Codex `config.toml` with a trusted-project entry
/// for `dir`, or `None` when the directory is already trusted (so the caller
/// can skip the write). Appends a new `[projects."<dir>"]` table rather than
/// reparsing the whole document, preserving the user's existing formatting and
/// comments. The path is quoted as a TOML basic string with backslashes and
/// double quotes escaped.
fn codex_config_with_trusted_project(existing: &str, dir: &str) -> Option<String> {
    let escaped = dir.replace('\\', "\\\\").replace('"', "\\\"");
    let header = format!("[projects.\"{escaped}\"]");
    // Already declared (with any trust level / settings): leave the file alone.
    if existing
        .lines()
        .any(|line| line.trim() == header.as_str())
    {
        return None;
    }
    let mut updated = String::with_capacity(existing.len() + header.len() + 32);
    updated.push_str(existing);
    if !existing.is_empty() && !existing.ends_with('\n') {
        updated.push('\n');
    }
    if !updated.is_empty() {
        updated.push('\n');
    }
    updated.push_str(&header);
    updated.push('\n');
    updated.push_str("trust_level = \"trusted\"\n");
    Some(updated)
}

fn shell_single_quote(value: &str) -> String {
    let mut quoted = String::with_capacity(value.len() + 2);
    quoted.push('\'');
    for ch in value.chars() {
        if ch == '\'' {
            quoted.push_str("'\\''");
        } else {
            quoted.push(ch);
        }
    }
    quoted.push('\'');
    quoted
}

async fn spawn_pty_for_tab(
    tab_id: &str,
    grid: Arc<std::sync::Mutex<TerminalGrid>>,
    terminal_changes: broadcast::Sender<TerminalChange>,
) -> Result<PtyTab> {
    let tab_id = tab_id.to_string();
    let spawn_tab_id = tab_id.clone();
    task::spawn_blocking(move || {
        let output_tab_id = spawn_tab_id;
        PtyTab::spawn_shell_with_output_hook(TerminalSize::default(), move |bytes| {
            // Stamp the offset INSIDE the grid lock so it is pinned to the grid
            // position; the broadcast send may run after the guard drops.
            let offset = grid
                .lock()
                .expect("terminal grid lock poisoned")
                .process(bytes);
            let _ = terminal_changes.send(TerminalChange {
                tab_id: output_tab_id.clone(),
                offset,
                data: bytes.to_vec(),
            });
        })
    })
    .await
    .context("pty spawn task failed")?
    .with_context(|| format!("failed to spawn shell for tab {tab_id}"))
}

async fn relay_connection_loop(runtime: DaemonRuntime) {
    let mut active_binding_id: Option<String> = None;
    loop {
        tokio::select! {
            _ = runtime.shutdown.notified() => break,
            _ = sleep(Duration::from_millis(250)) => {}
        }

        let binding = match runtime.current_binding().await {
            Some(binding) if binding.status == BindingStatus::Active => binding,
            Some(binding) if binding.status == BindingStatus::Revoked => {
                if active_binding_id.as_deref() != Some(binding.binding_id.as_str()) {
                    runtime
                        .set_relay_state(RelayConnectionState::error(
                            &binding,
                            "binding_revoked".to_string(),
                        ))
                        .await;
                    active_binding_id = Some(binding.binding_id.clone());
                }
                continue;
            }
            _ => {
                if active_binding_id.take().is_some() {
                    runtime
                        .set_relay_state(RelayConnectionState::unbound())
                        .await;
                }
                continue;
            }
        };

        if active_binding_id.as_deref() != Some(binding.binding_id.as_str()) {
            runtime
                .set_relay_state(RelayConnectionState::connecting(&binding))
                .await;
            active_binding_id = Some(binding.binding_id.clone());
        }

        if let Err(error) = connect_relay_once(&runtime, &binding).await {
            if runtime
                .current_active_binding()
                .await
                .map(|current| current.binding_id == binding.binding_id)
                .unwrap_or(false)
            {
                runtime
                    .set_relay_state(RelayConnectionState::error(&binding, format!("{error:#}")))
                    .await;
            }
            tokio::select! {
                _ = runtime.shutdown.notified() => break,
                _ = sleep(Duration::from_secs(1)) => {}
            }
        }
    }
}

async fn connect_relay_once(runtime: &DaemonRuntime, binding: &BindingState) -> Result<()> {
    let identity = runtime.device_identity().await?;
    let http_client = HttpClient::new();
    let url = signed_relay_websocket_url(&http_client, binding, &identity).await?;
    let bound_phone_id = binding
        .bound_phone_id
        .clone()
        .context("active relay binding is missing bound phone id")?;
    runtime
        .set_relay_state(RelayConnectionState::connecting(binding))
        .await;
    let (mut websocket, _) = connect_async(&url)
        .await
        .context("failed to connect relay websocket")?;
    runtime
        .set_relay_state(RelayConnectionState::connected(binding))
        .await;
    let mut terminal_changes = runtime.subscribe_terminal_changes();
    let mut agent_status_changes = runtime.subscribe_agent_status_changes();
    let mut e2e_session: Option<RelayE2ESession> = None;
    let mut pending_terminal_outputs: BTreeMap<String, PendingOutput> = BTreeMap::new();
    let mut snapshot_required: HashSet<String> = HashSet::new();
    // Start each relay session streaming every tab; focus from a prior session
    // could point at a now-closed/different tab and would background-filter the
    // whole stream. The phone re-sends focus right after it syncs sessionState.
    runtime.set_focused_tab(None).await;
    // Re-negotiate the binary-terminal capability per connection: default to the
    // JSON path until the phone re-advertises support via set_phone_profile.
    runtime.set_terminal_binary_supported(false).await;
    let min_interval = relay_terminal_flush_interval();
    let mut terminal_flush = interval(min_interval);
    terminal_flush.set_missed_tick_behavior(MissedTickBehavior::Skip);
    // Seed last_flush in the past so the first change after a quiet period
    // flushes immediately (immediate-on-idle, handled in the recv arm).
    let mut last_flush = Instant::now()
        .checked_sub(min_interval)
        .unwrap_or_else(Instant::now);

    loop {
        tokio::select! {
            _ = runtime.shutdown.notified() => break,
            change = terminal_changes.recv() => {
                match change {
                    Ok(change) => {
                        accumulate_terminal_change(
                            &mut pending_terminal_outputs,
                            &mut snapshot_required,
                            change.tab_id,
                            change.offset,
                            &change.data,
                        );
                        // Immediate-on-idle: a lone keystroke/output that lands
                        // after a quiet period echoes right away (~0 added
                        // latency); sustained bursts stay buffered and coalesce
                        // on the timer tick below.
                        if last_flush.elapsed() >= min_interval {
                            last_flush = Instant::now();
                            let focused = runtime.focused_tab().await;
                            flush_pending_terminal_outputs(
                                runtime,
                                binding,
                                &bound_phone_id,
                                &mut websocket,
                                e2e_session.as_mut(),
                                std::mem::take(&mut pending_terminal_outputs),
                                std::mem::take(&mut snapshot_required),
                                focused,
                            )
                            .await?;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        // We dropped broadcast items, so the per-tab byte stream
                        // is no longer contiguous — resync every live tab with a
                        // full snapshot rather than a delta that starts mid-stream.
                        for tab_id in runtime.running_tab_ids().await {
                            snapshot_required.insert(tab_id);
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
            change = agent_status_changes.recv() => {
                match change {
                    Ok(change) => {
                        let payload = relay_live_agent_status_payload(binding, &change.tab_id, &change.status);
                        let Some(payload) = relay_live_payload(binding, payload, e2e_session.as_mut())? else {
                            continue;
                        };
                        let message = relay_message_json(&bound_phone_id, None, payload);
                        websocket
                            .send(WebSocketMessage::Text(message.into()))
                            .await
                            .context("failed to send relay agent status update")?;
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        for tab_id in runtime.running_tab_ids().await {
                            if let Some(status) = runtime.tab_agent_status(&tab_id).await {
                                let payload = relay_live_agent_status_payload(binding, &tab_id, &status);
                                let Some(payload) = relay_live_payload(binding, payload, e2e_session.as_mut())? else {
                                    continue;
                                };
                                let message = relay_message_json(&bound_phone_id, None, payload);
                                websocket
                                    .send(WebSocketMessage::Text(message.into()))
                                    .await
                                    .context("failed to send relay agent status update")?;
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
            _ = terminal_flush.tick(), if !pending_terminal_outputs.is_empty() || !snapshot_required.is_empty() => {
                last_flush = Instant::now();
                let focused = runtime.focused_tab().await;
                flush_pending_terminal_outputs(
                    runtime,
                    binding,
                    &bound_phone_id,
                    &mut websocket,
                    e2e_session.as_mut(),
                    std::mem::take(&mut pending_terminal_outputs),
                    std::mem::take(&mut snapshot_required),
                    focused,
                )
                .await?;
            }
            message = websocket.next() => {
                match message {
                    Some(Ok(message)) => {
                        runtime.mark_relay_message().await;
                        if let Some(response) = handle_relay_message(
                            runtime,
                            binding,
                            &bound_phone_id,
                            &identity,
                            &mut e2e_session,
                            message,
                        )
                        .await?
                        {
                            websocket
                                .send(WebSocketMessage::Text(response.into()))
                                .await
                                .context("failed to send relay websocket response")?;
                        }
                    }
                    Some(Err(error)) => return Err(error).context("relay websocket error"),
                    None => break,
                }
            }
        }

        let still_current = runtime
            .current_active_binding()
            .await
            .map(|current| current.binding_id == binding.binding_id)
            .unwrap_or(false);
        if !still_current {
            break;
        }
    }

    if runtime
        .current_active_binding()
        .await
        .map(|current| current.binding_id == binding.binding_id)
        .unwrap_or(false)
    {
        runtime
            .set_relay_state(RelayConnectionState::disconnected(binding))
            .await;
    }
    Ok(())
}

async fn handle_relay_message(
    runtime: &DaemonRuntime,
    binding: &BindingState,
    bound_phone_id: &str,
    identity: &DeviceIdentity,
    e2e_session: &mut Option<RelayE2ESession>,
    message: WebSocketMessage,
) -> Result<Option<String>> {
    let text = match message {
        WebSocketMessage::Text(text) => text,
        WebSocketMessage::Binary(bytes) => match String::from_utf8(bytes.to_vec()) {
            Ok(text) => text.into(),
            Err(_) => return Ok(None),
        },
        _ => return Ok(None),
    };
    let relay_message = match serde_json::from_str::<RelaySocketMessage>(&text) {
        Ok(relay_message) => relay_message,
        Err(_) => return Ok(None),
    };
    if relay_message.message_type == "error"
        && is_relay_revocation_error(relay_message.error.as_deref())
    {
        runtime.mark_binding_revoked(&binding.binding_id).await?;
        return Err(SessionError::RelayBindingRevoked.into());
    }
    if relay_message.message_type != "message" {
        return Ok(None);
    }
    let Some(routed) = relay_message.message else {
        return Ok(None);
    };
    let Some(response_payload) = handle_relay_payload(
        runtime,
        binding,
        bound_phone_id,
        identity,
        e2e_session,
        &routed.from_device_id,
        routed.payload,
    )
    .await?
    else {
        return Ok(None);
    };
    Ok(Some(relay_message_json(
        &routed.from_device_id,
        Some(&routed.id),
        response_payload,
    )))
}

fn is_relay_revocation_error(error: Option<&str>) -> bool {
    matches!(error, Some("binding_revoked" | "device_revoked"))
}

async fn handle_relay_payload(
    runtime: &DaemonRuntime,
    binding: &BindingState,
    bound_phone_id: &str,
    identity: &DeviceIdentity,
    e2e_session: &mut Option<RelayE2ESession>,
    from_device_id: &str,
    payload: Value,
) -> Result<Option<Value>> {
    match payload_type(&payload).as_deref() {
        Some("e2e_handshake_start") => {
            let finish = accept_e2e_handshake_start(
                binding,
                bound_phone_id,
                identity,
                e2e_session,
                from_device_id,
                payload,
            )?;
            Ok(Some(e2e::handshake_finish_to_relay_payload(&finish)))
        }
        Some("e2e_envelope") => {
            let session = e2e_session
                .as_mut()
                .context("relay sent encrypted payload before e2e handshake")?;
            let envelope = e2e::envelope_from_relay_payload(&payload)?;
            let message_type = envelope.message_type.clone();
            let plaintext = session.keys.decrypt(&envelope)?;
            let request: RelayControlRequest = serde_json::from_slice(&plaintext)
                .context("failed to decode decrypted relay control request")?;
            let response = handle_relay_control_request(runtime, request).await;
            let response_payload = relay_control_response_payload(
                binding,
                None,
                &response.request_id,
                response.ok,
                response.payload,
            );
            let encrypted = session.keys.encrypt(
                format!("{message_type}_response"),
                response_payload.to_string().as_bytes(),
            )?;
            Ok(Some(e2e::envelope_to_relay_payload(&encrypted)))
        }
        _ => {
            let request: RelayControlRequest = serde_json::from_value(payload)
                .context("failed to decode relay control request")?;
            let response = handle_relay_control_request(runtime, request).await;
            Ok(Some(relay_control_response_payload(
                binding,
                None,
                &response.request_id,
                response.ok,
                response.payload,
            )))
        }
    }
}

fn accept_e2e_handshake_start(
    binding: &BindingState,
    bound_phone_id: &str,
    identity: &DeviceIdentity,
    e2e_session: &mut Option<RelayE2ESession>,
    from_device_id: &str,
    payload: Value,
) -> Result<v1::E2eHandshakeFinish> {
    if from_device_id != bound_phone_id {
        anyhow::bail!("e2e handshake start from unbound phone");
    }
    let expected_phone_key = binding
        .phone_public_key
        .as_deref()
        .context("binding is missing phone public key")?;
    let expected_phone_key = decode_fixed_base64::<32>(expected_phone_key)
        .context("binding phone public key is invalid")?;
    let start = e2e::handshake_start_from_relay_payload(&payload)?;
    if start.recipient_device_id != binding.daemon_device_id
        || start.sender_device_id != bound_phone_id
    {
        anyhow::bail!("e2e handshake start route mismatch");
    }
    e2e::verify_handshake_start(&start, &expected_phone_key)?;

    let daemon_secret = identity.secret_key_bytes()?;
    let daemon_ephemeral = e2e::KeyPair::generate()?;
    let phone_ephemeral: [u8; 32] = start
        .sender_ephemeral_public_key
        .as_slice()
        .try_into()
        .map_err(|_| anyhow::anyhow!("phone e2e ephemeral key must be 32 bytes"))?;
    let keys = e2e::SessionKeys::from_x25519(
        start.session_id.clone(),
        binding.daemon_device_id.clone(),
        bound_phone_id.to_string(),
        &daemon_ephemeral,
        phone_ephemeral,
        e2e::SessionRole::Daemon,
    )?;
    let finish = e2e::sign_handshake_finish(
        &daemon_secret,
        &start,
        v1::E2eHandshakeFinish {
            session_id: start.session_id.clone(),
            sender_device_id: binding.daemon_device_id.clone(),
            recipient_device_id: bound_phone_id.to_string(),
            sender_ephemeral_public_key: daemon_ephemeral.public_bytes().to_vec(),
            transcript_signature: Vec::new(),
            accepted_at: now_string(),
        },
    );
    *e2e_session = Some(RelayE2ESession { keys });
    Ok(finish)
}

struct RelayControlResponse {
    request_id: String,
    ok: bool,
    payload: Value,
}

async fn handle_relay_control_request(
    runtime: &DaemonRuntime,
    request: RelayControlRequest,
) -> RelayControlResponse {
    match request {
        RelayControlRequest::GetState { request_id } => RelayControlResponse::ok(
            request_id,
            session_state_json(runtime.session_state().await),
        ),
        RelayControlRequest::TerminalSnapshot { request_id, tab_id } => {
            match runtime.terminal_snapshot(&tab_id).await {
                Ok((snapshot, offset)) => {
                    RelayControlResponse::ok(request_id, terminal_snapshot_json(&snapshot, offset))
                }
                Err(error) => RelayControlResponse::error(request_id, error),
            }
        }
        RelayControlRequest::TerminalOutput {
            request_id,
            tab_id,
            max_bytes,
        } => {
            let max_bytes = replay_max_bytes(max_bytes);
            match runtime.output_tail(&tab_id, max_bytes).await {
                Ok(data) => {
                    // A raw byte tail has no meaningful absolute offset (it is a
                    // separate PTY buffer, not grid-aligned) and the phone
                    // replays it as a full replace without offset-tracking, so
                    // 0 is fine. Phase 1.4 retires this path for initial state.
                    RelayControlResponse::ok(request_id, terminal_output_json(&tab_id, 0, &data))
                }
                Err(error) => RelayControlResponse::error(request_id, error),
            }
        }
        RelayControlRequest::TerminalInput {
            request_id,
            tab_id,
            mut text,
            enter,
        } => {
            if enter {
                text.push('\r');
            }
            match runtime
                .write_input_from(
                    &tab_id,
                    text.into_bytes(),
                    ApprovalAuditSource::RelayControl,
                )
                .await
            {
                Ok(()) => RelayControlResponse::ok(request_id, json!({"accepted": true})),
                Err(error) => RelayControlResponse::error(request_id, error),
            }
        }
        RelayControlRequest::SetPhoneProfile {
            request_id,
            rows,
            cols,
            supports_binary_terminal,
        } => {
            runtime
                .set_terminal_binary_supported(supports_binary_terminal)
                .await;
            let rows = match u16::try_from(rows) {
                Ok(rows) => rows,
                Err(error) => return RelayControlResponse::error(request_id, error),
            };
            let cols = match u16::try_from(cols) {
                Ok(cols) => cols,
                Err(error) => return RelayControlResponse::error(request_id, error),
            };
            match runtime.set_phone_profile(rows, cols).await {
                Ok(state) => RelayControlResponse::ok(request_id, session_state_json(state)),
                Err(error) => RelayControlResponse::error(request_id, error),
            }
        }
        RelayControlRequest::SetWidthMode {
            request_id,
            tab_id,
            mode,
            computer_rows,
            computer_cols,
        } => {
            let computer_rows = match u16::try_from(computer_rows) {
                Ok(rows) => rows,
                Err(error) => return RelayControlResponse::error(request_id, error),
            };
            let computer_cols = match u16::try_from(computer_cols) {
                Ok(cols) => cols,
                Err(error) => return RelayControlResponse::error(request_id, error),
            };
            let mode = match mode.parse::<WidthMode>() {
                Ok(mode) => mode,
                Err(error) => return RelayControlResponse::error(request_id, error),
            };
            match runtime
                .set_width_mode(
                    &tab_id,
                    mode,
                    TerminalSize {
                        rows: computer_rows,
                        cols: computer_cols,
                    },
                )
                .await
            {
                Ok(state) => RelayControlResponse::ok(request_id, session_state_json(state)),
                Err(error) => RelayControlResponse::error(request_id, error),
            }
        }
        RelayControlRequest::SetFocusedTab { request_id, tab_id } => {
            runtime.set_focused_tab(tab_id).await;
            RelayControlResponse::ok(request_id, json!({"accepted": true}))
        }
        RelayControlRequest::CreateTab {
            request_id,
            title,
            cwd,
            launch,
        } => match runtime.create_tab_with(title, cwd, launch).await {
            Ok(state) => RelayControlResponse::ok(request_id, session_state_json(state)),
            Err(error) => RelayControlResponse::error(request_id, error),
        },
        RelayControlRequest::RenameTab {
            request_id,
            tab_id,
            title,
        } => match runtime.rename_tab(&tab_id, title).await {
            Ok(state) => RelayControlResponse::ok(request_id, session_state_json(state)),
            Err(error) => RelayControlResponse::error(request_id, error),
        },
        RelayControlRequest::CloseTab { request_id, tab_id } => {
            match runtime.close_tab(&tab_id).await {
                Ok(state) => RelayControlResponse::ok(request_id, session_state_json(state)),
                Err(error) => RelayControlResponse::error(request_id, error),
            }
        }
        RelayControlRequest::RestartTab { request_id, tab_id } => {
            match runtime.restart_tab(&tab_id).await {
                Ok(state) => RelayControlResponse::ok(request_id, session_state_json(state)),
                Err(error) => RelayControlResponse::error(request_id, error),
            }
        }
    }
}

impl RelayControlResponse {
    fn ok(request_id: String, payload: Value) -> Self {
        Self {
            request_id,
            ok: true,
            payload,
        }
    }

    fn error<E>(request_id: String, error: E) -> Self
    where
        E: std::fmt::Display,
    {
        Self {
            request_id,
            ok: false,
            payload: json!({"error": error.to_string()}),
        }
    }
}

fn relay_control_response_payload(
    binding: &BindingState,
    relay_message_id: Option<&str>,
    request_id: &str,
    ok: bool,
    payload: Value,
) -> Value {
    let mut response = json!({
        "type": "daemon_response",
        "requestId": request_id,
        "bindingId": binding.binding_id,
        "ok": ok,
        "data": payload,
    });
    if let Some(relay_message_id) = relay_message_id {
        response["relayMessageId"] = Value::String(relay_message_id.to_string());
    }
    response
}

fn approval_action_from_input(data: &[u8]) -> Option<ApprovalAuditAction> {
    let text = std::str::from_utf8(data).ok()?.trim();
    if text.eq_ignore_ascii_case("y") || text.eq_ignore_ascii_case("yes") {
        Some(ApprovalAuditAction::Approve)
    } else if text.eq_ignore_ascii_case("n") || text.eq_ignore_ascii_case("no") {
        Some(ApprovalAuditAction::Reject)
    } else {
        None
    }
}

fn relay_message_json(
    to_device_id: &str,
    relay_message_id: Option<&str>,
    payload: Value,
) -> String {
    let mut message = json!({
        "toDeviceId": to_device_id,
        "payload": payload,
    });
    if relay_message_id.is_none() {
        message["ephemeral"] = Value::Bool(true);
    }
    serde_json::to_string(&message).expect("relay response json should serialize")
}

/// Per-tab cap on buffered terminal bytes between flushes. Past this we can no
/// longer ship a contiguous delta, so the tab resyncs with a full snapshot.
const RELAY_TERMINAL_BUFFER_LIMIT: usize = 64 * 1024;

/// Coalescing floor between relay terminal flushes (~60fps burst floor),
/// overridable via `NUDGE_TERMINAL_FLUSH_MS` for on-device latency tuning.
fn relay_terminal_flush_interval() -> Duration {
    parse_flush_interval(std::env::var("NUDGE_TERMINAL_FLUSH_MS").ok())
}

fn parse_flush_interval(raw: Option<String>) -> Duration {
    const DEFAULT_MS: u64 = 16;
    const MAX_MS: u64 = 1000;
    let ms = raw
        .and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|ms| *ms > 0)
        .unwrap_or(DEFAULT_MS)
        .min(MAX_MS);
    Duration::from_millis(ms)
}

/// Buffered, not-yet-flushed terminal bytes for one tab, anchored to the
/// absolute offset of the first buffered byte so the flush can ship a delta the
/// phone can order against snapshots.
#[derive(Default)]
struct PendingOutput {
    offset: u64,
    data: Vec<u8>,
}

/// Buffer a terminal change for `tab_id`, anchored to its absolute `offset`.
/// Two conditions force a full snapshot instead of a delta: the buffered run
/// exceeding the relay cap (a delta would start mid-stream — roadmap R6), or a
/// non-contiguous offset (we'd otherwise ship a delta with a wrong start
/// position). Both re-baseline via [`snapshot_required`].
fn accumulate_terminal_change(
    pending: &mut BTreeMap<String, PendingOutput>,
    snapshot_required: &mut HashSet<String>,
    tab_id: String,
    offset: u64,
    data: &[u8],
) {
    let entry = pending.entry(tab_id.clone()).or_default();
    if entry.data.is_empty() {
        // Anchor a fresh run on the first byte's absolute offset. This also
        // re-anchors after an overflow clear, so the stored offset is always
        // accurate for the bytes currently buffered.
        entry.offset = offset;
    } else if offset != entry.offset + entry.data.len() as u64 {
        // Non-contiguous run — only reachable if the broadcast dropped items
        // (Lagged is handled separately) or after a future multi-reader
        // refactor. Re-baseline rather than emit a delta with a wrong offset.
        snapshot_required.insert(tab_id.clone());
        entry.offset = offset;
        entry.data.clear();
    }
    entry.data.extend_from_slice(data);
    if entry.data.len() > RELAY_TERMINAL_BUFFER_LIMIT {
        entry.data.clear();
        snapshot_required.insert(tab_id);
    }
}

/// A tab flushes as a full snapshot when it was explicitly flagged (overflow or
/// broadcast lag) or when it has no buffered bytes to ship as a delta.
fn tab_requires_snapshot(
    snapshot_required: &HashSet<String>,
    tab_id: &str,
    pending: &[u8],
) -> bool {
    snapshot_required.contains(tab_id) || pending.is_empty()
}

/// Whether this tab's pending output should be skipped on flush because the phone
/// is focused on a different tab. When no focus is set (`None`) every tab streams
/// as before; a skipped tab drops its delta AND its snapshot for this flush and
/// re-baselines via the gap→snapshot path when it regains focus.
fn tab_is_focus_filtered(focused: Option<&str>, tab_id: &str) -> bool {
    focused.is_some_and(|f| f != tab_id)
}

/// Drain the pending terminal buffers to the phone, sending a full snapshot for
/// any tab in `snapshot_required` (or with no buffered bytes) and an incremental
/// delta for the rest. Shared by the coalescing timer tick and the
/// immediate-on-idle path so both make the same snapshot-vs-delta decision.
// The relay-send context (binding, phone id, socket, e2e session) plus the two
// work sets and the focus filter is a wide-but-cohesive parameter list; bundling
// it into a struct would not make the two call sites clearer.
#[allow(clippy::too_many_arguments)]
async fn flush_pending_terminal_outputs<S>(
    runtime: &DaemonRuntime,
    binding: &BindingState,
    bound_phone_id: &str,
    websocket: &mut S,
    mut e2e_session: Option<&mut RelayE2ESession>,
    mut outputs: BTreeMap<String, PendingOutput>,
    snapshot_required: HashSet<String>,
    focused: Option<String>,
) -> Result<()>
where
    S: Sink<WebSocketMessage> + Unpin,
    S::Error: std::error::Error + Send + Sync + 'static,
{
    // Tabs flagged for a snapshot may carry no pending bytes (their buffer was
    // cleared on overflow, or they were flagged via broadcast lag), so union
    // them into the work set.
    for tab_id in &snapshot_required {
        outputs.entry(tab_id.clone()).or_default();
    }
    // Read the negotiated capability once per flush (connection-global, not
    // per-tab). Phase 4.1 Level A: terminal deltas go out as a binary E2E
    // plaintext only when the phone advertised support AND a session is active.
    let binary_supported = runtime.terminal_binary_supported().await;
    for (tab_id, pending) in outputs {
        // Background (non-focused) tabs are skipped entirely: we drop both their
        // pending delta and their snapshot for this flush. Their phone-side
        // offset goes stale, so the first delta after they regain focus arrives
        // with offset > nextOffset and the phone requests a fresh snapshot
        // (the existing gap→snapshot re-baseline). With no focus set, stream all.
        if tab_is_focus_filtered(focused.as_deref(), &tab_id) {
            continue;
        }
        let relay_payload = if tab_requires_snapshot(&snapshot_required, &tab_id, &pending.data) {
            // Snapshots stay on the JSON path: infrequent, and keeping them
            // human-readable aids debugging.
            let Some(payload) = live_terminal_snapshot_payload(runtime, binding, &tab_id).await
            else {
                continue;
            };
            relay_live_payload(binding, payload, e2e_session.as_deref_mut())?
        } else {
            let _ = runtime.refresh_agent_status_from_grid(&tab_id).await;
            if binary_supported && e2e_session.is_some() {
                // Phase 4.1 Level A: binary delta plaintext (drops the inner
                // base64). Encrypted under TERMINAL_BIN_MESSAGE_TYPE.
                relay_live_terminal_delta_binary_payload(
                    &tab_id,
                    pending.offset,
                    &pending.data,
                    e2e_session.as_deref_mut(),
                )?
            } else {
                let payload = relay_live_terminal_output_payload(
                    binding,
                    &tab_id,
                    pending.offset,
                    &pending.data,
                );
                relay_live_payload(binding, payload, e2e_session.as_deref_mut())?
            }
        };
        let Some(relay_payload) = relay_payload else { continue };
        let message = relay_message_json(bound_phone_id, None, relay_payload);
        websocket
            .send(WebSocketMessage::Text(message.into()))
            .await
            .context("failed to send relay terminal update")?;
    }
    Ok(())
}

async fn live_terminal_snapshot_payload(
    runtime: &DaemonRuntime,
    binding: &BindingState,
    tab_id: &str,
) -> Option<Value> {
    let (snapshot, offset) = runtime.terminal_snapshot(tab_id).await.ok()?;
    Some(relay_live_terminal_snapshot_payload(binding, &snapshot, offset))
}

fn relay_live_payload(
    binding: &BindingState,
    payload: Value,
    e2e_session: Option<&mut RelayE2ESession>,
) -> Result<Option<Value>> {
    let Some(session) = e2e_session else {
        return Ok(if binding.phone_public_key.is_some() {
            None
        } else {
            Some(payload)
        });
    };
    let encrypted = session
        .keys
        .encrypt("daemon_live_terminal", payload.to_string().as_bytes())?;
    Ok(Some(e2e::envelope_to_relay_payload(&encrypted)))
}

/// Phase 4.1 Level A — message type + binary plaintext layout for a live
/// terminal delta. Encrypted under this message type so the phone tells binary
/// deltas apart from JSON payloads via the (AAD-authenticated) envelope
/// `messageType`. The relay never sees plaintext, so this is a private
/// daemon↔phone contract — no relay change. Layout (big-endian):
///
/// ```text
/// [0]      version  u8  = TERMINAL_BIN_VERSION (1)
/// [1]      kind     u8  = TERMINAL_BIN_KIND_DELTA (1)
/// [2..10]  offset   u64  absolute stream offset (matches the JSON `offset`)
/// [10..12] tab_len  u16
/// [12..]   tab_id   UTF-8 (tab_len bytes), then the raw terminal bytes to EOF
/// ```
const TERMINAL_BIN_MESSAGE_TYPE: &str = "daemon_live_terminal_bin";
const TERMINAL_BIN_VERSION: u8 = 1;
const TERMINAL_BIN_KIND_DELTA: u8 = 1;

fn terminal_delta_binary_plaintext(tab_id: &str, offset: u64, data: &[u8]) -> Vec<u8> {
    let tab = tab_id.as_bytes();
    let tab_len = u16::try_from(tab.len()).unwrap_or(u16::MAX);
    let tab = &tab[..tab_len as usize];
    let mut frame = Vec::with_capacity(12 + tab.len() + data.len());
    frame.push(TERMINAL_BIN_VERSION);
    frame.push(TERMINAL_BIN_KIND_DELTA);
    frame.extend_from_slice(&offset.to_be_bytes());
    frame.extend_from_slice(&tab_len.to_be_bytes());
    frame.extend_from_slice(tab);
    frame.extend_from_slice(data);
    frame
}

/// Encrypt a binary terminal-delta plaintext into an E2E relay payload. Returns
/// `None` when there is no E2E session (binary plaintext requires encryption);
/// the flush path only selects this when a session is active, and falls back to
/// the JSON payload otherwise.
fn relay_live_terminal_delta_binary_payload(
    tab_id: &str,
    offset: u64,
    data: &[u8],
    e2e_session: Option<&mut RelayE2ESession>,
) -> Result<Option<Value>> {
    let Some(session) = e2e_session else {
        return Ok(None);
    };
    let plaintext = terminal_delta_binary_plaintext(tab_id, offset, data);
    let encrypted = session.keys.encrypt(TERMINAL_BIN_MESSAGE_TYPE, &plaintext)?;
    Ok(Some(e2e::envelope_to_relay_payload(&encrypted)))
}

#[cfg(test)]
fn parse_terminal_delta_binary_plaintext(frame: &[u8]) -> Option<(String, u64, Vec<u8>)> {
    if frame.len() < 12 || frame[0] != TERMINAL_BIN_VERSION || frame[1] != TERMINAL_BIN_KIND_DELTA {
        return None;
    }
    let offset = u64::from_be_bytes(frame[2..10].try_into().ok()?);
    let tab_len = u16::from_be_bytes(frame[10..12].try_into().ok()?) as usize;
    if frame.len() < 12 + tab_len {
        return None;
    }
    let tab_id = String::from_utf8(frame[12..12 + tab_len].to_vec()).ok()?;
    let data = frame[12 + tab_len..].to_vec();
    Some((tab_id, offset, data))
}

fn relay_live_terminal_snapshot_payload(
    binding: &BindingState,
    snapshot: &v1::TerminalSnapshot,
    offset: u64,
) -> Value {
    json!({
        "type": "daemon_response",
        "bindingId": binding.binding_id,
        "ok": true,
        "data": terminal_snapshot_json(snapshot, offset),
    })
}

#[cfg(test)]
fn relay_live_terminal_snapshot_json(
    to_device_id: &str,
    binding: &BindingState,
    snapshot: &v1::TerminalSnapshot,
    offset: u64,
) -> String {
    serde_json::to_string(&json!({
        "toDeviceId": to_device_id,
        "ephemeral": true,
        "payload": relay_live_terminal_snapshot_payload(binding, snapshot, offset),
    }))
    .expect("relay live terminal snapshot should serialize")
}

fn relay_live_terminal_output_payload(
    binding: &BindingState,
    tab_id: &str,
    offset: u64,
    data: &[u8],
) -> Value {
    json!({
        "type": "daemon_response",
        "bindingId": binding.binding_id,
        "ok": true,
        "data": terminal_output_json(tab_id, offset, data),
    })
}

#[cfg(test)]
fn relay_live_terminal_output_json(
    to_device_id: &str,
    binding: &BindingState,
    tab_id: &str,
    offset: u64,
    data: &[u8],
) -> String {
    serde_json::to_string(&json!({
        "toDeviceId": to_device_id,
        "ephemeral": true,
        "payload": relay_live_terminal_output_payload(binding, tab_id, offset, data),
    }))
    .expect("relay live terminal output should serialize")
}

fn relay_live_agent_status_payload(
    binding: &BindingState,
    tab_id: &str,
    status: &AgentStatus,
) -> Value {
    let status = status.to_proto();
    json!({
        "type": "daemon_response",
        "bindingId": binding.binding_id,
        "ok": true,
        "data": {
            "tabId": tab_id,
            "agentStatus": {
                "kind": status.kind,
                "state": status.state,
                "confidence": status.confidence,
                "source": status.source,
            },
        },
    })
}

#[cfg(test)]
fn relay_live_agent_status_json(
    to_device_id: &str,
    binding: &BindingState,
    tab_id: &str,
    status: &AgentStatus,
) -> String {
    serde_json::to_string(&json!({
        "toDeviceId": to_device_id,
        "ephemeral": true,
        "payload": relay_live_agent_status_payload(binding, tab_id, status),
    }))
    .expect("relay live agent status should serialize")
}

fn terminal_output_json(tab_id: &str, offset: u64, data: &[u8]) -> Value {
    json!({
        "tabId": tab_id,
        // Absolute start offset of these bytes in the tab's stream, so the phone
        // can order this delta against snapshots and detect gaps. Snapshots
        // carry the same axis (see terminal_snapshot_json).
        "offset": offset,
        "bytesBase64": base64_encode(data),
    })
}

fn payload_type(payload: &Value) -> Option<String> {
    payload
        .as_object()
        .and_then(|object| object.get("type"))
        .and_then(Value::as_str)
        .map(ToString::to_string)
}

fn replay_max_bytes(requested: u32) -> usize {
    if requested == 0 {
        32 * 1024
    } else {
        requested.min(128 * 1024) as usize
    }
}

fn terminal_snapshot_json(snapshot: &v1::TerminalSnapshot, offset: u64) -> Value {
    json!({
        "tabId": snapshot.tab_id,
        "rows": snapshot.rows,
        "cols": snapshot.cols,
        "text": snapshot.text,
        // Alt-screen-aware ANSI dump so full-screen TUIs (Claude, Codex) can be
        // reconstructed faithfully on the phone, not just the plain-text grid.
        "formatted": base64_encode(&snapshot.formatted),
        // Absolute stream offset this snapshot represents. The phone adopts it
        // as its baseline (nextOffset) and orders deltas against it.
        "offset": offset,
    })
}

fn base64_encode(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut encoded = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let first = chunk[0];
        let second = *chunk.get(1).unwrap_or(&0);
        let third = *chunk.get(2).unwrap_or(&0);
        let value = ((first as u32) << 16) | ((second as u32) << 8) | third as u32;
        encoded.push(ALPHABET[((value >> 18) & 0x3f) as usize] as char);
        encoded.push(ALPHABET[((value >> 12) & 0x3f) as usize] as char);
        if chunk.len() >= 2 {
            encoded.push(ALPHABET[((value >> 6) & 0x3f) as usize] as char);
        } else {
            encoded.push('=');
        }
        if chunk.len() == 3 {
            encoded.push(ALPHABET[(value & 0x3f) as usize] as char);
        } else {
            encoded.push('=');
        }
    }
    encoded
}

fn daemon_hostname() -> String {
    use std::sync::OnceLock;
    static HOSTNAME: OnceLock<String> = OnceLock::new();
    HOSTNAME
        .get_or_init(|| {
            let raw = std::process::Command::new("hostname")
                .output()
                .ok()
                .and_then(|output| String::from_utf8(output.stdout).ok())
                .map(|value| value.trim().to_string())
                .unwrap_or_default();
            let trimmed = raw.strip_suffix(".local").unwrap_or(raw.as_str()).trim();
            if trimmed.is_empty() {
                "Computer".to_string()
            } else {
                trimmed.to_string()
            }
        })
        .clone()
}

fn session_state_json(state: v1::SessionState) -> Value {
    let tabs: Vec<Value> = state
        .tabs
        .into_iter()
        .map(|tab| {
            json!({
                "id": tab.id,
                "title": tab.title,
                "status": tab.status,
                "widthMode": tab.width_mode,
                "rows": tab.rows,
                "cols": tab.cols,
                "agentStatus": tab.agent_status.map(|status| {
                    json!({
                        "kind": status.kind,
                        "state": status.state,
                        "confidence": status.confidence,
                        "source": status.source,
                    })
                }),
            })
        })
        .collect();
    json!({
        "tabs": tabs,
        "hostname": daemon_hostname(),
        "entitlement": state.entitlement.map(|entitlement| {
            json!({
                "plan": entitlement.plan,
                "maxBoundComputers": entitlement.max_bound_computers,
                "maxTabsPerComputer": entitlement.max_tabs_per_computer,
            })
        }),
        "phoneProfile": state.phone_profile.map(|profile| {
            json!({
                "rows": profile.rows,
                "cols": profile.cols,
            })
        }),
        "binding": state.binding.map(|binding| {
            json!({
                "relayUrl": binding.relay_url,
                "daemonDeviceId": binding.daemon_device_id,
                "bindingId": binding.binding_id,
                "code": binding.code,
                "expiresAt": binding.expires_at,
                "status": binding.status,
                "boundPhoneId": binding.bound_phone_id,
            })
        }),
    })
}

fn relay_websocket_url(binding: &BindingState) -> Result<String> {
    let base = binding.relay_url.trim_end_matches('/');
    let ws_base = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        anyhow::bail!("relay url must start with http:// or https://");
    };
    Ok(format!(
        "{ws_base}/ws/daemon?deviceId={}&bindingId={}",
        binding.daemon_device_id, binding.binding_id
    ))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SocketChallengeEnvelope {
    challenge: SocketChallenge,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SocketChallenge {
    id: String,
    message: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceKeyRotationRequest {
    device_id: String,
    new_public_key: String,
    signed_at: String,
    nonce: String,
    signature: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceEnvelope {
    device: RelayDevice,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RelayDevice {
    id: String,
    public_key: String,
}

fn prepare_device_key_rotation(
    device_id: &str,
    current_identity: &DeviceIdentity,
) -> Result<DeviceKeyRotation> {
    let identity = DeviceIdentity::generate()?;
    let signed_at = current_unix_millis().to_string();
    let nonce = random_rotation_nonce()?;
    let message = device_key_rotation_message(
        device_id,
        current_identity.public_key(),
        identity.public_key(),
        &signed_at,
        &nonce,
    );
    let signature = current_identity.sign(message.as_bytes())?;
    Ok(DeviceKeyRotation {
        identity,
        signed_at,
        nonce,
        signature,
    })
}

async fn rotate_relay_device_key(
    http_client: &HttpClient,
    binding: &BindingState,
    rotation: &DeviceKeyRotation,
) -> Result<()> {
    let response = http_client
        .post(format!(
            "{}/api/devices/rotate-key",
            binding.relay_url.trim_end_matches('/')
        ))
        .json(&DeviceKeyRotationRequest {
            device_id: binding.daemon_device_id.clone(),
            new_public_key: rotation.identity.public_key.clone(),
            signed_at: rotation.signed_at.clone(),
            nonce: rotation.nonce.clone(),
            signature: rotation.signature.clone(),
        })
        .send()
        .await
        .context("failed to request relay device key rotation")?;
    let status = response.status();
    let body = response
        .text()
        .await
        .context("failed to read relay device key rotation response")?;
    if !status.is_success() {
        anyhow::bail!("relay returned HTTP {status} from device key rotation: {body}");
    }
    let envelope: DeviceEnvelope =
        serde_json::from_str(&body).context("failed to decode relay device key rotation")?;
    if envelope.device.id != binding.daemon_device_id {
        anyhow::bail!("relay returned rotated device id for a different daemon");
    }
    if envelope.device.public_key != rotation.identity.public_key {
        anyhow::bail!("relay returned a different rotated daemon public key");
    }
    Ok(())
}

fn device_key_rotation_message(
    device_id: &str,
    current_public_key: &str,
    new_public_key: &str,
    signed_at: &str,
    nonce: &str,
) -> String {
    [
        "nudge.relay.device_key_rotation.v1",
        device_id,
        current_public_key,
        new_public_key,
        signed_at,
        nonce,
    ]
    .join("\n")
}

fn random_rotation_nonce() -> Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).context("failed to generate device key rotation nonce")?;
    Ok(format!("rotation-{}", BASE64_STANDARD.encode(bytes)))
}

async fn signed_relay_websocket_url(
    http_client: &HttpClient,
    binding: &BindingState,
    identity: &DeviceIdentity,
) -> Result<String> {
    let mut url = Url::parse(&relay_websocket_url(binding)?)
        .context("failed to parse relay websocket url")?;
    let challenge = issue_socket_challenge(http_client, binding).await?;
    let signature = identity.sign(challenge.message.as_bytes())?;
    url.query_pairs_mut()
        .append_pair("authChallengeId", &challenge.id)
        .append_pair("authChallengeSignature", &signature);
    Ok(url.to_string())
}

async fn issue_socket_challenge(
    http_client: &HttpClient,
    binding: &BindingState,
) -> Result<SocketChallenge> {
    let response = http_client
        .post(format!(
            "{}/api/ws/challenge",
            binding.relay_url.trim_end_matches('/')
        ))
        .json(&json!({
            "deviceId": binding.daemon_device_id,
            "bindingId": binding.binding_id,
        }))
        .send()
        .await
        .context("failed to request relay websocket challenge")?;
    let status = response.status();
    let body = response
        .text()
        .await
        .context("failed to read relay websocket challenge response")?;
    if !status.is_success() {
        anyhow::bail!("relay returned HTTP {status} from websocket challenge: {body}");
    }
    let envelope: SocketChallengeEnvelope =
        serde_json::from_str(&body).context("failed to decode relay websocket challenge")?;
    Ok(envelope.challenge)
}

#[cfg(test)]
fn legacy_signed_relay_websocket_url(
    binding: &BindingState,
    identity: &DeviceIdentity,
) -> Result<String> {
    let mut url = Url::parse(&relay_websocket_url(binding)?)
        .context("failed to parse relay websocket url")?;
    let timestamp = current_unix_millis().to_string();
    let nonce = random_nonce()?;
    let message = socket_signature_message(
        &binding.daemon_device_id,
        &binding.binding_id,
        &timestamp,
        &nonce,
    );
    let signature = identity.sign(message.as_bytes())?;
    url.query_pairs_mut()
        .append_pair("authTimestamp", &timestamp)
        .append_pair("authNonce", &nonce)
        .append_pair("authSignature", &signature);
    Ok(url.to_string())
}

#[cfg(test)]
fn socket_signature_message(
    device_id: &str,
    binding_id: &str,
    timestamp: &str,
    nonce: &str,
) -> String {
    [
        "nudge.relay.websocket.v1",
        device_id,
        binding_id,
        timestamp,
        nonce,
    ]
    .join("\n")
}

#[cfg(test)]
fn random_nonce() -> Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).context("failed to generate websocket auth nonce")?;
    Ok(BASE64_STANDARD.encode(bytes))
}

fn current_unix_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn decode_fixed_base64<const N: usize>(value: &str) -> Result<[u8; N]> {
    let bytes = BASE64_STANDARD.decode(value)?;
    let length = bytes.len();
    bytes
        .try_into()
        .map_err(|_| anyhow::anyhow!("expected {N} decoded bytes, got {length}"))
}

pub async fn run_server(config: DaemonConfig) -> Result<()> {
    let paths = IpcPaths::from_env_or_default()?;
    paths.prepare_runtime_dir()?;
    if paths.socket_path().exists() {
        match UnixStream::connect(paths.socket_path()).await {
            Ok(_) => {
                anyhow::bail!(
                    "daemon socket is already active at {}",
                    paths.socket_path().display()
                )
            }
            Err(_) => {
                paths.remove_stale_socket()?;
            }
        }
    }

    let state_store = StateStore::from_env_or_default()?;
    let (mut session, restored_from_disk) = state_store.load_or_create_with_status()?;
    if restored_from_disk {
        session.mark_all_tabs_needs_restart();
        state_store.save(&session)?;
    }
    let listener = UnixListener::bind(paths.socket_path())
        .with_context(|| format!("failed to bind {}", paths.socket_path().display()))?;
    fs::set_permissions(paths.socket_path(), fs::Permissions::from_mode(0o600))
        .with_context(|| format!("failed to secure {}", paths.socket_path().display()))?;

    let runtime = DaemonRuntime::new(state_store, session, paths.socket_path().to_path_buf());
    if !restored_from_disk {
        runtime.ensure_ptys().await?;
    }
    let relay_runtime = runtime.clone();
    tokio::spawn(async move {
        relay_connection_loop(relay_runtime).await;
    });

    if config.placeholder || config.foreground {
        let state = runtime.session_state().await;
        println!(
            "nudge daemon listening (placeholder={}, socket_path={}, state_path={}, tabs={})",
            config.placeholder,
            paths.socket_path().display(),
            runtime.state_store.path().display(),
            state.tabs.len()
        );
    }

    loop {
        tokio::select! {
            accept_result = listener.accept() => {
                let (stream, _) = accept_result.with_context(|| {
                    format!("failed to accept connection on {}", paths.socket_path().display())
                })?;
                let runtime = runtime.clone();
                tokio::spawn(async move {
                    if let Err(error) = handle_client(stream, runtime).await {
                        eprintln!("nudge daemon client error: {error:#}");
                    }
                });
            }
            _ = runtime.shutdown.notified() => {
                break;
            }
        }
    }

    paths.remove_stale_socket()?;
    Ok(())
}

async fn handle_client(mut stream: UnixStream, runtime: DaemonRuntime) -> Result<()> {
    let _client_guard = ClientCountGuard::new(runtime.connected_clients.clone());
    loop {
        let envelope = match read_envelope(&mut stream).await {
            Ok(envelope) => envelope,
            Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::ConnectionReset => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => return Ok(()),
            Err(error) => return Err(error).context("failed to read ipc envelope"),
        };
        let response = handle_envelope(envelope, &runtime).await;
        write_envelope(&mut stream, response)
            .await
            .context("failed to write ipc envelope")?;
    }
}

struct ClientCountGuard {
    connected_clients: Arc<AtomicU32>,
}

impl ClientCountGuard {
    fn new(connected_clients: Arc<AtomicU32>) -> Self {
        connected_clients.fetch_add(1, Ordering::Relaxed);
        Self { connected_clients }
    }
}

impl Drop for ClientCountGuard {
    fn drop(&mut self) {
        self.connected_clients.fetch_sub(1, Ordering::Relaxed);
    }
}

async fn handle_envelope(envelope: v1::Envelope, runtime: &DaemonRuntime) -> v1::Envelope {
    let response_payload = match handle_payload(envelope.payload, runtime).await {
        Ok(payload) => payload,
        Err(error) => v1::envelope::Payload::Error(v1::Error {
            code: "daemon_error".to_string(),
            message: format!("{error:#}"),
        }),
    };

    v1::Envelope {
        message_id: envelope.message_id,
        payload: Some(response_payload),
    }
}

async fn handle_payload(
    payload: Option<v1::envelope::Payload>,
    runtime: &DaemonRuntime,
) -> Result<v1::envelope::Payload> {
    let response_payload = match payload {
        Some(v1::envelope::Payload::AttachClient(_)) => Some(v1::envelope::Payload::SessionState(
            runtime.session_state().await,
        )),
        Some(v1::envelope::Payload::GetState(_)) => Some(v1::envelope::Payload::SessionState(
            runtime.session_state().await,
        )),
        Some(v1::envelope::Payload::DaemonStatusRequest(_)) => {
            Some(v1::envelope::Payload::DaemonStatus(runtime.status().await))
        }
        Some(v1::envelope::Payload::ClientExited(_)) => Some(v1::envelope::Payload::Ack(v1::Ack {
            message: "detached".to_string(),
        })),
        Some(v1::envelope::Payload::StopDaemon(_)) => {
            runtime.shutdown.notify_waiters();
            Some(v1::envelope::Payload::Ack(v1::Ack {
                message: "stopping".to_string(),
            }))
        }
        Some(v1::envelope::Payload::TerminalInput(input)) => {
            runtime
                .write_input_from(&input.tab_id, input.data, ApprovalAuditSource::LocalIpc)
                .await?;
            Some(v1::envelope::Payload::Ack(v1::Ack {
                message: "input accepted".to_string(),
            }))
        }
        Some(v1::envelope::Payload::TerminalOutputRequest(request)) => {
            let max_bytes = if request.max_bytes == 0 {
                4096
            } else {
                request.max_bytes.min(128 * 1024) as usize
            };
            let data = runtime.output_tail(&request.tab_id, max_bytes).await?;
            Some(v1::envelope::Payload::TerminalOutput(v1::TerminalOutput {
                tab_id: request.tab_id,
                data,
            }))
        }
        Some(v1::envelope::Payload::TerminalSnapshotRequest(request)) => {
            // Local IPC (CLI) consumes the protobuf snapshot only; the stream
            // offset is for the phone's JSON wire, so drop it here.
            let (snapshot, _offset) = runtime.terminal_snapshot(&request.tab_id).await?;
            Some(v1::envelope::Payload::TerminalSnapshot(snapshot))
        }
        Some(v1::envelope::Payload::TerminalRenderRequest(request)) => Some(
            v1::envelope::Payload::TerminalRender(runtime.terminal_render(&request.tab_id).await?),
        ),
        Some(v1::envelope::Payload::SetPhoneProfile(request)) => {
            let rows = u16::try_from(request.rows).context("rows do not fit in u16")?;
            let cols = u16::try_from(request.cols).context("cols do not fit in u16")?;
            Some(v1::envelope::Payload::SessionState(
                runtime.set_phone_profile(rows, cols).await?,
            ))
        }
        Some(v1::envelope::Payload::SetWidthMode(request)) => {
            let computer_rows =
                u16::try_from(request.computer_rows).context("computer_rows do not fit in u16")?;
            let computer_cols =
                u16::try_from(request.computer_cols).context("computer_cols do not fit in u16")?;
            let mode = request.mode.parse::<WidthMode>()?;
            Some(v1::envelope::Payload::SessionState(
                runtime
                    .set_width_mode(
                        &request.tab_id,
                        mode,
                        TerminalSize {
                            rows: computer_rows,
                            cols: computer_cols,
                        },
                    )
                    .await?,
            ))
        }
        Some(v1::envelope::Payload::SetBindingState(request)) => {
            let binding = binding_from_proto(
                request
                    .binding
                    .context("set_binding_state requires a binding")?,
            )?;
            Some(v1::envelope::Payload::SessionState(
                runtime.set_binding(binding).await?,
            ))
        }
        Some(v1::envelope::Payload::SetEntitlement(request)) => {
            let entitlement = entitlement_from_proto(
                request
                    .entitlement
                    .context("set_entitlement requires an entitlement")?,
            );
            Some(v1::envelope::Payload::SessionState(
                runtime.set_entitlement(entitlement).await?,
            ))
        }
        Some(v1::envelope::Payload::ClearBindingState(_)) => Some(
            v1::envelope::Payload::SessionState(runtime.clear_binding().await?),
        ),
        Some(v1::envelope::Payload::RotateDeviceKey(_)) => Some(
            v1::envelope::Payload::SessionState(runtime.rotate_device_key().await?),
        ),
        Some(v1::envelope::Payload::CreateTab(request)) => Some(
            v1::envelope::Payload::SessionState(runtime.create_tab(request.title).await?),
        ),
        Some(v1::envelope::Payload::RenameTab(request)) => {
            Some(v1::envelope::Payload::SessionState(
                runtime.rename_tab(&request.tab_id, request.title).await?,
            ))
        }
        Some(v1::envelope::Payload::CloseTab(request)) => Some(
            v1::envelope::Payload::SessionState(runtime.close_tab(&request.tab_id).await?),
        ),
        Some(v1::envelope::Payload::ResizeTab(request)) => {
            let rows = u16::try_from(request.rows).context("rows do not fit in u16")?;
            let cols = u16::try_from(request.cols).context("cols do not fit in u16")?;
            runtime
                .resize_tab(&request.tab_id, TerminalSize { rows, cols })
                .await?;
            Some(v1::envelope::Payload::Ack(v1::Ack {
                message: "resize accepted".to_string(),
            }))
        }
        Some(v1::envelope::Payload::RestartTab(request)) => Some(
            v1::envelope::Payload::SessionState(runtime.restart_tab(&request.tab_id).await?),
        ),
        Some(_) => Some(v1::envelope::Payload::Error(v1::Error {
            code: "unsupported_message".to_string(),
            message: "daemon cannot handle this message yet".to_string(),
        })),
        None => Some(v1::envelope::Payload::Error(v1::Error {
            code: "empty_message".to_string(),
            message: "ipc envelope did not include a payload".to_string(),
        })),
    };
    Ok(response_payload.expect("all daemon payload branches return a response"))
}

pub async fn request(envelope: v1::Envelope) -> Result<v1::Envelope> {
    let paths = IpcPaths::from_env_or_default()?;
    let mut stream = UnixStream::connect(paths.socket_path())
        .await
        .with_context(|| format!("failed to connect to {}", paths.socket_path().display()))?;
    write_envelope(&mut stream, envelope)
        .await
        .context("failed to write ipc request")?;
    read_envelope(&mut stream)
        .await
        .context("failed to read ipc response")
}

pub async fn ping_socket() -> Result<()> {
    let paths = IpcPaths::from_env_or_default()?;
    let stream = UnixStream::connect(paths.socket_path())
        .await
        .with_context(|| format!("failed to connect to {}", paths.socket_path().display()))?;
    drop(stream);
    Ok(())
}

pub async fn wait_for_socket(timeout: Duration) -> Result<()> {
    let started_at = Instant::now();
    loop {
        if ping_socket().await.is_ok() {
            return Ok(());
        }
        if started_at.elapsed() >= timeout {
            anyhow::bail!("timed out waiting for daemon socket");
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

async fn read_envelope(stream: &mut UnixStream) -> std::io::Result<v1::Envelope> {
    let frame_len = stream.read_u32().await? as usize;
    if frame_len > 8 * 1024 * 1024 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            IpcError::FrameTooLarge(frame_len),
        ));
    }

    let mut bytes = vec![0; frame_len];
    stream.read_exact(&mut bytes).await?;
    v1::Envelope::decode(bytes.as_slice()).map_err(|error| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("failed to decode ipc envelope: {error}"),
        )
    })
}

async fn write_envelope(stream: &mut UnixStream, envelope: v1::Envelope) -> std::io::Result<()> {
    let bytes = envelope.encode_to_vec();
    let frame_len = u32::try_from(bytes.len()).map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            IpcError::FrameTooLarge(bytes.len()),
        )
    })?;
    stream.write_u32(frame_len).await?;
    stream.write_all(&bytes).await?;
    stream.flush().await
}

pub async fn run_placeholder(config: DaemonConfig) -> Result<()> {
    run_server(config).await
}

fn now_string() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .to_string()
}

fn default_rows() -> u16 {
    24
}

fn default_cols() -> u16 {
    80
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Serializes every test that depends on the process-global
    /// `NUDGE_DAEMON_PLAN` value (both the override tests and the entitlement
    /// tests that assume it is unset), so they cannot observe each other's
    /// mutations under cargo's parallel test runner.
    static DAEMON_PLAN_ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// RAII guard that holds [`DAEMON_PLAN_ENV_LOCK`] and sets/clears
    /// `NUDGE_DAEMON_PLAN` for the duration of a test, restoring (clearing) it
    /// on drop even if the test panics.
    struct DaemonPlanEnvGuard {
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    impl DaemonPlanEnvGuard {
        fn unset() -> Self {
            let lock = DAEMON_PLAN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            // SAFETY: env access is serialized by the held lock.
            unsafe { std::env::remove_var("NUDGE_DAEMON_PLAN") };
            Self { _lock: lock }
        }

        fn set(plan: &str) -> Self {
            let lock = DAEMON_PLAN_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            // SAFETY: env access is serialized by the held lock.
            unsafe { std::env::set_var("NUDGE_DAEMON_PLAN", plan) };
            Self { _lock: lock }
        }
    }

    impl Drop for DaemonPlanEnvGuard {
        fn drop(&mut self) {
            // SAFETY: still holding the lock until this guard is dropped.
            unsafe { std::env::remove_var("NUDGE_DAEMON_PLAN") };
        }
    }

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

    #[test]
    fn approval_action_classifier_accepts_only_explicit_answers() {
        assert_eq!(
            approval_action_from_input(b"y\r"),
            Some(ApprovalAuditAction::Approve)
        );
        assert_eq!(
            approval_action_from_input(b"YES\n"),
            Some(ApprovalAuditAction::Approve)
        );
        assert_eq!(
            approval_action_from_input(b"n\r"),
            Some(ApprovalAuditAction::Reject)
        );
        assert_eq!(approval_action_from_input(b"yes please\r"), None);
        assert_eq!(approval_action_from_input("确认\n".as_bytes()), None);
    }

    #[test]
    fn daemon_audit_writes_approval_metadata_without_input_text() {
        let root = std::env::temp_dir().join(format!(
            "nudge-daemon-audit-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let audit_path = root.join("daemon-audit.jsonl");
        let sink = DaemonAuditSink {
            path: audit_path.clone(),
        };
        let status = AgentStatus {
            kind: AgentKind::Claude,
            state: AgentInteractionState::NeedsApproval,
            confidence: 0.84,
            source: AgentDetectionSource::Screen,
        };

        sink.write_approval_action(
            "default",
            &status,
            ApprovalAuditAction::Approve,
            ApprovalAuditSource::RelayControl,
        )
        .expect("audit event should write");

        let audit_text = fs::read_to_string(&audit_path).expect("audit log should exist");
        assert!(audit_text.contains(r#""type":"approval_action""#));
        assert!(audit_text.contains(r#""tab_id":"default""#));
        assert!(audit_text.contains(r#""agent_kind":"claude""#));
        assert!(audit_text.contains(r#""action":"approve""#));
        assert!(audit_text.contains(r#""source":"relay_control""#));
        assert!(!audit_text.contains(r#""text""#));
        assert!(!audit_text.contains("y\r"));

        let permissions = fs::metadata(&audit_path)
            .expect("audit log metadata")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(permissions, 0o600);
        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn runtime_prepares_approval_audit_only_for_approval_state() {
        let root = std::env::temp_dir().join(format!(
            "nudge-daemon-audit-event-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let state_path = root.join("state").join("session.json");
        let socket_path = root.join("run").join("nudge.sock");
        let mut session = MachineSession::new_default();
        session.tabs[0].agent_status = AgentStatus {
            kind: AgentKind::Codex,
            state: AgentInteractionState::NeedsApproval,
            confidence: 0.82,
            source: AgentDetectionSource::Screen,
        };
        let mut runtime = DaemonRuntime::new(StateStore::new(state_path), session, socket_path);
        runtime.audit_sink = Some(DaemonAuditSink {
            path: root.join("daemon-audit.jsonl"),
        });

        let event = runtime
            .approval_audit_event("default", b"y\r", ApprovalAuditSource::LocalIpc)
            .await
            .expect("approval input should prepare audit event");
        assert_eq!(event.0.kind, AgentKind::Codex);
        assert_eq!(event.1, ApprovalAuditAction::Approve);
        assert_eq!(event.2, ApprovalAuditSource::LocalIpc);

        assert!(
            runtime
                .approval_audit_event("default", b"continue\r", ApprovalAuditSource::LocalIpc)
                .await
                .is_none()
        );
        {
            let mut session = runtime.session.lock().await;
            session.tabs[0].agent_status.state = AgentInteractionState::WaitingForInput;
        }
        assert!(
            runtime
                .approval_audit_event("default", b"y\r", ApprovalAuditSource::LocalIpc)
                .await
                .is_none()
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn entitlement_update_controls_tab_limit() {
        let _env = DaemonPlanEnvGuard::unset();
        let mut session = MachineSession::new_default();
        let suspended = session.set_entitlement(Entitlement {
            plan: "paid".to_string(),
            max_bound_computers: 1,
            max_tabs_per_computer: 3,
            updated_at: "1".to_string(),
        });
        assert!(suspended.is_empty());

        session
            .create_tab("second".to_string())
            .expect("updated entitlement should allow more tabs");

        assert_eq!(session.tabs.len(), 2);
        let entitlement = session
            .to_proto()
            .entitlement
            .expect("entitlement should be present");
        assert_eq!(entitlement.plan, "paid");
        assert_eq!(entitlement.max_tabs_per_computer, 3);
    }

    #[test]
    fn entitlement_downgrade_suspends_excess_tabs_without_deleting_metadata() {
        let _env = DaemonPlanEnvGuard::unset();
        let mut session = MachineSession::new_default();
        session.set_entitlement(Entitlement {
            plan: "paid".to_string(),
            max_bound_computers: 1,
            max_tabs_per_computer: 3,
            updated_at: "1".to_string(),
        });
        session
            .create_tab("second".to_string())
            .expect("paid entitlement should allow second tab");
        session
            .create_tab("third".to_string())
            .expect("paid entitlement should allow third tab");

        let suspended = session.set_entitlement(Entitlement::free());

        assert_eq!(suspended, vec!["tab-2".to_string(), "tab-3".to_string()]);
        assert_eq!(session.tabs.len(), 3);
        assert!(matches!(session.tabs[0].status, TabStatus::Running));
        assert!(matches!(session.tabs[1].status, TabStatus::NeedsRestart));
        assert!(matches!(session.tabs[2].status, TabStatus::NeedsRestart));
        assert_eq!(session.entitlement.max_tabs_per_computer, 1);
        assert_eq!(
            session.tabs[1].agent_status.state,
            AgentInteractionState::Exited
        );
    }

    #[tokio::test]
    async fn runtime_entitlement_downgrade_stops_excess_tab_ptys() {
        let _env = DaemonPlanEnvGuard::unset();
        let root = std::env::temp_dir().join(format!(
            "nudge-entitlement-downgrade-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let state_path = root.join("state").join("session.json");
        let socket_path = root.join("run").join("nudge.sock");
        let mut session = MachineSession::new_default();
        session.set_entitlement(Entitlement {
            plan: "paid".to_string(),
            max_bound_computers: 1,
            max_tabs_per_computer: 3,
            updated_at: "1".to_string(),
        });
        session
            .create_tab("second".to_string())
            .expect("paid entitlement should allow second tab");
        session
            .create_tab("third".to_string())
            .expect("paid entitlement should allow third tab");
        let runtime = DaemonRuntime::new(StateStore::new(state_path), session, socket_path);
        runtime.ensure_ptys().await.expect("ptys should start");
        assert!(
            runtime
                .write_input("default", b"echo keep\r".to_vec())
                .await
                .is_ok()
        );
        assert!(
            runtime
                .write_input("tab-2", b"echo suspend\r".to_vec())
                .await
                .is_ok()
        );

        let state = runtime
            .set_entitlement(Entitlement::free())
            .await
            .expect("downgrade should apply");

        assert_eq!(
            state
                .entitlement
                .expect("entitlement")
                .max_tabs_per_computer,
            1
        );
        assert_eq!(state.tabs[0].status, "running");
        assert_eq!(state.tabs[1].status, "needs_restart");
        assert_eq!(state.tabs[2].status, "needs_restart");
        assert!(
            runtime
                .write_input("default", b"echo still-running\r".to_vec())
                .await
                .is_ok()
        );
        assert!(
            runtime
                .write_input("tab-2", b"echo should-fail\r".to_vec())
                .await
                .is_err()
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn relay_control_tab_actions_return_session_state() {
        let _env = DaemonPlanEnvGuard::unset();
        let root = std::env::temp_dir().join(format!(
            "nudge-relay-tab-actions-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let state_path = root.join("state").join("session.json");
        let socket_path = root.join("run").join("nudge.sock");
        let mut session = MachineSession::new_default();
        session.set_entitlement(Entitlement {
            plan: "paid".to_string(),
            max_bound_computers: 1,
            max_tabs_per_computer: 2,
            updated_at: "1".to_string(),
        });
        let runtime = DaemonRuntime::new(StateStore::new(state_path), session, socket_path);

        let response = handle_relay_control_request(
            &runtime,
            RelayControlRequest::CreateTab {
                request_id: "create-1".to_string(),
                title: "shell".to_string(),
                cwd: None,
                launch: None,
            },
        )
        .await;
        assert!(response.ok);
        assert_eq!(response.payload["tabs"][1]["id"], "tab-2");

        let response = handle_relay_control_request(
            &runtime,
            RelayControlRequest::RenameTab {
                request_id: "rename-1".to_string(),
                tab_id: "tab-2".to_string(),
                title: "Claude".to_string(),
            },
        )
        .await;
        assert!(response.ok);
        assert_eq!(response.payload["tabs"][1]["title"], "Claude");

        let response = handle_relay_control_request(
            &runtime,
            RelayControlRequest::RestartTab {
                request_id: "restart-1".to_string(),
                tab_id: "tab-2".to_string(),
            },
        )
        .await;
        assert!(response.ok);
        assert_eq!(response.payload["tabs"][1]["status"], "running");

        let response = handle_relay_control_request(
            &runtime,
            RelayControlRequest::CloseTab {
                request_id: "close-1".to_string(),
                tab_id: "tab-2".to_string(),
            },
        )
        .await;
        assert!(response.ok);
        assert_eq!(response.payload["tabs"].as_array().map(Vec::len), Some(1));
        assert_eq!(response.payload["tabs"][0]["id"], "default");

        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn relay_control_set_focused_tab_updates_runtime() {
        let _env = DaemonPlanEnvGuard::unset();
        let root = std::env::temp_dir().join(format!(
            "nudge-relay-focused-tab-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let state_path = root.join("state").join("session.json");
        let socket_path = root.join("run").join("nudge.sock");
        let runtime = DaemonRuntime::new(
            StateStore::new(state_path),
            MachineSession::new_default(),
            socket_path,
        );

        // No focus by default → every tab streams.
        assert_eq!(runtime.focused_tab().await, None);

        let response = handle_relay_control_request(
            &runtime,
            RelayControlRequest::SetFocusedTab {
                request_id: "focus-1".to_string(),
                tab_id: Some("tab-2".to_string()),
            },
        )
        .await;
        assert!(response.ok);
        assert_eq!(response.payload["accepted"], true);
        assert_eq!(runtime.focused_tab().await, Some("tab-2".to_string()));

        // A null tab_id clears the focus, reverting to streaming every tab.
        let response = handle_relay_control_request(
            &runtime,
            RelayControlRequest::SetFocusedTab {
                request_id: "focus-2".to_string(),
                tab_id: None,
            },
        )
        .await;
        assert!(response.ok);
        assert_eq!(response.payload["accepted"], true);
        assert_eq!(runtime.focused_tab().await, None);

        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn set_phone_profile_negotiates_binary_terminal_capability() {
        let _env = DaemonPlanEnvGuard::unset();
        let root = std::env::temp_dir().join(format!(
            "nudge-relay-binary-cap-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let state_path = root.join("state").join("session.json");
        let socket_path = root.join("run").join("nudge.sock");
        let runtime = DaemonRuntime::new(
            StateStore::new(state_path),
            MachineSession::new_default(),
            socket_path,
        );

        // Default: JSON path (legacy phones never advertise binary support).
        assert!(!runtime.terminal_binary_supported().await);

        let response = handle_relay_control_request(
            &runtime,
            RelayControlRequest::SetPhoneProfile {
                request_id: "profile-1".to_string(),
                rows: 24,
                cols: 80,
                supports_binary_terminal: true,
            },
        )
        .await;
        assert!(response.ok);
        assert!(runtime.terminal_binary_supported().await);

        // A phone that stops advertising support reverts to the JSON path.
        let response = handle_relay_control_request(
            &runtime,
            RelayControlRequest::SetPhoneProfile {
                request_id: "profile-2".to_string(),
                rows: 30,
                cols: 100,
                supports_binary_terminal: false,
            },
        )
        .await;
        assert!(response.ok);
        assert!(!runtime.terminal_binary_supported().await);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn terminal_delta_binary_plaintext_round_trips() {
        // Raw terminal bytes include non-UTF-8 (0xff) and NUL — the binary path
        // must carry them verbatim (the whole point vs. base64-in-JSON).
        let data: &[u8] = b"hello\x1b[0m\xff\x00world";
        let offset: u64 = 0x0102_0304_0506_0708;
        let frame = terminal_delta_binary_plaintext("tab-7", offset, data);
        assert_eq!(frame[0], TERMINAL_BIN_VERSION);
        assert_eq!(frame[1], TERMINAL_BIN_KIND_DELTA);
        assert_eq!(&frame[2..10], offset.to_be_bytes().as_slice());
        assert_eq!(&frame[10..12], 5u16.to_be_bytes().as_slice());
        let (tab_id, parsed_offset, parsed) =
            parse_terminal_delta_binary_plaintext(&frame).expect("round-trips");
        assert_eq!(tab_id, "tab-7");
        assert_eq!(parsed_offset, offset);
        assert_eq!(parsed.as_slice(), data);
    }

    #[test]
    fn parse_terminal_delta_binary_plaintext_rejects_malformed() {
        // Shorter than the 12-byte header.
        assert!(parse_terminal_delta_binary_plaintext(&[1, 1, 0, 0]).is_none());
        // Wrong version byte.
        let mut wrong_version = terminal_delta_binary_plaintext("t", 1, b"x");
        wrong_version[0] = 2;
        assert!(parse_terminal_delta_binary_plaintext(&wrong_version).is_none());
        // tab_len claims more bytes than the frame holds.
        let mut overlong_tab = terminal_delta_binary_plaintext("tab", 1, b"");
        overlong_tab[11] = 250;
        assert!(parse_terminal_delta_binary_plaintext(&overlong_tab).is_none());
    }

    #[tokio::test]
    async fn closing_the_focused_tab_clears_focus() {
        // Regression (Phase 3-5 review): closing the focused tab must clear focus,
        // else tab_is_focus_filtered skips EVERY surviving tab and black-holes all
        // live output until the phone re-sends focus.
        let _env = DaemonPlanEnvGuard::set("PAID");
        let root = std::env::temp_dir().join(format!(
            "nudge-close-focus-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let state_path = root.join("state").join("session.json");
        let socket_path = root.join("run").join("nudge.sock");
        let mut session = MachineSession::new_default();
        session.apply_entitlement_override();
        session.create_tab("tab-2".to_string()).expect("second tab");
        session.create_tab("tab-3".to_string()).expect("third tab");
        let runtime = DaemonRuntime::new(StateStore::new(state_path), session, socket_path);

        runtime.set_focused_tab(Some("default".to_string())).await;

        // Closing a NON-focused tab leaves focus intact.
        runtime.close_tab("tab-2").await.expect("close non-focused tab");
        assert_eq!(runtime.focused_tab().await, Some("default".to_string()));

        // Closing the FOCUSED tab clears focus (revert to stream-all so the
        // surviving tabs aren't black-holed).
        runtime.close_tab("default").await.expect("close focused tab");
        assert_eq!(runtime.focused_tab().await, None);

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn tab_launch_parses_agent_keys_case_insensitively() {
        assert_eq!(TabLaunch::parse(None), TabLaunch::Shell);
        assert_eq!(TabLaunch::parse(Some("shell")), TabLaunch::Shell);
        assert_eq!(TabLaunch::parse(Some(" Claude ")), TabLaunch::Claude);
        assert_eq!(TabLaunch::parse(Some("CODEX")), TabLaunch::Codex);
        assert_eq!(TabLaunch::parse(Some("other")), TabLaunch::Shell);
    }

    #[test]
    fn tab_launch_builds_trust_bypass_commands() {
        assert_eq!(
            TabLaunch::Claude.initial_command(Some("/Users/me/Projects/app")),
            Some(
                "cd '/Users/me/Projects/app' && claude --dangerously-skip-permissions\n"
                    .to_string()
            )
        );
        assert_eq!(
            TabLaunch::Codex.initial_command(Some("/Users/me/Projects/app")),
            Some(
                "cd '/Users/me/Projects/app' && codex --dangerously-bypass-approvals-and-sandbox\n"
                    .to_string()
            )
        );
        // Empty/blank cwd: run the agent without a cd.
        assert_eq!(
            TabLaunch::Claude.initial_command(Some("   ")),
            Some("claude --dangerously-skip-permissions\n".to_string())
        );
        assert_eq!(
            TabLaunch::Claude.initial_command(None),
            Some("claude --dangerously-skip-permissions\n".to_string())
        );
        // Plain shell: cd only when a directory is supplied, never an agent.
        assert_eq!(
            TabLaunch::Shell.initial_command(Some("/tmp/work")),
            Some("cd '/tmp/work'\n".to_string())
        );
        assert_eq!(TabLaunch::Shell.initial_command(None), None);
    }

    #[test]
    fn shell_single_quote_escapes_embedded_single_quotes() {
        assert_eq!(shell_single_quote("/tmp/plain"), "'/tmp/plain'");
        assert_eq!(
            shell_single_quote("/tmp/o'brien && rm -rf /"),
            "'/tmp/o'\\''brien && rm -rf /'"
        );
    }

    #[test]
    fn canonical_launch_dir_resolves_symlinks() {
        // Regression: Codex/Claude key directory trust off the canonical,
        // symlink-resolved path (e.g. `/tmp` -> `/private/tmp` on macOS). The
        // pre-trust entry must be written under that resolved path or the
        // agent still shows its first-run trust prompt.
        use std::os::unix::fs::symlink;
        let base = std::env::temp_dir().join(format!("nudge-canon-{}", std::process::id()));
        let real = base.join("real");
        let link = base.join("link");
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&real).expect("create real dir");
        symlink(&real, &link).expect("create symlink");

        let resolved = canonical_launch_dir(link.clone());
        assert_eq!(resolved, std::fs::canonicalize(&real).expect("canonicalize real"));
        assert_ne!(resolved, link, "symlink path should be resolved away");

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn canonical_launch_dir_falls_back_for_missing_path() {
        let missing = std::path::PathBuf::from("/no/such/nudge/launch/dir/xyz");
        assert_eq!(canonical_launch_dir(missing.clone()), missing);
    }

    #[test]
    fn codex_config_appends_trusted_project_to_empty_config() {
        let updated = codex_config_with_trusted_project("", "/Users/me/Projects/app")
            .expect("an empty config should gain a trusted-project entry");
        assert_eq!(
            updated,
            "[projects.\"/Users/me/Projects/app\"]\ntrust_level = \"trusted\"\n"
        );
    }

    #[test]
    fn codex_config_appends_trusted_project_preserving_existing_contents() {
        let existing = "model = \"gpt-5.5\"\n\n[projects.\"/other\"]\ntrust_level = \"trusted\"\n";
        let updated = codex_config_with_trusted_project(existing, "/Users/me/Projects/app")
            .expect("a populated config should gain a trusted-project entry");
        assert_eq!(
            updated,
            "model = \"gpt-5.5\"\n\n[projects.\"/other\"]\ntrust_level = \"trusted\"\n\n\
             [projects.\"/Users/me/Projects/app\"]\ntrust_level = \"trusted\"\n"
        );
    }

    #[test]
    fn codex_config_inserts_newline_when_existing_lacks_trailing_newline() {
        let updated = codex_config_with_trusted_project("model = \"gpt-5.5\"", "/tmp/work")
            .expect("config without trailing newline should still gain an entry");
        assert_eq!(
            updated,
            "model = \"gpt-5.5\"\n\n[projects.\"/tmp/work\"]\ntrust_level = \"trusted\"\n"
        );
    }

    #[test]
    fn codex_config_skips_write_when_project_already_declared() {
        let existing =
            "[projects.\"/Users/me/Projects/app\"]\ntrust_level = \"trusted\"\n";
        assert_eq!(
            codex_config_with_trusted_project(existing, "/Users/me/Projects/app"),
            None
        );
    }

    #[test]
    fn codex_config_escapes_quotes_and_backslashes_in_path() {
        let updated = codex_config_with_trusted_project("", "/tmp/o\"brien\\dir")
            .expect("a path with special characters should still produce an entry");
        assert_eq!(
            updated,
            "[projects.\"/tmp/o\\\"brien\\\\dir\"]\ntrust_level = \"trusted\"\n"
        );
    }

    #[test]
    fn tab_launch_titles_match_agent() {
        assert_eq!(TabLaunch::Claude.tab_title("ignored"), "claude");
        assert_eq!(TabLaunch::Codex.tab_title("ignored"), "codex");
        assert_eq!(TabLaunch::Shell.tab_title("my tab"), "my tab");
        assert_eq!(TabLaunch::Shell.tab_title("   "), "shell");
    }

    #[tokio::test]
    async fn create_tab_with_claude_launch_titles_tab_and_runs_command() {
        let _env = DaemonPlanEnvGuard::set("pro");

        let root = std::env::temp_dir().join(format!(
            "nudge-create-tab-launch-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let state_path = root.join("state").join("session.json");
        let socket_path = root.join("run").join("nudge.sock");
        let mut session = MachineSession::new_default();
        session.apply_entitlement_override();
        let runtime = DaemonRuntime::new(StateStore::new(state_path), session, socket_path);
        runtime.ensure_ptys().await.expect("ptys should start");

        let state = runtime
            .create_tab_with(
                "ignored".to_string(),
                Some("/tmp/projects/app".to_string()),
                Some("claude".to_string()),
            )
            .await
            .expect("create_tab with claude launch should succeed");

        assert_eq!(state.tabs.len(), 2);
        assert_eq!(state.tabs[1].id, "tab-2");
        assert_eq!(state.tabs[1].title, "claude");

        // The daemon-built launch command must reach the new tab's PTY.
        tokio::time::sleep(Duration::from_millis(150)).await;
        let tail = runtime
            .output_tail("tab-2", 8 * 1024)
            .await
            .expect("tab-2 should have a pty");
        let tail = String::from_utf8_lossy(&tail);
        assert!(
            tail.contains("claude --dangerously-skip-permissions"),
            "expected trust-bypass command in pty output, got: {tail}"
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn output_tail_is_empty_for_a_tab_without_a_live_pty() {
        // A tab restored from state after a daemon restart has no live PTY
        // (status needs_restart). The phone requests each tab's output on
        // sessionState; output_tail must yield empty here, NOT an error —
        // erroring made the daemon reply ok=false, which the phone treated as
        // fatal and wedged it in a relay-reconnect loop.
        let root = std::env::temp_dir().join(format!(
            "nudge-output-tail-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let state_path = root.join("state").join("session.json");
        let socket_path = root.join("run").join("nudge.sock");
        let session = MachineSession::new_default();
        // No ensure_ptys(): the default tab keeps pty: None, mimicking a
        // needs_restart tab whose process has exited.
        let runtime = DaemonRuntime::new(StateStore::new(state_path), session, socket_path);

        let tail = runtime
            .output_tail("default", 8 * 1024)
            .await
            .expect("a tab without a live PTY should yield an empty tail, not an error");
        assert!(tail.is_empty());

        // A tab that does not exist at all is still a genuine error.
        assert!(runtime.output_tail("no-such-tab", 8 * 1024).await.is_err());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn small_terminal_change_stays_a_delta() {
        let mut pending: BTreeMap<String, PendingOutput> = BTreeMap::new();
        let mut snapshot_required: HashSet<String> = HashSet::new();

        accumulate_terminal_change(&mut pending, &mut snapshot_required, "tab".into(), 0, b"hello");

        let entry = pending.get("tab").expect("tab should be buffered");
        assert_eq!(entry.offset, 0);
        assert_eq!(entry.data.as_slice(), b"hello");
        assert!(!snapshot_required.contains("tab"));
        assert!(!tab_requires_snapshot(&snapshot_required, "tab", &entry.data));
    }

    #[test]
    fn contiguous_changes_extend_one_delta() {
        let mut pending: BTreeMap<String, PendingOutput> = BTreeMap::new();
        let mut snapshot_required: HashSet<String> = HashSet::new();

        // A fresh run anchors on the first byte's absolute offset...
        accumulate_terminal_change(&mut pending, &mut snapshot_required, "tab".into(), 100, b"ab");
        // ...and a contiguous follow-on (offset 102 == 100 + 2) extends the same
        // buffer without forcing a snapshot.
        accumulate_terminal_change(&mut pending, &mut snapshot_required, "tab".into(), 102, b"cd");

        let entry = pending.get("tab").expect("tab should be buffered");
        assert_eq!(entry.offset, 100);
        assert_eq!(entry.data.as_slice(), b"abcd");
        assert!(!snapshot_required.contains("tab"));
    }

    #[test]
    fn non_contiguous_offset_forces_snapshot_and_rebaselines() {
        let mut pending: BTreeMap<String, PendingOutput> = BTreeMap::new();
        let mut snapshot_required: HashSet<String> = HashSet::new();

        accumulate_terminal_change(&mut pending, &mut snapshot_required, "tab".into(), 100, b"ab");
        // A gap (expected 102, got 200 — bytes were lost) must re-baseline via a
        // snapshot and re-anchor on the new offset, never ship a delta whose
        // start offset is wrong.
        accumulate_terminal_change(&mut pending, &mut snapshot_required, "tab".into(), 200, b"zz");

        assert!(snapshot_required.contains("tab"));
        let entry = pending.get("tab").expect("tab should be buffered");
        assert_eq!(entry.offset, 200);
        assert_eq!(entry.data.as_slice(), b"zz");
    }

    #[test]
    fn overflow_clears_buffer_and_requires_snapshot() {
        // A burst past the relay cap must NOT ship a delta that begins at an
        // arbitrary mid-stream byte (the phone would replay it as full state).
        // Instead we drop the buffered bytes and force a complete snapshot.
        let mut pending: BTreeMap<String, PendingOutput> = BTreeMap::new();
        let mut snapshot_required: HashSet<String> = HashSet::new();

        let burst = vec![b'x'; RELAY_TERMINAL_BUFFER_LIMIT + 1];
        accumulate_terminal_change(&mut pending, &mut snapshot_required, "tab".into(), 0, &burst);

        let entry = pending.get("tab").expect("tab should be buffered");
        assert!(
            entry.data.is_empty(),
            "buffer should be cleared on overflow, not head-dropped"
        );
        assert!(snapshot_required.contains("tab"));
        assert!(tab_requires_snapshot(&snapshot_required, "tab", &entry.data));
    }

    #[test]
    fn flush_interval_parses_and_falls_back() {
        assert_eq!(parse_flush_interval(None), Duration::from_millis(16));
        assert_eq!(parse_flush_interval(Some("8".into())), Duration::from_millis(8));
        assert_eq!(
            parse_flush_interval(Some("  33 ".into())),
            Duration::from_millis(33)
        );
        // Zero and garbage fall back to the default — never a 0ms busy-loop.
        assert_eq!(parse_flush_interval(Some("0".into())), Duration::from_millis(16));
        assert_eq!(parse_flush_interval(Some("nope".into())), Duration::from_millis(16));
        // An absurdly large value is clamped so the terminal can't be frozen.
        assert_eq!(parse_flush_interval(Some("600000".into())), Duration::from_millis(1000));
    }

    #[test]
    fn lagged_or_empty_tab_requires_snapshot() {
        // Broadcast lag flags a tab with no buffered bytes; it must still
        // resync via a snapshot.
        let mut flagged: HashSet<String> = HashSet::new();
        flagged.insert("tab".to_string());
        assert!(tab_requires_snapshot(&flagged, "tab", b""));

        // No flag + no pending bytes is the legacy forced-snapshot case.
        let empty: HashSet<String> = HashSet::new();
        assert!(tab_requires_snapshot(&empty, "tab", b""));
        // No flag + pending bytes is a normal delta.
        assert!(!tab_requires_snapshot(&empty, "tab", b"data"));
    }

    #[test]
    fn focus_filter_skips_only_background_tabs() {
        // No focus set (legacy phone) → never skip, stream every tab.
        assert!(!tab_is_focus_filtered(None, "tab"));
        // Focused on another tab → skip this background tab's flush.
        assert!(tab_is_focus_filtered(Some("other"), "tab"));
        // Focused on this tab → don't skip.
        assert!(!tab_is_focus_filtered(Some("tab"), "tab"));
    }

    #[test]
    fn entitlement_override_yields_pro_and_allows_extra_tabs() {
        let _env = DaemonPlanEnvGuard::set("PAID");

        let mut session = MachineSession::new_default();
        session.apply_entitlement_override();
        assert_eq!(session.entitlement.plan, "pro");
        assert_eq!(session.entitlement.max_tabs_per_computer, 16);
        assert_eq!(session.entitlement.max_bound_computers, 8);

        session
            .create_tab("second".to_string())
            .expect("override should allow a second tab");
        assert_eq!(session.tabs.len(), 2);
    }

    #[test]
    fn set_entitlement_does_not_downgrade_under_override() {
        let _env = DaemonPlanEnvGuard::set("max");

        let mut session = MachineSession::new_default();
        session.apply_entitlement_override();
        session
            .create_tab("second".to_string())
            .expect("override should allow a second tab");

        // The relay reports FREE, but the dev override must keep us paid and
        // must not suspend the extra tab.
        let suspended = session.set_entitlement(Entitlement::free());
        assert!(suspended.is_empty());
        assert_eq!(session.entitlement.plan, "pro");
        assert_eq!(session.entitlement.max_tabs_per_computer, 16);
        assert_eq!(session.tabs.len(), 2);
        assert!(matches!(session.tabs[1].status, TabStatus::Running));
    }

    #[test]
    fn entitlement_proto_updates_local_timestamp() {
        let entitlement = entitlement_from_proto(v1::Entitlement {
            plan: "paid".to_string(),
            max_bound_computers: 2,
            max_tabs_per_computer: 4,
        });

        assert_eq!(entitlement.plan, "paid");
        assert_eq!(entitlement.max_bound_computers, 2);
        assert_eq!(entitlement.max_tabs_per_computer, 4);
        assert!(!entitlement.updated_at.is_empty());
    }

    #[test]
    fn rename_tab_updates_existing_tab() {
        let mut session = MachineSession::new_default();
        session
            .rename_tab("default", "agent".to_string())
            .expect("default tab should be renamed");
        assert_eq!(session.tabs[0].title, "agent");
    }

    #[test]
    fn close_rejects_last_tab() {
        let mut session = MachineSession::new_default();
        let error = session
            .close_tab("default")
            .expect_err("closing the last tab should be rejected");
        assert!(matches!(error, SessionError::CannotCloseLastTab));
    }

    #[test]
    fn restored_tabs_are_marked_needs_restart() {
        let mut session = MachineSession::new_default();
        session.mark_all_tabs_needs_restart();
        assert!(matches!(session.tabs[0].status, TabStatus::NeedsRestart));
        assert_eq!(session.to_proto().tabs[0].status, "needs_restart");
    }

    #[test]
    fn restart_marks_tab_running() {
        let mut session = MachineSession::new_default();
        session.mark_all_tabs_needs_restart();
        session
            .mark_tab_running("default")
            .expect("default tab should exist");
        assert!(matches!(session.tabs[0].status, TabStatus::Running));
    }

    #[test]
    fn phone_width_requires_profile() {
        let mut session = MachineSession::new_default();
        let error = session
            .set_width_mode(
                "default",
                WidthMode::Phone,
                TerminalSize { rows: 24, cols: 80 },
            )
            .expect_err("phone profile should be required");
        assert!(matches!(error, SessionError::MissingPhoneProfile));
    }

    #[test]
    fn width_mode_updates_tab_size() {
        let mut session = MachineSession::new_default();
        session.set_phone_profile(30, 90);
        let size = session
            .set_width_mode(
                "default",
                WidthMode::Phone,
                TerminalSize { rows: 24, cols: 80 },
            )
            .expect("phone profile exists");
        assert_eq!(size.rows, 30);
        assert_eq!(size.cols, 90);
        assert_eq!(session.tabs[0].width_mode, WidthMode::Phone);
        assert_eq!(session.tabs[0].rows, 30);
        assert_eq!(session.tabs[0].cols, 90);

        let size = session
            .set_width_mode(
                "default",
                WidthMode::Computer,
                TerminalSize {
                    rows: 40,
                    cols: 120,
                },
            )
            .expect("computer width should always be valid");
        assert_eq!(size.rows, 40);
        assert_eq!(size.cols, 120);
        assert_eq!(session.tabs[0].width_mode, WidthMode::Computer);
        assert_eq!(session.tabs[0].rows, 40);
        assert_eq!(session.tabs[0].cols, 120);
    }

    #[test]
    fn binding_state_round_trips_to_proto() {
        let mut session = MachineSession::new_default();
        session.set_binding(BindingState::pending(
            "http://127.0.0.1:8787".to_string(),
            "daemon_1".to_string(),
            "bind_1".to_string(),
            "ABC123".to_string(),
            "2026-05-29T00:00:00.000Z".to_string(),
        ));

        let proto = session.to_proto();
        let binding = proto.binding.expect("binding should be present");
        assert_eq!(binding.relay_url, "http://127.0.0.1:8787");
        assert_eq!(binding.daemon_device_id, "daemon_1");
        assert_eq!(binding.binding_id, "bind_1");
        assert_eq!(binding.status, "pending");

        let parsed = binding_from_proto(binding).expect("proto binding should parse");
        assert_eq!(parsed.status, BindingStatus::Pending);
        assert_eq!(parsed.bound_phone_id, None);
    }

    #[test]
    fn device_identity_generates_stable_public_key_and_signature() {
        let identity = DeviceIdentity::from_secret_key([7; 32]);

        assert_eq!(identity.public_key.len(), 44);
        assert_eq!(identity.signing_key.len(), 44);
        assert_eq!(identity.sign(b"hello").expect("signature").len(), 88);
    }

    #[test]
    fn device_key_rotation_message_matches_relay_transcript() {
        assert_eq!(
            device_key_rotation_message(
                "daemon_1",
                "current-public-key",
                "new-public-key",
                "1780000000000",
                "rotation-nonce"
            ),
            "nudge.relay.device_key_rotation.v1\ndaemon_1\ncurrent-public-key\nnew-public-key\n1780000000000\nrotation-nonce"
        );
    }

    #[test]
    fn device_key_rotation_request_uses_relay_contract_fields() {
        let request = DeviceKeyRotationRequest {
            device_id: "daemon_1".to_string(),
            new_public_key: "new-public-key".to_string(),
            signed_at: "1780000000000".to_string(),
            nonce: "rotation-nonce".to_string(),
            signature: "signature".to_string(),
        };
        let json = serde_json::to_value(request).expect("request should serialize");

        assert_eq!(json["deviceId"], "daemon_1");
        assert_eq!(json["newPublicKey"], "new-public-key");
        assert_eq!(json["signedAt"], "1780000000000");
        assert_eq!(json["nonce"], "rotation-nonce");
        assert_eq!(json["signature"], "signature");
    }

    #[test]
    fn device_key_rotation_is_signed_by_current_identity() {
        let current = DeviceIdentity::from_secret_key([7; 32]);
        let rotation =
            prepare_device_key_rotation("daemon_1", &current).expect("rotation should prepare");
        let message = device_key_rotation_message(
            "daemon_1",
            current.public_key(),
            rotation.identity.public_key(),
            &rotation.signed_at,
            &rotation.nonce,
        );

        current
            .verify(message.as_bytes(), &rotation.signature)
            .expect("rotation signature should verify with current key");
        assert_ne!(rotation.identity.public_key(), current.public_key());
        assert!(rotation.nonce.starts_with("rotation-"));
    }

    #[test]
    fn rotating_session_identity_updates_binding_public_key() {
        let old_identity = DeviceIdentity::from_secret_key([7; 32]);
        let new_identity = DeviceIdentity::from_secret_key([8; 32]);
        let mut session = MachineSession::new_default();
        session.device_identity = Some(old_identity.clone());
        let mut binding = BindingState::pending(
            "http://127.0.0.1:8787".to_string(),
            "daemon_1".to_string(),
            "bind_1".to_string(),
            "ABC123".to_string(),
            "2026-05-29T00:00:00.000Z".to_string(),
        )
        .active("phone_1".to_string(), None);
        binding.daemon_public_key = Some(old_identity.public_key.clone());
        session.set_binding(binding);

        let previous = session
            .rotate_device_identity(new_identity.clone())
            .expect("rotation should update session identity");

        assert_eq!(previous.public_key, old_identity.public_key);
        assert_eq!(
            session
                .device_identity
                .as_ref()
                .map(|identity| identity.public_key()),
            Some(new_identity.public_key())
        );
        assert_eq!(
            session
                .binding
                .as_ref()
                .and_then(|binding| binding.daemon_public_key.as_deref()),
            Some(new_identity.public_key())
        );
    }

    #[test]
    fn legacy_signed_relay_websocket_url_adds_auth_parameters() {
        let binding = BindingState::pending(
            "https://relay.example".to_string(),
            "daemon_1".to_string(),
            "bind_1".to_string(),
            "ABC123".to_string(),
            "2026-05-29T00:00:00.000Z".to_string(),
        );
        let identity = DeviceIdentity::from_secret_key([9; 32]);

        let url = legacy_signed_relay_websocket_url(&binding, &identity).expect("signed url");

        assert!(
            url.starts_with("wss://relay.example/ws/daemon?deviceId=daemon_1&bindingId=bind_1")
        );
        assert!(url.contains("authTimestamp="));
        assert!(url.contains("authNonce="));
        assert!(url.contains("authSignature="));
    }

    #[test]
    fn state_store_writes_private_session_file() {
        let root = std::env::temp_dir().join(format!(
            "nudge-state-permissions-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let state_path = root.join("state").join("session.json");
        let store = StateStore::new(state_path.clone());
        let session = MachineSession::new_default();

        store.save(&session).expect("state should save");

        let mode = fs::metadata(&state_path)
            .expect("state file should exist")
            .permissions()
            .mode()
            & 0o777;
        let _ = fs::remove_dir_all(&root);
        assert_eq!(mode, 0o600);
    }

    #[tokio::test]
    async fn relay_binding_revoked_error_marks_local_binding_revoked() {
        let root = std::env::temp_dir().join(format!(
            "nudge-relay-revoked-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let state_path = root.join("state").join("session.json");
        let socket_path = root.join("run").join("nudge.sock");
        let mut session = MachineSession::new_default();
        let binding = BindingState::pending(
            "http://127.0.0.1:8787".to_string(),
            "daemon_1".to_string(),
            "bind_1".to_string(),
            "ABC123".to_string(),
            "2026-05-29T00:00:00.000Z".to_string(),
        )
        .active("phone_1".to_string(), None);
        session.set_binding(binding.clone());
        let runtime = DaemonRuntime::new(StateStore::new(state_path), session, socket_path);
        let identity = DeviceIdentity::from_secret_key([7; 32]);
        let mut e2e_session = None;

        let error = handle_relay_message(
            &runtime,
            &binding,
            "phone_1",
            &identity,
            &mut e2e_session,
            WebSocketMessage::Text(r#"{"type":"error","error":"binding_revoked"}"#.into()),
        )
        .await
        .expect_err("revocation should break relay connection");

        assert!(error.to_string().contains("relay binding was revoked"));
        assert!(runtime.current_active_binding().await.is_none());
        let session = runtime.session.lock().await;
        assert_eq!(
            session.binding.as_ref().map(|binding| binding.status),
            Some(BindingStatus::Revoked)
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn relay_device_revoked_error_marks_local_binding_revoked() {
        let root = std::env::temp_dir().join(format!(
            "nudge-relay-device-revoked-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let state_path = root.join("state").join("session.json");
        let socket_path = root.join("run").join("nudge.sock");
        let mut session = MachineSession::new_default();
        let binding = BindingState::pending(
            "http://127.0.0.1:8787".to_string(),
            "daemon_1".to_string(),
            "bind_1".to_string(),
            "ABC123".to_string(),
            "2026-05-29T00:00:00.000Z".to_string(),
        )
        .active("phone_1".to_string(), None);
        session.set_binding(binding.clone());
        let runtime = DaemonRuntime::new(StateStore::new(state_path), session, socket_path);
        let identity = DeviceIdentity::from_secret_key([7; 32]);
        let mut e2e_session = None;

        let error = handle_relay_message(
            &runtime,
            &binding,
            "phone_1",
            &identity,
            &mut e2e_session,
            WebSocketMessage::Text(r#"{"type":"error","error":"device_revoked"}"#.into()),
        )
        .await
        .expect_err("device revocation should break relay connection");

        assert!(error.to_string().contains("relay binding was revoked"));
        assert!(runtime.current_active_binding().await.is_none());
        let session = runtime.session.lock().await;
        assert_eq!(
            session.binding.as_ref().map(|binding| binding.status),
            Some(BindingStatus::Revoked)
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn relay_handler_accepts_e2e_handshake_and_encrypted_control_request() {
        let root = std::env::temp_dir().join(format!(
            "nudge-relay-e2e-{}-{}",
            std::process::id(),
            current_unix_millis()
        ));
        let state_path = root.join("state").join("session.json");
        let socket_path = root.join("run").join("nudge.sock");
        let daemon_identity = DeviceIdentity::from_secret_key([4; 32]);
        let phone_identity = DeviceIdentity::from_secret_key([3; 32]);
        let daemon_device_id = "daemon_1";
        let phone_device_id = "phone_1";
        let binding = BindingState::pending(
            "http://127.0.0.1:8787".to_string(),
            daemon_device_id.to_string(),
            "bind_1".to_string(),
            "ABC123".to_string(),
            "2026-05-29T00:00:00.000Z".to_string(),
        )
        .active(
            phone_device_id.to_string(),
            Some(phone_identity.public_key.clone()),
        );
        let binding = BindingState {
            daemon_public_key: Some(daemon_identity.public_key.clone()),
            ..binding
        };
        let mut session = MachineSession::new_default();
        session.set_binding(binding.clone());
        let runtime = DaemonRuntime::new(StateStore::new(state_path), session, socket_path);
        let mut e2e_session = None;
        let phone_ephemeral = e2e::KeyPair::from_secret_bytes([9; 32]);
        let start = e2e::sign_handshake_start(
            &phone_identity
                .secret_key_bytes()
                .expect("phone secret should decode"),
            v1::E2eHandshakeStart {
                session_id: "e2e_test".to_string(),
                sender_device_id: phone_device_id.to_string(),
                recipient_device_id: daemon_device_id.to_string(),
                sender_identity_public_key: decode_fixed_base64::<32>(&phone_identity.public_key)
                    .expect("phone public key should decode")
                    .to_vec(),
                sender_ephemeral_public_key: phone_ephemeral.public_bytes().to_vec(),
                transcript_signature: Vec::new(),
                created_at: "2026-05-29T00:00:01.000Z".to_string(),
            },
        );
        let handshake_message = json!({
            "type": "message",
            "message": {
                "id": "relay_handshake",
                "fromDeviceId": phone_device_id,
                "payload": e2e::handshake_start_to_relay_payload(&start),
            }
        });

        let finish_response = handle_relay_message(
            &runtime,
            &binding,
            phone_device_id,
            &daemon_identity,
            &mut e2e_session,
            WebSocketMessage::Text(handshake_message.to_string().into()),
        )
        .await
        .expect("handshake should be accepted")
        .expect("handshake should produce finish");
        let finish_response: Value =
            serde_json::from_str(&finish_response).expect("finish response should parse");
        let finish_payload = finish_response["payload"].clone();
        assert_eq!(finish_payload["type"], "e2e_handshake_finish");
        let finish = e2e::handshake_finish_from_relay_payload(&finish_payload)
            .expect("finish payload should decode");
        e2e::verify_handshake_finish(
            &start,
            &finish,
            &decode_fixed_base64::<32>(&daemon_identity.public_key)
                .expect("daemon public key should decode"),
        )
        .expect("finish signature should verify");
        let daemon_ephemeral: [u8; 32] = finish
            .sender_ephemeral_public_key
            .as_slice()
            .try_into()
            .expect("daemon e2e ephemeral key should be 32 bytes");
        let mut phone_session = e2e::SessionKeys::from_x25519(
            start.session_id.clone(),
            phone_device_id.to_string(),
            daemon_device_id.to_string(),
            &phone_ephemeral,
            daemon_ephemeral,
            e2e::SessionRole::Phone,
        )
        .expect("phone e2e session should derive");
        let request_payload = json!({
            "type": "get_state",
            "requestId": "request_1",
        });
        let encrypted_request = phone_session
            .encrypt("get_state", request_payload.to_string().as_bytes())
            .expect("request should encrypt");
        let encrypted_message = json!({
            "type": "message",
            "message": {
                "id": "relay_request",
                "fromDeviceId": phone_device_id,
                "payload": e2e::envelope_to_relay_payload(&encrypted_request),
            }
        });

        let encrypted_response = handle_relay_message(
            &runtime,
            &binding,
            phone_device_id,
            &daemon_identity,
            &mut e2e_session,
            WebSocketMessage::Text(encrypted_message.to_string().into()),
        )
        .await
        .expect("encrypted request should be accepted")
        .expect("encrypted request should produce response");
        assert!(!encrypted_response.contains("request_1"));
        let encrypted_response: Value =
            serde_json::from_str(&encrypted_response).expect("encrypted response should parse");
        let encrypted_payload = encrypted_response["payload"].clone();
        assert_eq!(encrypted_payload["type"], "e2e_envelope");
        let response_envelope = e2e::envelope_from_relay_payload(&encrypted_payload)
            .expect("response envelope should decode");
        let plaintext = phone_session
            .decrypt(&response_envelope)
            .expect("response should decrypt");
        let response: Value =
            serde_json::from_slice(&plaintext).expect("decrypted response should parse");
        assert_eq!(response["type"], "daemon_response");
        assert_eq!(response["requestId"], "request_1");
        assert_eq!(response["ok"], true);
        assert_eq!(response["data"]["tabs"][0]["id"], "default");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn live_terminal_snapshot_uses_unsolicited_daemon_response_shape() {
        let binding = BindingState::pending(
            "http://127.0.0.1:8787".to_string(),
            "daemon_1".to_string(),
            "bind_1".to_string(),
            "ABC123".to_string(),
            "2026-05-29T00:00:00.000Z".to_string(),
        )
        .active("phone_1".to_string(), None);
        let snapshot = v1::TerminalSnapshot {
            tab_id: "default".to_string(),
            rows: 24,
            cols: 80,
            text: "ready".to_string(),
            formatted: Vec::new(),
        };

        let json = relay_live_terminal_snapshot_json("phone_1", &binding, &snapshot, 2048);
        let value: Value = serde_json::from_str(&json).expect("live snapshot json should parse");

        assert_eq!(value["toDeviceId"], "phone_1");
        assert_eq!(value["ephemeral"], true);
        assert_eq!(value["payload"]["type"], "daemon_response");
        assert_eq!(value["payload"]["bindingId"], "bind_1");
        assert_eq!(value["payload"]["ok"], true);
        assert!(value["payload"].get("requestId").is_none());
        assert_eq!(value["payload"]["data"]["tabId"], "default");
        assert_eq!(value["payload"]["data"]["rows"], 24);
        assert_eq!(value["payload"]["data"]["cols"], 80);
        assert_eq!(value["payload"]["data"]["text"], "ready");
        assert_eq!(value["payload"]["data"]["offset"], 2048);
    }

    #[test]
    fn live_terminal_output_uses_base64_bytes() {
        let binding = BindingState::pending(
            "http://127.0.0.1:8787".to_string(),
            "daemon_1".to_string(),
            "bind_1".to_string(),
            "ABC123".to_string(),
            "2026-05-29T00:00:00.000Z".to_string(),
        )
        .active("phone_1".to_string(), None);

        let json = relay_live_terminal_output_json(
            "phone_1",
            &binding,
            "default",
            4096,
            b"\x1b[31mred\n",
        );
        let value: Value = serde_json::from_str(&json).expect("live output json should parse");

        assert_eq!(value["toDeviceId"], "phone_1");
        assert_eq!(value["ephemeral"], true);
        assert_eq!(value["payload"]["type"], "daemon_response");
        assert_eq!(value["payload"]["bindingId"], "bind_1");
        assert_eq!(value["payload"]["ok"], true);
        assert_eq!(value["payload"]["data"]["tabId"], "default");
        assert_eq!(value["payload"]["data"]["offset"], 4096);
        assert_eq!(value["payload"]["data"]["bytesBase64"], "G1szMW1yZWQK");
    }

    #[test]
    fn live_agent_status_payload_updates_one_tab() {
        let binding = BindingState::pending(
            "http://127.0.0.1:8787".to_string(),
            "daemon_1".to_string(),
            "bind_1".to_string(),
            "ABC123".to_string(),
            "2026-05-29T00:00:00.000Z".to_string(),
        )
        .active("phone_1".to_string(), None);
        let status = AgentStatus {
            kind: AgentKind::Claude,
            state: AgentInteractionState::NeedsApproval,
            confidence: 0.82,
            source: AgentDetectionSource::Screen,
        };

        let json = relay_live_agent_status_json("phone_1", &binding, "default", &status);
        let value: Value = serde_json::from_str(&json).expect("live status json should parse");

        assert_eq!(value["toDeviceId"], "phone_1");
        assert_eq!(value["ephemeral"], true);
        assert_eq!(value["payload"]["type"], "daemon_response");
        assert_eq!(value["payload"]["bindingId"], "bind_1");
        assert_eq!(value["payload"]["ok"], true);
        assert_eq!(value["payload"]["data"]["tabId"], "default");
        assert_eq!(value["payload"]["data"]["agentStatus"]["kind"], "claude");
        assert_eq!(
            value["payload"]["data"]["agentStatus"]["state"],
            "needs_approval"
        );
        assert_eq!(value["payload"]["data"]["agentStatus"]["source"], "screen");
    }

    #[test]
    fn base64_encoder_handles_padding() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"a"), "YQ==");
        assert_eq!(base64_encode(b"ab"), "YWI=");
        assert_eq!(base64_encode(b"abc"), "YWJj");
    }

    #[test]
    fn replay_max_bytes_defaults_and_caps() {
        assert_eq!(replay_max_bytes(0), 32 * 1024);
        assert_eq!(replay_max_bytes(512), 512);
        assert_eq!(replay_max_bytes(200 * 1024), 128 * 1024);
    }

    #[test]
    fn detects_claude_approval_from_screen_text() {
        let status = detect_agent_status(
            "shell",
            include_str!("../fixtures/agent/claude_approval.txt"),
            None,
            &TabStatus::Running,
        );
        assert_eq!(status.kind, AgentKind::Claude);
        assert_eq!(status.state, AgentInteractionState::NeedsApproval);
        assert_eq!(status.source, AgentDetectionSource::Screen);
        assert!(status.confidence >= 0.82);
    }

    #[test]
    fn detects_codex_approval_from_screen_text() {
        let status = detect_agent_status(
            "shell",
            include_str!("../fixtures/agent/codex_approval.txt"),
            None,
            &TabStatus::Running,
        );
        assert_eq!(status.kind, AgentKind::Codex);
        assert_eq!(status.state, AgentInteractionState::NeedsApproval);
        assert_eq!(status.source, AgentDetectionSource::Screen);
        assert!(status.confidence >= 0.82);
    }

    #[test]
    fn detects_codex_waiting_from_title_and_screen_text() {
        let status = detect_agent_status(
            "codex",
            include_str!("../fixtures/agent/codex_waiting.txt"),
            None,
            &TabStatus::Running,
        );
        assert_eq!(status.kind, AgentKind::Codex);
        assert_eq!(status.state, AgentInteractionState::WaitingForInput);
        assert_eq!(status.source, AgentDetectionSource::Title);
    }

    #[test]
    fn detects_claude_waiting_from_screen_text() {
        let status = detect_agent_status(
            "shell",
            include_str!("../fixtures/agent/claude_waiting.txt"),
            None,
            &TabStatus::Running,
        );
        assert_eq!(status.kind, AgentKind::Claude);
        assert_eq!(status.state, AgentInteractionState::WaitingForInput);
        assert_eq!(status.source, AgentDetectionSource::Screen);
        assert!(status.confidence >= 0.78);
    }

    #[test]
    fn detects_opencode_waiting_from_screen_text() {
        let status = detect_agent_status(
            "shell",
            include_str!("../fixtures/agent/opencode_waiting.txt"),
            None,
            &TabStatus::Running,
        );
        assert_eq!(status.kind, AgentKind::Opencode);
        assert_eq!(status.state, AgentInteractionState::WaitingForInput);
        assert_eq!(status.source, AgentDetectionSource::Screen);
        assert!(status.confidence >= 0.78);
    }

    #[test]
    fn detects_openclaw_approval_from_chinese_screen_text() {
        let status = detect_agent_status(
            "shell",
            include_str!("../fixtures/agent/openclaw_approval_zh.txt"),
            None,
            &TabStatus::Running,
        );
        assert_eq!(status.kind, AgentKind::Openclaw);
        assert_eq!(status.state, AgentInteractionState::NeedsApproval);
        assert_eq!(status.source, AgentDetectionSource::Screen);
        assert!(status.confidence >= 0.82);
    }

    #[test]
    fn shell_permission_text_does_not_trigger_approval() {
        let status = detect_agent_status(
            "shell",
            include_str!("../fixtures/agent/shell_permission_note.txt"),
            None,
            &TabStatus::Running,
        );
        assert_eq!(status.kind, AgentKind::Shell);
        assert_eq!(status.state, AgentInteractionState::Running);
        assert_ne!(status.state, AgentInteractionState::NeedsApproval);
    }

    #[test]
    fn unknown_fixture_stays_low_confidence() {
        let status = detect_agent_status(
            "shell",
            include_str!("../fixtures/agent/unknown_low_confidence.txt"),
            None,
            &TabStatus::Running,
        );

        assert_eq!(status.kind, AgentKind::Unknown);
        assert_eq!(status.state, AgentInteractionState::Running);
        assert!(status.confidence < 0.5);
    }

    #[test]
    fn detects_agent_kind_from_process_name() {
        let status = detect_agent_status(
            "shell",
            "$ ",
            Some(&ProcessSignal::new("/Users/me/.local/bin/codex", Some(42))),
            &TabStatus::Running,
        );

        assert_eq!(status.kind, AgentKind::Codex);
        assert_eq!(status.source, AgentDetectionSource::Process);
        assert!(status.confidence >= 0.9);
    }

    #[test]
    fn process_name_does_not_override_exited_tabs() {
        let status = detect_agent_status(
            "shell",
            "$ ",
            Some(&ProcessSignal::new("claude", Some(42))),
            &TabStatus::NeedsRestart,
        );

        assert_eq!(status.kind, AgentKind::Unknown);
        assert_eq!(status.state, AgentInteractionState::Exited);
        assert_ne!(status.source, AgentDetectionSource::Process);
    }

    #[test]
    fn process_entries_parse_ps_rows() {
        let entries = parse_process_entries(
            "  100     1   100 Ss   /bin/zsh\n  101   100   101 S+   /Users/me/.local/bin/codex\n",
        )
        .expect("process rows should parse");

        assert_eq!(entries.len(), 2);
        assert_eq!(entries[1].pid, 101);
        assert_eq!(entries[1].parent_pid, 100);
        assert_eq!(entries[1].process_group, 101);
        assert!(entries[1].foreground);
        assert_eq!(entries[1].command, "/Users/me/.local/bin/codex");
    }

    #[test]
    fn process_signal_prefers_agent_descendant() {
        let entries = vec![
            ProcessEntry {
                pid: 100,
                parent_pid: 1,
                process_group: 100,
                foreground: true,
                command: "zsh".to_string(),
            },
            ProcessEntry {
                pid: 101,
                parent_pid: 100,
                process_group: 101,
                foreground: true,
                command: "python".to_string(),
            },
            ProcessEntry {
                pid: 102,
                parent_pid: 101,
                process_group: 101,
                foreground: true,
                command: "/opt/homebrew/bin/claude".to_string(),
            },
        ];

        let signal = process_signal_from_entries(100, None, &entries).expect("signal should exist");

        assert_eq!(signal.command, "/opt/homebrew/bin/claude");
        assert_eq!(signal.pid, Some(102));
    }

    #[test]
    fn process_signal_prefers_foreground_descendant_over_background_agent() {
        let entries = vec![
            ProcessEntry {
                pid: 100,
                parent_pid: 1,
                process_group: 100,
                foreground: true,
                command: "zsh".to_string(),
            },
            ProcessEntry {
                pid: 101,
                parent_pid: 100,
                process_group: 101,
                foreground: false,
                command: "claude".to_string(),
            },
            ProcessEntry {
                pid: 102,
                parent_pid: 100,
                process_group: 102,
                foreground: true,
                command: "vim".to_string(),
            },
        ];

        let signal = process_signal_from_entries(100, None, &entries).expect("signal should exist");

        assert_eq!(signal.command, "vim");
        assert_eq!(signal.pid, Some(102));
    }

    #[test]
    fn process_signal_prefers_direct_foreground_process_group() {
        let entries = vec![
            ProcessEntry {
                pid: 100,
                parent_pid: 1,
                process_group: 100,
                foreground: true,
                command: "zsh".to_string(),
            },
            ProcessEntry {
                pid: 101,
                parent_pid: 100,
                process_group: 101,
                foreground: true,
                command: "claude".to_string(),
            },
            ProcessEntry {
                pid: 102,
                parent_pid: 100,
                process_group: 102,
                foreground: false,
                command: "vim".to_string(),
            },
        ];

        let signal =
            process_signal_from_entries(100, Some(102), &entries).expect("signal should exist");

        assert_eq!(signal.command, "vim");
        assert_eq!(signal.pid, Some(102));
    }

    #[test]
    fn process_signal_uses_stat_foreground_when_process_group_is_unmatched() {
        let entries = vec![
            ProcessEntry {
                pid: 100,
                parent_pid: 1,
                process_group: 100,
                foreground: true,
                command: "zsh".to_string(),
            },
            ProcessEntry {
                pid: 101,
                parent_pid: 100,
                process_group: 101,
                foreground: false,
                command: "claude".to_string(),
            },
            ProcessEntry {
                pid: 102,
                parent_pid: 100,
                process_group: 102,
                foreground: true,
                command: "vim".to_string(),
            },
        ];

        let signal =
            process_signal_from_entries(100, Some(999), &entries).expect("signal should exist");

        assert_eq!(signal.command, "vim");
        assert_eq!(signal.pid, Some(102));
    }

    #[test]
    fn process_signal_falls_back_to_root_process() {
        let entries = vec![ProcessEntry {
            pid: 100,
            parent_pid: 1,
            process_group: 100,
            foreground: true,
            command: "zsh".to_string(),
        }];

        let signal =
            process_signal_from_entries(100, Some(100), &entries).expect("signal should exist");

        assert_eq!(signal.command, "zsh");
        assert_eq!(signal.pid, Some(100));
    }

    #[test]
    fn exited_tabs_do_not_get_high_confidence_agent_labels() {
        let status = detect_agent_status("claude", "Claude Code", None, &TabStatus::NeedsRestart);
        assert_eq!(status.kind, AgentKind::Unknown);
        assert_eq!(status.state, AgentInteractionState::Exited);
        assert!(status.confidence < 0.8);
    }
}
