import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import AudioToolbox

/// Unified, customizable terminal keyboard. Customizable rows scroll
/// horizontally; a fixed arrow + enter row is pinned below. A composer
/// TextField submits free-form prompts. Adapts dinotty's MobileKeyboard.
struct TerminalKeyboardView: View {
    @Environment(AppModel.self) private var model
    var onEditLayout: () -> Void

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 7) {
            ForEach(Array(model.keyboardLayout.rows.enumerated()), id: \.offset) { _, row in
                keyRow(row)
            }
            controlRow
            composerRow
        }
        .padding(10)
        .background(Color.surface)
    }

    private func keyRow(_ keys: [KeyboardKey]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys) { key in
                    KeyCapButton(key: key) {
                        press(key)
                    }
                    .frame(minWidth: 38 * key.grow)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var controlRow: some View {
        HStack(spacing: 6) {
            ForEach(KeyboardControlKeys.all) { key in
                KeyCapButton(key: key) {
                    press(key)
                }
            }
            Button {
                onEditLayout()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(KeyCapStyle(danger: false))
            .accessibilityLabel("Edit keyboard")
        }
    }

    private var composerRow: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            TextField("Send Command", text: $model.commandComposer)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.borderBright, lineWidth: 1)
                )
            Button {
                let text = model.commandComposer
                model.commandComposer = ""
                Task {
                    await model.sendSelectedTabInput(text, enter: true)
                }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(.body).weight(.semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(Color(hex: "#080b0f"))
                    .background(Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(model.commandComposer.isEmpty)
            .opacity(model.commandComposer.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Send Command")
        }
    }

    private func press(_ key: KeyboardKey) {
        KeyboardFeedback.fire(soundEnabled: model.keyboardSoundEnabled)
        Task {
            await model.sendSelectedTabInput(key.send, enter: key.autoEnter)
        }
    }
}

/// A single dark, rounded, monospace keycap. Danger keys tint red.
private struct KeyCapButton: View {
    var key: KeyboardKey
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(key.label.isEmpty ? " " : key.label)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, minHeight: 38)
                .padding(.horizontal, 8)
        }
        .buttonStyle(KeyCapStyle(danger: key.danger))
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        key.label.isEmpty ? "Key" : key.label
    }
}

private struct KeyCapStyle: ButtonStyle {
    var danger: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(danger ? Color.danger : Color.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(danger ? Color.dangerDim : Color.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        danger ? Color.dangerBorder : Color.borderBright,
                        lineWidth: 1
                    )
            )
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Optional key-press sound + haptic, gated by the user's setting.
enum KeyboardFeedback {
    static func fire(soundEnabled: Bool) {
        guard soundEnabled else {
            return
        }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        // 1104 is the system "Tock" keyboard click.
        AudioServicesPlaySystemSound(1104)
    }
}
