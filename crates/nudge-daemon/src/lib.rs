use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use nudge_protocol::v1;
use nudge_pty::{PtyTab, TerminalSize};
use prost::Message;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{Mutex, Notify};
use tokio::task;

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
            })
            .collect();
        Self {
            state_store,
            session: Arc::new(Mutex::new(session)),
            ptys: Arc::new(Mutex::new(ptys)),
            shutdown: Arc::new(Notify::new()),
            connected_clients: Arc::new(AtomicU32::new(0)),
            started_at: Instant::now(),
            socket_path,
        }
    }

    async fn status(&self) -> v1::DaemonStatus {
        let session = self.session.lock().await;
        v1::DaemonStatus {
            socket_path: self.socket_path.display().to_string(),
            state_path: self.state_store.path().display().to_string(),
            connected_clients: self.connected_clients.load(Ordering::Relaxed),
            uptime_seconds: self.started_at.elapsed().as_secs(),
            tabs: session.tabs.len() as u32,
            plan: session.entitlement.plan.clone(),
        }
    }

    async fn session_state(&self) -> v1::SessionState {
        self.session.lock().await.to_proto()
    }

    async fn ensure_ptys(&self) -> Result<()> {
        let mut ptys = self.ptys.lock().await;
        for runtime_tab in ptys.iter_mut() {
            if runtime_tab.pty.is_none() {
                let tab_id = runtime_tab.tab_id.clone();
                let pty =
                    task::spawn_blocking(move || PtyTab::spawn_shell(TerminalSize::default()))
                        .await
                        .context("pty spawn task failed")?
                        .with_context(|| format!("failed to spawn shell for tab {tab_id}"))?;
                runtime_tab.pty = Some(pty);
            }
        }
        Ok(())
    }

    async fn write_input(&self, tab_id: &str, data: Vec<u8>) -> Result<()> {
        self.ensure_ptys().await?;
        let ptys = self.ptys.lock().await;
        let pty = ptys
            .iter()
            .find(|tab| tab.tab_id == tab_id)
            .and_then(|tab| tab.pty.as_ref())
            .with_context(|| format!("tab {tab_id} does not have a pty"))?;
        pty.write_input(&data)
    }

    async fn output_tail(&self, tab_id: &str, max_bytes: usize) -> Result<Vec<u8>> {
        self.ensure_ptys().await?;
        let ptys = self.ptys.lock().await;
        let pty = ptys
            .iter()
            .find(|tab| tab.tab_id == tab_id)
            .and_then(|tab| tab.pty.as_ref())
            .with_context(|| format!("tab {tab_id} does not have a pty"))?;
        Ok(pty.output_tail(max_bytes))
    }
}

struct RuntimeTab {
    tab_id: String,
    pty: Option<PtyTab>,
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
    let session = state_store.load_or_create()?;
    let listener = UnixListener::bind(paths.socket_path())
        .with_context(|| format!("failed to bind {}", paths.socket_path().display()))?;
    fs::set_permissions(paths.socket_path(), fs::Permissions::from_mode(0o600))
        .with_context(|| format!("failed to secure {}", paths.socket_path().display()))?;

    let runtime = DaemonRuntime::new(state_store, session, paths.socket_path().to_path_buf());
    runtime.ensure_ptys().await?;

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
