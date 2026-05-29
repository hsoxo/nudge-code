import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var machines: [Machine]
    var tabsByMachine: [String: [TerminalTab]]
    var selectedMachineID: String?
    var selectedTabID: String?
    var bindingDraft: BindingDraft?
    var bindingClaimState: BindingClaimState = .idle
    var phoneProfile: TerminalProfile
    var commandComposer = ""
    private let relayClient: any RelayClient
    private let sessionReconnectDelayNanoseconds: UInt64
    private var relaySession: (any RelaySession)?
    private var relaySessionMachineID: String?
    private var computerProfilesByTabKey: [String: TerminalProfile] = [:]

    init(
        machines: [Machine] = [],
        tabsByMachine: [String: [TerminalTab]] = [:],
        selectedMachineID: String? = nil,
        selectedTabID: String? = nil,
        bindingDraft: BindingDraft? = nil,
        phoneProfile: TerminalProfile = TerminalProfile(rows: 32, cols: 48),
        relayClient: any RelayClient = HTTPRelayClient(),
        sessionReconnectDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        let initialMachineID = selectedMachineID ?? machines.first?.id
        let initialTabID = selectedTabID ?? tabsByMachine[initialMachineID ?? ""]?.first?.id

        self.machines = machines
        self.tabsByMachine = tabsByMachine
        self.selectedMachineID = initialMachineID
        self.selectedTabID = initialTabID
        self.bindingDraft = bindingDraft
        self.phoneProfile = phoneProfile
        self.relayClient = relayClient
        self.sessionReconnectDelayNanoseconds = sessionReconnectDelayNanoseconds
    }

    var selectedMachine: Machine? {
        machines.first { $0.id == selectedMachineID }
    }

    var selectedTabs: [TerminalTab] {
        guard let selectedMachineID else {
            return []
        }
        return tabsByMachine[selectedMachineID] ?? []
    }

    var selectedTab: TerminalTab? {
        selectedTabs.first { $0.id == selectedTabID } ?? selectedTabs.first
    }

    func selectMachine(_ machine: Machine) {
        selectedMachineID = machine.id
        selectedTabID = tabsByMachine[machine.id]?.first?.id
    }

    func selectTab(_ tab: TerminalTab) {
        selectedTabID = tab.id
    }

    func updateSelectedTabWidth(_ widthMode: WidthMode) async {
        guard let machineID = selectedMachineID,
              let machine = selectedMachine,
              let tabID = selectedTab?.id,
              let tab = selectedTab,
              let index = tabsByMachine[machineID]?.firstIndex(where: { $0.id == tabID })
        else {
            return
        }
        let profileKey = tabProfileKey(machineID: machineID, tabID: tabID)
        if tab.widthMode == .computer {
            computerProfilesByTabKey[profileKey] = tab.profile
        }
        let previousTab = tab
        tabsByMachine[machineID]?[index].widthMode = widthMode
        let computerProfile = computerProfilesByTabKey[profileKey] ?? tab.profile
        do {
            if let relaySession, relaySessionMachineID == machineID {
                try await relaySession.setWidthMode(
                    tabID: tabID,
                    widthMode: widthMode,
                    computerProfile: computerProfile
                )
            } else {
                let state = try await relayClient.setWidthMode(
                    machine: machine,
                    tabID: tabID,
                    widthMode: widthMode,
                    computerProfile: computerProfile
                )
                applyRemoteSessionState(state, machineID: machineID)
            }
        } catch {
            tabsByMachine[machineID]?[index] = previousTab
            if let machineIndex = machines.firstIndex(where: { $0.id == machineID }) {
                machines[machineIndex].lastSeenText = "Unable to update width"
            }
        }
    }

    func refreshSelectedMachineBinding() async {
        guard let machineID = selectedMachineID,
              let machineIndex = machines.firstIndex(where: { $0.id == machineID }),
              let binding = machines[machineIndex].binding
        else {
            return
        }
        guard binding.status != .active else {
            return
        }

        do {
            let claim = try await relayClient.fetchBindingStatus(binding: binding, relayURL: machines[machineIndex].relayURL)
            applyBindingClaim(claim, toMachineAt: machineIndex)
        } catch {
            machines[machineIndex].connectionState = .offline
            machines[machineIndex].lastSeenText = "Unable to refresh binding"
        }
    }

    func attachSelectedMachineSession() async {
        guard let machineID = selectedMachineID,
              let machineIndex = machines.firstIndex(where: { $0.id == machineID }),
              machines[machineIndex].binding?.status == .active
        else {
            return
        }
        do {
            try await attachMachineSession(at: machineIndex)
        } catch {
            machines[machineIndex].connectionState = .offline
            machines[machineIndex].lastSeenText = "Unable to attach relay session"
        }
    }

    func syncSelectedMachineSession() async {
        guard let machineID = selectedMachineID
        else {
            closeRelaySession()
            return
        }
        closeRelaySession()
        while !Task.isCancelled {
            guard let machineIndex = activeSelectedMachineIndex(machineID: machineID) else {
                closeRelaySession()
                return
            }
            do {
                try await runRelaySession(machineID: machineID, machine: machines[machineIndex])
            } catch is CancellationError {
                closeRelaySession()
                return
            } catch RelayClientError.bindingRevoked {
                closeRelaySession()
                markMachineBindingRevoked(machineID: machineID)
                return
            } catch {
                closeRelaySession()
                guard activeSelectedMachineIndex(machineID: machineID) != nil else {
                    return
                }
                markMachine(machineID: machineID, state: .connecting, text: "relay session reconnecting")
                do {
                    try await Task.sleep(nanoseconds: sessionReconnectDelayNanoseconds)
                } catch is CancellationError {
                    closeRelaySession()
                    return
                } catch {
                    closeRelaySession()
                    return
                }
            }
        }
        closeRelaySession()
    }

    func sendSelectedTabInput(_ text: String, enter: Bool) async {
        guard !text.isEmpty,
              let machine = selectedMachine,
              let tab = selectedTab
        else {
            return
        }
        do {
            if let relaySession, relaySessionMachineID == machine.id {
                try await relaySession.sendTerminalInput(tabID: tab.id, text: text, enter: enter)
            } else {
                try await relayClient.sendTerminalInput(machine: machine, tabID: tab.id, text: text, enter: enter)
                await refreshTabSnapshot(machineID: machine.id, tabID: tab.id)
            }
        } catch {
            if let machineIndex = machines.firstIndex(where: { $0.id == machine.id }) {
                machines[machineIndex].lastSeenText = "Unable to send input"
            }
        }
    }

    func refreshSelectedTabSnapshot() async {
        guard let machine = selectedMachine,
              let tab = selectedTab
        else {
            return
        }
        if let relaySession, relaySessionMachineID == machine.id {
            do {
                try await relaySession.requestTerminalSnapshot(tabID: tab.id)
            } catch {
                await refreshTabSnapshot(machineID: machine.id, tabID: tab.id)
            }
            return
        }
        await refreshTabSnapshot(machineID: machine.id, tabID: tab.id)
    }

    func parsePairingURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let draft = BindingDraft(pairingURL: url)
        else {
            return false
        }
        bindingDraft = draft
        bindingClaimState = .idle
        return true
    }

    func claimDraftBinding() async {
        guard let draft = bindingDraft else {
            return
        }
        bindingClaimState = .claiming
        let claim: BindingClaim
        do {
            claim = try await relayClient.claimBinding(code: draft.code, relayURL: draft.relayURL)
        } catch {
            bindingClaimState = .failed(error.localizedDescription)
            return
        }

        let machine = Machine(
            id: "machine-\(draft.code)",
            name: "Pending Mac",
            relayURL: draft.relayURL,
            connectionState: .connecting,
            lastSeenText: "Waiting for computer confirmation",
            binding: MachineBinding(claim: claim)
        )
        machines.insert(machine, at: 0)
        tabsByMachine[machine.id] = [
            TerminalTab(
                id: "default",
                title: "shell",
                state: .running,
                widthMode: .phone,
                profile: phoneProfile,
                agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "placeholder"),
                previewText: "$ nudge bind confirmed\nWaiting for relay session..."
            )
        ]
        bindingDraft = nil
        bindingClaimState = .claimed
        selectMachine(machine)
    }

    private func applyBindingClaim(_ claim: BindingClaim, toMachineAt index: Int) {
        machines[index].binding = MachineBinding(claim: claim)
        switch claim.status {
        case .pending, .claimed:
            machines[index].connectionState = .connecting
            machines[index].lastSeenText = "Waiting for computer confirmation"
        case .active:
            machines[index].connectionState = .online
            machines[index].lastSeenText = "binding active"
        case .revoked:
            machines[index].connectionState = .offline
            machines[index].lastSeenText = "binding revoked"
        }
    }

    private func attachMachineSession(at index: Int) async throws {
        let state = try await relayClient.fetchSessionState(machine: machines[index])
        let machineID = machines[index].id
        applyRemoteSessionState(state, machineID: machineID)
        machines[index].connectionState = .online
        machines[index].lastSeenText = "relay session attached"
        if let tabID = state.tabs.first?.id {
            await refreshTabSnapshot(machineID: machineID, tabID: tabID)
        }
    }

    private func closeRelaySession() {
        relaySession?.close()
        relaySession = nil
        relaySessionMachineID = nil
    }

    private func activeSelectedMachineIndex(machineID: String) -> Int? {
        guard selectedMachineID == machineID,
              let machineIndex = machines.firstIndex(where: { $0.id == machineID }),
              machines[machineIndex].binding?.status == .active
        else {
            return nil
        }
        return machineIndex
    }

    private func markMachine(machineID: String, state: ConnectionState, text: String) {
        guard let index = machines.firstIndex(where: { $0.id == machineID }) else {
            return
        }
        machines[index].connectionState = state
        machines[index].lastSeenText = text
    }

    private func markMachineBindingRevoked(machineID: String) {
        guard let index = machines.firstIndex(where: { $0.id == machineID }) else {
            return
        }
        if let binding = machines[index].binding {
            machines[index].binding = MachineBinding(
                bindingID: binding.bindingID,
                daemonDeviceID: binding.daemonDeviceID,
                phoneDeviceID: binding.phoneDeviceID,
                status: .revoked,
                expiresAt: binding.expiresAt
            )
        }
        machines[index].connectionState = .offline
        machines[index].lastSeenText = "binding revoked"
    }

    private func runRelaySession(machineID: String, machine: Machine) async throws {
        let session = try await relayClient.openSession(machine: machine)
        relaySession = session
        relaySessionMachineID = machineID
        markMachine(machineID: machineID, state: .online, text: "relay session connected")
        try await session.setPhoneProfile(phoneProfile)
        try await session.requestSessionState()
        while !Task.isCancelled {
            let event = try await session.receiveEvent()
            try await applyRelaySessionEvent(event, machineID: machineID, session: session)
        }
        throw CancellationError()
    }

    private func applyRelaySessionEvent(
        _ event: RelaySessionEvent,
        machineID: String,
        session: any RelaySession
    ) async throws {
        switch event {
        case .sessionState(let state):
            applyRemoteSessionState(state, machineID: machineID)
            if let index = machines.firstIndex(where: { $0.id == machineID }) {
                machines[index].connectionState = .online
                machines[index].lastSeenText = "relay session synced"
            }
            for tab in state.tabs {
                try await session.requestTerminalOutput(tabID: tab.id, maxBytes: 32 * 1024)
            }
        case .terminalSnapshot(let snapshot):
            applyTerminalSnapshot(snapshot, machineID: machineID)
        case .terminalOutput(let output):
            applyTerminalOutput(output, machineID: machineID)
        case .terminalInputAccepted(let tabID):
            if let tabID {
                try await session.requestTerminalSnapshot(tabID: tabID)
            }
        }
    }

    private func applyRemoteSessionState(_ state: RemoteSessionState, machineID: String) {
        let previousSelectedTabID = selectedTabID
        tabsByMachine[machineID] = state.tabs
        if let previousSelectedTabID,
           state.tabs.contains(where: { $0.id == previousSelectedTabID }) {
            selectedTabID = previousSelectedTabID
        } else {
            selectedTabID = state.tabs.first?.id
        }
        for tab in state.tabs where tab.widthMode == .computer {
            computerProfilesByTabKey[tabProfileKey(machineID: machineID, tabID: tab.id)] = tab.profile
        }
    }

    private func tabProfileKey(machineID: String, tabID: String) -> String {
        "\(machineID):\(tabID)"
    }

    private func refreshTabSnapshot(machineID: String, tabID: String) async {
        guard let machine = machines.first(where: { $0.id == machineID }),
              tabsByMachine[machineID]?.firstIndex(where: { $0.id == tabID }) != nil
        else {
            return
        }
        do {
            let snapshot = try await relayClient.fetchTerminalSnapshot(machine: machine, tabID: tabID)
            applyTerminalSnapshot(snapshot, machineID: machineID)
        } catch {
            guard let tabIndex = tabsByMachine[machineID]?.firstIndex(where: { $0.id == tabID }) else {
                return
            }
            tabsByMachine[machineID]?[tabIndex].previewText = "Unable to refresh terminal snapshot"
        }
    }

    private func applyTerminalSnapshot(_ snapshot: TerminalSnapshot, machineID: String) {
        guard let tabIndex = tabsByMachine[machineID]?.firstIndex(where: { $0.id == snapshot.tabID }) else {
            return
        }
        tabsByMachine[machineID]?[tabIndex].profile = snapshot.profile
        tabsByMachine[machineID]?[tabIndex].previewText = snapshot.text
        tabsByMachine[machineID]?[tabIndex].pendingOutputText = ""
    }

    private func applyTerminalOutput(_ output: TerminalOutput, machineID: String) {
        guard let tabIndex = tabsByMachine[machineID]?.firstIndex(where: { $0.id == output.tabID }) else {
            return
        }
        tabsByMachine[machineID]?[tabIndex].pendingOutputText = output.text
        tabsByMachine[machineID]?[tabIndex].outputSequence += 1
    }

    static func preview() -> AppModel {
        let machine = Machine(
            id: "macbook",
            name: "MacBook Pro",
            relayURL: URL(string: "https://nudgecode.dev")!,
            connectionState: .online,
            lastSeenText: "online now",
            binding: MachineBinding(claim: BindingClaim(
                bindingID: "bind_preview",
                daemonDeviceID: "daemon_preview",
                phoneDeviceID: "phone_preview",
                status: .active,
                expiresAt: ""
            ))
        )
        let tabs = [
            TerminalTab(
                id: "claude",
                title: "Claude",
                state: .needsAttention,
                widthMode: .phone,
                profile: TerminalProfile(rows: 32, cols: 48),
                agentStatus: AgentStatus(kind: .claude, state: .needsApproval, confidence: 0.78, source: "screen"),
                previewText: "Claude wants to run a command.\nApprove or reject to continue."
            ),
            TerminalTab(
                id: "codex",
                title: "Codex",
                state: .running,
                widthMode: .computer,
                profile: TerminalProfile(rows: 24, cols: 100),
                agentStatus: AgentStatus(kind: .codex, state: .waitingForInput, confidence: 0.72, source: "screen"),
                previewText: "Codex is waiting for input.\n› "
            )
        ]
        return AppModel(
            machines: [machine],
            tabsByMachine: [machine.id: tabs],
            selectedMachineID: machine.id,
            selectedTabID: tabs.first?.id
        )
    }
}
