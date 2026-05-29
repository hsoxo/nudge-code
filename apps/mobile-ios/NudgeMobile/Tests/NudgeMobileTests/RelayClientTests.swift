import Foundation
import Testing
@testable import NudgeMobile

@Suite("Relay client")
struct RelayClientTests {
    @Test func claimBindingRegistersPhoneThenClaimsCode() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [
            StubResponse(
                path: "/api/devices/register",
                data: #"{"device":{"id":"phone_1"}}"#.data(using: .utf8)!
            ),
            StubResponse(
                path: "/api/bind/claim",
                data: #"{"binding":{"id":"bind_1","daemonDeviceId":"daemon_1","phoneDeviceId":"phone_1","status":"claimed","expiresAt":"2026-05-29T00:00:00Z"}}"#.data(using: .utf8)!
            )
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let identityStore = MemoryPhoneIdentityStore(publicKey: "phone-public-key")
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: identityStore
        )

        let claim = try await client.claimBinding(code: "pair-123", relayURL: URL(string: "https://relay.test")!)

        #expect(claim == BindingClaim(
            bindingID: "bind_1",
            daemonDeviceID: "daemon_1",
            phoneDeviceID: "phone_1",
            status: .claimed,
            expiresAt: "2026-05-29T00:00:00Z"
        ))
        #expect(URLProtocolStub.requests.map(\.url?.path) == ["/api/devices/register", "/api/bind/claim"])
        let bodies = URLProtocolStub.requests.compactMap(\.httpBodyString)
        #expect(bodies[0].contains(#""kind":"phone""#))
        #expect(bodies[0].contains(#""publicKey":"phone-public-key""#))
        #expect(bodies[1].contains(#""code":"pair-123""#))
        #expect(bodies[1].contains(#""phoneDeviceId":"phone_1""#))
    }

    @Test func fetchBindingStatusUsesPhoneDeviceAsParticipant() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [
            StubResponse(
                path: "/api/bind/status",
                data: #"{"binding":{"id":"bind_1","daemonDeviceId":"daemon_1","phoneDeviceId":"phone_1","status":"active","expiresAt":"2026-05-29T00:00:00Z"}}"#.data(using: .utf8)!
            )
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key")
        )

        let claim = try await client.fetchBindingStatus(
            binding: MachineBinding(
                bindingID: "bind_1",
                daemonDeviceID: "daemon_1",
                phoneDeviceID: "phone_1",
                status: .claimed,
                expiresAt: "2026-05-29T00:00:00Z"
            ),
            relayURL: URL(string: "https://relay.test")!
        )

        #expect(claim.status == .active)
        #expect(URLProtocolStub.requests.map(\.url?.path) == ["/api/bind/status"])
        #expect(URLProtocolStub.requests.first?.url?.query == "bindingId=bind_1&deviceId=phone_1")
    }

    @Test func fetchSessionStateConnectsMobileSocketAndRequestsState() async throws {
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"ios-fixed","ok":true,"data":{"tabs":[{"id":"default","title":"Claude","status":"running","widthMode":"phone","rows":32,"cols":48,"agentStatus":{"kind":"claude","state":"needs_approval","confidence":0.82,"source":"screen"}}]}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: .ephemeral),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { "ios-fixed" }
        )

        let state = try await client.fetchSessionState(machine: activeMachine)

        assertSignedWebSocketURL(factory.urls.first)
        #expect(socket.sent.count == 1)
        #expect(socket.sent[0].contains(#""toDeviceId":"daemon_1""#))
        #expect(socket.sent[0].contains(#""type":"get_state""#))
        #expect(socket.sent[0].contains(#""requestId":"ios-fixed""#))
        #expect(socket.closed)
        #expect(state.tabs == [
            TerminalTab(
                id: "default",
                title: "Claude",
                state: .running,
                widthMode: .phone,
                profile: TerminalProfile(rows: 32, cols: 48),
                agentStatus: AgentStatus(kind: .claude, state: .needsApproval, confidence: 0.82, source: "screen"),
                previewText: "Relay session attached\nWaiting for terminal snapshot..."
            )
        ])
    }

    @Test func sendTerminalInputSendsRelayControlRequest() async throws {
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"ios-input","ok":true,"data":{"accepted":true}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: .ephemeral),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { "ios-input" }
        )

        try await client.sendTerminalInput(machine: activeMachine, tabID: "default", text: "echo hi", enter: true)

        assertSignedWebSocketURL(factory.urls.first)
        #expect(socket.sent.count == 1)
        #expect(socket.sent[0].contains(#""toDeviceId":"daemon_1""#))
        #expect(socket.sent[0].contains(#""type":"terminal_input""#))
        #expect(socket.sent[0].contains(#""requestId":"ios-input""#))
        #expect(socket.sent[0].contains(#""tabId":"default""#))
        #expect(socket.sent[0].contains(#""text":"echo hi""#))
        #expect(socket.sent[0].contains(#""enter":true"#))
        #expect(socket.closed)
    }

    @Test func fetchTerminalSnapshotRequestsSelectedTabSnapshot() async throws {
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"ios-snapshot","ok":true,"data":{"tabId":"default","rows":24,"cols":80,"text":"$ echo hi\nhi"}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: .ephemeral),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { "ios-snapshot" }
        )

        let snapshot = try await client.fetchTerminalSnapshot(machine: activeMachine, tabID: "default")

        assertSignedWebSocketURL(factory.urls.first)
        #expect(socket.sent.count == 1)
        #expect(socket.sent[0].contains(#""type":"terminal_snapshot""#))
        #expect(socket.sent[0].contains(#""requestId":"ios-snapshot""#))
        #expect(socket.sent[0].contains(#""tabId":"default""#))
        #expect(snapshot == TerminalSnapshot(
            tabID: "default",
            profile: TerminalProfile(rows: 24, cols: 80),
            text: "$ echo hi\nhi"
        ))
        #expect(socket.closed)
    }

    @Test func openSessionReusesMobileSocketForMultipleRequests() async throws {
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"session-1","ok":true,"data":{"tabs":[{"id":"default","title":"Claude","status":"running","widthMode":"phone","rows":32,"cols":48,"agentStatus":{"kind":"claude","state":"needs_approval","confidence":0.82,"source":"screen"}}]}}}}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"output-1","ok":true,"data":{"tabId":"default","bytesBase64":"Q2xhdWRlIHJlYWR5"}}}}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"input-1","ok":true,"data":{"accepted":true}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let requestIDs = RequestIDSequence(["session-1", "output-1", "input-1"])
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: .ephemeral),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { requestIDs.next() }
        )

        let session = try await client.openSession(machine: activeMachine)
        try await session.requestSessionState()
        let stateEvent = try await session.receiveEvent()
        try await session.requestTerminalOutput(tabID: "default", maxBytes: 4096)
        let outputEvent = try await session.receiveEvent()
        try await session.sendTerminalInput(tabID: "default", text: "echo hi", enter: true)
        let inputEvent = try await session.receiveEvent()
        session.close()

        assertSignedWebSocketURL(factory.urls.first)
        #expect(socket.sent.count == 3)
        #expect(socket.sent[0].contains(#""type":"get_state""#))
        #expect(socket.sent[1].contains(#""type":"terminal_output""#))
        #expect(socket.sent[1].contains(#""maxBytes":4096"#))
        #expect(socket.sent[2].contains(#""type":"terminal_input""#))
        #expect(socket.closed)
        guard case .sessionState(let state) = stateEvent else {
            Issue.record("Expected session state event")
            return
        }
        #expect(state.tabs.first?.id == "default")
        #expect(outputEvent == .terminalOutput(TerminalOutput(
            tabID: "default",
            text: "Claude ready"
        )))
        #expect(inputEvent == .terminalInputAccepted(tabID: "default"))
    }

    @Test func openSessionAcceptsUnsolicitedLiveTerminalSnapshot() async throws {
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","ok":true,"data":{"tabId":"default","rows":24,"cols":80,"text":"live update"}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: .ephemeral),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { "unused" }
        )

        let session = try await client.openSession(machine: activeMachine)
        let event = try await session.receiveEvent()
        session.close()

        #expect(socket.sent.isEmpty)
        #expect(event == .terminalSnapshot(TerminalSnapshot(
            tabID: "default",
            profile: TerminalProfile(rows: 24, cols: 80),
            text: "live update"
        )))
    }

    @Test func openSessionAcceptsUnsolicitedTerminalOutputBytes() async throws {
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","ok":true,"data":{"tabId":"default","bytesBase64":"G1szMW1yZWQK"}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: .ephemeral),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { "unused" }
        )

        let session = try await client.openSession(machine: activeMachine)
        let event = try await session.receiveEvent()
        session.close()

        #expect(socket.sent.isEmpty)
        #expect(event == .terminalOutput(TerminalOutput(
            tabID: "default",
            text: "\u{001B}[31mred\n"
        )))
    }

    @Test func setPhoneProfileSendsRelayControlRequest() async throws {
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"profile-1","ok":true,"data":{"tabs":[{"id":"default","title":"shell","status":"running","widthMode":"phone","rows":34,"cols":52}]}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: .ephemeral),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { "profile-1" }
        )

        let state = try await client.setPhoneProfile(
            machine: activeMachine,
            profile: TerminalProfile(rows: 34, cols: 52)
        )

        #expect(socket.sent.count == 1)
        #expect(socket.sent[0].contains(#""type":"set_phone_profile""#))
        #expect(socket.sent[0].contains(#""rows":34"#))
        #expect(socket.sent[0].contains(#""cols":52"#))
        #expect(state.tabs.first?.profile == TerminalProfile(rows: 34, cols: 52))
        #expect(socket.closed)
    }

    @Test func setWidthModeSendsRelayControlRequest() async throws {
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"width-1","ok":true,"data":{"tabs":[{"id":"default","title":"shell","status":"running","widthMode":"computer","rows":24,"cols":100}]}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: .ephemeral),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { "width-1" }
        )

        let state = try await client.setWidthMode(
            machine: activeMachine,
            tabID: "default",
            widthMode: .computer,
            computerProfile: TerminalProfile(rows: 24, cols: 100)
        )

        #expect(socket.sent.count == 1)
        #expect(socket.sent[0].contains(#""type":"set_width_mode""#))
        #expect(socket.sent[0].contains(#""tabId":"default""#))
        #expect(socket.sent[0].contains(#""mode":"computer""#))
        #expect(socket.sent[0].contains(#""computerRows":24"#))
        #expect(socket.sent[0].contains(#""computerCols":100"#))
        #expect(state.tabs.first?.widthMode == .computer)
        #expect(state.tabs.first?.profile == TerminalProfile(rows: 24, cols: 100))
        #expect(socket.closed)
    }

    private var activeMachine: Machine {
        Machine(
            id: "mac",
            name: "Mac",
            relayURL: URL(string: "https://relay.test")!,
            connectionState: .online,
            lastSeenText: "binding active",
            binding: MachineBinding(
                bindingID: "bind_1",
                daemonDeviceID: "daemon_1",
                phoneDeviceID: "phone_1",
                status: .active,
                expiresAt: "2026-05-29T00:00:00Z"
            )
        )
    }

    private func assertSignedWebSocketURL(_ url: URL?) {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems
        else {
            Issue.record("Expected websocket URL")
            return
        }
        let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        #expect(components.scheme == "wss")
        #expect(components.host == "relay.test")
        #expect(components.path == "/ws/mobile")
        #expect(query["deviceId"] == "phone_1")
        #expect(query["bindingId"] == "bind_1")
        #expect(query["authTimestamp"] != nil)
        #expect(query["authNonce"]?.isEmpty == false)
        #expect(query["authSignature"] == Data("signed:nudge.relay.websocket.v1\nphone_1\nbind_1\n\(query["authTimestamp"] ?? "")\n\(query["authNonce"] ?? "")".utf8).base64EncodedString())
    }
}

private struct MemoryPhoneIdentityStore: PhoneIdentityStore {
    var publicKey: String

    func loadOrCreate() throws -> PhoneIdentity {
        PhoneIdentity(publicKey: publicKey)
    }

    func sign(_ message: Data) throws -> Data {
        Data("signed:\(String(data: message, encoding: .utf8) ?? "")".utf8)
    }

    func reset() throws {}
}

private struct StubResponse {
    var path: String
    var statusCode: Int = 200
    var data: Data
}

private final class RecordingWebSocketFactory: RelayWebSocketFactory, @unchecked Sendable {
    var urls: [URL] = []
    let socket: RecordingWebSocket

    init(socket: RecordingWebSocket) {
        self.socket = socket
    }

    func webSocket(for url: URL) throws -> any RelayWebSocketTransport {
        urls.append(url)
        return socket
    }
}

private final class RequestIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.withLock {
            values.removeFirst()
        }
    }
}

private final class RecordingWebSocket: RelayWebSocketTransport, @unchecked Sendable {
    var messages: [String]
    var sent: [String] = []
    var closed = false

    init(messages: [String]) {
        self.messages = messages
    }

    func sendString(_ value: String) async throws {
        sent.append(value)
    }

    func receiveString() async throws -> String {
        if messages.isEmpty {
            throw RelayClientError.invalidWebSocketMessage
        }
        return messages.removeFirst()
    }

    func close() {
        closed = true
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [StubResponse] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        responses = []
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(request)
        guard !Self.responses.isEmpty else {
            client?.urlProtocol(self, didFailWithError: RelayClientError.badStatus)
            return
        }
        let response = Self.responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    var httpBodyString: String {
        if let httpBody {
            return String(data: httpBody, encoding: .utf8) ?? ""
        }
        if let stream = httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: bufferSize)
                if count <= 0 {
                    break
                }
                data.append(buffer, count: count)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }
}
