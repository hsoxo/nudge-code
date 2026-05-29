#[derive(Debug, thiserror::Error)]
pub enum PtyError {
    #[error("pty support is not implemented until Phase 1")]
    NotImplemented,
}

pub type Result<T> = std::result::Result<T, PtyError>;
