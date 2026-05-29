import Foundation

protocol RelayClient: Sendable {
    func claimBinding(code: String, relayURL: URL) async throws -> BindingClaim
    func fetchBindingStatus(binding: MachineBinding, relayURL: URL) async throws -> BindingClaim
    func fetchSessionState(machine: Machine) async throws -> RemoteSessionState
    func fetchTerminalSnapshot(machine: Machine, tabID: String) async throws -> TerminalSnapshot
    func sendTerminalInput(machine: Machine, tabID: String, text: String, enter: Bool) async throws
    func setPhoneProfile(machine: Machine, profile: TerminalProfile) async throws -> RemoteSessionState
    func setWidthMode(
        machine: Machine,
        tabID: String,
        widthMode: WidthMode,
        computerProfile: TerminalProfile
    ) async throws -> RemoteSessionState
    func openSession(machine: Machine) async throws -> any RelaySession
    func connect(machine: Machine) async throws
}

struct HTTPRelayClient: RelayClient {
    var urlSession: URLSession = .shared
    var identityStore: any PhoneIdentityStore = KeychainPhoneIdentityStore()
    var webSocketFactory: any RelayWebSocketFactory = URLSessionRelayWebSocketFactory(urlSession: .shared)
    var requestIDGenerator: @Sendable () -> String = { "ios-\(UUID().uuidString)" }

    func claimBinding(code: String, relayURL: URL) async throws -> BindingClaim {
        let identity = try identityStore.loadOrCreate()
        let device = try await registerPhone(relayURL: relayURL, phonePublicKey: identity.publicKey)
        var request = URLRequest(url: relayURL.appending(path: "/api/bind/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ClaimRequest(code: code, phoneDeviceId: device.id))
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response)
        return try decodeBindingClaim(from: data)
    }

    func fetchBindingStatus(binding: MachineBinding, relayURL: URL) async throws -> BindingClaim {
        var components = URLComponents(url: relayURL.appending(path: "/api/bind/status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "bindingId", value: binding.bindingID),
            URLQueryItem(name: "deviceId", value: binding.phoneDeviceID)
        ]
        guard let url = components?.url else {
            throw RelayClientError.badURL
        }
        let (data, response) = try await urlSession.data(from: url)
        try validate(response: response)
        return try decodeBindingClaim(from: data)
    }

    func connect(machine: Machine) async throws {
        _ = machine
    }

    func openSession(machine: Machine) async throws -> any RelaySession {
        guard let binding = machine.binding else {
            throw RelayClientError.missingBinding
        }
        let socket = try webSocketFactory.webSocket(for: relayWebSocketURL(relayURL: machine.relayURL, binding: binding))
        do {
            try await waitForConnected(socket: socket, binding: binding)
        } catch {
            socket.close()
            throw error
        }
        return HTTPRelaySession(
            socket: socket,
            daemonDeviceID: binding.daemonDeviceID,
            requestIDGenerator: requestIDGenerator
        )
    }

    func fetchSessionState(machine: Machine) async throws -> RemoteSessionState {
        let requestID = requestIDGenerator()
        let payload = try await sendDaemonRequest(
            machine: machine,
            payload: RelayGetStatePayload(requestId: requestID),
            requestID: requestID
        )
        guard let data = payload.data else {
            throw RelayClientError.invalidWebSocketMessage
        }
        return try data.toRemoteSessionState()
    }

    func fetchTerminalSnapshot(machine: Machine, tabID: String) async throws -> TerminalSnapshot {
        let requestID = requestIDGenerator()
        let payload = try await sendDaemonRequest(
            machine: machine,
            payload: RelayTerminalSnapshotPayload(requestId: requestID, tabId: tabID),
            requestID: requestID
        )
        guard let snapshot = payload.data?.snapshot else {
            throw RelayClientError.invalidWebSocketMessage
        }
        return TerminalSnapshot(
            tabID: snapshot.tabId,
            profile: TerminalProfile(rows: snapshot.rows, cols: snapshot.cols),
            text: snapshot.text
        )
    }

    func sendTerminalInput(machine: Machine, tabID: String, text: String, enter: Bool) async throws {
        let requestID = requestIDGenerator()
        _ = try await sendDaemonRequest(
            machine: machine,
            payload: RelayTerminalInputPayload(
                requestId: requestID,
                tabId: tabID,
                text: text,
                enter: enter
            ),
            requestID: requestID
        )
    }

    func setPhoneProfile(machine: Machine, profile: TerminalProfile) async throws -> RemoteSessionState {
        let requestID = requestIDGenerator()
        let payload = try await sendDaemonRequest(
            machine: machine,
            payload: RelaySetPhoneProfilePayload(requestId: requestID, rows: profile.rows, cols: profile.cols),
            requestID: requestID
        )
        guard let data = payload.data else {
            throw RelayClientError.invalidWebSocketMessage
        }
        return try data.toRemoteSessionState()
    }

    func setWidthMode(
        machine: Machine,
        tabID: String,
        widthMode: WidthMode,
        computerProfile: TerminalProfile
    ) async throws -> RemoteSessionState {
        let requestID = requestIDGenerator()
        let payload = try await sendDaemonRequest(
            machine: machine,
            payload: RelaySetWidthModePayload(
                requestId: requestID,
                tabId: tabID,
                mode: widthMode.rawValue,
                computerRows: computerProfile.rows,
                computerCols: computerProfile.cols
            ),
            requestID: requestID
        )
        guard let data = payload.data else {
            throw RelayClientError.invalidWebSocketMessage
        }
        return try data.toRemoteSessionState()
    }

    private func registerPhone(relayURL: URL, phonePublicKey: String) async throws -> DeviceResponse.Device {
        var request = URLRequest(url: relayURL.appending(path: "/api/devices/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DeviceRequest(kind: "phone", publicKey: phonePublicKey))
        let (data, response) = try await urlSession.data(for: request)
        try validate(response: response)
        return try JSONDecoder().decode(DeviceResponse.self, from: data).device
    }

    private func decodeBindingClaim(from data: Data) throws -> BindingClaim {
        let binding = try JSONDecoder().decode(BindingResponse.self, from: data).binding
        guard let phoneDeviceID = binding.phoneDeviceId else {
            throw RelayClientError.missingPhoneDeviceID
        }
        return BindingClaim(
            bindingID: binding.id,
            daemonDeviceID: binding.daemonDeviceId,
            phoneDeviceID: phoneDeviceID,
            status: binding.status,
            expiresAt: binding.expiresAt
        )
    }

    private func relayWebSocketURL(relayURL: URL, binding: MachineBinding) throws -> URL {
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)
        switch components?.scheme {
        case "https":
            components?.scheme = "wss"
        case "http":
            components?.scheme = "ws"
        default:
            throw RelayClientError.badURL
        }
        components?.path = "/ws/mobile"
        components?.queryItems = [
            URLQueryItem(name: "deviceId", value: binding.phoneDeviceID),
            URLQueryItem(name: "bindingId", value: binding.bindingID)
        ]
        guard let url = components?.url else {
            throw RelayClientError.badURL
        }
        return url
    }

    private func waitForConnected(socket: any RelayWebSocketTransport, binding: MachineBinding) async throws {
        while true {
            let text = try await socket.receiveString()
            let message = try JSONDecoder().decode(RelaySocketIncoming.self, from: Data(text.utf8))
            if message.type == "connected",
               message.deviceId == binding.phoneDeviceID,
               message.bindingId == binding.bindingID {
                return
            }
            if message.type == "error" {
                throw RelayClientError.daemonRejected(message.error ?? "relay websocket error")
            }
        }
    }

    private func sendDaemonRequest<Payload: Encodable>(
        machine: Machine,
        payload: Payload,
        requestID: String
    ) async throws -> RelayDaemonPayload {
        guard let binding = machine.binding else {
            throw RelayClientError.missingBinding
        }
        let socket = try webSocketFactory.webSocket(for: relayWebSocketURL(relayURL: machine.relayURL, binding: binding))
        defer {
            socket.close()
        }
        let request = RelaySocketRequest(
            toDeviceId: binding.daemonDeviceID,
            payload: payload
        )
        try await waitForConnected(socket: socket, binding: binding)
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RelayClientError.invalidWebSocketMessage
        }
        try await socket.sendString(text)
        return try await waitForDaemonResponse(socket: socket, requestID: requestID)
    }

    private func waitForDaemonResponse(socket: any RelayWebSocketTransport, requestID: String) async throws -> RelayDaemonPayload {
        while true {
            let text = try await socket.receiveString()
            let message = try JSONDecoder().decode(RelaySocketIncoming.self, from: Data(text.utf8))
            if message.type == "error" {
                throw RelayClientError.daemonRejected(message.error ?? "relay websocket error")
            }
            guard message.type == "message",
                  let payload = message.message?.payload,
                  payload.type == "daemon_response",
                  payload.requestId == requestID
            else {
                continue
            }
            guard payload.ok else {
                throw RelayClientError.daemonRejected(payload.data?.error ?? "daemon rejected request")
            }
            return payload
        }
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              200 ..< 300 ~= http.statusCode
        else {
            throw RelayClientError.badStatus
        }
    }
}

enum RelayClientError: Error {
    case badURL
    case badStatus
    case daemonRejected(String)
    case invalidWebSocketMessage
    case missingBinding
    case missingPhoneDeviceID
    case unsupportedRelayValue(String)
}

struct BindingClaim: Equatable, Sendable {
    var bindingID: String
    var daemonDeviceID: String
    var phoneDeviceID: String
    var status: BindingStatus
    var expiresAt: String
}

struct RemoteSessionState: Equatable, Sendable {
    var tabs: [TerminalTab]
}

struct TerminalSnapshot: Equatable, Sendable {
    var tabID: String
    var profile: TerminalProfile
    var text: String
}

enum RelaySessionEvent: Equatable, Sendable {
    case sessionState(RemoteSessionState)
    case terminalSnapshot(TerminalSnapshot)
    case terminalInputAccepted(tabID: String?)
}

protocol RelaySession: Sendable {
    func requestSessionState() async throws
    func requestTerminalSnapshot(tabID: String) async throws
    func sendTerminalInput(tabID: String, text: String, enter: Bool) async throws
    func setPhoneProfile(_ profile: TerminalProfile) async throws
    func setWidthMode(tabID: String, widthMode: WidthMode, computerProfile: TerminalProfile) async throws
    func receiveEvent() async throws -> RelaySessionEvent
    func close()
}

protocol RelayWebSocketTransport: Sendable {
    func sendString(_ value: String) async throws
    func receiveString() async throws -> String
    func close()
}

protocol RelayWebSocketFactory: Sendable {
    func webSocket(for url: URL) throws -> any RelayWebSocketTransport
}

struct URLSessionRelayWebSocketFactory: RelayWebSocketFactory, @unchecked Sendable {
    var urlSession: URLSession

    func webSocket(for url: URL) throws -> any RelayWebSocketTransport {
        let task = urlSession.webSocketTask(with: url)
        task.resume()
        return URLSessionRelayWebSocketTransport(task: task)
    }
}

struct URLSessionRelayWebSocketTransport: RelayWebSocketTransport, @unchecked Sendable {
    var task: URLSessionWebSocketTask

    func sendString(_ value: String) async throws {
        try await task.send(.string(value))
    }

    func receiveString() async throws -> String {
        let message = try await task.receive()
        switch message {
        case .string(let value):
            return value
        case .data(let data):
            guard let value = String(data: data, encoding: .utf8) else {
                throw RelayClientError.invalidWebSocketMessage
            }
            return value
        @unknown default:
            throw RelayClientError.invalidWebSocketMessage
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

private enum RelaySessionRequestKind: Sendable {
    case sessionState
    case terminalSnapshot
    case terminalInput(tabID: String)
}

private final class HTTPRelaySession: RelaySession, @unchecked Sendable {
    private let socket: any RelayWebSocketTransport
    private let daemonDeviceID: String
    private let requestIDGenerator: @Sendable () -> String
    private let lock = NSLock()
    private var requestKinds: [String: RelaySessionRequestKind] = [:]

    init(
        socket: any RelayWebSocketTransport,
        daemonDeviceID: String,
        requestIDGenerator: @escaping @Sendable () -> String
    ) {
        self.socket = socket
        self.daemonDeviceID = daemonDeviceID
        self.requestIDGenerator = requestIDGenerator
    }

    func requestSessionState() async throws {
        let requestID = requestIDGenerator()
        try await rememberAndSend(
            kind: .sessionState,
            requestID: requestID,
            payload: RelayGetStatePayload(requestId: requestID)
        )
    }

    func requestTerminalSnapshot(tabID: String) async throws {
        let requestID = requestIDGenerator()
        try await rememberAndSend(
            kind: .terminalSnapshot,
            requestID: requestID,
            payload: RelayTerminalSnapshotPayload(requestId: requestID, tabId: tabID)
        )
    }

    func sendTerminalInput(tabID: String, text: String, enter: Bool) async throws {
        let requestID = requestIDGenerator()
        try await rememberAndSend(
            kind: .terminalInput(tabID: tabID),
            requestID: requestID,
            payload: RelayTerminalInputPayload(
                requestId: requestID,
                tabId: tabID,
                text: text,
                enter: enter
            )
        )
    }

    func setPhoneProfile(_ profile: TerminalProfile) async throws {
        let requestID = requestIDGenerator()
        try await rememberAndSend(
            kind: .sessionState,
            requestID: requestID,
            payload: RelaySetPhoneProfilePayload(requestId: requestID, rows: profile.rows, cols: profile.cols)
        )
    }

    func setWidthMode(tabID: String, widthMode: WidthMode, computerProfile: TerminalProfile) async throws {
        let requestID = requestIDGenerator()
        try await rememberAndSend(
            kind: .sessionState,
            requestID: requestID,
            payload: RelaySetWidthModePayload(
                requestId: requestID,
                tabId: tabID,
                mode: widthMode.rawValue,
                computerRows: computerProfile.rows,
                computerCols: computerProfile.cols
            )
        )
    }

    func receiveEvent() async throws -> RelaySessionEvent {
        while true {
            let text = try await socket.receiveString()
            let message = try JSONDecoder().decode(RelaySocketIncoming.self, from: Data(text.utf8))
            if message.type == "error" {
                throw RelayClientError.daemonRejected(message.error ?? "relay websocket error")
            }
            guard message.type == "message",
                  let payload = message.message?.payload,
                  payload.type == "daemon_response"
            else {
                continue
            }
            guard payload.ok else {
                throw RelayClientError.daemonRejected(payload.data?.error ?? "daemon rejected request")
            }
            let requestKind = payload.requestId.flatMap(takeRequestKind)
            return try event(from: payload, requestKind: requestKind)
        }
    }

    func close() {
        socket.close()
    }

    private func rememberAndSend<Payload: Encodable>(
        kind: RelaySessionRequestKind,
        requestID: String,
        payload: Payload
    ) async throws {
        lock.withLock {
            requestKinds[requestID] = kind
        }
        let request = RelaySocketRequest(
            toDeviceId: daemonDeviceID,
            payload: payload
        )
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RelayClientError.invalidWebSocketMessage
        }
        do {
            try await socket.sendString(text)
        } catch {
            _ = takeRequestKind(requestID: requestID)
            throw error
        }
    }

    private func takeRequestKind(requestID: String) -> RelaySessionRequestKind? {
        lock.withLock {
            requestKinds.removeValue(forKey: requestID)
        }
    }

    private func event(
        from payload: RelayDaemonPayload,
        requestKind: RelaySessionRequestKind?
    ) throws -> RelaySessionEvent {
        switch requestKind {
        case .sessionState:
            guard let data = payload.data else {
                throw RelayClientError.invalidWebSocketMessage
            }
            return try .sessionState(data.toRemoteSessionState())
        case .terminalSnapshot:
            guard let snapshot = payload.data?.snapshot else {
                throw RelayClientError.invalidWebSocketMessage
            }
            return .terminalSnapshot(TerminalSnapshot(
                tabID: snapshot.tabId,
                profile: TerminalProfile(rows: snapshot.rows, cols: snapshot.cols),
                text: snapshot.text
            ))
        case .terminalInput(let tabID):
            return .terminalInputAccepted(tabID: tabID)
        case nil:
            return try fallbackEvent(from: payload)
        }
    }

    private func fallbackEvent(from payload: RelayDaemonPayload) throws -> RelaySessionEvent {
        guard let data = payload.data else {
            throw RelayClientError.invalidWebSocketMessage
        }
        if data.tabs != nil {
            return try .sessionState(data.toRemoteSessionState())
        }
        if let snapshot = data.snapshot {
            return .terminalSnapshot(TerminalSnapshot(
                tabID: snapshot.tabId,
                profile: TerminalProfile(rows: snapshot.rows, cols: snapshot.cols),
                text: snapshot.text
            ))
        }
        if data.accepted == true {
            return .terminalInputAccepted(tabID: nil)
        }
        throw RelayClientError.invalidWebSocketMessage
    }
}

private struct DeviceRequest: Encodable {
    var kind: String
    var publicKey: String
}

private struct DeviceResponse: Decodable {
    struct Device: Decodable {
        var id: String
    }

    var device: Device
}

private struct BindingResponse: Decodable {
    struct Binding: Decodable {
        var id: String
        var daemonDeviceId: String
        var phoneDeviceId: String?
        var status: BindingStatus
        var expiresAt: String
    }

    var binding: Binding
}

private struct ClaimRequest: Encodable {
    var code: String
    var phoneDeviceId: String
}

private struct RelaySocketRequest<Payload: Encodable>: Encodable {
    var toDeviceId: String
    var payload: Payload
}

private struct RelayGetStatePayload: Encodable {
    let type = "get_state"
    var requestId: String
}

private struct RelayTerminalSnapshotPayload: Encodable {
    let type = "terminal_snapshot"
    var requestId: String
    var tabId: String
}

private struct RelayTerminalInputPayload: Encodable {
    let type = "terminal_input"
    var requestId: String
    var tabId: String
    var text: String
    var enter: Bool
}

private struct RelaySetPhoneProfilePayload: Encodable {
    let type = "set_phone_profile"
    var requestId: String
    var rows: Int
    var cols: Int
}

private struct RelaySetWidthModePayload: Encodable {
    let type = "set_width_mode"
    var requestId: String
    var tabId: String
    var mode: String
    var computerRows: Int
    var computerCols: Int
}

private struct RelaySocketIncoming: Decodable {
    var type: String
    var deviceId: String?
    var bindingId: String?
    var error: String?
    var message: RelaySocketRoutedMessage?
}

private struct RelaySocketRoutedMessage: Decodable {
    var payload: RelayDaemonPayload
}

private struct RelayDaemonPayload: Decodable {
    var type: String
    var requestId: String?
    var ok: Bool
    var data: RelayDaemonDataResponse?
}

private struct RelayDaemonDataResponse: Decodable {
    var tabs: [RelayTabResponse]?
    var tabId: String?
    var rows: Int?
    var cols: Int?
    var text: String?
    var accepted: Bool?
    var error: String?

    func toRemoteSessionState() throws -> RemoteSessionState {
        let tabs = try (tabs ?? []).map { try $0.toTerminalTab() }
        return RemoteSessionState(tabs: tabs)
    }

    var snapshot: RelayTerminalSnapshotResponse? {
        guard let tabId, let rows, let cols, let text else {
            return nil
        }
        return RelayTerminalSnapshotResponse(tabId: tabId, rows: rows, cols: cols, text: text)
    }
}

private struct RelayTerminalSnapshotResponse: Decodable {
    var tabId: String
    var rows: Int
    var cols: Int
    var text: String
}

private struct RelayTabResponse: Decodable {
    var id: String
    var title: String
    var status: String
    var widthMode: String
    var rows: Int
    var cols: Int
    var agentStatus: RelayAgentStatusResponse?

    func toTerminalTab() throws -> TerminalTab {
        TerminalTab(
            id: id,
            title: title,
            state: try TabRunState(relayValue: status),
            widthMode: try WidthMode(relayValue: widthMode),
            profile: TerminalProfile(rows: rows, cols: cols),
            agentStatus: try agentStatus?.toAgentStatus() ?? AgentStatus(
                kind: .unknown,
                state: .idle,
                confidence: 0,
                source: "unknown"
            ),
            previewText: "Relay session attached\nWaiting for terminal snapshot..."
        )
    }
}

private struct RelayAgentStatusResponse: Decodable {
    var kind: String
    var state: String
    var confidence: Double
    var source: String

    func toAgentStatus() throws -> AgentStatus {
        AgentStatus(
            kind: AgentKind(relayValue: kind),
            state: try AgentInteractionState(relayValue: state),
            confidence: confidence,
            source: source
        )
    }
}

private extension TabRunState {
    init(relayValue: String) throws {
        switch relayValue {
        case "running":
            self = .running
        case "exited":
            self = .exited
        case "needs_attention":
            self = .needsAttention
        case "needs_restart":
            self = .needsRestart
        default:
            throw RelayClientError.unsupportedRelayValue(relayValue)
        }
    }
}

private extension WidthMode {
    init(relayValue: String) throws {
        switch relayValue {
        case "phone":
            self = .phone
        case "computer":
            self = .computer
        default:
            throw RelayClientError.unsupportedRelayValue(relayValue)
        }
    }
}

private extension AgentKind {
    init(relayValue: String) {
        self = AgentKind(rawValue: relayValue) ?? .unknown
    }
}

private extension AgentInteractionState {
    init(relayValue: String) throws {
        switch relayValue {
        case "running":
            self = .running
        case "idle":
            self = .idle
        case "waiting_for_input":
            self = .waitingForInput
        case "needs_approval":
            self = .needsApproval
        case "needs_attention":
            self = .needsAttention
        case "exited":
            self = .exited
        default:
            throw RelayClientError.unsupportedRelayValue(relayValue)
        }
    }
}
