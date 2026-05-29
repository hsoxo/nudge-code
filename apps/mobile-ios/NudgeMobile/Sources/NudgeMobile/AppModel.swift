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

    init(
        machines: [Machine] = [],
        tabsByMachine: [String: [TerminalTab]] = [:],
        selectedMachineID: String? = nil,
        selectedTabID: String? = nil,
        bindingDraft: BindingDraft? = nil,
        phoneProfile: TerminalProfile = TerminalProfile(rows: 32, cols: 48),
        relayClient: any RelayClient = HTTPRelayClient()
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

    func updateSelectedTabWidth(_ widthMode: WidthMode) {
        guard let machineID = selectedMachineID,
              let tabID = selectedTab?.id,
              let index = tabsByMachine[machineID]?.firstIndex(where: { $0.id == tabID })
        else {
            return
        }
        tabsByMachine[machineID]?[index].widthMode = widthMode
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

    func sendSelectedTabInput(_ text: String, enter: Bool) async {
        guard !text.isEmpty,
              let machine = selectedMachine,
              let tab = selectedTab
        else {
            return
        }
        do {
            try await relayClient.sendTerminalInput(machine: machine, tabID: tab.id, text: text, enter: enter)
        } catch {
            if let machineIndex = machines.firstIndex(where: { $0.id == machine.id }) {
                machines[machineIndex].lastSeenText = "Unable to send input"
            }
        }
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
        tabsByMachine[machines[index].id] = state.tabs
        selectedTabID = state.tabs.first?.id
        machines[index].connectionState = .online
        machines[index].lastSeenText = "relay session attached"
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
