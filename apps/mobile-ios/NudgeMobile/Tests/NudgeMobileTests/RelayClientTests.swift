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
