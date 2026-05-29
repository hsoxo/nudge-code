import Foundation
import Testing
@testable import NudgeMobile

@Suite("Binding claim flow")
@MainActor
struct BindingClaimTests {
    @Test func appModelClaimsDraftThroughRelayClient() async throws {
        let client = RecordingRelayClient()
        let model = AppModel(relayClient: client)

        #expect(model.parsePairingURL("https://nudgecode.dev/pair?code=abc123"))
        await model.claimDraftBinding()

        #expect(client.claims == [RelayClaim(code: "abc123", relayURL: URL(string: "https://nudgecode.dev")!)])
        #expect(model.bindingClaimState == .claimed)
        #expect(model.bindingDraft == nil)
        #expect(model.machines.first?.connectionState == .connecting)
    }

    @Test func appModelKeepsDraftWhenRelayClaimFails() async throws {
        let client = RecordingRelayClient(error: RelayClientError.badStatus)
        let model = AppModel(relayClient: client)

        #expect(model.parsePairingURL("https://nudgecode.dev/pair?code=abc123"))
        await model.claimDraftBinding()

        #expect(model.bindingDraft?.code == "abc123")
        guard case .failed = model.bindingClaimState else {
            Issue.record("Expected failed binding state")
            return
        }
        #expect(model.machines.isEmpty)
    }
}

private struct RelayClaim: Equatable {
    var code: String
    var relayURL: URL
}

private final class RecordingRelayClient: RelayClient, @unchecked Sendable {
    var claims: [RelayClaim] = []
    var error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func claimBinding(code: String, relayURL: URL) async throws {
        if let error {
            throw error
        }
        claims.append(RelayClaim(code: code, relayURL: relayURL))
    }

    func connect(machine: Machine) async throws {
        _ = machine
    }
}
