import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private static let maxReplayOutputBytes = 64 * 1024

    var machines: [Machine]
    @ObservationIgnored private var tabsByMachineStorage: [String: [TerminalTab]]
    private var tabsByMachineRevision = 0
    @ObservationIgnored
    var tabsByMachine: [String: [TerminalTab]] {
        get {
            return tabsByMachineStorage
        }
        set {
            tabsByMachineStorage = newValue
            markTabsChanged()
        }
    }
    var selectedMachineID: String?
    var selectedTabID: String?
    var bindingDraft: BindingDraft?
    var bindingClaimState: BindingClaimState = .idle
    var phoneProfile: TerminalProfile
    var terminalFontSize: Int
    var keyboardLayout: KeyboardLayout
    var keyboardSoundEnabled: Bool
    var workspaceNoticeText: String?
    var commandComposer = ""

    /// Folders the user recently launched a tab in, most-recent first. Surfaced
    /// as quick-fill chips in the New Tab sheet. Capped at `maxRecentFolders`.
    private(set) var recentFolders: [String]
    /// Wire value (`shell`/`claude`/`codex`) of the agent the user last launched,
    /// used to preselect the New Tab sheet. `nil` until the first launch.
    private(set) var lastLaunchAgent: String?

    static let minFontSize = TerminalFontSize.min
    static let maxFontSize = TerminalFontSize.max
    static let defaultFontSize = TerminalFontSize.default
    static let maxRecentFolders = 5
    private(set) var relaySyncGeneration = 0
    private let relayClient: any RelayClient
    private let persistence: (any AppModelPersistence)?
    private let sessionReconnectDelayNanoseconds: UInt64
    private var relaySession: (any RelaySession)?
    private var relaySessionMachineID: String?
    private var computerProfilesByTabKey: [String: TerminalProfile] = [:]
    // Phase 1 stream contract: the expected next absolute stream offset per tab,
    // set when a snapshot is adopted and advanced as deltas apply. Absent means
    // no baseline yet (no snapshot received, or a legacy daemon without offsets).
    @ObservationIgnored private var terminalNextOffsetByTabKey: [String: UInt64] = [:]
    // When a re-baseline snapshot was last requested, per tab. While an entry is
    // present and fresh (< terminalResyncRetry old) interim deltas are dropped so
    // a burst of gaps can't storm the daemon; once it goes stale the next gap
    // re-requests, so a LOST snapshot reply self-heals instead of wedging the tab.
    @ObservationIgnored private var terminalResyncRequestedAt: [String: ContinuousClock.Instant] = [:]
    private let resyncClock = ContinuousClock()
    private let terminalResyncRetry: Duration
    @ObservationIgnored private var relaySessionSuspendedForBackground = false

    init(
        machines: [Machine] = [],
        tabsByMachine: [String: [TerminalTab]] = [:],
        selectedMachineID: String? = nil,
        selectedTabID: String? = nil,
        bindingDraft: BindingDraft? = nil,
        phoneProfile: TerminalProfile = TerminalProfile(rows: 32, cols: 48),
        terminalFontSize: Int = TerminalFontSize.default,
        keyboardLayout: KeyboardLayout = .default,
        keyboardSoundEnabled: Bool = false,
        recentFolders: [String] = [],
        lastLaunchAgent: String? = nil,
        relayClient: any RelayClient = HTTPRelayClient(),
        persistence: (any AppModelPersistence)? = nil,
        sessionReconnectDelayNanoseconds: UInt64 = 1_000_000_000,
        terminalResyncRetry: Duration = .seconds(2)
    ) {
        self.terminalResyncRetry = terminalResyncRetry
        let initialMachineID = selectedMachineID ?? machines.first?.id
        let initialTabID = selectedTabID ?? tabsByMachine[initialMachineID ?? ""]?.first?.id

        self.machines = machines
        self.tabsByMachineStorage = tabsByMachine
        self.selectedMachineID = initialMachineID
        self.selectedTabID = initialTabID
        self.bindingDraft = bindingDraft
        self.phoneProfile = phoneProfile
        self.terminalFontSize = TerminalFontSize.clamp(terminalFontSize)
        self.keyboardLayout = keyboardLayout
        self.keyboardSoundEnabled = keyboardSoundEnabled
        self.recentFolders = Self.sanitizedRecentFolders(recentFolders)
        self.lastLaunchAgent = lastLaunchAgent
        self.relayClient = relayClient
        self.persistence = persistence
        self.sessionReconnectDelayNanoseconds = sessionReconnectDelayNanoseconds
    }

    static func persistent(
        relayClient: any RelayClient = HTTPRelayClient(),
        sessionReconnectDelayNanoseconds: UInt64 = 1_000_000_000
    ) -> AppModel {
        restoring(
            from: UserDefaultsAppModelPersistence(),
            relayClient: relayClient,
            sessionReconnectDelayNanoseconds: sessionReconnectDelayNanoseconds
        )
    }

    static func restoring(
        from persistence: any AppModelPersistence,
        relayClient: any RelayClient = HTTPRelayClient(),
        sessionReconnectDelayNanoseconds: UInt64 = 1_000_000_000
    ) -> AppModel {
        let storedState = persistence.load()
        let machines = storedState?.machines.map(restoredMachine) ?? []
        let selectedMachineID = storedState?.selectedMachineID.flatMap { selectedID in
            machines.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? machines.first?.id
        return AppModel(
            machines: machines,
            tabsByMachine: [:],
            selectedMachineID: selectedMachineID,
            phoneProfile: storedState?.phoneProfile ?? TerminalProfile(rows: 32, cols: 48),
            terminalFontSize: storedState?.terminalFontSize ?? TerminalFontSize.default,
            keyboardLayout: storedState?.keyboardLayout ?? .default,
            keyboardSoundEnabled: storedState?.keyboardSoundEnabled ?? false,
            recentFolders: storedState?.recentFolders ?? [],
            lastLaunchAgent: storedState?.lastLaunchAgent,
            relayClient: relayClient,
            persistence: persistence,
            sessionReconnectDelayNanoseconds: sessionReconnectDelayNanoseconds
        )
    }

    static func clampFontSize(_ value: Int) -> Int {
        TerminalFontSize.clamp(value)
    }

    /// Trim, drop blanks, de-duplicate (keeping first occurrence), and cap the
    /// recent-folders list. Shared by the initializer and the record path so a
    /// restored list is always normalized.
    static func sanitizedRecentFolders(_ folders: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for folder in folders {
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                continue
            }
            result.append(trimmed)
            if result.count == maxRecentFolders {
                break
            }
        }
        return result
    }

    var selectedMachine: Machine? {
        machines.first { $0.id == selectedMachineID }
    }

    var selectedTabs: [TerminalTab] {
        _ = tabsByMachineRevision
        guard let selectedMachineID else {
            return []
        }
        return tabsByMachineStorage[selectedMachineID] ?? []
    }

    var selectedTab: TerminalTab? {
        let tabs = selectedTabs
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    var relaySyncTaskID: RelaySyncTaskID {
        RelaySyncTaskID(machineID: selectedMachineID, generation: relaySyncGeneration)
    }

    func selectMachine(_ machine: Machine) {
        selectedMachineID = machine.id
        selectedTabID = tabsByMachineStorage[machine.id]?.first?.id
        persistStableState()
    }

    func selectTab(_ tab: TerminalTab) {
        selectedTabID = tab.id
        // Phase 4.3: tell the daemon which tab is visible so it only streams live
        // output for the focused tab; background tabs re-baseline via the gap→
        // snapshot path when refocused. Fire-and-forget from this sync entry point.
        let tabID = tab.id
        Task { @MainActor [weak self] in
            await self?.sendFocusedTab(tabID)
        }
    }

    func updatePhoneProfile(_ profile: TerminalProfile) async {
        guard profile.rows > 0,
              profile.cols > 0,
              profile != phoneProfile
        else {
            return
        }
        phoneProfile = profile
        persistStableState()
        guard let machine = selectedMachine,
              machine.binding?.status == .active
        else {
            return
        }
        do {
            if let relaySession, relaySessionMachineID == machine.id {
                try await relaySession.setPhoneProfile(profile)
                // Phase 3: re-baseline the visible tab at the new geometry so the
                // phone adopts the daemon's re-rendered grid instead of diverging
                // via independent xterm reflow. Rate-limited, so rapid resizes
                // (e.g. keyboard toggles) coalesce; interim deltas drop until the
                // snapshot, and the watchdog covers a lost reply.
                if let tabID = selectedTabID {
                    await requestResyncSnapshot(
                        key: tabProfileKey(machineID: machine.id, tabID: tabID),
                        tabID: tabID,
                        session: relaySession
                    )
                }
            } else {
                let state = try await relayClient.setPhoneProfile(machine: machine, profile: profile)
                applyRemoteSessionState(state, machineID: machine.id)
            }
        } catch {
            if let machineIndex = machines.firstIndex(where: { $0.id == machine.id }) {
                machines[machineIndex].lastSeenText = "Unable to update phone profile"
            }
        }
    }

    func updateSelectedTabWidth(_ widthMode: WidthMode) async {
        guard let machineID = selectedMachineID,
              let machine = selectedMachine,
              let tabID = selectedTab?.id,
              let tab = selectedTab
        else {
            return
        }
        let profileKey = tabProfileKey(machineID: machineID, tabID: tabID)
        if tab.widthMode == .computer {
            computerProfilesByTabKey[profileKey] = tab.profile
        }
        let previousTab = tab
        updateTab(machineID: machineID, tabID: tabID) { tab in
            tab.widthMode = widthMode
        }
        let computerProfile = computerProfilesByTabKey[profileKey] ?? tab.profile
        do {
            if let relaySession, relaySessionMachineID == machineID {
                try await relaySession.setWidthMode(
                    tabID: tabID,
                    widthMode: widthMode,
                    computerProfile: computerProfile
                )
                // Phase 3: re-baseline this tab at the new geometry (see
                // updatePhoneProfile) so the phone adopts the daemon's re-rendered
                // grid rather than diverging via xterm reflow.
                await requestResyncSnapshot(
                    key: profileKey,
                    tabID: tabID,
                    session: relaySession
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
            replaceTab(previousTab, machineID: machineID)
            if let machineIndex = machines.firstIndex(where: { $0.id == machineID }) {
                machines[machineIndex].lastSeenText = "Unable to update width"
            }
        }
    }

    func updateFontSize(_ size: Int) {
        let clamped = Self.clampFontSize(size)
        guard clamped != terminalFontSize else {
            return
        }
        terminalFontSize = clamped
        persistStableState()
    }

    func updateKeyboardLayout(_ layout: KeyboardLayout) {
        guard layout != keyboardLayout else {
            return
        }
        keyboardLayout = layout
        persistStableState()
    }

    func restoreDefaultKeyboardLayout() {
        updateKeyboardLayout(.default)
    }

    func setKeyboardSoundEnabled(_ enabled: Bool) {
        guard enabled != keyboardSoundEnabled else {
            return
        }
        keyboardSoundEnabled = enabled
        persistStableState()
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

    func rotateSelectedMachinePhoneKey() async {
        guard let machineID = selectedMachineID,
              let machineIndex = machines.firstIndex(where: { $0.id == machineID }),
              machines[machineIndex].binding?.status == .active
        else {
            return
        }
        do {
            let identity = try await relayClient.rotatePhoneKey(machine: machines[machineIndex])
            if let currentIndex = machines.firstIndex(where: { $0.id == machineID }),
               var binding = machines[currentIndex].binding {
                binding.phonePublicKey = identity.publicKey
                machines[currentIndex].binding = binding
                machines[currentIndex].lastSeenText = "phone key rotated"
                persistStableState()
            }
        } catch {
            if let currentIndex = machines.firstIndex(where: { $0.id == machineID }) {
                machines[currentIndex].lastSeenText = "Unable to rotate phone key"
            }
        }
    }

    func revokeSelectedMachineBinding() async {
        guard let selectedMachineID else {
            return
        }
        await revokeMachineBinding(machineID: selectedMachineID)
    }

    func revokeMachineBinding(machineID: String) async {
        guard let machineIndex = machines.firstIndex(where: { $0.id == machineID }),
              machines[machineIndex].binding != nil
        else {
            return
        }
        do {
            let claim = try await relayClient.revokeBinding(machine: machines[machineIndex])
            if let currentIndex = machines.firstIndex(where: { $0.id == machineID }) {
                applyBindingClaim(claim, toMachineAt: currentIndex)
                machines[currentIndex].connectionState = .offline
                machines[currentIndex].lastSeenText = "binding revoked"
            }
        } catch {
            if let currentIndex = machines.firstIndex(where: { $0.id == machineID }) {
                machines[currentIndex].lastSeenText = "Unable to revoke binding"
            }
        }
    }

    func suspendRelaySessionForBackground() {
        relaySessionSuspendedForBackground = true
        closeRelaySession()
        guard let machineID = selectedMachineID,
              activeSelectedMachineIndex(machineID: machineID) != nil
        else {
            return
        }
        markMachine(machineID: machineID, state: .connecting, text: "relay session paused")
    }

    func resumeRelaySessionFromForeground() {
        guard relaySessionSuspendedForBackground else {
            return
        }
        relaySessionSuspendedForBackground = false
        if let machineID = selectedMachineID,
           activeSelectedMachineIndex(machineID: machineID) != nil {
            markMachine(machineID: machineID, state: .connecting, text: "relay session reconnecting")
        }
        relaySyncGeneration &+= 1
    }

    func syncSelectedMachineSession() async {
        guard let machineID = selectedMachineID
        else {
            closeRelaySession()
            return
        }
        closeRelaySession()
        while !Task.isCancelled {
            guard !relaySessionSuspendedForBackground else {
                closeRelaySession()
                return
            }
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
                guard !relaySessionSuspendedForBackground else {
                    return
                }
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
            // The long-lived session may be stale (e.g. mid-reconnect after a
            // drop); fall back to a one-shot send so input still reaches the tab.
            do {
                try await relayClient.sendTerminalInput(machine: machine, tabID: tab.id, text: text, enter: enter)
                await refreshTabSnapshot(machineID: machine.id, tabID: tab.id)
            } catch {
                if let machineIndex = machines.firstIndex(where: { $0.id == machine.id }) {
                    machines[machineIndex].lastSeenText = "Unable to send input"
                }
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

    func createRemoteTab(title: String = "shell", cwd: String? = nil, launch: String? = nil) async {
        guard let machine = selectedMachine else {
            return
        }
        await applyTabAction(machineID: machine.id, fallbackErrorText: "Unable to create tab", fallbackNoticeText: "Free version is limited to one tab on this computer.") {
            try await relayClient.createTab(machine: machine, title: title, cwd: cwd, launch: launch)
        }
        // Switch to the newly created tab (it is appended last).
        if let newTab = selectedTabs.last {
            selectTab(newTab)
        }
        // The live relay session only streams output for the tabs that were
        // present when it attached, so a freshly created tab would otherwise
        // stay blank until the next natural re-sync. Bump the sync generation to
        // re-run the session task: it re-attaches and re-subscribes every current
        // tab (including the new one) so the tab renders its live output.
        relaySyncGeneration &+= 1
    }

    /// Persist the user's New Tab choices so the sheet can preselect the
    /// last-used agent and offer recent folders next time. `agent` is the wire
    /// launch value (`shell`/`claude`/`codex`); `folder` is the chosen path or
    /// `nil`/blank when launching in the home directory (not recorded).
    func recordLaunch(agent: String, folder: String?) {
        var changed = false
        if agent != lastLaunchAgent {
            lastLaunchAgent = agent
            changed = true
        }
        if let folder,
           case let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            let updated = Self.sanitizedRecentFolders([trimmed] + recentFolders)
            if updated != recentFolders {
                recentFolders = updated
                changed = true
            }
        }
        if changed {
            persistStableState()
        }
    }

    func renameSelectedTab(to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let machine = selectedMachine,
              let tab = selectedTab
        else {
            return
        }
        await applyTabAction(machineID: machine.id, fallbackErrorText: "Unable to rename tab") {
            try await relayClient.renameTab(machine: machine, tabID: tab.id, title: title)
        }
    }

    func closeSelectedTab() async {
        guard let machine = selectedMachine,
              let tab = selectedTab
        else {
            return
        }
        await applyTabAction(machineID: machine.id, fallbackErrorText: "Unable to close tab") {
            try await relayClient.closeTab(machine: machine, tabID: tab.id)
        }
    }

    func restartSelectedTab() async {
        guard let machine = selectedMachine,
              let tab = selectedTab
        else {
            return
        }
        await applyTabAction(machineID: machine.id, fallbackErrorText: "Unable to restart tab") {
            try await relayClient.restartTab(machine: machine, tabID: tab.id)
        }
    }

    func clearWorkspaceNotice() {
        workspaceNoticeText = nil
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

    func openPairingURL(_ url: URL) -> Bool {
        let parsed = parsePairingURL(url.absoluteString)
        if parsed {
            selectedMachineID = nil
        }
        return parsed
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
        replaceTabs([
            TerminalTab(
                id: "default",
                title: "shell",
                state: .running,
                widthMode: .phone,
                profile: phoneProfile,
                agentStatus: AgentStatus(kind: .shell, state: .running, confidence: 0.5, source: "placeholder"),
                previewText: "$ nudge bind confirmed\nWaiting for relay session..."
            )
        ], machineID: machine.id)
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
        persistStableState()
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
                daemonPublicKey: binding.daemonPublicKey,
                phonePublicKey: binding.phonePublicKey,
                status: .revoked,
                expiresAt: binding.expiresAt
            )
        }
        machines[index].connectionState = .offline
        machines[index].lastSeenText = "binding revoked"
        persistStableState()
    }

    private func runRelaySession(machineID: String, machine: Machine) async throws {
        let session = try await relayClient.openSession(machine: machine)
        guard !relaySessionSuspendedForBackground else {
            session.close()
            throw CancellationError()
        }
        relaySession = session
        relaySessionMachineID = machineID
        // A fresh relay session re-syncs from scratch: drop any stale per-tab
        // stream offsets so the next snapshot re-establishes each baseline.
        terminalNextOffsetByTabKey.removeAll()
        terminalResyncRequestedAt.removeAll()
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
            // Phase 4.3: applyRemoteSessionState (re)sets selectedTabID after an
            // attach/reconnect — tell the daemon the focused tab so it streams only
            // that tab. Best-effort: a stale/failed send just means the daemon
            // keeps streaming all tabs (the backward-compatible default).
            await sendFocusedTab(selectedTabID)
            for tab in state.tabs {
                // Initial state is a full snapshot, not a raw byte tail (R1): the
                // snapshot is complete restorable state and carries the stream
                // offset that re-baselines gap detection, whereas a tail starts at
                // an arbitrary mid-stream byte. Best-effort per tab: a tab that
                // cannot currently stream (e.g. a restored tab awaiting restart
                // after a computer-side daemon bounce) must not throw and tear
                // down the whole session, which would wedge a relay reconnect loop.
                try? await session.requestTerminalSnapshot(tabID: tab.id)
            }
        case .terminalSnapshot(let snapshot):
            applyTerminalSnapshot(snapshot, machineID: machineID)
        case .terminalOutput(let output):
            await applyTerminalDelta(output, machineID: machineID, session: session)
        case .agentStatus(let update):
            applyAgentStatus(update, machineID: machineID)
        case .terminalInputAccepted(let tabID):
            if let tabID {
                try await session.requestTerminalSnapshot(tabID: tabID)
            }
        }
    }

    private func applyTabAction(
        machineID: String,
        fallbackErrorText: String,
        fallbackNoticeText: String? = nil,
        action: () async throws -> RemoteSessionState
    ) async {
        do {
            let state = try await action()
            workspaceNoticeText = nil
            applyRemoteSessionState(state, machineID: machineID)
        } catch {
            workspaceNoticeText = tabActionNoticeText(error: error, fallback: fallbackNoticeText ?? fallbackErrorText)
            markMachine(machineID: machineID, state: .online, text: fallbackErrorText)
        }
    }

    private func tabActionNoticeText(error: Error, fallback: String) -> String {
        guard case RelayClientError.daemonRejected(let message) = error else {
            return fallback
        }
        if message.contains("free entitlement") || message.contains("max_tabs") {
            return "Free version is limited to one tab on this computer."
        }
        return fallback
    }

    private func applyRemoteSessionState(_ state: RemoteSessionState, machineID: String) {
        let previousSelectedTabID = selectedTabID
        replaceTabs(state.tabs, machineID: machineID)
        if let previousSelectedTabID,
           state.tabs.contains(where: { $0.id == previousSelectedTabID }) {
            selectedTabID = previousSelectedTabID
        } else {
            selectedTabID = state.tabs.first?.id
        }
        for tab in state.tabs where tab.widthMode == .computer {
            computerProfilesByTabKey[tabProfileKey(machineID: machineID, tabID: tab.id)] = tab.profile
        }
        // Adopt the computer's hostname as the machine name once the daemon reports it.
        if let hostname = state.hostname,
           !hostname.isEmpty,
           let index = machines.firstIndex(where: { $0.id == machineID }),
           machines[index].name != hostname {
            machines[index].name = hostname
            persistStableState()
        }
    }

    private func tabProfileKey(machineID: String, tabID: String) -> String {
        "\(machineID):\(tabID)"
    }

    private func refreshTabSnapshot(machineID: String, tabID: String) async {
        guard let machine = machines.first(where: { $0.id == machineID }),
              tabsByMachineStorage[machineID]?.firstIndex(where: { $0.id == tabID }) != nil
        else {
            return
        }
        do {
            let snapshot = try await relayClient.fetchTerminalSnapshot(machine: machine, tabID: tabID)
            applyTerminalSnapshot(snapshot, machineID: machineID)
        } catch {
            updateTab(machineID: machineID, tabID: tabID) { tab in
                tab.previewText = "Unable to refresh terminal snapshot"
            }
        }
    }

    private func applyTerminalSnapshot(_ snapshot: TerminalSnapshot, machineID: String) {
        // Adopt the snapshot's stream offset as the new baseline UNCONDITIONALLY:
        // restart and daemon-restart reset the byte axis, so we must not gate on
        // offset >= the current expected value. A legacy daemon omits offset, in
        // which case the key is cleared and we fall back to no gap detection.
        let key = tabProfileKey(machineID: machineID, tabID: snapshot.tabID)
        terminalNextOffsetByTabKey[key] = snapshot.offset
        terminalResyncRequestedAt[key] = nil
        updateTab(machineID: machineID, tabID: snapshot.tabID) { tab in
            tab.profile = snapshot.profile
            if snapshot.formattedBase64.isEmpty {
                tab.previewText = snapshot.text
                tab.replayOutputBase64 = ""
            } else {
                // Render the alt-screen-aware ANSI dump so full-screen TUIs
                // (Claude, Codex) reconstruct correctly instead of plain text.
                tab.previewText = ""
                tab.replayOutputBase64 = snapshot.formattedBase64
            }
            tab.replayOutputSequence += 1
            tab.pendingOutputBase64 = ""
        }
    }

    private func applyTerminalOutput(_ output: TerminalOutput, machineID: String) {
        updateTab(machineID: machineID, tabID: output.tabID) { tab in
            if output.isReplay {
                // A replayed byte tail is the tab's entire visible state, so a
                // leftover "connecting/waiting" placeholder must not linger
                // beneath it (roadmap L3). The live branch deliberately keeps
                // previewText: after a plain-text snapshot it carries the base
                // screen that live deltas are layered on top of.
                tab.previewText = ""
                tab.replayOutputBase64 = output.bytesBase64
                tab.replayOutputSequence += 1
                tab.pendingOutputBase64 = ""
                return
            }
            appendReplayOutput(&tab.replayOutputData, output.bytesBase64)
            tab.pendingOutputBase64 = output.bytesBase64
            tab.outputSequence += 1
        }
    }

    /// Apply a live terminal delta with Phase 1 gap detection. A replay tail is a
    /// full replace (no offset tracking). For an offset-carrying delta we apply
    /// only the contiguous continuation, trim an overlap we already hold, and on
    /// a gap (or before any baseline) request a re-baseline snapshot and drop
    /// interim deltas until it arrives. A legacy daemon (no offset) applies as-is.
    private func applyTerminalDelta(
        _ output: TerminalOutput,
        machineID: String,
        session: any RelaySession
    ) async {
        if output.isReplay {
            applyTerminalOutput(output, machineID: machineID)
            return
        }
        guard let offset = output.offset else {
            // Legacy daemon without offsets — no gap detection, apply as-is.
            applyTerminalOutput(output, machineID: machineID)
            return
        }
        let key = tabProfileKey(machineID: machineID, tabID: output.tabID)
        guard let next = terminalNextOffsetByTabKey[key] else {
            // No baseline yet: request a snapshot once, drop deltas until it lands.
            await requestResyncSnapshot(key: key, tabID: output.tabID, session: session)
            return
        }
        if terminalResyncRequestedAt[key] != nil {
            // A resync is in flight: drop this interim delta, but let
            // requestResyncSnapshot re-request if it has gone stale (lost reply).
            await requestResyncSnapshot(key: key, tabID: output.tabID, session: session)
            return
        }
        let length = UInt64(output.byteCount)
        if offset == next {
            applyTerminalOutput(output, machineID: machineID)
            terminalNextOffsetByTabKey[key] = next + length
        } else if offset > next {
            // Gap: bytes between `next` and `offset` were lost. Re-baseline.
            await requestResyncSnapshot(key: key, tabID: output.tabID, session: session)
        } else {
            // offset < next: we already applied a prefix of these bytes. Trim the
            // overlap and apply only the new tail (drop entirely if fully old).
            let alreadyApplied = next - offset
            if alreadyApplied >= length {
                return
            }
            applyTerminalOutput(output.droppingFirst(Int(alreadyApplied)), machineID: machineID)
            terminalNextOffsetByTabKey[key] = offset + length
        }
    }

    private func requestResyncSnapshot(
        key: String,
        tabID: String,
        session: any RelaySession
    ) async {
        // Rate-limit so a burst of gaps can't storm the daemon, but re-request
        // once the previous request has gone unanswered past the retry window:
        // otherwise a snapshot reply lost in flight (request sent OK, no event
        // back, socket still alive) would wedge the tab until the session
        // restarts. Reconnect also clears the map (runRelaySession).
        if let requestedAt = terminalResyncRequestedAt[key],
           resyncClock.now - requestedAt < terminalResyncRetry {
            return
        }
        let stamp = resyncClock.now
        terminalResyncRequestedAt[key] = stamp
        do {
            try await session.requestTerminalSnapshot(tabID: tabID)
            // Arm a watchdog: if the reply is lost AND the stream then goes silent
            // (no further delta to drive a re-request), re-fire after the window.
            scheduleResyncWatchdog(key: key, tabID: tabID, stamp: stamp)
        } catch {
            // The request never reached the daemon, so no snapshot will arrive.
            // Clear immediately so the next delta re-requests rather than waiting
            // out the retry window (the throw is expected for a tab that cannot
            // currently stream — e.g. mid-restart).
            terminalResyncRequestedAt[key] = nil
        }
    }

    /// Re-fire a resync request once the retry window passes with no snapshot, so
    /// a LOST reply self-heals even if the stream goes silent (the delta-driven
    /// re-request in applyTerminalDelta only fires when more output arrives). Each
    /// re-request re-arms this watchdog, so it retries at the retry cadence until a
    /// snapshot lands (clears the stamp), the session resets, or the model is gone.
    /// Disabled when retry == .zero (tests rely on delta-driven recovery, and a
    /// zero-length sleep would busy-loop).
    private func scheduleResyncWatchdog(key: String, tabID: String, stamp: ContinuousClock.Instant) {
        let retry = terminalResyncRetry
        guard retry > .zero else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: retry)
            guard let self,
                  self.terminalResyncRequestedAt[key] == stamp,
                  let session = self.relaySession
            else {
                return
            }
            // Still pending after the window — the reply was lost. Clear our stamp
            // so we aren't rate-limited against it, then re-request.
            self.terminalResyncRequestedAt[key] = nil
            await self.requestResyncSnapshot(key: key, tabID: tabID, session: session)
        }
    }

    /// Phase 4.3: best-effort tell the live daemon session which tab is focused so
    /// it only streams live output for that tab (background tabs re-baseline via
    /// the gap→snapshot path on refocus). Only fires over a session that owns the
    /// focused tab's machine, mirroring the resize re-baseline guard in
    /// updatePhoneProfile; a send failure is harmless (the daemon keeps streaming
    /// the previous focus, or all tabs if none was set).
    private func sendFocusedTab(_ tabID: String?) async {
        guard let relaySession,
              let machineID = relaySessionMachineID,
              selectedMachineID == machineID
        else {
            return
        }
        try? await relaySession.setFocusedTab(tabID: tabID)
    }

    private func applyAgentStatus(_ update: AgentStatusUpdate, machineID: String) {
        updateTab(machineID: machineID, tabID: update.tabID) { tab in
            tab.agentStatus = update.status
        }
    }

    private func replaceTabs(_ tabs: [TerminalTab], machineID: String) {
        tabsByMachineStorage[machineID] = tabs
        markTabsChanged()
    }

    private func replaceTab(_ tab: TerminalTab, machineID: String) {
        updateTabs(machineID: machineID) { tabs in
            guard let tabIndex = tabs.firstIndex(where: { $0.id == tab.id }) else {
                return false
            }
            tabs[tabIndex] = tab
            return true
        }
    }

    private func updateTab(machineID: String, tabID: String, mutate: (inout TerminalTab) -> Void) {
        updateTabs(machineID: machineID) { tabs in
            guard let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else {
                return false
            }
            mutate(&tabs[tabIndex])
            return true
        }
    }

    @discardableResult
    private func updateTabs(machineID: String, mutate: (inout [TerminalTab]) -> Bool) -> Bool {
        guard var tabs = tabsByMachineStorage[machineID],
              mutate(&tabs)
        else {
            return false
        }
        tabsByMachineStorage[machineID] = tabs
        markTabsChanged()
        return true
    }

    private func markTabsChanged() {
        tabsByMachineRevision &+= 1
    }

    /// Append a live delta to the cumulative replay buffer, decoding ONLY the
    /// delta (not re-decoding + re-encoding the whole buffer each time, which was
    /// O(n²) under sustained bursts). base64 is produced lazily by the
    /// `replayOutputBase64` accessor when the WebView bridge reads it.
    private func appendReplayOutput(_ buffer: inout Data, _ newBase64: String) {
        if let newData = Data(base64Encoded: newBase64) {
            buffer.append(newData)
        }
        if buffer.count > Self.maxReplayOutputBytes {
            buffer.removeFirst(buffer.count - Self.maxReplayOutputBytes)
        }
    }

    private func persistStableState() {
        guard let persistence else {
            return
        }
        persistence.save(AppModelStoredState(
            machines: machines.map(Self.restoredMachine),
            selectedMachineID: selectedMachineID,
            phoneProfile: phoneProfile,
            terminalFontSize: terminalFontSize,
            keyboardLayout: keyboardLayout,
            keyboardSoundEnabled: keyboardSoundEnabled,
            recentFolders: recentFolders,
            lastLaunchAgent: lastLaunchAgent
        ))
    }

    private static func restoredMachine(_ machine: Machine) -> Machine {
        var restored = machine
        switch machine.binding?.status {
        case .some(.pending), .some(.claimed):
            restored.connectionState = .connecting
            restored.lastSeenText = "Waiting for computer confirmation"
        case .some(.active):
            restored.connectionState = .connecting
            restored.lastSeenText = "binding active"
        case .some(.revoked):
            restored.connectionState = .offline
            restored.lastSeenText = "binding revoked"
        case .none:
            restored.connectionState = .offline
            restored.lastSeenText = "not bound"
        }
        return restored
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

@MainActor
protocol AppModelPersistence: AnyObject {
    func load() -> AppModelStoredState?
    func save(_ state: AppModelStoredState)
}

struct AppModelStoredState: Codable, Equatable {
    var version: Int
    var machines: [Machine]
    var selectedMachineID: String?
    var phoneProfile: TerminalProfile
    var terminalFontSize: Int
    var keyboardLayout: KeyboardLayout
    var keyboardSoundEnabled: Bool
    var recentFolders: [String]
    var lastLaunchAgent: String?

    init(
        version: Int = 2,
        machines: [Machine],
        selectedMachineID: String?,
        phoneProfile: TerminalProfile,
        terminalFontSize: Int = TerminalFontSize.default,
        keyboardLayout: KeyboardLayout = .default,
        keyboardSoundEnabled: Bool = false,
        recentFolders: [String] = [],
        lastLaunchAgent: String? = nil
    ) {
        self.version = version
        self.machines = machines
        self.selectedMachineID = selectedMachineID
        self.phoneProfile = phoneProfile
        self.terminalFontSize = terminalFontSize
        self.keyboardLayout = keyboardLayout
        self.keyboardSoundEnabled = keyboardSoundEnabled
        self.recentFolders = recentFolders
        self.lastLaunchAgent = lastLaunchAgent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        machines = try container.decodeIfPresent([Machine].self, forKey: .machines) ?? []
        selectedMachineID = try container.decodeIfPresent(String.self, forKey: .selectedMachineID)
        phoneProfile = try container.decodeIfPresent(TerminalProfile.self, forKey: .phoneProfile)
            ?? TerminalProfile(rows: 32, cols: 48)
        terminalFontSize = try container.decodeIfPresent(Int.self, forKey: .terminalFontSize)
            ?? TerminalFontSize.default
        keyboardLayout = try container.decodeIfPresent(KeyboardLayout.self, forKey: .keyboardLayout)
            ?? .default
        keyboardSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .keyboardSoundEnabled)
            ?? false
        recentFolders = try container.decodeIfPresent([String].self, forKey: .recentFolders)
            ?? []
        lastLaunchAgent = try container.decodeIfPresent(String.self, forKey: .lastLaunchAgent)
    }
}

@MainActor
final class UserDefaultsAppModelPersistence: AppModelPersistence {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "dev.nudgecode.NudgeMobile.appModelState.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> AppModelStoredState? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(AppModelStoredState.self, from: data)
    }

    func save(_ state: AppModelStoredState) {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
