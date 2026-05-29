import Testing
@testable import NudgeMobile

@Suite("Keyboard profile selection")
struct KeyboardProfileTests {
    @Test func claudeApprovalAddsApprovalKeys() {
        let status = AgentStatus(kind: .claude, state: .needsApproval, confidence: 0.8, source: "screen")
        let profile = KeyboardProfile.profile(for: status)

        #expect(profile.actionTitle == "Confirm")
        #expect(profile.primary.contains { $0.label == "Approve" })
        #expect(profile.primary.contains { $0.label == "Reject" })
        #expect(profile.secondary.contains { $0.label == "Plan" })
        #expect(profile.primary.first { $0.label == "Approve" }?.submit == true)
        #expect(profile.primary.first { $0.label == "Reject" }?.submit == true)
        #expect(profile.primary.first { $0.label == "Approve" }?.requiresConfirmation == true)
        #expect(profile.primary.first { $0.label == "Approve" }?.armedLabel == "Confirm Approve")
        #expect(profile.primary.first { $0.label == "Reject" }?.requiresConfirmation == false)
    }

    @Test func codexWaitingAddsSubmitAndCodexShortcuts() {
        let status = AgentStatus(kind: .codex, state: .waitingForInput, confidence: 0.7, source: "screen")
        let profile = KeyboardProfile.profile(for: status)

        #expect(profile.actionTitle == "Send Prompt")
        #expect(profile.primary.contains { $0.label == "Submit" })
        #expect(profile.secondary.contains { $0.label == "Test" })
        #expect(profile.secondary.first { $0.label == "Test" }?.submit == true)
    }

    @Test func rawTerminalKeysDoNotSubmit() {
        let status = AgentStatus(kind: .shell, state: .running, confidence: 0.6, source: "process")
        let profile = KeyboardProfile.profile(for: status)

        #expect(profile.primary.first { $0.label == "Esc" }?.submit == false)
        #expect(profile.primary.first { $0.label == "Tab" }?.submit == false)
        #expect(profile.primary.first { $0.label == "Ctrl-C" }?.submit == false)
        #expect(profile.primary.first { $0.label == "Enter" }?.submit == false)
    }

    @Test func shellShortcutCommandsSubmitOnce() {
        let status = AgentStatus(kind: .shell, state: .running, confidence: 0.6, source: "process")
        let profile = KeyboardProfile.profile(for: status)

        #expect(profile.secondary.first { $0.label == "ls" } == ShortcutKey(label: "ls", payload: "ls", submit: true))
        #expect(profile.secondary.first { $0.label == "git" } == ShortcutKey(label: "git", payload: "git status", submit: true))
        #expect(profile.secondary.first { $0.label == "clear" } == ShortcutKey(label: "clear", payload: "clear", submit: true))
    }
}
