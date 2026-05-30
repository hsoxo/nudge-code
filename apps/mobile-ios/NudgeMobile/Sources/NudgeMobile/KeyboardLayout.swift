import Foundation

/// Terminal font-size bounds shared by the model, persistence, and UI.
/// Kept nonisolated so it can seed default values in `AppModel`'s
/// nonisolated initializer and in `Codable` decoding.
enum TerminalFontSize {
    static let min = 10
    static let max = 20
    static let `default` = 13

    static func clamp(_ value: Int) -> Int {
        Swift.min(max, Swift.max(min, value))
    }
}

/// A single customizable key on the terminal keyboard.
///
/// `send` carries either literal text (e.g. "claude") or a control sequence
/// (e.g. "\u{1b}" for ESC). When `autoEnter` is true the daemon appends a
/// carriage return after the payload. `grow` is a flex-grow weight used for
/// relative key width; `danger` tints the keycap red.
struct KeyboardKey: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var label: String
    var send: String
    var autoEnter: Bool
    var grow: Double
    var danger: Bool

    static let minGrow: Double = 0.5
    static let maxGrow: Double = 12

    init(
        id: UUID = UUID(),
        label: String,
        send: String,
        autoEnter: Bool = false,
        grow: Double = 1,
        danger: Bool = false
    ) {
        self.id = id
        self.label = label
        self.send = send
        self.autoEnter = autoEnter
        self.grow = KeyboardKey.clampGrow(grow)
        self.danger = danger
    }

    /// Decodes tolerantly so future/legacy payloads without every field still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        send = try container.decodeIfPresent(String.self, forKey: .send) ?? ""
        autoEnter = try container.decodeIfPresent(Bool.self, forKey: .autoEnter) ?? false
        grow = KeyboardKey.clampGrow(try container.decodeIfPresent(Double.self, forKey: .grow) ?? 1)
        danger = try container.decodeIfPresent(Bool.self, forKey: .danger) ?? false
    }

    static func clampGrow(_ value: Double) -> Double {
        guard value.isFinite else {
            return 1
        }
        let rounded = (value * 4).rounded() / 4
        return min(maxGrow, max(minGrow, rounded))
    }

    /// Equality compares content only. `id` is a per-instance handle for
    /// SwiftUI list identity and intentionally excluded so two layouts with
    /// the same keys (e.g. the default) compare equal.
    static func == (lhs: KeyboardKey, rhs: KeyboardKey) -> Bool {
        lhs.label == rhs.label &&
            lhs.send == rhs.send &&
            lhs.autoEnter == rhs.autoEnter &&
            lhs.grow == rhs.grow &&
            lhs.danger == rhs.danger
    }
}

/// A grid of customizable keys rendered above the fixed arrow row.
struct KeyboardLayout: Codable, Equatable, Sendable {
    var rows: [[KeyboardKey]]

    init(rows: [[KeyboardKey]]) {
        self.rows = rows
    }

    /// The default layout, adapted from dinotty's `DEFAULT_ACTION_KEYBOARD`.
    static var `default`: KeyboardLayout {
        KeyboardLayout(rows: [
            [
                KeyboardKey(label: "cc", send: "claude", autoEnter: true),
                KeyboardKey(label: "oc", send: "codex", autoEnter: true)
            ],
            [
                KeyboardKey(label: "esc", send: "\u{1b}", autoEnter: true, danger: true),
                KeyboardKey(label: "ctrl+c", send: "\u{3}", autoEnter: true, danger: true),
                KeyboardKey(label: "clear", send: "clear", autoEnter: true),
                KeyboardKey(label: "⌫", send: "\u{7f}", grow: 1.5)
            ],
            [
                KeyboardKey(label: "PlanMode", send: "\u{1b}[Z", autoEnter: true, grow: 1.75),
                KeyboardKey(label: "/", send: "/", grow: 1.5),
                KeyboardKey(label: "tab", send: "\t", grow: 1.5),
                KeyboardKey(label: "1", send: "1", autoEnter: true),
                KeyboardKey(label: "2", send: "2", autoEnter: true),
                KeyboardKey(label: "3", send: "3", autoEnter: true),
                KeyboardKey(label: "4", send: "4", autoEnter: true)
            ]
        ])
    }
}

/// The fixed (non-editable) control row pinned below the customizable rows.
enum KeyboardControlKeys {
    static let arrowUp = KeyboardKey(label: "↑", send: "\u{1b}[A")
    static let arrowLeft = KeyboardKey(label: "←", send: "\u{1b}[D")
    static let arrowDown = KeyboardKey(label: "↓", send: "\u{1b}[B")
    static let arrowRight = KeyboardKey(label: "→", send: "\u{1b}[C")
    static let enter = KeyboardKey(label: "↵", send: "\r")

    static let all: [KeyboardKey] = [arrowUp, arrowLeft, arrowDown, arrowRight, enter]
}

/// Conversion between raw control bytes and the human-editable escape syntax
/// used in the keyboard editor (adapted from dinotty's KeyboardTab.vue):
/// `\e`=ESC, `\t`, `\r`, `\n`, `\x7f`, `^A..^Z`=ctrl, `\xHH`=hex byte.
enum KeyboardEscape {
    /// Encodes control characters in `value` into the editable display syntax.
    static func encodeForDisplay(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let code = scalar.value
            switch code {
            case 0x1b:
                result += "\\e"
            case 0x09:
                result += "\\t"
            case 0x0d:
                result += "\\r"
            case 0x0a:
                result += "\\n"
            case 0x7f:
                result += "\\x7f"
            case 1...26:
                result.append("^")
                result.unicodeScalars.append(Unicode.Scalar(code + 64)!)
            case 0..<0x20:
                result += "\\x" + String(format: "%02x", code)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Decodes the editable display syntax back into raw control characters.
    static func decodeFromDisplay(_ value: String) -> String {
        var result = ""
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\" || scalar == "^" else {
                result.unicodeScalars.append(scalar)
                index += 1
                continue
            }

            if scalar == "\\", index + 1 < scalars.count {
                let next = scalars[index + 1]
                switch next {
                case "e":
                    result.unicodeScalars.append(Unicode.Scalar(0x1b)!)
                    index += 2
                    continue
                case "t":
                    result.unicodeScalars.append(Unicode.Scalar(0x09)!)
                    index += 2
                    continue
                case "r":
                    result.unicodeScalars.append(Unicode.Scalar(0x0d)!)
                    index += 2
                    continue
                case "n":
                    result.unicodeScalars.append(Unicode.Scalar(0x0a)!)
                    index += 2
                    continue
                case "x", "X":
                    if index + 3 < scalars.count,
                       let high = scalars[index + 2].hexDigitValue,
                       let low = scalars[index + 3].hexDigitValue,
                       let decoded = Unicode.Scalar(UInt32(high * 16 + low)) {
                        result.unicodeScalars.append(decoded)
                        index += 4
                        continue
                    }
                default:
                    break
                }
            }

            if scalar == "^", index + 1 < scalars.count {
                let next = scalars[index + 1]
                if next == "?" {
                    result.unicodeScalars.append(Unicode.Scalar(0x7f)!)
                    index += 2
                    continue
                }
                if next == "@" {
                    result.unicodeScalars.append(Unicode.Scalar(0)!)
                    index += 2
                    continue
                }
                let value = next.value
                if value >= 65, value <= 95 {
                    result.unicodeScalars.append(Unicode.Scalar(value - 64)!)
                    index += 2
                    continue
                }
            }

            result.unicodeScalars.append(scalar)
            index += 1
        }
        return result
    }
}

private extension Unicode.Scalar {
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9":
            return Int(value - 48)
        case "a"..."f":
            return Int(value - 97 + 10)
        case "A"..."F":
            return Int(value - 65 + 10)
        default:
            return nil
        }
    }
}
