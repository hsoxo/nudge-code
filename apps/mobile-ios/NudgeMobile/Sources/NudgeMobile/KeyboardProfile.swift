import Foundation

struct ShortcutKey: Identifiable, Equatable, Sendable {
    var id: String { label + payload }
    var label: String
    var payload: String
    var submit: Bool = false
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
                ShortcutKey(label: "Plan", payload: "Plan the next step", submit: true),
                ShortcutKey(label: "Continue", payload: "continue", submit: true),
                ShortcutKey(label: "Summarize", payload: "summarize current state", submit: true)
            ]
            actionTitle = "Send Prompt"
        case .codex:
            secondary = [
                ShortcutKey(label: "Status", payload: "status", submit: true),
                ShortcutKey(label: "Continue", payload: "continue", submit: true),
                ShortcutKey(label: "Test", payload: "run tests", submit: true)
            ]
            actionTitle = "Send Prompt"
        case .opencode, .openclaw:
            secondary = [
                ShortcutKey(label: "Continue", payload: "continue", submit: true),
                ShortcutKey(label: "Diff", payload: "show diff", submit: true),
                ShortcutKey(label: "Tests", payload: "run tests", submit: true)
            ]
            actionTitle = "Send Prompt"
        case .shell, .unknown:
            secondary = [
                ShortcutKey(label: "ls", payload: "ls", submit: true),
                ShortcutKey(label: "git", payload: "git status", submit: true),
                ShortcutKey(label: "clear", payload: "clear", submit: true)
            ]
        }

        switch status.state {
        case .needsApproval:
            primary.insert(ShortcutKey(label: "Reject", payload: "n", submit: true), at: 0)
            primary.insert(ShortcutKey(label: "Approve", payload: "y", submit: true), at: 0)
            actionTitle = "Confirm"
        case .waitingForInput:
            primary.append(ShortcutKey(label: "Submit", payload: "\r"))
        case .running, .idle, .needsAttention, .exited:
            break
        }

        return KeyboardProfile(primary: primary, secondary: secondary, actionTitle: actionTitle)
    }
}
