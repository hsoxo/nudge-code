import SwiftUI
import WebKit

struct TerminalWorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TabStripView()
            Divider()
            if model.selectedMachine?.lastSeenText == "relay session reconnecting" {
                RelayReconnectBanner()
                Divider()
            }
            if let tab = model.selectedTab {
                TerminalView(tab: tab)
                Divider()
                WidthModePicker(tab: tab)
                Divider()
                ShortcutKeyboardView(tab: tab)
            } else {
                ContentUnavailableView("No Tabs", systemImage: "terminal")
            }
        }
        .navigationTitle(model.selectedMachine?.name ?? "Nudge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .task(id: model.selectedMachineID) {
            await model.refreshSelectedMachineBinding()
            await model.syncSelectedMachineSession()
        }
    }
}

struct RelayReconnectBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text("Reconnecting to relay")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

struct TabStripView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.selectedTabs) { tab in
                    Button {
                        model.selectTab(tab)
                    } label: {
                        HStack(spacing: 6) {
                            statusDot(for: tab)
                            Text(tab.title)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(tab.id == model.selectedTab?.id ? Color.accentColor.opacity(0.16) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func statusDot(for tab: TerminalTab) -> some View {
        Circle()
            .fill(tab.agentStatus.state == .needsApproval ? Color.orange : Color.green)
            .frame(width: 8, height: 8)
    }
}

struct TerminalView: View {
    var tab: TerminalTab

    var body: some View {
        TerminalWebView(
            snapshotText: tab.previewText,
            widthMode: tab.widthMode,
            outputText: tab.pendingOutputText,
            outputSequence: tab.outputSequence
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
    var outputText: String
    var outputSequence: Int

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
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
            outputText: outputText,
            outputSequence: outputSequence,
            in: webView
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var isLoaded = false
        private var pendingSnapshot: (text: String, widthMode: WidthMode)?
        private var lastSnapshot: (text: String, widthMode: WidthMode)?
        private var pendingOutput: (text: String, sequence: Int)?
        private var lastOutputSequence = 0

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
            outputText: String,
            outputSequence: Int,
            in webView: WKWebView
        ) {
            let snapshot = (text: snapshotText, widthMode: widthMode)
            guard isLoaded else {
                pendingSnapshot = snapshot
                if outputSequence > lastOutputSequence {
                    pendingOutput = (text: outputText, sequence: outputSequence)
                }
                return
            }
            if lastSnapshot?.text != snapshotText || lastSnapshot?.widthMode != widthMode {
                apply(snapshot, in: webView)
            }
            if outputSequence > lastOutputSequence {
                applyOutput(outputText, sequence: outputSequence, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let pendingSnapshot {
                apply(pendingSnapshot, in: webView)
                self.pendingSnapshot = nil
            }
            if let pendingOutput {
                applyOutput(pendingOutput.text, sequence: pendingOutput.sequence, in: webView)
                self.pendingOutput = nil
            }
        }

        private func apply(_ snapshot: (text: String, widthMode: WidthMode), in webView: WKWebView) {
            lastSnapshot = snapshot
            let encodedText = Self.javascriptString(snapshot.text)
            let encodedWidthMode = Self.javascriptString(snapshot.widthMode.rawValue)
            webView.evaluateJavaScript(
                "window.nudgeTerminal && window.nudgeTerminal.setSnapshot(\(encodedText), \(encodedWidthMode));"
            )
        }

        private func applyOutput(_ text: String, sequence: Int, in webView: WKWebView) {
            lastOutputSequence = sequence
            let encodedText = Self.javascriptString(text)
            webView.evaluateJavaScript(
                "window.nudgeTerminal && window.nudgeTerminal.writeOutput(\(encodedText));"
            )
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
        HStack(spacing: 6) {
            Text(status.kind.rawValue)
            Text(status.state.rawValue)
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.72))
        .clipShape(Capsule())
    }
}

struct WidthModePicker: View {
    @Environment(AppModel.self) private var model
    var tab: TerminalTab

    var body: some View {
        @Bindable var model = model
        Picker("Width", selection: Binding(
            get: { tab.widthMode },
            set: { widthMode in
                Task {
                    await model.updateSelectedTabWidth(widthMode)
                }
            }
        )) {
            Text("Phone").tag(WidthMode.phone)
            Text("Computer").tag(WidthMode.computer)
        }
        .pickerStyle(.segmented)
        .padding(12)
    }
}
