import Foundation
import Testing
@testable import NudgeMobile

@Suite("Keyboard layout model")
struct KeyboardLayoutTests {
    @Test func defaultLayoutMatchesDinottyAdaptation() {
        let layout = KeyboardLayout.default
        #expect(layout.rows.count == 3)

        let row1 = layout.rows[0]
        #expect(row1.map(\.label) == ["cc", "oc"])
        #expect(row1[0].send == "claude")
        #expect(row1[0].autoEnter)
        #expect(row1[1].send == "codex")

        let row2 = layout.rows[1]
        #expect(row2.map(\.label) == ["esc", "ctrl+c", "clear", "⌫"])
        #expect(row2[0].send == "\u{1b}")
        #expect(row2[0].danger)
        #expect(row2[0].autoEnter)
        #expect(row2[1].send == "\u{3}")
        #expect(row2[1].danger)
        #expect(row2[3].send == "\u{7f}")
        #expect(row2[3].grow == 1.5)

        let row3 = layout.rows[2]
        #expect(row3[0].label == "PlanMode")
        #expect(row3[0].send == "\u{1b}[Z")
        #expect(row3[0].grow == 1.75)
        #expect(row3.suffix(4).map(\.label) == ["1", "2", "3", "4"])
        #expect(row3.suffix(4).allSatisfy { $0.autoEnter })
    }

    @Test func controlKeysAreFixedArrowsAndEnter() {
        #expect(KeyboardControlKeys.arrowUp.send == "\u{1b}[A")
        #expect(KeyboardControlKeys.arrowLeft.send == "\u{1b}[D")
        #expect(KeyboardControlKeys.arrowDown.send == "\u{1b}[B")
        #expect(KeyboardControlKeys.arrowRight.send == "\u{1b}[C")
        #expect(KeyboardControlKeys.enter.send == "\r")
        #expect(KeyboardControlKeys.all.count == 5)
    }

    @Test func growIsClampedAndQuantized() {
        #expect(KeyboardKey(label: "a", send: "a", grow: 0.1).grow == KeyboardKey.minGrow)
        #expect(KeyboardKey(label: "a", send: "a", grow: 99).grow == KeyboardKey.maxGrow)
        #expect(KeyboardKey(label: "a", send: "a", grow: 1.31).grow == 1.25)
    }

    @Test func escapeEncodesControlCharacters() {
        #expect(KeyboardEscape.encodeForDisplay("\u{1b}") == "\\e")
        #expect(KeyboardEscape.encodeForDisplay("\t") == "\\t")
        #expect(KeyboardEscape.encodeForDisplay("\r") == "\\r")
        #expect(KeyboardEscape.encodeForDisplay("\n") == "\\n")
        #expect(KeyboardEscape.encodeForDisplay("\u{7f}") == "\\x7f")
        #expect(KeyboardEscape.encodeForDisplay("\u{3}") == "^C")
        #expect(KeyboardEscape.encodeForDisplay("claude") == "claude")
        #expect(KeyboardEscape.encodeForDisplay("\u{1b}[Z") == "\\e[Z")
    }

    @Test func escapeDecodesDisplaySyntax() {
        #expect(KeyboardEscape.decodeFromDisplay("\\e") == "\u{1b}")
        #expect(KeyboardEscape.decodeFromDisplay("\\t") == "\t")
        #expect(KeyboardEscape.decodeFromDisplay("\\r") == "\r")
        #expect(KeyboardEscape.decodeFromDisplay("\\n") == "\n")
        #expect(KeyboardEscape.decodeFromDisplay("\\x7f") == "\u{7f}")
        #expect(KeyboardEscape.decodeFromDisplay("^C") == "\u{3}")
        #expect(KeyboardEscape.decodeFromDisplay("^?") == "\u{7f}")
        #expect(KeyboardEscape.decodeFromDisplay("\\e[Z") == "\u{1b}[Z")
        #expect(KeyboardEscape.decodeFromDisplay("clear") == "clear")
    }

    @Test func escapeRoundTripsForDefaultKeys() {
        for row in KeyboardLayout.default.rows {
            for key in row {
                let display = KeyboardEscape.encodeForDisplay(key.send)
                #expect(KeyboardEscape.decodeFromDisplay(display) == key.send)
            }
        }
    }

    @Test func layoutIsCodableRoundTrip() throws {
        let layout = KeyboardLayout.default
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(KeyboardLayout.self, from: data)
        #expect(decoded == layout)
    }
}
