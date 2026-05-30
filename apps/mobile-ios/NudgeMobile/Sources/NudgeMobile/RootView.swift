import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        Group {
            if model.machines.isEmpty {
                NavigationStack {
                    BindingView()
                }
            } else {
                NavigationSplitView {
                    MachineListView()
                } detail: {
                    if model.selectedMachine == nil {
                        BindingView()
                    } else {
                        TerminalWorkspaceView()
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.resumeRelaySessionFromForeground()
            case .background:
                model.suspendRelaySessionForBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onOpenURL { url in
            _ = model.openPairingURL(url)
        }
    }
}

struct MachineListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedMachineID) {
            Section {
                ForEach(model.machines) { machine in
                    MachineRow(machine: machine)
                        .tag(machine.id)
                        .listRowBackground(Color.surface)
                        .onTapGesture {
                            model.selectMachine(machine)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if machine.binding?.status != .revoked {
                                Button(role: .destructive) {
                                    Task {
                                        await model.revokeMachineBinding(machineID: machine.id)
                                    }
                                } label: {
                                    Label("Revoke", systemImage: "link.badge.minus")
                                }
                            }
                        }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBg)
        .navigationTitle("Nudge")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.selectedMachineID = nil
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                        .foregroundStyle(Color.accent)
                }
                .accessibilityLabel("Bind computer")
            }
        }
    }
}

struct MachineRow: View {
    var machine: Machine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(machine.name)
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            HStack(spacing: 6) {
                // Emerald dot for online, muted amber otherwise
                Circle()
                    .fill(machine.connectionState == .online ? Color.accent : Color(hex: "#e3b341"))
                    .frame(width: 8, height: 8)
                    .shadow(color: machine.connectionState == .online
                            ? Color.accent.opacity(0.5) : Color.clear,
                            radius: 4, x: 0, y: 0)
                Text(machine.lastSeenText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(.vertical, 4)
    }
}
