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
    }

    @Test func codexWaitingAddsSubmitAndCodexShortcuts() {
        let status = AgentStatus(kind: .codex, state: .waitingForInput, confidence: 0.7, source: "screen")
        let profile = KeyboardProfile.profile(for: status)

        #expect(profile.actionTitle == "Send Prompt")
        #expect(profile.primary.contains { $0.label == "Submit" })
        #expect(profile.secondary.contains { $0.label == "Test" })
    }
}
