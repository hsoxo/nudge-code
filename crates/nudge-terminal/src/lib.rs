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
    /// Absolute stream offset this snapshot represents (`total_bytes` at capture
    /// time). Deltas at a smaller offset are already included here; the phone
    /// adopts this as its baseline and trims/drops anything earlier.
    pub offset: u64,
}

pub struct TerminalGrid {
    size: TerminalSize,
    parser: vt100::Parser,
    /// Total bytes ever fed through `process` for this tab. Monotonic, and
    /// preserved across `resize`. It is the absolute axis the phone uses to
    /// order deltas against snapshots: a snapshot captures this value under the
    /// same lock as its contents, so any byte is unambiguously before or after
    /// the snapshot.
    total_bytes: u64,
}

impl TerminalGrid {
    pub fn new(size: TerminalSize) -> Self {
        Self {
            size,
            parser: vt100::Parser::new(size.rows, size.cols, 0),
            total_bytes: 0,
        }
    }

    /// Feed bytes to the emulator, returning the absolute **start** offset of
    /// this chunk (i.e. `total_bytes` before the chunk is applied).
    pub fn process(&mut self, bytes: &[u8]) -> u64 {
        let start = self.total_bytes;
        self.parser.process(bytes);
        self.total_bytes += bytes.len() as u64;
        start
    }

    /// Absolute count of bytes fed so far — the offset a snapshot represents.
    pub fn total_bytes(&self) -> u64 {
        self.total_bytes
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
            offset: self.total_bytes,
        }
    }

    /// Bytes that reconstruct the FULL terminal state when written into a freshly
    /// reset emulator: a hard reset, the active modes (alt-screen, application
    /// cursor/keypad, bracketed paste, mouse protocol + encoding), then the
    /// formatted visible contents (cursor visibility + SGR + cells + cursor
    /// position). Unlike `snapshot().formatted` — which is contents only — this
    /// restores the modes, so deltas that resume after a resync are interpreted
    /// in the right mode (e.g. while inside the alternate screen).
    ///
    /// Limitation: vt100 0.16 does not track origin mode (DECOM), scroll region
    /// (DECSTBM), or charset (SCS), so those are not restored — a TUI relying on
    /// them re-establishes them on its next redraw. Scrollback (M1) is likewise
    /// out of scope.
    pub fn state_frame(&self) -> Vec<u8> {
        let screen = self.parser.screen();
        let mut frame = Vec::new();
        // Hard reset (RIS) so the target starts from a known baseline.
        frame.extend_from_slice(b"\x1bc");
        // Alternate-screen is the one mode vt100's input_mode_formatted() omits,
        // so restore it first; contents_formatted() then draws into it.
        if screen.alternate_screen() {
            frame.extend_from_slice(b"\x1b[?1049h");
        }
        // Canonical input-mode restoration (application keypad/cursor, bracketed
        // paste, mouse protocol + encoding). Using vt100's own emitter rather
        // than hand-rolled escape sequences keeps us in lock-step with the
        // emulator and won't silently drift if vt100 adds tracked modes.
        frame.extend_from_slice(&screen.input_mode_formatted());
        // Visible cells + SGR.
        frame.extend_from_slice(&screen.contents_formatted());
        // Cursor visibility + FINAL cursor position. contents_formatted() leaves
        // the cursor in an unspecified spot, so this lands it where the real
        // terminal has it — emitted last.
        frame.extend_from_slice(&screen.cursor_state_formatted());
        frame
    }

    pub fn render_frame(&self, row_offset: u16) -> Vec<u8> {
        let screen = self.parser.screen();
        let mut frame = Vec::new();
        push_cursor_visibility(&mut frame, screen.hide_cursor());
        for (row, row_bytes) in screen.rows_formatted(0, self.size.cols).enumerate() {
            let row = u16::try_from(row).unwrap_or(u16::MAX);
            push_move_to(&mut frame, row_offset.saturating_add(row), 0);
            frame.extend_from_slice(b"\x1b[2K");
            push_offset_cursor_moves(&mut frame, &row_bytes, row_offset);
        }
        frame.extend_from_slice(b"\x1b[m");
        let (cursor_row, cursor_col) = screen.cursor_position();
        let cursor_col = cursor_col.min(self.size.cols.saturating_sub(1));
        push_move_to(
            &mut frame,
            row_offset.saturating_add(cursor_row),
            cursor_col,
        );
        push_cursor_visibility(&mut frame, screen.hide_cursor());
        frame
    }
}

fn push_move_to(buffer: &mut Vec<u8>, row: u16, col: u16) {
    if row == 0 && col == 0 {
        buffer.extend_from_slice(b"\x1b[H");
    } else {
        buffer.extend_from_slice(format!("\x1b[{};{}H", row + 1, col + 1).as_bytes());
    }
}

fn push_cursor_visibility(buffer: &mut Vec<u8>, hidden: bool) {
    if hidden {
        buffer.extend_from_slice(b"\x1b[?25l");
    } else {
        buffer.extend_from_slice(b"\x1b[?25h");
    }
}

fn push_offset_cursor_moves(buffer: &mut Vec<u8>, bytes: &[u8], row_offset: u16) {
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == 0x1b && bytes.get(index + 1) == Some(&b'[') {
            let sequence_start = index;
            index += 2;
            while index < bytes.len() && !(0x40..=0x7e).contains(&bytes[index]) {
                index += 1;
            }
            if index >= bytes.len() {
                buffer.extend_from_slice(&bytes[sequence_start..]);
                return;
            }

            let final_byte = bytes[index];
            let params = &bytes[(sequence_start + 2)..index];
            if matches!(final_byte, b'H' | b'f')
                && let Some((row, col)) = parse_cursor_position_params(params)
            {
                let row = row.saturating_add(row_offset);
                buffer.extend_from_slice(
                    format!("\x1b[{row};{col}{}", final_byte as char).as_bytes(),
                );
            } else {
                buffer.extend_from_slice(&bytes[sequence_start..=index]);
            }
            index += 1;
        } else {
            buffer.push(bytes[index]);
            index += 1;
        }
    }
}

fn parse_cursor_position_params(params: &[u8]) -> Option<(u16, u16)> {
    if params.is_empty() {
        return Some((1, 1));
    }
    if params
        .iter()
        .any(|byte| !byte.is_ascii_digit() && *byte != b';')
    {
        return None;
    }
    let mut parts = params.split(|byte| *byte == b';');
    let row = parse_cursor_position_param(parts.next().unwrap_or_default())?;
    let col = parse_cursor_position_param(parts.next().unwrap_or_default())?;
    if parts.next().is_some() {
        return None;
    }
    Some((row, col))
}

fn parse_cursor_position_param(param: &[u8]) -> Option<u16> {
    if param.is_empty() {
        return Some(1);
    }
    let mut value = 0u32;
    for byte in param {
        value = value
            .saturating_mul(10)
            .saturating_add(u32::from(byte - b'0'));
    }
    Some(value.clamp(1, u32::from(u16::MAX)) as u16)
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
        assert_eq!(snapshot.offset, 5, "snapshot offset is total_bytes at capture");
    }

    #[test]
    fn process_returns_contiguous_start_offsets() {
        let mut grid = TerminalGrid::default();
        assert_eq!(grid.process(b"hello"), 0);
        assert_eq!(grid.total_bytes(), 5);
        assert_eq!(grid.process(b" world"), 5);
        assert_eq!(grid.total_bytes(), 11);
    }

    #[test]
    fn state_frame_round_trips_alt_screen_modes_and_cursor() {
        let mut grid = TerminalGrid::default();
        // Enter alt-screen + application cursor + bracketed paste + mouse
        // (press/release, SGR encoding), draw red text, then park the cursor at a
        // non-trivial spot (row 6, col 11) that differs from where drawing ends.
        grid.process(b"\x1b[?1049h\x1b[?1h\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[31mhello\x1b[6;11H");
        let original = grid.snapshot();
        let original_cursor = grid.parser.screen().cursor_position();
        assert_eq!(original_cursor, (5, 10), "cursor parked at row 6 col 11 (0-indexed)");
        assert!(grid.parser.screen().alternate_screen());

        // Reconstruct in a fresh emulator from the state frame alone.
        let mut rebuilt = TerminalGrid::default();
        rebuilt.process(&grid.state_frame());

        let screen = rebuilt.parser.screen();
        assert!(screen.alternate_screen(), "alt-screen restored");
        assert!(screen.application_cursor(), "application cursor restored");
        assert!(screen.bracketed_paste(), "bracketed paste restored");
        assert_eq!(screen.mouse_protocol_mode(), vt100::MouseProtocolMode::PressRelease);
        assert_eq!(screen.mouse_protocol_encoding(), vt100::MouseProtocolEncoding::Sgr);
        // Visible contents (text + SGR) match...
        assert_eq!(rebuilt.snapshot().text, original.text);
        assert_eq!(rebuilt.snapshot().formatted, original.formatted);
        // ...and the FINAL cursor position is restored (what cursor_state_formatted
        // adds; contents_formatted alone leaves it unspecified).
        assert_eq!(screen.cursor_position(), original_cursor);
    }

    #[test]
    fn total_bytes_survives_resize() {
        let mut grid = TerminalGrid::default();
        grid.process(b"hello world");
        assert_eq!(grid.total_bytes(), 11);
        // resize re-renders geometry; it must not discontinue the byte axis.
        grid.resize(TerminalSize::new(100, 40));
        assert_eq!(grid.total_bytes(), 11);
        // The next chunk continues from the preserved offset.
        assert_eq!(grid.process(b"!"), 11);
    }

    #[test]
    fn render_frame_targets_content_area_without_full_screen_clear() {
        let mut grid = TerminalGrid::default();
        grid.process(b"\x1b[31mhello");

        let frame = grid.render_frame(1);

        assert!(frame.starts_with(b"\x1b[?25h\x1b[2;1H\x1b[2K"));
        assert!(
            frame
                .windows(b"hello".len())
                .any(|window| window == b"hello")
        );
        assert!(
            !frame
                .windows(b"\x1b[H\x1b[J".len())
                .any(|window| window == b"\x1b[H\x1b[J")
        );
    }

    #[test]
    fn render_frame_restores_offset_cursor_position() {
        let mut grid = TerminalGrid::default();
        grid.process(b"hi");

        let frame = grid.render_frame(1);

        assert!(frame.ends_with(b"\x1b[2;3H\x1b[?25h"));
    }

    #[test]
    fn render_frame_offsets_absolute_cursor_moves_inside_row_bytes() {
        let mut frame = Vec::new();

        push_offset_cursor_moves(&mut frame, b"\x1b[Htop\x1b[3;4Hcell\x1b[2K", 1);

        assert_eq!(frame, b"\x1b[2;1Htop\x1b[4;4Hcell\x1b[2K");
    }
}
