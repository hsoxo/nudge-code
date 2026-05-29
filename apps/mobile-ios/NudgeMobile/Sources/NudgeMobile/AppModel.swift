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
    var phoneProfile: TerminalProfile
    var commandComposer = ""

    init(
        machines: [Machine] = [],
        tabsByMachine: [String: [TerminalTab]] = [:],
        selectedMachineID: String? = nil,
        selectedTabID: String? = nil,
        bindingDraft: BindingDraft? = nil,
        phoneProfile: TerminalProfile = TerminalProfile(rows: 32, cols: 48)
    ) {
        let initialMachineID = selectedMachineID ?? machines.first?.id
        let initialTabID = selectedTabID ?? tabsByMachine[initialMachineID ?? ""]?.first?.id

        self.machines = machines
        self.tabsByMachine = tabsByMachine
        self.selectedMachineID = initialMachineID
        self.selectedTabID = initialTabID
        self.bindingDraft = bindingDraft
        self.phoneProfile = phoneProfile
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

    func parsePairingURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let draft = BindingDraft(pairingURL: url)
        else {
            return false
        }
        bindingDraft = draft
        return true
    }

    func claimDraftBinding() {
        guard let draft = bindingDraft else {
            return
        }
        let machine = Machine(
            id: "machine-\(draft.code)",
            name: "Pending Mac",
            relayURL: draft.relayURL,
            connectionState: .connecting,
            lastSeenText: "Waiting for computer confirmation"
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
        selectMachine(machine)
    }

    static func preview() -> AppModel {
        let machine = Machine(
            id: "macbook",
            name: "MacBook Pro",
            relayURL: URL(string: "https://nudgecode.dev")!,
            connectionState: .online,
            lastSeenText: "online now"
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
