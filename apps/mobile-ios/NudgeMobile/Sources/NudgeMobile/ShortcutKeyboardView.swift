import SwiftUI

struct ShortcutKeyboardView: View {
    @Environment(AppModel.self) private var model
    var tab: TerminalTab

    private var profile: KeyboardProfile {
        KeyboardProfile.profile(for: tab.agentStatus)
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 10) {
            shortcutRow(profile.primary)
            shortcutRow(profile.secondary)
            HStack(spacing: 8) {
                TextField(profile.actionTitle, text: $model.commandComposer)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    let text = model.commandComposer
                    model.commandComposer = ""
                    Task {
                        await model.sendSelectedTabInput(text, enter: true)
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.commandComposer.isEmpty)
                .accessibilityLabel(profile.actionTitle)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
    }

    private func shortcutRow(_ keys: [ShortcutKey]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(keys) { key in
                    Button(key.label) {
                        Task {
                            await model.sendSelectedTabInput(key.payload, enter: false)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

}
