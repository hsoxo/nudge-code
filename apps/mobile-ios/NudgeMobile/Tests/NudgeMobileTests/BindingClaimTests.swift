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
        let client = RecordingRelayClient(
            sessionState: RemoteSessionState(tabs: [remoteTab]),
            snapshots: ["default": TerminalSnapshot(
                tabID: "default",
                profile: TerminalProfile(rows: 26, cols: 92),
                text: "Codex is ready"
            )]
        )
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: []],
            selectedMachineID: machine.id,
            relayClient: client
        )

        await model.attachSelectedMachineSession()

        #expect(client.sessionRequests == [machine])
        #expect(client.snapshotRequests.map(\.machine.id) == [machine.id])
        #expect(client.snapshotRequests.map(\.tabID) == ["default"])
        #expect(model.selectedTabID == "default")
        #expect(model.tabsByMachine[machine.id]?.first?.previewText == "Codex is ready")
        #expect(model.tabsByMachine[machine.id]?.first?.profile == TerminalProfile(rows: 26, cols: 92))
        #expect(model.machines.first?.lastSeenText == "relay session attached")
    }

    @Test func appModelSendsSelectedTabInput() async throws {
        let machine = Machine(
            id: "mac",
            name: "Mac",
            relayURL: URL(string: "https://nudgecode.dev")!,
            connectionState: .online,
            lastSeenText: "relay session attached",
            binding: MachineBinding(
                bindingID: "bind_1",
                daemonDeviceID: "daemon_1",
                phoneDeviceID: "phone_1",
                status: .active,
                expiresAt: "2026-05-29T00:00:00Z"
            )
        )
        let tab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
            previewText: "$ "
        )
        let client = RecordingRelayClient(snapshots: ["default": TerminalSnapshot(
            tabID: "default",
            profile: TerminalProfile(rows: 32, cols: 48),
            text: "$ echo hi\nhi"
        )])
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: [tab]],
            selectedMachineID: machine.id,
            selectedTabID: tab.id,
            relayClient: client
        )

        await model.sendSelectedTabInput("echo hi", enter: true)

        #expect(client.inputRequests == [TerminalInputRequest(
            machine: machine,
            tabID: tab.id,
            text: "echo hi",
            enter: true
        )])
        #expect(client.snapshotRequests == [TerminalSnapshotRequest(machine: machine, tabID: tab.id)])
        #expect(model.tabsByMachine[machine.id]?.first?.previewText == "$ echo hi\nhi")
    }

    @Test func appModelRefreshesSelectedTabSnapshot() async throws {
        let machine = Machine(
            id: "mac",
            name: "Mac",
            relayURL: URL(string: "https://nudgecode.dev")!,
            connectionState: .online,
            lastSeenText: "relay session attached",
            binding: MachineBinding(
                bindingID: "bind_1",
                daemonDeviceID: "daemon_1",
                phoneDeviceID: "phone_1",
                status: .active,
                expiresAt: "2026-05-29T00:00:00Z"
            )
        )
        let tab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
            previewText: "$ "
        )
        let client = RecordingRelayClient(snapshots: ["default": TerminalSnapshot(
            tabID: "default",
            profile: TerminalProfile(rows: 24, cols: 80),
            text: "$ date"
        )])
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: [tab]],
            selectedMachineID: machine.id,
            selectedTabID: tab.id,
            relayClient: client
        )

        await model.refreshSelectedTabSnapshot()

        #expect(client.snapshotRequests == [TerminalSnapshotRequest(machine: machine, tabID: tab.id)])
        #expect(model.tabsByMachine[machine.id]?.first?.profile == TerminalProfile(rows: 24, cols: 80))
        #expect(model.tabsByMachine[machine.id]?.first?.previewText == "$ date")
    }

    @Test func appModelSyncsSelectedMachineThroughOpenRelaySession() async throws {
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
            title: "Claude",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: AgentStatus(kind: .claude, state: .needsApproval, confidence: 0.82, source: "screen"),
            previewText: "Relay session attached\nWaiting for terminal snapshot..."
        )
        let session = RecordingRelaySession(events: [
            .sessionState(RemoteSessionState(tabs: [remoteTab])),
            .terminalSnapshot(TerminalSnapshot(
                tabID: "default",
                profile: TerminalProfile(rows: 24, cols: 80),
                text: "Claude asks for approval"
            ))
        ])
        let client = RecordingRelayClient(session: session)
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: []],
            selectedMachineID: machine.id,
            relayClient: client
        )

        await model.syncSelectedMachineSession()

        #expect(client.openSessionRequests == [machine])
        #expect(session.sessionStateRequestCount == 1)
        #expect(session.snapshotRequests == ["default"])
        #expect(session.closed)
        #expect(model.machines.first?.connectionState == .offline)
        #expect(model.machines.first?.lastSeenText == "relay session disconnected")
        #expect(model.selectedTabID == "default")
        #expect(model.tabsByMachine[machine.id]?.first?.previewText == "Claude asks for approval")
        #expect(model.tabsByMachine[machine.id]?.first?.profile == TerminalProfile(rows: 24, cols: 80))
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

private struct TerminalInputRequest: Equatable {
    var machine: Machine
    var tabID: String
    var text: String
    var enter: Bool
}

private struct TerminalSnapshotRequest: Equatable {
    var machine: Machine
    var tabID: String
}

private final class RecordingRelayClient: RelayClient, @unchecked Sendable {
    var claims: [RelayClaim] = []
    var statusRequests: [BindingStatusRequest] = []
    var sessionRequests: [Machine] = []
    var openSessionRequests: [Machine] = []
    var inputRequests: [TerminalInputRequest] = []
    var snapshotRequests: [TerminalSnapshotRequest] = []
    var statusClaim: BindingClaim
    var sessionState: RemoteSessionState
    var snapshots: [String: TerminalSnapshot]
    var session: RecordingRelaySession
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
        snapshots: [String: TerminalSnapshot] = [:],
        session: RecordingRelaySession = RecordingRelaySession(),
        error: Error? = nil
    ) {
        self.statusClaim = statusClaim
        self.sessionState = sessionState
        self.snapshots = snapshots
        self.session = session
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

    func fetchTerminalSnapshot(machine: Machine, tabID: String) async throws -> TerminalSnapshot {
        if let error {
            throw error
        }
        snapshotRequests.append(TerminalSnapshotRequest(machine: machine, tabID: tabID))
        return snapshots[tabID] ?? TerminalSnapshot(
            tabID: tabID,
            profile: TerminalProfile(rows: 32, cols: 48),
            text: "snapshot unavailable"
        )
    }

    func sendTerminalInput(machine: Machine, tabID: String, text: String, enter: Bool) async throws {
        if let error {
            throw error
        }
        inputRequests.append(TerminalInputRequest(machine: machine, tabID: tabID, text: text, enter: enter))
    }

    func openSession(machine: Machine) async throws -> any RelaySession {
        if let error {
            throw error
        }
        openSessionRequests.append(machine)
        return session
    }

    func connect(machine: Machine) async throws {
        _ = machine
    }
}

private final class RecordingRelaySession: RelaySession, @unchecked Sendable {
    var events: [RelaySessionEvent]
    var sessionStateRequestCount = 0
    var snapshotRequests: [String] = []
    var inputRequests: [TerminalInputRequest] = []
    var closed = false

    init(events: [RelaySessionEvent] = []) {
        self.events = events
    }

    func requestSessionState() async throws {
        sessionStateRequestCount += 1
    }

    func requestTerminalSnapshot(tabID: String) async throws {
        snapshotRequests.append(tabID)
    }

    func sendTerminalInput(tabID: String, text: String, enter: Bool) async throws {
        inputRequests.append(TerminalInputRequest(
            machine: Machine(
                id: "session",
                name: "session",
                relayURL: URL(string: "https://nudgecode.dev")!,
                connectionState: .online,
                lastSeenText: "",
                binding: nil
            ),
            tabID: tabID,
            text: text,
            enter: enter
        ))
    }

    func receiveEvent() async throws -> RelaySessionEvent {
        if events.isEmpty {
            throw RelayClientError.invalidWebSocketMessage
        }
        return events.removeFirst()
    }

    func close() {
        closed = true
    }
}
