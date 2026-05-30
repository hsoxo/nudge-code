import SwiftUI

/// Editor sheet for the customizable terminal keyboard. Adapts dinotty's
/// KeyboardTab.vue: edit keycaps, add/remove keys + rows, set width via
/// stepper or drag, restore defaults, and toggle key sound.
struct KeyboardEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var layout: KeyboardLayout
    @State private var editingKey: KeyPath?
    @State private var showRestoreConfirm = false

    init(layout: KeyboardLayout) {
        _layout = State(initialValue: layout)
    }

    private struct KeyPath: Identifiable, Equatable {
        var row: Int
        var key: Int
        var id: String { "\(row)-\(key)" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Key sound + haptics", isOn: Binding(
                        get: { model.keyboardSoundEnabled },
                        set: { model.setKeyboardSoundEnabled($0) }
                    ))
                    .foregroundStyle(Color.textPrimary)
                    .tint(Color.accent)
                } header: {
                    Text("Feedback")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.textSubtle)
                        .kerning(1.1)
                }
                .listRowBackground(Color.surface)

                ForEach(Array(layout.rows.enumerated()), id: \.offset) { rowIndex, row in
                    Section {
                        ForEach(Array(row.enumerated()), id: \.element.id) { keyIndex, key in
                            keyRowItem(rowIndex: rowIndex, keyIndex: keyIndex, key: key)
                                .listRowBackground(Color.surface)
                        }
                        Button {
                            addKey(toRow: rowIndex)
                        } label: {
                            Label("Add Key", systemImage: "plus.circle")
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(Color.accent)
                        }
                        .listRowBackground(Color.surface)
                    } header: {
                        HStack {
                            Text("Row \(rowIndex + 1)")
                                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Color.textSubtle)
                                .kerning(1.1)
                            Spacer()
                            if layout.rows.count > 1 {
                                Button(role: .destructive) {
                                    removeRow(rowIndex)
                                } label: {
                                    Text("Remove Row")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(Color.danger)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        addRow()
                    } label: {
                        Label("Add Row", systemImage: "plus.square.on.square")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(Color.accent)
                    }
                    .listRowBackground(Color.surface)
                    Button(role: .destructive) {
                        showRestoreConfirm = true
                    } label: {
                        Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                            .font(.system(.subheadline, design: .monospaced))
                    }
                    .listRowBackground(Color.surface)
                }

                Section {
                    HStack(spacing: 6) {
                        ForEach(KeyboardControlKeys.all) { key in
                            Text(key.label)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(Color.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.surface2)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.borderBright, lineWidth: 1)
                                )
                        }
                    }
                    .listRowBackground(Color.surface)
                } header: {
                    Text("Fixed Controls")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.textSubtle)
                        .kerning(1.1)
                } footer: {
                    Text("Arrow keys and Enter are always shown below your custom rows.")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.textSubtle)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBg)
            .navigationTitle("Edit Keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(Color.accent)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                }
            }
            .sheet(item: $editingKey) { path in
                keyEditorSheet(path)
            }
            .confirmationDialog(
                "Restore the default keyboard layout?",
                isPresented: $showRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive) {
                    layout = .default
                    commit()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func keyRowItem(rowIndex: Int, keyIndex: Int, key: KeyboardKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    editingKey = KeyPath(row: rowIndex, key: keyIndex)
                } label: {
                    HStack(spacing: 10) {
                        Text(key.label.isEmpty ? " " : key.label)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(key.danger ? Color.danger : Color.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(key.danger ? Color.dangerDim : Color.surface2)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        key.danger ? Color.dangerBorder : Color.borderBright,
                                        lineWidth: 1
                                    )
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(KeyboardEscape.encodeForDisplay(key.send))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.textMuted)
                                .lineLimit(1)
                            if key.autoEnter {
                                Text("auto-enter")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(Color.accent.opacity(0.7))
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button(role: .destructive) {
                    removeKey(rowIndex: rowIndex, keyIndex: keyIndex)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Color.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove key \(key.label)")
            }
            widthControl(rowIndex: rowIndex, keyIndex: keyIndex, key: key)
        }
        .padding(.vertical, 2)
    }

    private func widthControl(rowIndex: Int, keyIndex: Int, key: KeyboardKey) -> some View {
        HStack(spacing: 8) {
            Text("Width")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.textMuted)
            Slider(
                value: Binding(
                    get: { layout.rows[rowIndex][keyIndex].grow },
                    set: { newValue in
                        layout.rows[rowIndex][keyIndex].grow = KeyboardKey.clampGrow(newValue)
                    }
                ),
                in: KeyboardKey.minGrow...6,
                step: 0.25,
                onEditingChanged: { editing in
                    if !editing {
                        commit()
                    }
                }
            )
            .tint(Color.accent)
            Stepper(
                value: Binding(
                    get: { layout.rows[rowIndex][keyIndex].grow },
                    set: { newValue in
                        layout.rows[rowIndex][keyIndex].grow = KeyboardKey.clampGrow(newValue)
                        commit()
                    }
                ),
                in: KeyboardKey.minGrow...KeyboardKey.maxGrow,
                step: 0.25
            ) {
                Text(String(format: "%.2f×", key.grow))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.textMuted)
                    .frame(width: 56, alignment: .trailing)
            }
            .labelsHidden()
            Text(String(format: "%.2f×", key.grow))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.textSubtle)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func keyEditorSheet(_ path: KeyPath) -> some View {
        KeyCapEditor(
            key: layout.rows[path.row][path.key],
            onSave: { updated in
                layout.rows[path.row][path.key] = updated
                commit()
                editingKey = nil
            },
            onCancel: {
                editingKey = nil
            }
        )
    }

    // MARK: Mutations

    private func addRow() {
        layout.rows.append([KeyboardKey(label: "new", send: "", autoEnter: true)])
        commit()
    }

    private func removeRow(_ index: Int) {
        guard layout.rows.indices.contains(index) else {
            return
        }
        layout.rows.remove(at: index)
        commit()
    }

    private func addKey(toRow rowIndex: Int) {
        guard layout.rows.indices.contains(rowIndex) else {
            return
        }
        layout.rows[rowIndex].append(KeyboardKey(label: "new", send: "", autoEnter: true))
        commit()
    }

    private func removeKey(rowIndex: Int, keyIndex: Int) {
        guard layout.rows.indices.contains(rowIndex),
              layout.rows[rowIndex].indices.contains(keyIndex)
        else {
            return
        }
        layout.rows[rowIndex].remove(at: keyIndex)
        commit()
    }

    private func commit() {
        model.updateKeyboardLayout(layout)
    }
}

/// Modal form for editing a single keycap's label, send payload, width, and flags.
private struct KeyCapEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var label: String
    @State private var sendDisplay: String
    @State private var autoEnter: Bool
    @State private var danger: Bool
    @State private var grow: Double

    var onSave: (KeyboardKey) -> Void
    var onCancel: () -> Void

    init(
        key: KeyboardKey,
        onSave: @escaping (KeyboardKey) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _label = State(initialValue: key.label)
        _sendDisplay = State(initialValue: KeyboardEscape.encodeForDisplay(key.send))
        _autoEnter = State(initialValue: key.autoEnter)
        _danger = State(initialValue: key.danger)
        _grow = State(initialValue: key.grow)
        self.onSave = onSave
        self.onCancel = onCancel
        self.original = key
    }

    private let original: KeyboardKey

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Keycap label", text: $label)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)
                        .listRowBackground(Color.surface)
                } header: {
                    Text("Label")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.textSubtle)
                        .kerning(1.1)
                }

                Section {
                    TextField("Text or escape sequence", text: $sendDisplay, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2...4)
                        .listRowBackground(Color.surface)
                } header: {
                    Text("Send")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.textSubtle)
                        .kerning(1.1)
                } footer: {
                    Text("Escapes: \\e=ESC, \\t, \\r, \\n, \\x7f, ^A..^Z for ctrl, \\xHH for any byte.")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.textSubtle)
                }

                Section {
                    Toggle("Append Enter", isOn: $autoEnter)
                        .foregroundStyle(Color.textPrimary)
                        .tint(Color.accent)
                        .listRowBackground(Color.surface)
                    Toggle("Danger (red)", isOn: $danger)
                        .foregroundStyle(Color.textPrimary)
                        .tint(Color.danger)
                        .listRowBackground(Color.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBg)
            .navigationTitle("Edit Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .foregroundStyle(Color.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(KeyboardKey(
                            id: original.id,
                            label: label,
                            send: KeyboardEscape.decodeFromDisplay(sendDisplay),
                            autoEnter: autoEnter,
                            grow: grow,
                            danger: danger
                        ))
                    }
                    .foregroundStyle(Color.accent)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                }
            }
        }
    }
}
