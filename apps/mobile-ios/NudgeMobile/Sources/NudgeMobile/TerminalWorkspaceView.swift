import SwiftUI
import WebKit

struct TerminalWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var showingRenameTab = false
    @State private var showingCloseTab = false
    @State private var showingKeyboardEditor = false
    @State private var renameTitle = ""

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TabStripView()
            Divider()
                .background(Color.border)
            if model.selectedMachine?.lastSeenText == "relay session reconnecting" {
                RelayReconnectBanner()
                Divider()
                    .background(Color.border)
            }
            if let tab = model.selectedTab {
                TerminalView(
                    tab: tab,
                    fontSize: model.terminalFontSize,
                    onPhoneProfileMeasured: { profile in
                        Task {
                            await model.updatePhoneProfile(profile)
                        }
                    }
                )
                Divider()
                    .background(Color.border)
                FontSizeStepper()
                    .background(Color.surface)
                Divider()
                    .background(Color.border)
                TerminalKeyboardView(onEditLayout: {
                    showingKeyboardEditor = true
                })
            } else {
                ContentUnavailableView("No Tabs", systemImage: "terminal")
                    .foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appBg)
            }
        }
        .background(Color.appBg)
        .navigationTitle(model.selectedMachine?.name ?? "Nudge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TabActionsMenu(
                    canCloseTab: model.selectedTabs.count > 1,
                    onNewTab: {
                        Task {
                            await model.createRemoteTab()
                        }
                    },
                    onRenameTab: {
                        renameTitle = model.selectedTab?.title ?? ""
                        showingRenameTab = true
                    },
                    onRestartTab: {
                        Task {
                            await model.restartSelectedTab()
                        }
                    },
                    onCloseTab: {
                        showingCloseTab = true
                    }
                )
                .disabled(model.selectedMachine == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingKeyboardEditor = true
                } label: {
                    Image(systemName: "keyboard")
                }
                .accessibilityLabel("Edit keyboard")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await model.refreshSelectedTabSnapshot()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh terminal")
            }
        }
        .sheet(isPresented: $showingKeyboardEditor) {
            KeyboardEditorView(layout: model.keyboardLayout)
                .environment(model)
        }
        .alert("Rename Tab", isPresented: $showingRenameTab) {
            TextField("Title", text: $renameTitle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") {
                let title = renameTitle
                Task {
                    await model.renameSelectedTab(to: title)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Close Tab", isPresented: $showingCloseTab) {
            Button("Close Tab", role: .destructive) {
                Task {
                    await model.closeSelectedTab()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Tab Action Failed",
            isPresented: Binding(
                get: { model.workspaceNoticeText != nil },
                set: { isPresented in
                    if !isPresented {
                        model.clearWorkspaceNotice()
                    }
                }
            )
        ) {
            Button("OK") {
                model.clearWorkspaceNotice()
            }
        } message: {
            Text(model.workspaceNoticeText ?? "")
        }
        .task(id: model.relaySyncTaskID) {
            await model.refreshSelectedMachineBinding()
            await model.syncSelectedMachineSession()
        }
    }
}

struct TabActionsMenu: View {
    var canCloseTab: Bool
    var onNewTab: () -> Void
    var onRenameTab: () -> Void
    var onRestartTab: () -> Void
    var onCloseTab: () -> Void

    var body: some View {
        Menu {
            Button(action: onNewTab) {
                Label("New Tab", systemImage: "plus")
            }
            Button(action: onRenameTab) {
                Label("Rename Tab", systemImage: "pencil")
            }
            Button(action: onRestartTab) {
                Label("Restart Tab", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive, action: onCloseTab) {
                Label("Close Tab", systemImage: "xmark")
            }
            .disabled(!canCloseTab)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Tab actions")
    }
}

struct RelayReconnectBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.caption)
            Text("Reconnecting to relay")
                .font(.system(.caption, design: .monospaced))
            Spacer()
        }
        .foregroundStyle(Color(hex: "#e3b341"))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: "#e3b341").opacity(0.10))
    }
}

struct TabStripView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.selectedTabs) { tab in
                    Button {
                        model.selectTab(tab)
                    } label: {
                        HStack(spacing: 6) {
                            statusDot(for: tab)
                            Text(tab.title)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(tab.id == model.selectedTab?.id
                                                 ? Color.textPrimary : Color.textMuted)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            tab.id == model.selectedTab?.id
                            ? Color.accent.opacity(0.12)
                            : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(
                                    tab.id == model.selectedTab?.id
                                    ? Color.accent.opacity(0.25) : Color.clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(Color.surface)
    }

    @ViewBuilder
    private func statusDot(for tab: TerminalTab) -> some View {
        let isWaiting = tab.agentStatus.state == .needsApproval
        Circle()
            .fill(isWaiting ? Color(hex: "#e3b341") : Color.accent)
            .frame(width: 6, height: 6)
            .shadow(color: isWaiting ? Color.clear : Color.accent.opacity(0.6),
                    radius: 3, x: 0, y: 0)
    }
}

struct TerminalView: View {
    @Environment(AppModel.self) private var model
    var tab: TerminalTab
    var fontSize: Int
    var onPhoneProfileMeasured: (TerminalProfile) -> Void = { _ in }

    var body: some View {
        TerminalWebView(
            snapshotText: tab.previewText,
            widthMode: tab.widthMode,
            profile: tab.profile,
            fontSize: fontSize,
            replayOutputBase64: tab.replayOutputBase64,
            replayOutputSequence: tab.replayOutputSequence,
            outputBase64: tab.pendingOutputBase64,
            outputSequence: tab.outputSequence,
            onTerminalInput: { data in
                Task {
                    await model.sendSelectedTabInput(data, enter: false)
                }
            },
            onPhoneProfileMeasured: onPhoneProfileMeasured
        )
        .background(Color.black)
        .overlay(alignment: .topTrailing) {
            AgentBadge(status: tab.agentStatus)
                .padding(10)
        }
    }
}

struct TerminalWebView: UIViewRepresentable {
    var snapshotText: String
    var widthMode: WidthMode
    var profile: TerminalProfile
    var fontSize: Int
    var replayOutputBase64: String
    var replayOutputSequence: Int
    var outputBase64: String
    var outputSequence: Int
    var onTerminalInput: (String) -> Void = { _ in }
    var onPhoneProfileMeasured: (TerminalProfile) -> Void = { _ in }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "phoneProfile")
        configuration.userContentController.add(context.coordinator, name: "terminalInput")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.loadTerminal(in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            snapshotText: snapshotText,
            widthMode: widthMode,
            profile: profile,
            fontSize: fontSize,
            replayOutputBase64: replayOutputBase64,
            replayOutputSequence: replayOutputSequence,
            outputBase64: outputBase64,
            outputSequence: outputSequence,
            onTerminalInput: onTerminalInput,
            onPhoneProfileMeasured: onPhoneProfileMeasured,
            in: webView
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "phoneProfile")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalInput")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var isLoaded = false
        private var pendingSnapshot: (text: String, widthMode: WidthMode, profile: TerminalProfile)?
        private var lastSnapshot: (text: String, widthMode: WidthMode, profile: TerminalProfile)?
        private var pendingReplayOutput: (base64: String, sequence: Int)?
        private var pendingOutput: (base64: String, sequence: Int)?
        private var lastReplayOutputSequence = 0
        private var lastOutputSequence = 0
        private var pendingFontSize: Int?
        private var lastFontSize: Int?
        private var onTerminalInput: (String) -> Void = { _ in }
        private var onPhoneProfileMeasured: (TerminalProfile) -> Void = { _ in }

        func loadTerminal(in webView: WKWebView) {
            guard let url = TerminalWebAssets.indexURL() else {
                webView.loadHTMLString("<pre>Unable to load terminal renderer</pre>", baseURL: nil)
                return
            }
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        func update(
            snapshotText: String,
            widthMode: WidthMode,
            profile: TerminalProfile,
            fontSize: Int,
            replayOutputBase64: String,
            replayOutputSequence: Int,
            outputBase64: String,
            outputSequence: Int,
            onTerminalInput: @escaping (String) -> Void,
            onPhoneProfileMeasured: @escaping (TerminalProfile) -> Void,
            in webView: WKWebView
        ) {
            self.onTerminalInput = onTerminalInput
            self.onPhoneProfileMeasured = onPhoneProfileMeasured
            let snapshot = (text: snapshotText, widthMode: widthMode, profile: profile)
            guard isLoaded else {
                pendingSnapshot = snapshot
                pendingFontSize = fontSize
                if replayOutputSequence > lastReplayOutputSequence {
                    pendingReplayOutput = (base64: replayOutputBase64, sequence: replayOutputSequence)
                }
                if outputSequence > lastOutputSequence {
                    pendingOutput = (base64: outputBase64, sequence: outputSequence)
                }
                return
            }
            if lastFontSize != fontSize {
                applyFontSize(fontSize, in: webView)
            }
            if lastSnapshot?.text != snapshotText ||
                lastSnapshot?.widthMode != widthMode ||
                lastSnapshot?.profile != profile {
                apply(snapshot, in: webView)
            }
            if replayOutputSequence > lastReplayOutputSequence {
                applyReplayOutput(replayOutputBase64, sequence: replayOutputSequence, in: webView)
            }
            if outputSequence > lastOutputSequence {
                applyOutput(outputBase64, sequence: outputSequence, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let pendingFontSize {
                applyFontSize(pendingFontSize, in: webView)
                self.pendingFontSize = nil
            }
            if let pendingSnapshot {
                apply(pendingSnapshot, in: webView)
                self.pendingSnapshot = nil
            }
            if let pendingReplayOutput {
                applyReplayOutput(pendingReplayOutput.base64, sequence: pendingReplayOutput.sequence, in: webView)
                self.pendingReplayOutput = nil
            }
            if let pendingOutput {
                applyOutput(pendingOutput.base64, sequence: pendingOutput.sequence, in: webView)
                self.pendingOutput = nil
            }
        }

        private func apply(_ snapshot: (text: String, widthMode: WidthMode, profile: TerminalProfile), in webView: WKWebView) {
            lastSnapshot = snapshot
            let encodedText = Self.javascriptString(snapshot.text)
            let encodedWidthMode = Self.javascriptString(snapshot.widthMode.rawValue)
            let rows = max(snapshot.profile.rows, 1)
            let cols = max(snapshot.profile.cols, 1)
            webView.evaluateJavaScript(
                "window.nudgeTerminal && window.nudgeTerminal.setSnapshot(\(encodedText), \(encodedWidthMode), \(rows), \(cols));"
            )
        }

        private func applyReplayOutput(_ base64: String, sequence: Int, in webView: WKWebView) {
            lastReplayOutputSequence = sequence
            let encodedBase64 = Self.javascriptString(base64)
            webView.evaluateJavaScript(
                "window.nudgeTerminal && window.nudgeTerminal.setReplayOutputBase64(\(encodedBase64));"
            )
        }

        private func applyOutput(_ base64: String, sequence: Int, in webView: WKWebView) {
            lastOutputSequence = sequence
            if base64.isEmpty {
                return
            }
            let encodedBase64 = Self.javascriptString(base64)
            webView.evaluateJavaScript(
                "window.nudgeTerminal && window.nudgeTerminal.writeOutputBase64(\(encodedBase64));"
            )
        }

        private func applyFontSize(_ fontSize: Int, in webView: WKWebView) {
            lastFontSize = fontSize
            webView.evaluateJavaScript(
                "window.nudgeTerminal && window.nudgeTerminal.setFontSize(\(fontSize));"
            )
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "terminalInput" {
                guard let body = message.body as? [String: Any],
                      let data = body["data"] as? String,
                      !data.isEmpty
                else {
                    return
                }
                onTerminalInput(data)
                return
            }

            guard message.name == "phoneProfile",
                  let body = message.body as? [String: Any],
                  let rows = body["rows"] as? Int,
                  let cols = body["cols"] as? Int,
                  rows > 0,
                  cols > 0
            else {
                return
            }
            onPhoneProfileMeasured(TerminalProfile(rows: rows, cols: cols))
        }

        private static func javascriptString(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let encoded = String(data: data, encoding: .utf8)
            else {
                return "\"\""
            }
            return encoded
        }
    }
}

struct AgentBadge: View {
    var status: AgentStatus

    var body: some View {
        HStack(spacing: 5) {
            Text(status.kind.rawValue)
                .foregroundStyle(Color.textMuted)
            Text(status.state.rawValue)
                .foregroundStyle(Color.accent)
        }
        .font(.system(.caption2, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.surface.opacity(0.90))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.border, lineWidth: 1)
        )
    }
}

struct FontSizeStepper: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "textformat.size")
                .foregroundStyle(Color.textMuted)
                .font(.subheadline)
            Text("Font")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.textMuted)
            Spacer()
            Button {
                model.updateFontSize(model.terminalFontSize - 1)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(StepperCapStyle())
            .disabled(model.terminalFontSize <= AppModel.minFontSize)
            .accessibilityLabel("Decrease font size")

            Text("\(model.terminalFontSize)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.textPrimary)
                .frame(minWidth: 28)
                .accessibilityLabel("Font size \(model.terminalFontSize)")

            Button {
                model.updateFontSize(model.terminalFontSize + 1)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(StepperCapStyle())
            .disabled(model.terminalFontSize >= AppModel.maxFontSize)
            .accessibilityLabel("Increase font size")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct StepperCapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.borderBright, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
