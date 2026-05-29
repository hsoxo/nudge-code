#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalSize {
    pub cols: u16,
    pub rows: u16,
}

impl TerminalSize {
    pub const fn new(cols: u16, rows: u16) -> Self {
        Self { cols, rows }
    }
}

impl Default for TerminalSize {
    fn default() -> Self {
        Self { cols: 80, rows: 24 }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalSnapshot {
    pub rows: u16,
    pub cols: u16,
    pub text: String,
    pub formatted: Vec<u8>,
}

pub struct TerminalGrid {
    size: TerminalSize,
    parser: vt100::Parser,
}

impl TerminalGrid {
    pub fn new(size: TerminalSize) -> Self {
        Self {
            size,
            parser: vt100::Parser::new(size.rows, size.cols, 0),
        }
    }

    pub fn process(&mut self, bytes: &[u8]) {
        self.parser.process(bytes);
    }

    pub fn resize(&mut self, size: TerminalSize) {
        if self.size == size {
            return;
        }

        // vt100 0.16 does not expose a public resize API. Replaying the
        // formatted visible contents gives us a useful resized snapshot for
        // reconnect until we add richer scrollback/reflow support.
        let formatted = self.parser.screen().contents_formatted();
        self.size = size;
        self.parser = vt100::Parser::new(size.rows, size.cols, 0);
        self.parser.process(&formatted);
    }

    pub fn snapshot(&self) -> TerminalSnapshot {
        TerminalSnapshot {
            rows: self.size.rows,
            cols: self.size.cols,
            text: self.parser.screen().contents(),
            formatted: self.parser.screen().contents_formatted(),
        }
    }
}

impl Default for TerminalGrid {
    fn default() -> Self {
        Self::new(TerminalSize::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_contains_processed_text() {
        let mut grid = TerminalGrid::default();
        grid.process(b"hello");
        let snapshot = grid.snapshot();
        assert_eq!(snapshot.rows, 24);
        assert_eq!(snapshot.cols, 80);
        assert!(snapshot.text.contains("hello"));
        assert!(!snapshot.formatted.is_empty());
    }
}
