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

        #expect(factory.urls.map(\.absoluteString) == ["wss://relay.test/ws/mobile?deviceId=phone_1&bindingId=bind_1"])
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

        #expect(factory.urls.map(\.absoluteString) == ["wss://relay.test/ws/mobile?deviceId=phone_1&bindingId=bind_1"])
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

        #expect(factory.urls.map(\.absoluteString) == ["wss://relay.test/ws/mobile?deviceId=phone_1&bindingId=bind_1"])
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
}

private struct MemoryPhoneIdentityStore: PhoneIdentityStore {
    var publicKey: String

    func loadOrCreate() throws -> PhoneIdentity {
        PhoneIdentity(publicKey: publicKey)
    }

    func sign(_ message: Data) throws -> Data {
        _ = message
        return Data()
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
