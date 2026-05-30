import SwiftUI

/// Sheet presented from the workspace "New Tab" action. Lets the user open a
/// plain Shell, or launch Claude Code / Codex in a chosen folder with the agent
/// trust prompt bypassed. The daemon builds the actual launch command; this
/// sheet only chooses the agent and (optional) folder path.
struct NewTabSheet: View {
    /// Invoked with `(title, cwd, launch)` when the user taps Create.
    /// `cwd` is `nil` when the folder field is empty (daemon defaults to home).
    var onCreate: (_ title: String, _ cwd: String?, _ launch: String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var agent: TabAgent = .shell
    @State private var folderPath: String = ""

    private enum TabAgent: String, CaseIterable, Identifiable {
        case shell
        case claude
        case codex

        var id: String { rawValue }

        /// Wire value sent to the daemon as `launch`.
        var launch: String { rawValue }

        var title: String {
            switch self {
            case .shell: return "Shell"
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            }
        }

        var systemImage: String {
            switch self {
            case .shell: return "terminal"
            case .claude: return "sparkles"
            case .codex: return "chevron.left.forwardslash.chevron.right"
            }
        }

        var detail: String {
            switch self {
            case .shell: return "A plain shell. Optionally start in a folder."
            case .claude: return "Launch claude with --dangerously-skip-permissions."
            case .codex: return "Launch codex with approvals + sandbox bypassed."
            }
        }

        /// Map a persisted wire value back to an agent, defaulting to `.shell`.
        static func from(launch: String?) -> TabAgent {
            guard let launch else { return .shell }
            return TabAgent(rawValue: launch) ?? .shell
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(TabAgent.allCases) { option in
                        agentRow(option)
                    }
                } header: {
                    sectionHeader("Open")
                }

                Section {
                    TextField("/Users/you/Projects/app", text: $folderPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.done)
                        .listRowBackground(Color.surface)

                    if !model.recentFolders.isEmpty {
                        recentFolders
                            .listRowBackground(Color.surface)
                    }
                } header: {
                    sectionHeader("Folder on the computer")
                } footer: {
                    Text(agent == .shell
                         ? "Optional. Leave empty to start in the home directory."
                         : "Optional. Leave empty to launch \(agent.title) in the home directory.")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.textSubtle)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBg)
            .navigationTitle("New Tab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.appBg)
        .onAppear {
            agent = TabAgent.from(launch: model.lastLaunchAgent)
        }
    }

    @ViewBuilder
    private func agentRow(_ option: TabAgent) -> some View {
        let isSelected = agent == option
        Button {
            agent = option
        } label: {
            HStack(spacing: 12) {
                Image(systemName: option.systemImage)
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? Color.accent : Color.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)
                    Text(option.detail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color.textMuted)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accent)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(isSelected ? Color.accentGlowSm : Color.surface)
        .listRowSeparatorTint(Color.border)
    }

    private var recentFolders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.textSubtle)
                .kerning(1.1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.recentFolders, id: \.self) { folder in
                        Button {
                            folderPath = folder
                        } label: {
                            Text(folder)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(folderPath == folder ? Color.accent : Color.textMuted)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(folderPath == folder ? Color.accent.opacity(0.12) : Color.surface2)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            folderPath == folder ? Color.accent.opacity(0.30) : Color.border,
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use folder \(folder)")
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.vertical, 4)
    }

    private func create() {
        let trimmed = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = trimmed.isEmpty ? nil : trimmed
        model.recordLaunch(agent: agent.launch, folder: cwd)
        onCreate(agent.title, cwd, agent.launch)
        dismiss()
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(Color.textSubtle)
            .kerning(1.1)
    }
}
