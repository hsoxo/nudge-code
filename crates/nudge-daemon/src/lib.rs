use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use futures_util::StreamExt;
use nudge_protocol::v1;
use nudge_pty::{PtyTab, TerminalSize};
use nudge_terminal::{TerminalGrid, TerminalSize as GridSize};
use prost::Message;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{Mutex, Notify};
use tokio::task;
use tokio::time::sleep;
use tokio_tungstenite::connect_async;

#[derive(Debug, Clone)]
pub struct DaemonConfig {
    pub placeholder: bool,
    pub foreground: bool,
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
    #[serde(default)]
    pub phone_profile: Option<PhoneProfile>,
    #[serde(default)]
    pub binding: Option<BindingState>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalTab {
    pub id: String,
    pub title: String,
    pub status: TabStatus,
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
    pub updated_at: String,
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
            let session = serde_json::from_slice(&bytes)
                .with_context(|| format!("failed to parse {}", self.path.display()))?;
            return Ok(session);
        }

        let session = MachineSession::new_default();
        self.save(&session)?;
        Ok(session)
    }

    pub fn load_or_create_with_status(&self) -> Result<(MachineSession, bool)> {
        if self.path.exists() {
            let bytes = fs::read(&self.path)
                .with_context(|| format!("failed to read {}", self.path.display()))?;
            let session = serde_json::from_slice(&bytes)
                .with_context(|| format!("failed to parse {}", self.path.display()))?;
            return Ok((session, true));
        }

        let session = MachineSession::new_default();
        self.save(&session)?;
        Ok((session, false))
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
            phone_profile: None,
            binding: None,
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
        self.updated_at = now_string();
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
            updated_at: now_string(),
        }
    }

    pub fn active(mut self, bound_phone_id: String) -> Self {
        self.status = BindingStatus::Active;
        self.bound_phone_id = Some(bound_phone_id);
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
        updated_at: now_string(),
    })
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
    started_at: Instant,
    socket_path: PathBuf,
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
            started_at: Instant::now(),
            socket_path,
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
        self.session.lock().await.to_proto()
    }

    async fn create_tab(&self, title: String) -> Result<v1::SessionState> {
        {
            let mut session = self.session.lock().await;
            let tab = session.create_tab(title)?;
            self.ptys.lock().await.push(RuntimeTab {
                tab_id: tab.id.clone(),
                pty: None,
                grid: Arc::new(std::sync::Mutex::new(TerminalGrid::default())),
            });
            self.state_store.save(&session)?;
        }
        self.ensure_ptys().await?;
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
                runtime_tab.pty = Some(spawn_pty_for_tab(tab_id, runtime_tab.grid.clone()).await?);
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
        let mut ptys = self.ptys.lock().await;
        for runtime_tab in ptys.iter_mut() {
            if runtime_tab.pty.is_none() {
                runtime_tab.pty =
                    Some(spawn_pty_for_tab(&runtime_tab.tab_id, runtime_tab.grid.clone()).await?);
            }
        }
        Ok(())
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

    async fn output_tail(&self, tab_id: &str, max_bytes: usize) -> Result<Vec<u8>> {
        let ptys = self.ptys.lock().await;
        let pty = ptys
            .iter()
            .find(|tab| tab.tab_id == tab_id)
            .and_then(|tab| tab.pty.as_ref())
            .with_context(|| format!("tab {tab_id} does not have a pty"))?;
        Ok(pty.output_tail(max_bytes))
    }

    async fn terminal_snapshot(&self, tab_id: &str) -> Result<v1::TerminalSnapshot> {
        let ptys = self.ptys.lock().await;
        let runtime_tab = ptys
            .iter()
            .find(|tab| tab.tab_id == tab_id)
            .with_context(|| format!("tab {tab_id} was not found"))?;
        let snapshot = runtime_tab
            .grid
            .lock()
            .expect("terminal grid lock poisoned")
            .snapshot();
        Ok(v1::TerminalSnapshot {
            tab_id: tab_id.to_string(),
            rows: snapshot.rows as u32,
            cols: snapshot.cols as u32,
            text: snapshot.text,
            formatted: snapshot.formatted,
        })
    }

    async fn terminal_render(&self, tab_id: &str) -> Result<v1::TerminalRender> {
        let ptys = self.ptys.lock().await;
        let runtime_tab = ptys
            .iter()
            .find(|tab| tab.tab_id == tab_id)
            .with_context(|| format!("tab {tab_id} was not found"))?;
        let snapshot = runtime_tab
            .grid
            .lock()
            .expect("terminal grid lock poisoned")
            .snapshot();
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
            frame: snapshot.formatted,
            width_mode,
        })
    }

    async fn set_phone_profile(&self, rows: u16, cols: u16) -> Result<v1::SessionState> {
        {
            let mut session = self.session.lock().await;
            session.set_phone_profile(rows, cols);
            self.state_store.save(&session)?;
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

    async fn clear_binding(&self) -> Result<v1::SessionState> {
        {
            let mut session = self.session.lock().await;
            session.clear_binding();
            self.state_store.save(&session)?;
        }
        self.set_relay_state(RelayConnectionState::unbound()).await;
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

    async fn set_relay_state(&self, state: RelayConnectionState) {
        *self.relay_state.lock().await = state;
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
}

struct RuntimeTab {
    tab_id: String,
    pty: Option<PtyTab>,
    grid: Arc<std::sync::Mutex<TerminalGrid>>,
}

async fn spawn_pty_for_tab(
    tab_id: &str,
    grid: Arc<std::sync::Mutex<TerminalGrid>>,
) -> Result<PtyTab> {
    let tab_id = tab_id.to_string();
    task::spawn_blocking(move || {
        PtyTab::spawn_shell_with_output_hook(TerminalSize::default(), move |bytes| {
            grid.lock()
                .expect("terminal grid lock poisoned")
                .process(bytes);
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

        let binding = match runtime.current_active_binding().await {
            Some(binding) => binding,
            None => {
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
            runtime
                .set_relay_state(RelayConnectionState::error(&binding, format!("{error:#}")))
                .await;
            tokio::select! {
                _ = runtime.shutdown.notified() => break,
                _ = sleep(Duration::from_secs(1)) => {}
            }
        }
    }
}

async fn connect_relay_once(runtime: &DaemonRuntime, binding: &BindingState) -> Result<()> {
    let url = relay_websocket_url(binding)?;
    runtime
        .set_relay_state(RelayConnectionState::connecting(binding))
        .await;
    let (mut websocket, _) = connect_async(&url)
        .await
        .with_context(|| format!("failed to connect relay websocket {url}"))?;
    runtime
        .set_relay_state(RelayConnectionState::connected(binding))
        .await;

    loop {
        tokio::select! {
            _ = runtime.shutdown.notified() => break,
            message = websocket.next() => {
                match message {
                    Some(Ok(_message)) => runtime.mark_relay_message().await,
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

    runtime
        .set_relay_state(RelayConnectionState::disconnected(binding))
        .await;
    Ok(())
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
            runtime.write_input(&input.tab_id, input.data).await?;
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
            Some(v1::envelope::Payload::TerminalSnapshot(
                runtime.terminal_snapshot(&request.tab_id).await?,
            ))
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
        Some(v1::envelope::Payload::ClearBindingState(_)) => Some(
            v1::envelope::Payload::SessionState(runtime.clear_binding().await?),
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
}
