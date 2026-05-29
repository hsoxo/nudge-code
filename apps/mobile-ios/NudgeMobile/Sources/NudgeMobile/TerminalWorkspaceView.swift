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
        TerminalWebView(text: tab.previewText, widthMode: tab.widthMode)
            .background(Color.black)
            .overlay(alignment: .topTrailing) {
                AgentBadge(status: tab.agentStatus)
                    .padding(10)
            }
    }
}

struct TerminalWebView: UIViewRepresentable {
    var text: String
    var widthMode: WidthMode

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.isOpaque = false
        webView.scrollView.bounces = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }

    private var html: String {
        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let minWidth = widthMode == .computer ? "900px" : "100%"
        return """
        <!doctype html>
        <html>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
        html, body { margin: 0; height: 100%; background: #050505; color: #E6E8EA; }
        body { overflow: auto; }
        pre {
          box-sizing: border-box;
          min-width: \(minWidth);
          min-height: 100vh;
          margin: 0;
          padding: 16px;
          font: 13px ui-monospace, SFMono-Regular, Menlo, monospace;
          line-height: 1.45;
          white-space: pre-wrap;
        }
        </style>
        <body><pre>\(escapedText)</pre></body>
        </html>
        """
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
