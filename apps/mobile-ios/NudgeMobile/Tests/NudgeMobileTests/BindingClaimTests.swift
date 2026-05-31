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

    @Test func appModelPersistsClaimedComputerProfileAndRestoresItForReconnect() async throws {
        let client = RecordingRelayClient()
        let persistence = RecordingAppModelPersistence()
        let model = AppModel(
            relayClient: client,
            persistence: persistence
        )

        #expect(model.parsePairingURL("https://nudgecode.dev/pair?code=abc123"))
        await model.claimDraftBinding()

        let saved = try #require(persistence.savedStates.last)
        #expect(saved.selectedMachineID == "machine-abc123")
        #expect(saved.phoneProfile == TerminalProfile(rows: 32, cols: 48))
        #expect(saved.machines.count == 1)
        #expect(saved.machines.first?.binding?.status == .claimed)

        let restored = AppModel.restoring(
            from: RecordingAppModelPersistence(storedState: saved),
            relayClient: client
        )

        #expect(restored.selectedMachineID == "machine-abc123")
        #expect(restored.phoneProfile == TerminalProfile(rows: 32, cols: 48))
        #expect(restored.machines.first?.binding?.status == .claimed)
        #expect(restored.machines.first?.connectionState == .connecting)
        #expect(restored.machines.first?.lastSeenText == "Waiting for computer confirmation")
        #expect(restored.tabsByMachine.isEmpty)
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

    @Test func appModelOpensPairingDeepLinkIntoBindingFlow() throws {
        let machine = activeMachine()
        let model = AppModel(
            machines: [machine],
            selectedMachineID: machine.id
        )
        let url = try #require(URL(string: "nudge://pair?relay=https%3A%2F%2Fnudgecode.dev&code=abc123"))

        #expect(model.openPairingURL(url))

        #expect(model.selectedMachineID == nil)
        #expect(model.bindingDraft == BindingDraft(
            code: "abc123",
            relayURL: URL(string: "https://nudgecode.dev")!
        ))
        #expect(model.bindingClaimState == .idle)
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

    @Test func appModelPersistsActiveBindingAfterRefresh() async throws {
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
        let persistence = RecordingAppModelPersistence()
        let model = AppModel(
            machines: [machine],
            selectedMachineID: machine.id,
            relayClient: client,
            persistence: persistence
        )

        await model.refreshSelectedMachineBinding()

        let saved = try #require(persistence.savedStates.last)
        #expect(saved.machines.first?.binding?.status == .active)
        #expect(saved.machines.first?.binding?.daemonPublicKey == "daemon-public-key")
        #expect(saved.machines.first?.binding?.phonePublicKey == "phone-public-key")

        let restored = AppModel.restoring(
            from: RecordingAppModelPersistence(storedState: saved),
            relayClient: client
        )
        #expect(restored.machines.first?.binding?.status == .active)
        #expect(restored.machines.first?.connectionState == .connecting)
        #expect(restored.machines.first?.lastSeenText == "binding active")
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

    @Test func appModelRotatesSelectedMachinePhoneKeyAndPersistsBinding() async throws {
        let machine = activeMachine()
        let client = RecordingRelayClient(rotatedPhoneIdentity: PhoneIdentity(publicKey: "phone-new-public-key"))
        let persistence = RecordingAppModelPersistence()
        let model = AppModel(
            machines: [machine],
            selectedMachineID: machine.id,
            relayClient: client,
            persistence: persistence
        )

        await model.rotateSelectedMachinePhoneKey()

        #expect(client.phoneKeyRotationRequests == [machine])
        #expect(model.machines.first?.binding?.phonePublicKey == "phone-new-public-key")
        #expect(model.machines.first?.lastSeenText == "phone key rotated")
        let saved = try #require(persistence.savedStates.last)
        #expect(saved.machines.first?.binding?.phonePublicKey == "phone-new-public-key")
    }

    @Test func appModelLeavesPhoneKeyUnchangedWhenRotationFails() async throws {
        let machine = activeMachine()
        let client = RecordingRelayClient(error: RelayClientError.badStatus)
        let model = AppModel(
            machines: [machine],
            selectedMachineID: machine.id,
            relayClient: client
        )

        await model.rotateSelectedMachinePhoneKey()

        #expect(client.phoneKeyRotationRequests.isEmpty)
        #expect(model.machines.first?.binding?.phonePublicKey == machine.binding?.phonePublicKey)
        #expect(model.machines.first?.lastSeenText == "Unable to rotate phone key")
    }

    @Test func appModelRevokesSelectedMachineBindingAndPersistsState() async throws {
        let machine = activeMachine()
        let client = RecordingRelayClient(revokedClaim: BindingClaim(
            bindingID: "bind_1",
            daemonDeviceID: "daemon_1",
            phoneDeviceID: "phone_1",
            daemonPublicKey: "daemon-public-key",
            phonePublicKey: "phone-public-key",
            status: .revoked,
            expiresAt: "2026-05-29T00:00:00Z"
        ))
        let persistence = RecordingAppModelPersistence()
        let model = AppModel(
            machines: [machine],
            selectedMachineID: machine.id,
            relayClient: client,
            persistence: persistence
        )

        await model.revokeSelectedMachineBinding()

        #expect(client.revokeRequests == [machine])
        #expect(model.machines.first?.binding?.status == .revoked)
        #expect(model.machines.first?.connectionState == .offline)
        #expect(model.machines.first?.lastSeenText == "binding revoked")
        let saved = try #require(persistence.savedStates.last)
        #expect(saved.machines.first?.binding?.status == .revoked)
    }

    @Test func appModelKeepsBindingWhenRevokeFails() async throws {
        let machine = activeMachine()
        let client = RecordingRelayClient(error: RelayClientError.badStatus)
        let model = AppModel(
            machines: [machine],
            selectedMachineID: machine.id,
            relayClient: client
        )

        await model.revokeSelectedMachineBinding()

        #expect(client.revokeRequests.isEmpty)
        #expect(model.machines.first?.binding == machine.binding)
        #expect(model.machines.first?.lastSeenText == "Unable to revoke binding")
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
        #expect(model.tabsByMachine[machine.id]?.first?.pendingOutputBase64 == Data("echo hi\r\nhi\r\n".utf8).base64EncodedString())
        #expect(model.tabsByMachine[machine.id]?.first?.replayOutputBase64 == Data("echo hi\r\nhi\r\n".utf8).base64EncodedString())
        #expect(model.tabsByMachine[machine.id]?.first?.outputSequence == 1)
    }

    @Test func appModelAppliesTerminalOutputReplayWithoutLiveIncrement() async throws {
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
        let replayBase64 = Data("older output\r\n".utf8).base64EncodedString()
        let session = RecordingRelaySession(events: [
            .sessionState(RemoteSessionState(tabs: [remoteTab])),
            .terminalOutput(TerminalOutput(tabID: "default", bytesBase64: replayBase64, isReplay: true))
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
            model.tabsByMachine[machine.id]?.first?.replayOutputSequence == 1
        }
        syncTask.cancel()
        await syncTask.value

        #expect(session.outputRequests == [TerminalOutputRequest(tabID: "default", maxBytes: 32 * 1024)])
        #expect(model.tabsByMachine[machine.id]?.first?.replayOutputBase64 == replayBase64)
        #expect(model.tabsByMachine[machine.id]?.first?.pendingOutputBase64 == "")
        #expect(model.tabsByMachine[machine.id]?.first?.replayOutputSequence == 1)
        #expect(model.tabsByMachine[machine.id]?.first?.outputSequence == 0)
        // L3: the replayed tail is the whole visible state, so the leftover
        // "Waiting for terminal snapshot..." placeholder must be cleared.
        #expect(model.tabsByMachine[machine.id]?.first?.previewText == "")
    }

    @Test func appModelAppliesOffsetOrderedDeltasInOrder() async throws {
        let machine = activeMachine()
        let remoteTab = offsetStreamTab()
        let session = RecordingRelaySession(events: [
            .sessionState(RemoteSessionState(tabs: [remoteTab])),
            .terminalSnapshot(TerminalSnapshot(
                tabID: "default",
                profile: TerminalProfile(rows: 32, cols: 48),
                text: "",
                offset: 0
            )),
            .terminalOutput(TerminalOutput(tabID: "default", text: "ab", offset: 0)),
            .terminalOutput(TerminalOutput(tabID: "default", text: "cd", offset: 2))
        ], suspendWhenEmpty: true)
        let model = offsetStreamModel(machine: machine, session: session)
        let syncTask = Task { await model.syncSelectedMachineSession() }
        defer { syncTask.cancel() }

        try await waitUntil {
            model.tabsByMachine[machine.id]?.first?.outputSequence == 2
        }
        syncTask.cancel()
        await syncTask.value

        // Contiguous deltas (offset 0 then 2) both apply; no gap, no resync.
        #expect(session.snapshotRequests.isEmpty)
        #expect(model.tabsByMachine[machine.id]?.first?.replayOutputBase64 == Data("abcd".utf8).base64EncodedString())
        #expect(model.tabsByMachine[machine.id]?.first?.outputSequence == 2)
    }

    @Test func appModelRequestsSnapshotOnDeltaGap() async throws {
        let machine = activeMachine()
        let remoteTab = offsetStreamTab()
        let session = RecordingRelaySession(events: [
            .sessionState(RemoteSessionState(tabs: [remoteTab])),
            .terminalSnapshot(TerminalSnapshot(
                tabID: "default",
                profile: TerminalProfile(rows: 32, cols: 48),
                text: "",
                offset: 0
            )),
            .terminalOutput(TerminalOutput(tabID: "default", text: "ab", offset: 0)),
            // Gap: offset 10 != expected 2 (bytes lost) -> request a snapshot, drop this delta.
            .terminalOutput(TerminalOutput(tabID: "default", text: "XX", offset: 10))
        ], suspendWhenEmpty: true)
        let model = offsetStreamModel(machine: machine, session: session)
        let syncTask = Task { await model.syncSelectedMachineSession() }
        defer { syncTask.cancel() }

        try await waitUntil {
            session.snapshotRequests.contains("default")
        }
        syncTask.cancel()
        await syncTask.value

        // The contiguous delta applied; the gapped one did not.
        #expect(model.tabsByMachine[machine.id]?.first?.replayOutputBase64 == Data("ab".utf8).base64EncodedString())
        #expect(model.tabsByMachine[machine.id]?.first?.outputSequence == 1)
        #expect(session.snapshotRequests == ["default"])
    }

    @Test func appModelTrimsOverlappingDelta() async throws {
        let machine = activeMachine()
        let remoteTab = offsetStreamTab()
        let session = RecordingRelaySession(events: [
            .sessionState(RemoteSessionState(tabs: [remoteTab])),
            .terminalSnapshot(TerminalSnapshot(
                tabID: "default",
                profile: TerminalProfile(rows: 32, cols: 48),
                text: "",
                offset: 0
            )),
            .terminalOutput(TerminalOutput(tabID: "default", text: "abcd", offset: 0)),
            // Overlap: offset 2 < expected 4, so the first 2 bytes ("cd") are
            // already applied -> trim them and apply only the new tail ("ef").
            .terminalOutput(TerminalOutput(tabID: "default", text: "cdef", offset: 2))
        ], suspendWhenEmpty: true)
        let model = offsetStreamModel(machine: machine, session: session)
        let syncTask = Task { await model.syncSelectedMachineSession() }
        defer { syncTask.cancel() }

        try await waitUntil {
            model.tabsByMachine[machine.id]?.first?.outputSequence == 2
        }
        syncTask.cancel()
        await syncTask.value

        #expect(session.snapshotRequests.isEmpty)
        #expect(model.tabsByMachine[machine.id]?.first?.replayOutputBase64 == Data("abcdef".utf8).base64EncodedString())
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
                model.tabsByMachine[machine.id]?.first?.pendingOutputBase64 == Data("Codex reconnected".utf8).base64EncodedString()
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
        #expect(model.tabsByMachine[machine.id]?.first?.pendingOutputBase64 == Data("Codex reconnected".utf8).base64EncodedString())

        syncTask.cancel()
        await syncTask.value
        #expect(secondSession.closed)
    }

    @Test func appModelMarksBindingRevokedAndStopsReconnectAfterRelayRevocation() async throws {
        let machine = activeMachine()
        let session = RecordingRelaySession(errorWhenReceiving: RelayClientError.bindingRevoked)
        let client = RecordingRelayClient(session: session)
        let persistence = RecordingAppModelPersistence()
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: []],
            selectedMachineID: machine.id,
            relayClient: client,
            persistence: persistence,
            sessionReconnectDelayNanoseconds: 1_000_000
        )

        await model.syncSelectedMachineSession()

        #expect(client.openSessionRequests == [machine])
        #expect(session.closed)
        #expect(model.machines.first?.binding?.status == .revoked)
        #expect(model.machines.first?.connectionState == .offline)
        #expect(model.machines.first?.lastSeenText == "binding revoked")
        #expect(persistence.savedStates.last?.machines.first?.binding?.status == .revoked)
    }

    @Test func appModelSuspendsRelaySessionWhenAppBackgrounds() async throws {
        let machine = activeMachine()
        let session = RecordingRelaySession(suspendWhenEmpty: true)
        let client = RecordingRelayClient(session: session)
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
            client.openSessionRequests == [machine] &&
                session.sessionStateRequestCount == 1
        }

        model.suspendRelaySessionForBackground()
        await syncTask.value

        #expect(session.closed)
        #expect(client.openSessionRequests == [machine])
        #expect(model.machines.first?.connectionState == .connecting)
        #expect(model.machines.first?.lastSeenText == "relay session paused")
    }

    @Test func appModelResumesRelaySessionWhenAppReturnsForeground() async throws {
        let machine = activeMachine()
        let firstSession = RecordingRelaySession(suspendWhenEmpty: true)
        let secondTab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
            previewText: "Relay session attached\nWaiting for terminal snapshot..."
        )
        let secondSession = RecordingRelaySession(events: [
            .sessionState(RemoteSessionState(tabs: [secondTab]))
        ], suspendWhenEmpty: true)
        let client = RecordingRelayClient(sessions: [firstSession, secondSession])
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: []],
            selectedMachineID: machine.id,
            relayClient: client,
            sessionReconnectDelayNanoseconds: 1_000_000
        )
        let firstTaskID = model.relaySyncTaskID
        let firstSyncTask = Task {
            await model.syncSelectedMachineSession()
        }
        defer {
            firstSyncTask.cancel()
        }

        try await waitUntil {
            client.openSessionRequests == [machine] &&
                firstSession.sessionStateRequestCount == 1
        }
        model.suspendRelaySessionForBackground()
        await firstSyncTask.value

        model.resumeRelaySessionFromForeground()
        let resumedTaskID = model.relaySyncTaskID

        #expect(resumedTaskID.machineID == firstTaskID.machineID)
        #expect(resumedTaskID.generation == firstTaskID.generation + 1)
        #expect(model.machines.first?.lastSeenText == "relay session reconnecting")

        let secondSyncTask = Task {
            await model.syncSelectedMachineSession()
        }
        defer {
            secondSyncTask.cancel()
        }

        try await waitUntil {
            client.openSessionRequests.count == 2 &&
                model.machines.first?.lastSeenText == "relay session synced"
        }

        secondSyncTask.cancel()
        await secondSyncTask.value

        #expect(client.openSessionRequests.map(\.id) == [machine.id, machine.id])
        #expect(firstSession.closed)
        #expect(secondSession.closed)
        #expect(secondSession.sessionStateRequestCount == 1)
        #expect(secondSession.outputRequests == [TerminalOutputRequest(tabID: "default", maxBytes: 32 * 1024)])
        #expect(model.tabsByMachine[machine.id]?.first?.id == "default")
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

    @Test func appModelCreatesRenamesRestartsAndClosesTabsThroughOneShotRelay() async throws {
        let machine = activeMachine()
        let defaultTab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
            previewText: "$ "
        )
        let secondTab = TerminalTab(
            id: "tab-2",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: defaultTab.agentStatus,
            previewText: "$ "
        )
        let renamedSecondTab = TerminalTab(
            id: "tab-2",
            title: "Claude",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: defaultTab.agentStatus,
            previewText: "$ "
        )
        let client = RecordingRelayClient(tabActionStates: [
            RemoteSessionState(tabs: [defaultTab, secondTab]),
            RemoteSessionState(tabs: [
                defaultTab,
                renamedSecondTab
            ]),
            RemoteSessionState(tabs: [
                defaultTab,
                renamedSecondTab
            ]),
            RemoteSessionState(tabs: [defaultTab])
        ])
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: [defaultTab]],
            selectedMachineID: machine.id,
            selectedTabID: defaultTab.id,
            relayClient: client
        )

        await model.createRemoteTab()
        model.selectTab(secondTab)
        await model.renameSelectedTab(to: "Claude")
        await model.restartSelectedTab()
        await model.closeSelectedTab()

        #expect(client.createTabRequests == [CreateTabClientRequest(machine: machine, title: "shell")])
        #expect(client.renameTabRequests == [RenameTabClientRequest(machine: machine, tabID: "tab-2", title: "Claude")])
        #expect(client.restartTabRequests == [RestartTabClientRequest(machine: machine, tabID: "tab-2")])
        #expect(client.closeTabRequests == [CloseTabClientRequest(machine: machine, tabID: "tab-2")])
        #expect(model.tabsByMachine[machine.id]?.map(\.id) == ["default"])
        #expect(model.selectedTabID == "default")
    }

    @Test func appModelUsesOneShotRelayForTabActionsWhenSessionIsClosed() async throws {
        let machine = activeMachine()
        let tab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
            previewText: "$ "
        )
        let returnedTab = TerminalTab(
            id: "default",
            title: "Claude",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: tab.agentStatus,
            previewText: "Relay session attached\nWaiting for terminal snapshot..."
        )
        let client = RecordingRelayClient(tabActionState: RemoteSessionState(tabs: [returnedTab]))
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: [tab]],
            selectedMachineID: machine.id,
            selectedTabID: tab.id,
            relayClient: client
        )

        await model.renameSelectedTab(to: "Claude")

        #expect(client.renameTabRequests == [RenameTabClientRequest(machine: machine, tabID: "default", title: "Claude")])
        #expect(model.tabsByMachine[machine.id]?.first?.title == "Claude")
    }

    @Test func appModelShowsNoticeWhenFreeTabLimitRejectsCreateTab() async throws {
        let machine = activeMachine()
        let tab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
            previewText: "$ "
        )
        let client = RecordingRelayClient(error: RelayClientError.daemonRejected("free entitlement allows 1 tab; close a tab or upgrade to create more"))
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: [tab]],
            selectedMachineID: machine.id,
            selectedTabID: tab.id,
            relayClient: client
        )

        await model.createRemoteTab()

        #expect(client.createTabRequests == [])
        #expect(model.workspaceNoticeText == "Free version is limited to one tab on this computer.")
        #expect(model.machines.first?.lastSeenText == "Unable to create tab")

        model.clearWorkspaceNotice()

        #expect(model.workspaceNoticeText == nil)
    }

    @Test func appModelKeepsActionFallbackNoticeWhenTabErrorIsNotFreeLimit() async throws {
        let machine = activeMachine()
        let tab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 32, cols: 48),
            agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
            previewText: "$ "
        )
        // A non-limit daemon rejection that still contains the word "tab" must not be
        // mislabeled as the free-plan limit notice (regression: rename/close/restart).
        let client = RecordingRelayClient(error: RelayClientError.daemonRejected("tab default was not found"))
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: [tab]],
            selectedMachineID: machine.id,
            selectedTabID: tab.id,
            relayClient: client
        )

        await model.renameSelectedTab(to: "Claude")

        #expect(model.workspaceNoticeText == "Unable to rename tab")
        #expect(model.workspaceNoticeText != "Free version is limited to one tab on this computer.")
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

    @Test func appModelForwardsMeasuredPhoneProfileThroughOpenRelaySession() async throws {
        let machine = activeMachine()
        let session = RecordingRelaySession(suspendWhenEmpty: true)
        let client = RecordingRelayClient(session: session)
        let model = AppModel(
            machines: [machine],
            selectedMachineID: machine.id,
            phoneProfile: TerminalProfile(rows: 32, cols: 48),
            relayClient: client
        )
        let syncTask = Task {
            await model.syncSelectedMachineSession()
        }
        defer {
            syncTask.cancel()
        }

        try await waitUntil {
            session.phoneProfiles == [TerminalProfile(rows: 32, cols: 48)]
        }
        await model.updatePhoneProfile(TerminalProfile(rows: 38, cols: 54))
        await model.updatePhoneProfile(TerminalProfile(rows: 38, cols: 54))

        #expect(session.phoneProfiles == [
            TerminalProfile(rows: 32, cols: 48),
            TerminalProfile(rows: 38, cols: 54)
        ])
        #expect(client.phoneProfileRequests.isEmpty)
        #expect(model.phoneProfile == TerminalProfile(rows: 38, cols: 54))

        syncTask.cancel()
        await syncTask.value
    }

    @Test func appModelSendsMeasuredPhoneProfileThroughOneShotRelayWhenSessionIsClosed() async throws {
        let machine = activeMachine()
        let returnedTab = TerminalTab(
            id: "default",
            title: "shell",
            state: .running,
            widthMode: .phone,
            profile: TerminalProfile(rows: 40, cols: 58),
            agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
            previewText: "Relay session attached\nWaiting for terminal snapshot..."
        )
        let client = RecordingRelayClient(phoneProfileState: RemoteSessionState(tabs: [returnedTab]))
        let model = AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: []],
            selectedMachineID: machine.id,
            phoneProfile: TerminalProfile(rows: 32, cols: 48),
            relayClient: client
        )

        await model.updatePhoneProfile(TerminalProfile(rows: 40, cols: 58))

        #expect(client.phoneProfileRequests == [PhoneProfileClientRequest(
            machine: machine,
            profile: TerminalProfile(rows: 40, cols: 58)
        )])
        #expect(model.phoneProfile == TerminalProfile(rows: 40, cols: 58))
        #expect(model.tabsByMachine[machine.id]?.first?.profile == TerminalProfile(rows: 40, cols: 58))
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

private struct CreateTabClientRequest: Equatable {
    var machine: Machine
    var title: String
    var cwd: String? = nil
    var launch: String? = nil
}

private struct RenameTabClientRequest: Equatable {
    var machine: Machine
    var tabID: String
    var title: String
}

private struct CloseTabClientRequest: Equatable {
    var machine: Machine
    var tabID: String
}

private struct RestartTabClientRequest: Equatable {
    var machine: Machine
    var tabID: String
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
            phonePublicKey: "phone-public-key",
            status: .active,
            expiresAt: "2026-05-29T00:00:00Z"
        )
    )
}

private func offsetStreamTab() -> TerminalTab {
    TerminalTab(
        id: "default",
        title: "shell",
        state: .running,
        widthMode: .phone,
        profile: TerminalProfile(rows: 32, cols: 48),
        agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "screen"),
        previewText: "Relay session attached\nWaiting for terminal snapshot..."
    )
}

@MainActor
private func offsetStreamModel(machine: Machine, session: RecordingRelaySession) -> AppModel {
    AppModel(
        machines: [machine],
        tabsByMachine: [machine.id: []],
        selectedMachineID: machine.id,
        relayClient: RecordingRelayClient(session: session)
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
    var createTabRequests: [CreateTabClientRequest] = []
    var renameTabRequests: [RenameTabClientRequest] = []
    var closeTabRequests: [CloseTabClientRequest] = []
    var restartTabRequests: [RestartTabClientRequest] = []
    var phoneKeyRotationRequests: [Machine] = []
    var revokeRequests: [Machine] = []
    var statusClaim: BindingClaim
    var revokedClaim: BindingClaim
    var rotatedPhoneIdentity: PhoneIdentity
    var sessionState: RemoteSessionState
    var snapshots: [String: TerminalSnapshot]
    var phoneProfileState: RemoteSessionState
    var widthModeState: RemoteSessionState
    var tabActionState: RemoteSessionState
    var tabActionStates: [RemoteSessionState]
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
        revokedClaim: BindingClaim = BindingClaim(
            bindingID: "bind_1",
            daemonDeviceID: "daemon_1",
            phoneDeviceID: "phone_1",
            daemonPublicKey: "daemon-public-key",
            phonePublicKey: "phone-public-key",
            status: .revoked,
            expiresAt: "2026-05-29T00:00:00Z"
        ),
        rotatedPhoneIdentity: PhoneIdentity = PhoneIdentity(publicKey: "rotated-phone-public-key"),
        sessionState: RemoteSessionState = RemoteSessionState(tabs: []),
        snapshots: [String: TerminalSnapshot] = [:],
        phoneProfileState: RemoteSessionState = RemoteSessionState(tabs: []),
        widthModeState: RemoteSessionState = RemoteSessionState(tabs: []),
        tabActionState: RemoteSessionState = RemoteSessionState(tabs: []),
        tabActionStates: [RemoteSessionState]? = nil,
        session: RecordingRelaySession = RecordingRelaySession(),
        sessions: [RecordingRelaySession]? = nil,
        error: Error? = nil
    ) {
        self.statusClaim = statusClaim
        self.revokedClaim = revokedClaim
        self.rotatedPhoneIdentity = rotatedPhoneIdentity
        self.sessionState = sessionState
        self.snapshots = snapshots
        self.phoneProfileState = phoneProfileState
        self.widthModeState = widthModeState
        self.tabActionState = tabActionState
        self.tabActionStates = tabActionStates ?? [tabActionState]
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

    func revokeBinding(machine: Machine) async throws -> BindingClaim {
        if let error {
            throw error
        }
        revokeRequests.append(machine)
        return revokedClaim
    }

    func rotatePhoneKey(machine: Machine) async throws -> PhoneIdentity {
        if let error {
            throw error
        }
        phoneKeyRotationRequests.append(machine)
        return rotatedPhoneIdentity
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

    func createTab(machine: Machine, title: String, cwd: String?, launch: String?) async throws -> RemoteSessionState {
        if let error {
            throw error
        }
        createTabRequests.append(CreateTabClientRequest(machine: machine, title: title, cwd: cwd, launch: launch))
        return nextTabActionState()
    }

    func renameTab(machine: Machine, tabID: String, title: String) async throws -> RemoteSessionState {
        if let error {
            throw error
        }
        renameTabRequests.append(RenameTabClientRequest(machine: machine, tabID: tabID, title: title))
        return nextTabActionState()
    }

    func closeTab(machine: Machine, tabID: String) async throws -> RemoteSessionState {
        if let error {
            throw error
        }
        closeTabRequests.append(CloseTabClientRequest(machine: machine, tabID: tabID))
        return nextTabActionState()
    }

    func restartTab(machine: Machine, tabID: String) async throws -> RemoteSessionState {
        if let error {
            throw error
        }
        restartTabRequests.append(RestartTabClientRequest(machine: machine, tabID: tabID))
        return nextTabActionState()
    }

    private func nextTabActionState() -> RemoteSessionState {
        guard !tabActionStates.isEmpty else {
            return tabActionState
        }
        return tabActionStates.removeFirst()
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

    func createTab(title: String, cwd: String?, launch: String?) async throws {
        _ = title
        _ = cwd
        _ = launch
    }

    func renameTab(tabID: String, title: String) async throws {
        _ = tabID
        _ = title
    }

    func closeTab(tabID: String) async throws {
        _ = tabID
    }

    func restartTab(tabID: String) async throws {
        _ = tabID
    }

    func setWidthMode(tabID: String, widthMode: WidthMode, computerProfile: TerminalProfile) async throws {
        widthModeRequests.append(WidthModeRequest(
            tabID: tabID,
            widthMode: widthMode,
            computerProfile: computerProfile
        ))
    }

    func receiveEvent() async throws -> RelaySessionEvent {
        if closed {
            throw CancellationError()
        }
        if let errorWhenReceiving {
            throw errorWhenReceiving
        }
        if events.isEmpty {
            if suspendWhenEmpty {
                while true {
                    if closed {
                        throw CancellationError()
                    }
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

@MainActor
private final class RecordingAppModelPersistence: AppModelPersistence {
    private var storedState: AppModelStoredState?
    var savedStates: [AppModelStoredState] = []

    init(storedState: AppModelStoredState? = nil) {
        self.storedState = storedState
    }

    func load() -> AppModelStoredState? {
        storedState
    }

    func save(_ state: AppModelStoredState) {
        storedState = state
        savedStates.append(state)
    }
}
