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
            daemonPublicKey: "daemon-public-key",
            phonePublicKey: "phone-public-key",
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
            daemonPublicKey: "daemon-public-key",
            phonePublicKey: "phone-public-key",
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
        #expect(model.machines.first?.binding?.daemonPublicKey == "daemon-public-key")
        #expect(model.machines.first?.binding?.phonePublicKey == "phone-public-key")
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
        ], suspendWhenEmpty: true)
        let client = RecordingRelayClient(session: session)
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: []],
            selectedMachineID: machine.id,
            relayClient: client
        )
        let syncTask = Task {
            await model.syncSelectedMachineSession()
        }
        defer {
            syncTask.cancel()
        }

        try await waitUntil {
            model.tabsByMachine[machine.id]?.first?.previewText == "Claude asks for approval"
        }
        syncTask.cancel()
        await syncTask.value

        #expect(client.openSessionRequests == [machine])
        #expect(session.sessionStateRequestCount == 1)
        #expect(session.phoneProfiles == [TerminalProfile(rows: 32, cols: 48)])
        #expect(session.outputRequests == [TerminalOutputRequest(tabID: "default", maxBytes: 32 * 1024)])
        #expect(session.closed)
        #expect(model.machines.first?.connectionState == .online)
        #expect(model.machines.first?.lastSeenText == "relay session synced")
        #expect(model.selectedTabID == "default")
        #expect(model.tabsByMachine[machine.id]?.first?.previewText == "Claude asks for approval")
        #expect(model.tabsByMachine[machine.id]?.first?.profile == TerminalProfile(rows: 24, cols: 80))
    }

    @Test func appModelAppliesLiveTerminalOutputWithoutSnapshotRequest() async throws {
        let machine = activeMachine()
        let remoteTab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
            previewText: "Relay session attached\nWaiting for terminal snapshot..."
        )
        let session = RecordingRelaySession(events: [
            .sessionState(RemoteSessionState(tabs: [remoteTab])),
            .terminalSnapshot(TerminalSnapshot(
                tabID: "default",
                profile: TerminalProfile(rows: 32, cols: 48),
                text: "$ "
            )),
            .terminalOutput(TerminalOutput(tabID: "default", text: "echo hi\r\nhi\r\n"))
        ], suspendWhenEmpty: true)
        let client = RecordingRelayClient(session: session)
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: []],
            selectedMachineID: machine.id,
            relayClient: client
        )
        let syncTask = Task {
            await model.syncSelectedMachineSession()
        }
        defer {
            syncTask.cancel()
        }

        try await waitUntil {
            model.tabsByMachine[machine.id]?.first?.outputSequence == 1
        }
        syncTask.cancel()
        await syncTask.value

        #expect(session.outputRequests == [TerminalOutputRequest(tabID: "default", maxBytes: 32 * 1024)])
        #expect(model.tabsByMachine[machine.id]?.first?.previewText == "$ ")
        #expect(model.tabsByMachine[machine.id]?.first?.pendingOutputText == "echo hi\r\nhi\r\n")
        #expect(model.tabsByMachine[machine.id]?.first?.outputSequence == 1)
    }

    @Test func appModelAppliesLiveAgentStatusWithoutSnapshotRequest() async throws {
        let machine = activeMachine()
        let remoteTab = TerminalTab(
            id: "default",
            title: "Claude",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: AgentStatus(kind: .claude, state: .running, confidence: 0.9, source: "process"),
            previewText: "Relay session attached\nWaiting for terminal snapshot..."
        )
        let session = RecordingRelaySession(events: [
            .sessionState(RemoteSessionState(tabs: [remoteTab])),
            .agentStatus(AgentStatusUpdate(
                tabID: "default",
                status: AgentStatus(kind: .claude, state: .needsApproval, confidence: 0.84, source: "screen")
            ))
        ], suspendWhenEmpty: true)
        let client = RecordingRelayClient(session: session)
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: []],
            selectedMachineID: machine.id,
            relayClient: client
        )
        let syncTask = Task {
            await model.syncSelectedMachineSession()
        }
        defer {
            syncTask.cancel()
        }

        try await waitUntil {
            model.tabsByMachine[machine.id]?.first?.agentStatus.state == .needsApproval
        }
        syncTask.cancel()
        await syncTask.value

        #expect(model.tabsByMachine[machine.id]?.first?.agentStatus == AgentStatus(
            kind: .claude,
            state: .needsApproval,
            confidence: 0.84,
            source: "screen"
        ))
        #expect(session.snapshotRequests.isEmpty)
    }

    @Test func appModelMarksRelaySessionReconnectingAfterDrop() async throws {
        let machine = activeMachine()
        let session = RecordingRelaySession()
        let client = RecordingRelayClient(session: session)
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: []],
            selectedMachineID: machine.id,
            relayClient: client,
            sessionReconnectDelayNanoseconds: 60_000_000_000
        )
        let syncTask = Task {
            await model.syncSelectedMachineSession()
        }
        defer {
            syncTask.cancel()
        }

        try await waitUntil {
            model.machines.first?.lastSeenText == "relay session reconnecting"
        }

        #expect(client.openSessionRequests == [machine])
        #expect(session.closed)
        #expect(model.machines.first?.connectionState == .connecting)
        #expect(model.machines.first?.lastSeenText == "relay session reconnecting")

        syncTask.cancel()
        await syncTask.value
    }

    @Test func appModelReconnectsRelaySessionAfterDrop() async throws {
        let machine = activeMachine()
        let firstTab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
            previewText: "Relay session attached\nWaiting for terminal snapshot..."
        )
        let secondTab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: AgentStatus(kind: .codex, state: .waitingForInput, confidence: 0.81, source: "screen"),
            previewText: "Relay session attached\nWaiting for terminal snapshot..."
        )
        let firstSession = RecordingRelaySession(events: [
            .sessionState(RemoteSessionState(tabs: [firstTab]))
        ])
        let secondSession = RecordingRelaySession(events: [
            .sessionState(RemoteSessionState(tabs: [secondTab])),
            .terminalOutput(TerminalOutput(tabID: "default", text: "Codex reconnected"))
        ], suspendWhenEmpty: true)
        let client = RecordingRelayClient(sessions: [firstSession, secondSession])
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: []],
            selectedMachineID: machine.id,
            relayClient: client,
            sessionReconnectDelayNanoseconds: 1_000_000
        )
        let syncTask = Task {
            await model.syncSelectedMachineSession()
        }
        defer {
            syncTask.cancel()
        }

        try await waitUntil {
            client.openSessionRequests.count == 2 &&
                model.tabsByMachine[machine.id]?.first?.pendingOutputText == "Codex reconnected"
        }

        #expect(client.openSessionRequests.map(\.id) == [machine.id, machine.id])
        #expect(client.openSessionRequests.map(\.binding) == [machine.binding, machine.binding])
        #expect(firstSession.closed)
        #expect(secondSession.sessionStateRequestCount == 1)
        #expect(secondSession.phoneProfiles == [TerminalProfile(rows: 32, cols: 48)])
        #expect(firstSession.outputRequests == [TerminalOutputRequest(tabID: "default", maxBytes: 32 * 1024)])
        #expect(secondSession.outputRequests == [TerminalOutputRequest(tabID: "default", maxBytes: 32 * 1024)])
        #expect(model.machines.first?.connectionState == .online)
        #expect(model.machines.first?.lastSeenText == "relay session synced")
        #expect(model.tabsByMachine[machine.id]?.first?.agentStatus.kind == .codex)
        #expect(model.tabsByMachine[machine.id]?.first?.pendingOutputText == "Codex reconnected")

        syncTask.cancel()
        await syncTask.value
        #expect(secondSession.closed)
    }

    @Test func appModelMarksBindingRevokedAndStopsReconnectAfterRelayRevocation() async throws {
        let machine = activeMachine()
        let session = RecordingRelaySession(errorWhenReceiving: RelayClientError.bindingRevoked)
        let client = RecordingRelayClient(session: session)
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: []],
            selectedMachineID: machine.id,
            relayClient: client,
            sessionReconnectDelayNanoseconds: 1_000_000
        )

        await model.syncSelectedMachineSession()

        #expect(client.openSessionRequests == [machine])
        #expect(session.closed)
        #expect(model.machines.first?.binding?.status == .revoked)
        #expect(model.machines.first?.connectionState == .offline)
        #expect(model.machines.first?.lastSeenText == "binding revoked")
    }

    @Test func appModelUpdatesWidthThroughOpenRelaySession() async throws {
        let machine = activeMachine()
        let tab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .computer,
            profile: TerminalProfile(rows: 24, cols: 100),
            agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
            previewText: "$ "
        )
        let session = RecordingRelaySession(suspendWhenEmpty: true)
        let client = RecordingRelayClient(session: session)
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: [tab]],
            selectedMachineID: machine.id,
            selectedTabID: tab.id,
            relayClient: client
        )
        let syncTask = Task {
            await model.syncSelectedMachineSession()
        }
        defer {
            syncTask.cancel()
        }

        for _ in 0..<100 {
            if client.openSessionRequests == [machine],
               session.sessionStateRequestCount == 1,
               session.phoneProfiles == [TerminalProfile(rows: 32, cols: 48)] {
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard client.openSessionRequests == [machine],
              session.sessionStateRequestCount == 1,
              session.phoneProfiles == [TerminalProfile(rows: 32, cols: 48)]
        else {
            Issue.record("Expected relay session to be open before width update")
            return
        }

        await model.updateSelectedTabWidth(.phone)

        #expect(client.openSessionRequests == [machine])
        #expect(session.widthModeRequests == [WidthModeRequest(
            tabID: tab.id,
            widthMode: .phone,
            computerProfile: TerminalProfile(rows: 24, cols: 100)
        )])
        #expect(model.tabsByMachine[machine.id]?.first?.widthMode == .phone)

        syncTask.cancel()
        await syncTask.value
    }

    @Test func appModelUpdatesWidthThroughOneShotRelayWhenSessionIsClosed() async throws {
        let machine = activeMachine()
        let tab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .computer,
            profile: TerminalProfile(rows: 24, cols: 100),
            agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
            previewText: "$ "
        )
        let returnedTab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: tab.agentStatus,
            previewText: "Relay session attached\nWaiting for terminal snapshot..."
        )
        let client = RecordingRelayClient(widthModeState: RemoteSessionState(tabs: [returnedTab]))
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: [tab]],
            selectedMachineID: machine.id,
            selectedTabID: tab.id,
            relayClient: client
        )

        await model.updateSelectedTabWidth(.phone)

        #expect(client.widthModeRequests == [WidthModeClientRequest(
            machine: machine,
            tabID: tab.id,
            widthMode: .phone,
            computerProfile: TerminalProfile(rows: 24, cols: 100)
        )])
        #expect(model.tabsByMachine[machine.id]?.first?.widthMode == .phone)
        #expect(model.tabsByMachine[machine.id]?.first?.profile == TerminalProfile(rows: 32, cols: 48))
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

private struct TerminalOutputRequest: Equatable {
    var tabID: String
    var maxBytes: Int
}

private struct PhoneProfileClientRequest: Equatable {
    var machine: Machine
    var profile: TerminalProfile
}

private struct WidthModeClientRequest: Equatable {
    var machine: Machine
    var tabID: String
    var widthMode: WidthMode
    var computerProfile: TerminalProfile
}

private struct WidthModeRequest: Equatable {
    var tabID: String
    var widthMode: WidthMode
    var computerProfile: TerminalProfile
}

private func activeMachine() -> Machine {
    Machine(
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
}

@MainActor
private func waitUntil(
    timeoutIterations: Int = 200,
    condition: () -> Bool
) async throws {
    for _ in 0..<timeoutIterations {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("Timed out waiting for condition")
}

private final class RecordingRelayClient: RelayClient, @unchecked Sendable {
    var claims: [RelayClaim] = []
    var statusRequests: [BindingStatusRequest] = []
    var sessionRequests: [Machine] = []
    var openSessionRequests: [Machine] = []
    var inputRequests: [TerminalInputRequest] = []
    var snapshotRequests: [TerminalSnapshotRequest] = []
    var phoneProfileRequests: [PhoneProfileClientRequest] = []
    var widthModeRequests: [WidthModeClientRequest] = []
    var statusClaim: BindingClaim
    var sessionState: RemoteSessionState
    var snapshots: [String: TerminalSnapshot]
    var phoneProfileState: RemoteSessionState
    var widthModeState: RemoteSessionState
    var sessions: [RecordingRelaySession]
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
        phoneProfileState: RemoteSessionState = RemoteSessionState(tabs: []),
        widthModeState: RemoteSessionState = RemoteSessionState(tabs: []),
        session: RecordingRelaySession = RecordingRelaySession(),
        sessions: [RecordingRelaySession]? = nil,
        error: Error? = nil
    ) {
        self.statusClaim = statusClaim
        self.sessionState = sessionState
        self.snapshots = snapshots
        self.phoneProfileState = phoneProfileState
        self.widthModeState = widthModeState
        self.sessions = sessions ?? [session]
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
            daemonPublicKey: "daemon-public-key",
            phonePublicKey: "phone-public-key",
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

    func setPhoneProfile(machine: Machine, profile: TerminalProfile) async throws -> RemoteSessionState {
        if let error {
            throw error
        }
        phoneProfileRequests.append(PhoneProfileClientRequest(machine: machine, profile: profile))
        return phoneProfileState
    }

    func setWidthMode(
        machine: Machine,
        tabID: String,
        widthMode: WidthMode,
        computerProfile: TerminalProfile
    ) async throws -> RemoteSessionState {
        if let error {
            throw error
        }
        widthModeRequests.append(WidthModeClientRequest(
            machine: machine,
            tabID: tabID,
            widthMode: widthMode,
            computerProfile: computerProfile
        ))
        return widthModeState
    }

    func openSession(machine: Machine) async throws -> any RelaySession {
        if let error {
            throw error
        }
        openSessionRequests.append(machine)
        guard !sessions.isEmpty else {
            throw RelayClientError.invalidWebSocketMessage
        }
        return sessions.removeFirst()
    }

    func connect(machine: Machine) async throws {
        _ = machine
    }
}

private final class RecordingRelaySession: RelaySession, @unchecked Sendable {
    var events: [RelaySessionEvent]
    var sessionStateRequestCount = 0
    var snapshotRequests: [String] = []
    var outputRequests: [TerminalOutputRequest] = []
    var inputRequests: [TerminalInputRequest] = []
    var phoneProfiles: [TerminalProfile] = []
    var widthModeRequests: [WidthModeRequest] = []
    var closed = false

    var suspendWhenEmpty: Bool
    var errorWhenReceiving: Error?

    init(events: [RelaySessionEvent] = [], suspendWhenEmpty: Bool = false, errorWhenReceiving: Error? = nil) {
        self.events = events
        self.suspendWhenEmpty = suspendWhenEmpty
        self.errorWhenReceiving = errorWhenReceiving
    }

    func requestSessionState() async throws {
        sessionStateRequestCount += 1
    }

    func requestTerminalSnapshot(tabID: String) async throws {
        snapshotRequests.append(tabID)
    }

    func requestTerminalOutput(tabID: String, maxBytes: Int) async throws {
        outputRequests.append(TerminalOutputRequest(tabID: tabID, maxBytes: maxBytes))
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

    func setPhoneProfile(_ profile: TerminalProfile) async throws {
        phoneProfiles.append(profile)
    }

    func setWidthMode(tabID: String, widthMode: WidthMode, computerProfile: TerminalProfile) async throws {
        widthModeRequests.append(WidthModeRequest(
            tabID: tabID,
            widthMode: widthMode,
            computerProfile: computerProfile
        ))
    }

    func receiveEvent() async throws -> RelaySessionEvent {
        if let errorWhenReceiving {
            throw errorWhenReceiving
        }
        if events.isEmpty {
            if suspendWhenEmpty {
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            throw RelayClientError.invalidWebSocketMessage
        }
        return events.removeFirst()
    }

    func close() {
        closed = true
    }
}
