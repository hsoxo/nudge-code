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
        #expect(model.machines.first?.binding == MachineBinding(
            bindingID: "bind_1",
            daemonDeviceID: "daemon_1",
            phoneDeviceID: "phone_1",
            status: .claimed,
            expiresAt: "2026-05-29T00:00:00Z"
        ))
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

    @Test func appModelRefreshesClaimedBindingToActive() async throws {
        let machine = Machine(
            id: "mac",
            name: "Mac",
            relayURL: URL(string: "https://nudgecode.dev")!,
            connectionState: .connecting,
            lastSeenText: "Waiting for computer confirmation",
            binding: MachineBinding(
                bindingID: "bind_1",
                daemonDeviceID: "daemon_1",
                phoneDeviceID: "phone_1",
                status: .claimed,
                expiresAt: "2026-05-29T00:00:00Z"
            )
        )
        let client = RecordingRelayClient(statusClaim: BindingClaim(
            bindingID: "bind_1",
            daemonDeviceID: "daemon_1",
            phoneDeviceID: "phone_1",
            status: .active,
            expiresAt: "2026-05-29T00:00:00Z"
        ))
        let model = AppModel(machines: [machine], selectedMachineID: machine.id, relayClient: client)

        await model.refreshSelectedMachineBinding()

        #expect(client.statusRequests == [BindingStatusRequest(
            binding: machine.binding!,
            relayURL: URL(string: "https://nudgecode.dev")!
        )])
        #expect(model.machines.first?.binding?.status == .active)
        #expect(model.machines.first?.connectionState == .online)
        #expect(model.machines.first?.lastSeenText == "binding active")
    }

    @Test func appModelSkipsRefreshForActiveBinding() async throws {
        let machine = Machine(
            id: "mac",
            name: "Mac",
            relayURL: URL(string: "https://nudgecode.dev")!,
            connectionState: .online,
            lastSeenText: "binding active",
            binding: MachineBinding(
                bindingID: "bind_1",
                daemonDeviceID: "daemon_1",
                phoneDeviceID: "phone_1",
                status: .active,
                expiresAt: "2026-05-29T00:00:00Z"
            )
        )
        let client = RecordingRelayClient(error: RelayClientError.badStatus)
        let model = AppModel(machines: [machine], selectedMachineID: machine.id, relayClient: client)

        await model.refreshSelectedMachineBinding()

        #expect(client.statusRequests.isEmpty)
        #expect(model.machines.first == machine)
    }

    @Test func appModelAttachesActiveMachineSession() async throws {
        let machine = Machine(
            id: "mac",
            name: "Mac",
            relayURL: URL(string: "https://nudgecode.dev")!,
            connectionState: .online,
            lastSeenText: "binding active",
            binding: MachineBinding(
                bindingID: "bind_1",
                daemonDeviceID: "daemon_1",
                phoneDeviceID: "phone_1",
                status: .active,
                expiresAt: "2026-05-29T00:00:00Z"
            )
        )
        let remoteTab = TerminalTab(
            id: "default",
            title: "Codex",
            state: .running,
            widthMode: .computer,
            profile: TerminalProfile(rows: 24, cols: 100),
            agentStatus: AgentStatus(kind: .codex, state: .waitingForInput, confidence: 0.72, source: "screen"),
            previewText: "Relay session attached\nWaiting for terminal snapshot..."
        )
        let client = RecordingRelayClient(sessionState: RemoteSessionState(tabs: [remoteTab]))
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: []],
            selectedMachineID: machine.id,
            relayClient: client
        )

        await model.attachSelectedMachineSession()

        #expect(client.sessionRequests == [machine])
        #expect(model.selectedTabID == "default")
        #expect(model.tabsByMachine[machine.id] == [remoteTab])
        #expect(model.machines.first?.lastSeenText == "relay session attached")
    }
}

private struct RelayClaim: Equatable {
    var code: String
    var relayURL: URL
}

private struct BindingStatusRequest: Equatable {
    var binding: MachineBinding
    var relayURL: URL
}

private final class RecordingRelayClient: RelayClient, @unchecked Sendable {
    var claims: [RelayClaim] = []
    var statusRequests: [BindingStatusRequest] = []
    var sessionRequests: [Machine] = []
    var statusClaim: BindingClaim
    var sessionState: RemoteSessionState
    var error: Error?

    init(
        statusClaim: BindingClaim = BindingClaim(
            bindingID: "bind_1",
            daemonDeviceID: "daemon_1",
            phoneDeviceID: "phone_1",
            status: .claimed,
            expiresAt: "2026-05-29T00:00:00Z"
        ),
        sessionState: RemoteSessionState = RemoteSessionState(tabs: []),
        error: Error? = nil
    ) {
        self.statusClaim = statusClaim
        self.sessionState = sessionState
        self.error = error
    }

    func claimBinding(code: String, relayURL: URL) async throws -> BindingClaim {
        if let error {
            throw error
        }
        claims.append(RelayClaim(code: code, relayURL: relayURL))
        return BindingClaim(
            bindingID: "bind_1",
            daemonDeviceID: "daemon_1",
            phoneDeviceID: "phone_1",
            status: .claimed,
            expiresAt: "2026-05-29T00:00:00Z"
        )
    }

    func fetchBindingStatus(binding: MachineBinding, relayURL: URL) async throws -> BindingClaim {
        if let error {
            throw error
        }
        statusRequests.append(BindingStatusRequest(binding: binding, relayURL: relayURL))
        return statusClaim
    }

    func fetchSessionState(machine: Machine) async throws -> RemoteSessionState {
        if let error {
            throw error
        }
        sessionRequests.append(machine)
        return sessionState
    }

    func connect(machine: Machine) async throws {
        _ = machine
    }
}
