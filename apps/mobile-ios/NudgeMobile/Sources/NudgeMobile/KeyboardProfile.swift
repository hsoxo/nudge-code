import Foundation

struct ShortcutKey: Identifiable, Equatable, Sendable {
    var id: String { label + payload }
    var label: String
    var payload: String
}

struct KeyboardProfile: Equatable, Sendable {
    var primary: [ShortcutKey]
    var secondary: [ShortcutKey]
    var actionTitle: String

    static func profile(for status: AgentStatus) -> KeyboardProfile {
        var primary = [
            ShortcutKey(label: "Esc", payload: "\u{1b}"),
            ShortcutKey(label: "Tab", payload: "\t"),
            ShortcutKey(label: "Ctrl-C", payload: "\u{3}"),
            ShortcutKey(label: "Enter", payload: "\r")
        ]
        var secondary: [ShortcutKey]
        var actionTitle = "Send Command"

        switch status.kind {
        case .claude:
            secondary = [
                ShortcutKey(label: "Plan", payload: "Plan the next step"),
                ShortcutKey(label: "Continue", payload: "continue"),
                ShortcutKey(label: "Summarize", payload: "summarize current state")
            ]
            actionTitle = "Send Prompt"
        case .codex:
            secondary = [
                ShortcutKey(label: "Status", payload: "status"),
                ShortcutKey(label: "Continue", payload: "continue"),
                ShortcutKey(label: "Test", payload: "run tests")
            ]
            actionTitle = "Send Prompt"
        case .opencode, .openclaw:
            secondary = [
                ShortcutKey(label: "Continue", payload: "continue"),
                ShortcutKey(label: "Diff", payload: "show diff"),
                ShortcutKey(label: "Tests", payload: "run tests")
            ]
            actionTitle = "Send Prompt"
        case .shell, .unknown:
            secondary = [
                ShortcutKey(label: "ls", payload: "ls\r"),
                ShortcutKey(label: "git", payload: "git status\r"),
                ShortcutKey(label: "clear", payload: "clear\r")
            ]
        }

        switch status.state {
        case .needsApproval:
            primary.insert(ShortcutKey(label: "Reject", payload: "n"), at: 0)
            primary.insert(ShortcutKey(label: "Approve", payload: "y"), at: 0)
            actionTitle = "Confirm"
        case .waitingForInput:
            primary.append(ShortcutKey(label: "Submit", payload: "\r"))
        case .running, .idle, .needsAttention, .exited:
            break
        }

        return KeyboardProfile(primary: primary, secondary: secondary, actionTitle: actionTitle)
    }
}
