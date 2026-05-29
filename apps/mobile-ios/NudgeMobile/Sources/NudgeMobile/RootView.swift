import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
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

struct MachineListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedMachineID) {
            Section {
                ForEach(model.machines) { machine in
                    MachineRow(machine: machine)
                        .tag(machine.id)
                        .onTapGesture {
                            model.selectMachine(machine)
                        }
                }
            }
        }
        .navigationTitle("Nudge")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.selectedMachineID = nil
                } label: {
                    Image(systemName: "qrcode.viewfinder")
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
            HStack(spacing: 6) {
                Circle()
                    .fill(machine.connectionState == .online ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(machine.lastSeenText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
