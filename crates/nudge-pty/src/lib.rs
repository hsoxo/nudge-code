use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

use anyhow::{Context, Result};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};

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
    _master: Box<dyn MasterPty + Send>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    output: Arc<Mutex<Vec<u8>>>,
    _reader_thread: JoinHandle<()>,
}

impl PtyTab {
    pub fn spawn_shell(size: TerminalSize) -> Result<Self> {
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
        let mut command = CommandBuilder::new(shell);
        command.env("TERM", "xterm-256color");
        let child = pair
            .slave
            .spawn_command(command)
            .context("failed to spawn shell in pty")?;
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
        let output = Arc::new(Mutex::new(Vec::new()));
        let reader_output = output.clone();
        let reader_thread = thread::spawn(move || {
            let mut buffer = [0_u8; 4096];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(bytes_read) => {
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

        Ok(Self {
            child,
            _master: pair.master,
            writer,
            output,
            _reader_thread: reader_thread,
        })
    }

    pub fn write_input(&self, data: &[u8]) -> Result<()> {
        let mut writer = self.writer.lock().expect("pty writer lock poisoned");
        writer
            .write_all(data)
            .context("failed to write pty input")?;
        writer.flush().context("failed to flush pty input")
    }

    pub fn output_tail(&self, max_bytes: usize) -> Vec<u8> {
        let output = self.output.lock().expect("pty output lock poisoned");
        let start = output.len().saturating_sub(max_bytes);
        output[start..].to_vec()
    }
}

impl Drop for PtyTab {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
