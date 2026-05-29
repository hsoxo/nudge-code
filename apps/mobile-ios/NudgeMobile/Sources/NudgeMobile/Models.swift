import Foundation

enum ConnectionState: String, Codable, Sendable {
    case offline
    case connecting
    case online
}

enum TabRunState: String, Codable, Sendable {
    case running
    case exited
    case needsAttention
    case needsRestart
}

enum WidthMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case phone
    case computer

    var id: String { rawValue }
}

enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case shell
    case claude
    case codex
    case opencode
    case openclaw
    case unknown

    var id: String { rawValue }
}

enum AgentInteractionState: String, Codable, Sendable {
    case running
    case idle
    case waitingForInput
    case needsApproval
    case needsAttention
    case exited
}

struct AgentStatus: Codable, Equatable, Sendable {
    var kind: AgentKind
    var state: AgentInteractionState
    var confidence: Double
    var source: String
}

struct TerminalProfile: Codable, Equatable, Sendable {
    var rows: Int
    var cols: Int
}

struct Machine: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var relayURL: URL
    var connectionState: ConnectionState
    var lastSeenText: String
}

struct TerminalTab: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var state: TabRunState
    var widthMode: WidthMode
    var profile: TerminalProfile
    var agentStatus: AgentStatus
    var previewText: String
}

struct BindingDraft: Equatable, Sendable {
    var code: String
    var relayURL: URL

    init?(pairingURL: URL) {
        guard pairingURL.path == "/pair",
              let components = URLComponents(url: pairingURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            return nil
        }
        self.code = code
        self.relayURL = URL(string: "\(pairingURL.scheme ?? "https")://\(pairingURL.host ?? "nudgecode.dev")") ?? pairingURL
    }
}
