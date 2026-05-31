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
    var binding: MachineBinding?
}

struct MachineBinding: Codable, Equatable, Sendable {
    var bindingID: String
    var daemonDeviceID: String
    var phoneDeviceID: String
    var daemonPublicKey: String?
    var phonePublicKey: String?
    var status: BindingStatus
    var expiresAt: String

    init(
        bindingID: String,
        daemonDeviceID: String,
        phoneDeviceID: String,
        daemonPublicKey: String? = nil,
        phonePublicKey: String? = nil,
        status: BindingStatus,
        expiresAt: String
    ) {
        self.bindingID = bindingID
        self.daemonDeviceID = daemonDeviceID
        self.phoneDeviceID = phoneDeviceID
        self.daemonPublicKey = daemonPublicKey
        self.phonePublicKey = phonePublicKey
        self.status = status
        self.expiresAt = expiresAt
    }

    init(claim: BindingClaim) {
        self.init(
            bindingID: claim.bindingID,
            daemonDeviceID: claim.daemonDeviceID,
            phoneDeviceID: claim.phoneDeviceID,
            daemonPublicKey: claim.daemonPublicKey,
            phonePublicKey: claim.phonePublicKey,
            status: claim.status,
            expiresAt: claim.expiresAt
        )
    }
}

enum BindingStatus: String, Codable, Sendable {
    case pending
    case claimed
    case active
    case revoked
}

struct TerminalTab: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var state: TabRunState
    var widthMode: WidthMode
    var profile: TerminalProfile
    var agentStatus: AgentStatus
    var previewText: String
    // Backed by raw Data so the live-delta append doesn't decode + re-encode the
    // whole buffer each time (it appends to replayOutputData — see
    // AppModel.applyTerminalOutput); base64 is computed lazily for the WebView
    // bridge. Transient (never persisted/wire-encoded), so the field-type change
    // is safe; Codable synthesizes over replayOutputData.
    var replayOutputData: Data = Data()
    var replayOutputBase64: String {
        get { replayOutputData.base64EncodedString() }
        set { replayOutputData = Data(base64Encoded: newValue) ?? Data() }
    }
    var replayOutputSequence: Int = 0
    var pendingOutputBase64: String = ""
    var outputSequence: Int = 0
}

struct BindingDraft: Equatable, Sendable {
    var code: String
    var relayURL: URL

    init(code: String, relayURL: URL) {
        self.code = code
        self.relayURL = relayURL
    }

    init?(pairingURL: URL) {
        guard let components = URLComponents(url: pairingURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty
        else {
            return nil
        }
        if pairingURL.scheme == "nudge", pairingURL.host == "pair" {
            guard let relay = components.queryItems?.first(where: { $0.name == "relay" })?.value,
                  let relayURL = URL(string: relay),
                  relayURL.scheme == "https" || relayURL.scheme == "http",
                  relayURL.host != nil
            else {
                return nil
            }
            self.code = code
            self.relayURL = relayURL.normalizedRelayURL
            return
        }
        guard pairingURL.path == "/pair" else {
            return nil
        }
        self.code = code
        self.relayURL = pairingURL.normalizedRelayURL
    }
}

private extension URL {
    var normalizedRelayURL: URL {
        var components = URLComponents()
        components.scheme = scheme ?? "https"
        components.host = host ?? "nudgecode.dev"
        components.port = port
        return components.url ?? self
    }
}

enum BindingClaimState: Equatable, Sendable {
    case idle
    case claiming
    case claimed
    case failed(String)

    var isClaiming: Bool {
        if case .claiming = self {
            return true
        }
        return false
    }
}

struct RelaySyncTaskID: Equatable {
    var machineID: String?
    var generation: Int
}
