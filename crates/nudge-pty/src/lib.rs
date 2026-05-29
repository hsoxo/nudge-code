use std::io::{Read, Write};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use anyhow::{Context, Result};
use portable_pty::{Child, CommandBuilder, PtySize, native_pty_system};

#[derive(Debug, Clone, Copy)]
pub struct TerminalSize {
    pub rows: u16,
    pub cols: u16,
}

impl Default for TerminalSize {
    fn default() -> Self {
        Self { rows: 24, cols: 80 }
    }
}

pub struct PtyTab {
    child: Box<dyn Child + Send + Sync>,
    child_pid: Option<u32>,
    command_name: String,
    control_tx: Option<Sender<PtyCommand>>,
    output: Arc<Mutex<Vec<u8>>>,
    _reader_thread: JoinHandle<()>,
    _writer_thread: Option<JoinHandle<()>>,
}

enum PtyCommand {
    Input(Vec<u8>),
    Resize(TerminalSize),
    Shutdown,
}

impl PtyTab {
    pub fn spawn_shell(size: TerminalSize) -> Result<Self> {
        Self::spawn_shell_with_output_hook(size, |_| {})
    }

    pub fn spawn_shell_with_output_hook<F>(size: TerminalSize, output_hook: F) -> Result<Self>
    where
        F: Fn(&[u8]) + Send + 'static,
    {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows: size.rows,
                cols: size.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("failed to open pty")?;

        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        let command_name = command_name(&shell);
        let mut command = CommandBuilder::new(shell);
        command.env("TERM", "xterm-256color");
        let child = pair
            .slave
            .spawn_command(command)
            .context("failed to spawn shell in pty")?;
        let child_pid = child.process_id();
        drop(pair.slave);

        let mut reader = pair
            .master
            .try_clone_reader()
            .context("failed to clone pty reader")?;
        let writer = Arc::new(Mutex::new(
            pair.master
                .take_writer()
                .context("failed to take pty writer")?,
        ));
        let master = pair.master;
        let output = Arc::new(Mutex::new(Vec::new()));
        let reader_output = output.clone();
        let reader_thread = thread::spawn(move || {
            let mut buffer = [0_u8; 4096];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(bytes_read) => {
                        output_hook(&buffer[..bytes_read]);
                        let mut output = reader_output.lock().expect("pty output lock poisoned");
                        output.extend_from_slice(&buffer[..bytes_read]);
                        let overflow = output.len().saturating_sub(128 * 1024);
                        if overflow > 0 {
                            output.drain(..overflow);
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(_) => break,
                }
            }
        });
        let (control_tx, control_rx) = mpsc::channel();
        let writer_thread = thread::spawn(move || {
            let mut pending_resize = None;
            loop {
                let command = match pending_resize.take() {
                    Some(size) => match control_rx.recv_timeout(Duration::from_millis(10)) {
                        Ok(PtyCommand::Resize(next_size)) => {
                            pending_resize = Some(next_size);
                            continue;
                        }
                        Ok(command) => {
                            let _ = master.resize(to_pty_size(size));
                            command
                        }
                        Err(mpsc::RecvTimeoutError::Timeout) => {
                            let _ = master.resize(to_pty_size(size));
                            continue;
                        }
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                    },
                    None => match control_rx.recv() {
                        Ok(command) => command,
                        Err(_) => break,
                    },
                };

                match command {
                    PtyCommand::Input(data) => {
                        let mut writer = writer.lock().expect("pty writer lock poisoned");
                        let _ = writer.write_all(&data);
                        let _ = writer.flush();
                    }
                    PtyCommand::Resize(size) => pending_resize = Some(size),
                    PtyCommand::Shutdown => break,
                }
            }
        });

        Ok(Self {
            child,
            child_pid,
            command_name,
            control_tx: Some(control_tx),
            output,
            _reader_thread: reader_thread,
            _writer_thread: Some(writer_thread),
        })
    }

    pub fn write_input(&self, data: &[u8]) -> Result<()> {
        self.send_command(PtyCommand::Input(data.to_vec()))
    }

    pub fn resize(&self, size: TerminalSize) -> Result<()> {
        self.send_command(PtyCommand::Resize(size))
    }

    pub fn output_tail(&self, max_bytes: usize) -> Vec<u8> {
        let output = self.output.lock().expect("pty output lock poisoned");
        let start = output.len().saturating_sub(max_bytes);
        output[start..].to_vec()
    }

    pub fn child_pid(&self) -> Option<u32> {
        self.child_pid
    }

    pub fn command_name(&self) -> &str {
        &self.command_name
    }

    fn send_command(&self, command: PtyCommand) -> Result<()> {
        self.control_tx
            .as_ref()
            .context("pty control queue is closed")?
            .send(command)
            .context("failed to send pty control command")
    }
}

impl Drop for PtyTab {
    fn drop(&mut self) {
        if let Some(control_tx) = self.control_tx.take() {
            let _ = control_tx.send(PtyCommand::Shutdown);
        }
        if let Some(writer_thread) = self._writer_thread.take() {
            let _ = writer_thread.join();
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn to_pty_size(size: TerminalSize) -> PtySize {
    PtySize {
        rows: size.rows,
        cols: size.cols,
        pixel_width: 0,
        pixel_height: 0,
    }
}

fn command_name(command: &str) -> String {
    command
        .rsplit('/')
        .next()
        .filter(|name| !name.is_empty())
        .unwrap_or(command)
        .to_string()
}
