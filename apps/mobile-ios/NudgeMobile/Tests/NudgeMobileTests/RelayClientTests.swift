import CryptoKit
import Foundation
import Testing
@testable import NudgeMobile

@Suite("Relay client")
struct RelayClientTests {
    // Phase 4.1 Level A: the phone-side binary terminal-delta parser must mirror
    // the daemon's `terminal_delta_binary_plaintext` exactly, including raw
    // (non-UTF-8) terminal bytes.
    @Test func binaryTerminalDeltaParsesTabOffsetAndRawBytes() throws {
        let tabID = "tab-7"
        let offset: UInt64 = 0x0102_0304_0506_0708
        let raw = Data([0x1b, 0x5b, 0x30, 0x6d, 0xff, 0x00, 0x41]) // ESC[0m, 0xff, NUL, 'A'
        var frame = Data([1, 1]) // version, kind=delta
        frame.append(contentsOf: withUnsafeBytes(of: offset.bigEndian, Array.init))
        frame.append(contentsOf: withUnsafeBytes(of: UInt16(tabID.utf8.count).bigEndian, Array.init))
        frame.append(contentsOf: Array(tabID.utf8))
        frame.append(raw)

        let parsed = parseBinaryTerminalDelta(frame)
        #expect(parsed?.tabID == tabID)
        #expect(parsed?.offset == offset)
        #expect(parsed?.data == raw)
    }

    @Test func binaryTerminalDeltaRejectsMalformedFrames() throws {
        // Shorter than the 12-byte header.
        #expect(parseBinaryTerminalDelta(Data([1, 1, 0, 0])) == nil)
        // Wrong version byte.
        #expect(parseBinaryTerminalDelta(Data([2, 1] + Array(repeating: UInt8(0), count: 12))) == nil)
        // tabLen claims more bytes than the frame holds.
        var overlong = Data([1, 1])
        overlong.append(contentsOf: Array(repeating: UInt8(0), count: 8)) // offset
        overlong.append(contentsOf: [0x00, 0xfa]) // tabLen = 250
        overlong.append(contentsOf: Array("tab".utf8))
        #expect(parseBinaryTerminalDelta(overlong) == nil)
    }

    @Test func claimBindingRegistersPhoneThenClaimsCode() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [
            StubResponse(
                path: "/api/devices/register",
                data: #"{"device":{"id":"phone_1"}}"#.data(using: .utf8)!
            ),
            StubResponse(
                path: "/api/bind/claim",
                data: #"{"binding":{"id":"bind_1","daemonDeviceId":"daemon_1","phoneDeviceId":"phone_1","daemonPublicKey":"daemon-public-key","phonePublicKey":"phone-public-key","status":"claimed","expiresAt":"2026-05-29T00:00:00Z"}}"#.data(using: .utf8)!
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
            daemonPublicKey: "daemon-public-key",
            phonePublicKey: "phone-public-key",
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

    @Test func liveRelayClaimAndTerminalSessionWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NUDGE_IOS_INTEGRATION"] == "1" else {
            return
        }
        let relayURLValue = try #require(environment["NUDGE_IOS_RELAY_URL"])
        let relayURL = try #require(URL(string: relayURLValue))
        let pairingCode = try #require(environment["NUDGE_IOS_PAIRING_CODE"])
        let identityStore = try liveIntegrationIdentityStore(environment: environment)
        let phonePublicKey = try identityStore.loadOrCreate().publicKey
        let client = HTTPRelayClient(identityStore: identityStore)

        let claim = try await client.claimBinding(code: pairingCode, relayURL: relayURL)

        #expect(claim.status == .claimed)
        #expect(!claim.bindingID.isEmpty)
        #expect(!claim.daemonDeviceID.isEmpty)
        #expect(!claim.phoneDeviceID.isEmpty)
        #expect(claim.phonePublicKey == phonePublicKey)

        let activeClaim = try await waitForActiveBinding(
            client: client,
            claim: claim,
            relayURL: relayURL
        )
        #expect(activeClaim.status == .active)
        #expect(activeClaim.daemonPublicKey != nil)
        #expect(activeClaim.phonePublicKey == phonePublicKey)

        try await waitForRelayDaemonSocket(relayURL: relayURL)

        let machine = Machine(
            id: activeClaim.daemonDeviceID,
            name: "Live Relay Smoke",
            relayURL: relayURL,
            connectionState: .online,
            lastSeenText: "binding active",
            binding: MachineBinding(claim: activeClaim)
        )
        let session = try await client.openSession(machine: machine)
        defer {
            session.close()
        }

        try await session.requestSessionState()
        let state = try await receiveSessionState(from: session)
        let tab = try #require(state.tabs.first)
        #expect(tab.id == "default")

        try await session.requestTerminalOutput(tabID: tab.id, maxBytes: 8192)
        let replay = try await receiveTerminalOutput(from: session, requireReplay: true)
        #expect(replay.tabID == tab.id)

        let marker = "NUDGE_IOS_RELAY_SESSION_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        try await session.sendTerminalInput(tabID: tab.id, text: "echo \(marker)", enter: true)
        try await waitForInputAcceptedAndTerminalOutput(from: session, containing: marker)
    }

    @Test func fetchBindingStatusUsesPhoneDeviceAsParticipant() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [
            StubResponse(
                path: "/api/bind/status",
                data: #"{"binding":{"id":"bind_1","daemonDeviceId":"daemon_1","phoneDeviceId":"phone_1","daemonPublicKey":"daemon-public-key","phonePublicKey":"phone-public-key","status":"active","expiresAt":"2026-05-29T00:00:00Z"}}"#.data(using: .utf8)!
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
        #expect(claim.daemonPublicKey == "daemon-public-key")
        #expect(claim.phonePublicKey == "phone-public-key")
        #expect(URLProtocolStub.requests.map(\.url?.path) == ["/api/bind/status"])
        #expect(URLProtocolStub.requests.first?.url?.query == "bindingId=bind_1&deviceId=phone_1")
    }

    @Test func revokeBindingUsesPhoneDeviceAsParticipant() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [
            StubResponse(
                path: "/api/bind/revoke",
                data: #"{"binding":{"id":"bind_1","daemonDeviceId":"daemon_1","phoneDeviceId":"phone_1","daemonPublicKey":"daemon-public-key","phonePublicKey":"phone-public-key","status":"revoked","expiresAt":"2026-05-29T00:00:00Z"}}"#.data(using: .utf8)!
            )
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key")
        )

        let claim = try await client.revokeBinding(machine: activeMachine)

        #expect(claim.status == .revoked)
        #expect(claim.bindingID == "bind_1")
        #expect(URLProtocolStub.requests.map(\.url?.path) == ["/api/bind/revoke"])
        let requestBody = try #require(URLProtocolStub.requests.first?.jsonBody)
        #expect(requestBody["bindingId"] as? String == "bind_1")
        #expect(requestBody["deviceId"] as? String == "phone_1")
    }

    @Test func rotatePhoneKeySignsCurrentIdentityThenCommitsNewIdentity() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [
            StubResponse(
                path: "/api/devices/rotate-key",
                data: #"{"device":{"id":"phone_1","kind":"phone","publicKey":"phone-new-public-key"}}"#.data(using: .utf8)!
            )
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let identityStore = MemoryPhoneIdentityStore(publicKey: "phone-old-public-key")
        identityStore.rotationCandidatePublicKey = "phone-new-public-key"
        identityStore.rotationCandidateSigningKey = Data(repeating: 4, count: 32)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: identityStore
        )

        let identity = try await client.rotatePhoneKey(machine: activeMachine)

        #expect(identity.publicKey == "phone-new-public-key")
        #expect(try identityStore.loadOrCreate().publicKey == "phone-new-public-key")
        #expect(try identityStore.signingPrivateKeyRaw() == Data(repeating: 4, count: 32))
        #expect(URLProtocolStub.requests.map(\.url?.path) == ["/api/devices/rotate-key"])
        let requestBody = try #require(URLProtocolStub.requests.first?.jsonBody)
        #expect(requestBody["deviceId"] as? String == "phone_1")
        #expect(requestBody["newPublicKey"] as? String == "phone-new-public-key")
        let signedAt = try #require(requestBody["signedAt"] as? String)
        let nonce = try #require(requestBody["nonce"] as? String)
        let signature = try #require(requestBody["signature"] as? String)
        let signatureBytes = try #require(Data(base64Encoded: signature))
        let signedMessage = try #require(String(data: signatureBytes, encoding: .utf8))
        #expect(signedAt.range(of: #"^\d+$"#, options: .regularExpression) != nil)
        #expect(nonce.hasPrefix("rotation-"))
        #expect(signedMessage == [
            "signed:nudge.relay.device_key_rotation.v1",
            "phone_1",
            "phone-old-public-key",
            "phone-new-public-key",
            signedAt,
            nonce
        ].joined(separator: "\n"))
    }

    @Test func rotatePhoneKeyDoesNotCommitWhenRelayRejects() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [
            StubResponse(
                path: "/api/devices/rotate-key",
                statusCode: 401,
                data: #"{"error":"invalid_device_key_rotation_signature"}"#.data(using: .utf8)!
            )
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let identityStore = MemoryPhoneIdentityStore(publicKey: "phone-old-public-key")
        identityStore.rotationCandidatePublicKey = "phone-new-public-key"
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: identityStore
        )

        do {
            _ = try await client.rotatePhoneKey(machine: activeMachine)
            Issue.record("Expected rotation failure")
        } catch RelayClientError.badStatus {
            #expect(try identityStore.loadOrCreate().publicKey == "phone-old-public-key")
        }
    }

    @Test func fetchSessionStateConnectsMobileSocketAndRequestsState() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"ios-fixed","ok":true,"data":{"tabs":[{"id":"default","title":"Claude","status":"running","widthMode":"phone","rows":32,"cols":48,"agentStatus":{"kind":"claude","state":"needs_approval","confidence":0.82,"source":"screen"}}]}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
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
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"ios-input","ok":true,"data":{"accepted":true}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
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
    }

    @Test func setFocusedTabAckDoesNotDecodeAsSessionState() async throws {
        // Regression (Phase 4.3 review, HIGH): set_focused_tab is sent
        // fire-and-forget; the daemon's `{accepted:true}` ack must NOT be
        // correlated as a session state, which (with no tabs) would replace the
        // tab list with [] and wipe the UI on every tab switch.
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"ios-focus","ok":true,"data":{"accepted":true}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { "ios-focus" }
        )

        let session = try await client.openSession(machine: activeMachine)
        try await session.setFocusedTab(tabID: "default")
        let event = try await session.receiveEvent()
        session.close()

        #expect(socket.sent.count == 1)
        #expect(socket.sent[0].contains(#""type":"set_focused_tab""#))
        #expect(socket.sent[0].contains(#""tabId":"default""#))
        // The ack is a benign no-op, NOT a session state (which would wipe tabs).
        #expect(event == .terminalInputAccepted(tabID: nil))
        #expect(socket.closed)
    }

    @Test func sendTerminalInputUsesE2EEnvelopeWhenBindingHasDaemonPublicKey() async throws {
        let phoneSigningPrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32))
        let daemonSigningPrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 4, count: 32))
        let identityStore = MemoryPhoneIdentityStore(
            publicKey: phoneSigningPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            signingKey: phoneSigningPrivateKey.rawRepresentation
        )
        let binding = MachineBinding(
            bindingID: "bind_1",
            daemonDeviceID: "daemon_1",
            phoneDeviceID: "phone_1",
            daemonPublicKey: daemonSigningPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            phonePublicKey: phoneSigningPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            status: .active,
            expiresAt: "2026-05-29T00:00:00Z"
        )
        let machine = Machine(
            id: "mac",
            name: "Mac",
            relayURL: URL(string: "https://relay.test")!,
            connectionState: .online,
            lastSeenText: "binding active",
            binding: binding
        )
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#
        ])
        socket.onSend = { sent in
            guard socket.messages.isEmpty,
                  let payload = relayPayload(from: sent),
                  payload["type"] as? String == "e2e_handshake_start"
            else {
                return
            }
            do {
                let start = try JSONDecoder().decode(E2EHandshakeStartRelayPayload.self, from: JSONSerialization.data(withJSONObject: payload)).start()
                var finish = Nudge_V1_E2EHandshakeFinish()
                finish.sessionID = start.sessionID
                finish.senderDeviceID = "daemon_1"
                finish.recipientDeviceID = "phone_1"
                let daemonEphemeral = try E2EKeyPair(rawRepresentation: Data(repeating: 9, count: 32))
                finish.senderEphemeralPublicKey = daemonEphemeral.publicKey
                finish.acceptedAt = "2026-05-29T00:00:01.000Z"
                finish = try signE2EHandshakeFinish(
                    signingPrivateKeyRaw: daemonSigningPrivateKey.rawRepresentation,
                    start: start,
                    finish: finish
                )
                let finishPayload = try jsonObjectString(E2EHandshakeFinishRelayPayload(finish: finish))
                socket.messages.append(#"{"type":"message","message":{"payload":\#(finishPayload)}}"#)
                var daemonSession = try E2ESession(
                    sessionID: start.sessionID,
                    localDeviceID: "daemon_1",
                    remoteDeviceID: "phone_1",
                    localKeyPair: daemonEphemeral,
                    remotePublicKey: start.senderEphemeralPublicKey,
                    role: .daemon
                )
                let response = RelayDaemonPayloadFixture(
                    type: "daemon_response",
                    requestId: "ios-e2e-input",
                    ok: true,
                    data: ["accepted": true]
                )
                let responseData = try JSONEncoder().encode(response)
                let encrypted = try daemonSession.encrypt(messageType: "terminal_input_response", plaintext: responseData)
                let encryptedPayload = try jsonObjectString(E2ERelayPayload(envelope: encrypted))
                socket.messages.append(#"{"type":"message","message":{"payload":\#(encryptedPayload)}}"#)
            } catch {
                Issue.record("Failed to prepare E2E daemon response: \(error)")
            }
        }
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: identityStore,
            webSocketFactory: RecordingWebSocketFactory(socket: socket),
            requestIDGenerator: { "ios-e2e-input" }
        )

        try await client.sendTerminalInput(machine: machine, tabID: "default", text: "echo hi", enter: true)

        #expect(socket.sent.count == 2)
        #expect(socket.sent[0].contains(#""type":"e2e_handshake_start""#))
        let encryptedPayload = try #require(relayPayload(from: socket.sent[1]))
        #expect(encryptedPayload["type"] as? String == "e2e_envelope")
        #expect(encryptedPayload["messageType"] as? String == "terminal_input")
        #expect(encryptedPayload["ciphertextBase64"] as? String != nil)
        #expect(!socket.sent[1].contains(#""requestId":"ios-e2e-input""#))
        #expect(!socket.sent[1].contains(#""tabId":"default""#))
        #expect(!socket.sent[1].contains("echo hi"))
    }

    @Test func relayErrorBindingRevokedStopsOneShotRequest() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"error","error":"binding_revoked"}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { "ios-input" }
        )

        do {
            try await client.sendTerminalInput(machine: activeMachine, tabID: "default", text: "echo hi", enter: true)
            Issue.record("Expected bindingRevoked")
        } catch RelayClientError.bindingRevoked {
            #expect(socket.closed)
        }
    }

    @Test func relayErrorDeviceRevokedStopsOneShotRequest() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"error","error":"device_revoked"}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { "ios-input" }
        )

        do {
            try await client.sendTerminalInput(machine: activeMachine, tabID: "default", text: "echo hi", enter: true)
            Issue.record("Expected bindingRevoked")
        } catch RelayClientError.bindingRevoked {
            #expect(socket.closed)
        }
    }

    @Test func fetchTerminalSnapshotRequestsSelectedTabSnapshot() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"ios-snapshot","ok":true,"data":{"tabId":"default","rows":24,"cols":80,"text":"$ echo hi\nhi"}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
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
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"session-1","ok":true,"data":{"tabs":[{"id":"default","title":"Claude","status":"running","widthMode":"phone","rows":32,"cols":48,"agentStatus":{"kind":"claude","state":"needs_approval","confidence":0.82,"source":"screen"}}]}}}}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"output-1","ok":true,"data":{"tabId":"default","bytesBase64":"Q2xhdWRlIHJlYWR5"}}}}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"input-1","ok":true,"data":{"accepted":true}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let requestIDs = RequestIDSequence(["session-1", "output-1", "input-1"])
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
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
            text: "Claude ready",
            isReplay: true
        )))
        #expect(inputEvent == .terminalInputAccepted(tabID: "default"))
    }

    @Test func openSessionUsesE2EForInputLiveOutputAndReconnectReplay() async throws {
        let phoneSigningPrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32))
        let daemonSigningPrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 4, count: 32))
        let binding = MachineBinding(
            bindingID: "bind_1",
            daemonDeviceID: "daemon_1",
            phoneDeviceID: "phone_1",
            daemonPublicKey: daemonSigningPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            phonePublicKey: phoneSigningPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            status: .active,
            expiresAt: "2026-05-29T00:00:00Z"
        )
        let machine = Machine(
            id: "mac",
            name: "Mac",
            relayURL: URL(string: "https://relay.test")!,
            connectionState: .online,
            lastSeenText: "binding active",
            binding: binding
        )
        let identityStore = MemoryPhoneIdentityStore(
            publicKey: phoneSigningPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            signingKey: phoneSigningPrivateKey.rawRepresentation
        )
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#
        ])
        let daemonScript = E2ERelaySessionDaemonScript(
            daemonSigningPrivateKey: daemonSigningPrivateKey,
            daemonEphemeral: try E2EKeyPair(rawRepresentation: Data(repeating: 9, count: 32))
        )
        socket.onSend = { sent in
            daemonScript.handle(sent: sent, socket: socket)
        }
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let requestIDs = RequestIDSequence(["input-e2e", "replay-e2e"])
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: identityStore,
            webSocketFactory: RecordingWebSocketFactory(socket: socket),
            requestIDGenerator: { requestIDs.next() }
        )

        let session = try await client.openSession(machine: machine)
        try await session.sendTerminalInput(tabID: "default", text: "echo hi", enter: true)
        let inputEvent = try await session.receiveEvent()
        let liveOutputEvent = try await session.receiveEvent()
        try await session.requestTerminalOutput(tabID: "default", maxBytes: 4096)
        let replayOutputEvent = try await session.receiveEvent()
        session.close()

        #expect(socket.sent.count == 3)
        #expect(socket.sent[0].contains(#""type":"e2e_handshake_start""#))
        #expect(socket.sent[1].contains(#""type":"e2e_envelope""#))
        #expect(socket.sent[2].contains(#""type":"e2e_envelope""#))
        #expect(!socket.sent[1].contains("echo hi"))
        #expect(!socket.sent[1].contains(#""tabId":"default""#))
        #expect(!socket.sent[2].contains(#""maxBytes""#))
        #expect(!socket.sent[2].contains(#""replay-e2e""#))
        #expect(daemonScript.errors.isEmpty)
        #expect(daemonScript.decryptedPayloads.count == 2)
        #expect(daemonScript.decryptedPayloads[0]["type"] as? String == "terminal_input")
        #expect(daemonScript.decryptedPayloads[0]["requestId"] as? String == "input-e2e")
        #expect(daemonScript.decryptedPayloads[0]["tabId"] as? String == "default")
        #expect(daemonScript.decryptedPayloads[0]["text"] as? String == "echo hi")
        #expect(daemonScript.decryptedPayloads[1]["type"] as? String == "terminal_output")
        #expect(daemonScript.decryptedPayloads[1]["requestId"] as? String == "replay-e2e")
        #expect(inputEvent == .terminalInputAccepted(tabID: "default"))
        #expect(liveOutputEvent == .terminalOutput(TerminalOutput(
            tabID: "default",
            text: "live output"
        )))
        #expect(replayOutputEvent == .terminalOutput(TerminalOutput(
            tabID: "default",
            text: "replayed output",
            isReplay: true
        )))
        #expect(socket.closed)
    }

    @Test func openSessionAcceptsUnsolicitedLiveTerminalSnapshot() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","ok":true,"data":{"tabId":"default","rows":24,"cols":80,"text":"live update"}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
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
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","ok":true,"data":{"tabId":"default","bytesBase64":"G1szMW1yZWQK"}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
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
            bytesBase64: "G1szMW1yZWQK"
        )))
    }

    @Test func openSessionPreservesNonUtf8TerminalOutputBytes() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","ok":true,"data":{"tabId":"default","bytesBase64":"//4A"}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { "unused" }
        )

        let session = try await client.openSession(machine: activeMachine)
        let event = try await session.receiveEvent()
        session.close()

        #expect(event == .terminalOutput(TerminalOutput(
            tabID: "default",
            bytesBase64: "//4A"
        )))
    }

    @Test func openSessionAcceptsUnsolicitedAgentStatusUpdate() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","ok":true,"data":{"tabId":"default","agentStatus":{"kind":"codex","state":"waiting_for_input","confidence":0.81,"source":"screen"}}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { "unused" }
        )

        let session = try await client.openSession(machine: activeMachine)
        let event = try await session.receiveEvent()
        session.close()

        #expect(socket.sent.isEmpty)
        #expect(event == .agentStatus(AgentStatusUpdate(
            tabID: "default",
            status: AgentStatus(kind: .codex, state: .waitingForInput, confidence: 0.81, source: "screen")
        )))
    }

    @Test func setPhoneProfileSendsRelayControlRequest() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"profile-1","ok":true,"data":{"tabs":[{"id":"default","title":"shell","status":"running","widthMode":"phone","rows":34,"cols":52}]}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
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
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"width-1","ok":true,"data":{"tabs":[{"id":"default","title":"shell","status":"running","widthMode":"computer","rows":24,"cols":100}]}}}}"#
        ])
        let factory = RecordingWebSocketFactory(socket: socket)
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
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

    @Test func tabActionsSendRelayControlRequests() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [
            socketChallengeResponse(),
            socketChallengeResponse(),
            socketChallengeResponse(),
            socketChallengeResponse()
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let sockets = [
            RecordingWebSocket(messages: [
                #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
                #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"create-1","ok":true,"data":{"tabs":[{"id":"default","title":"shell","status":"running","widthMode":"phone","rows":32,"cols":48},{"id":"tab-2","title":"shell","status":"running","widthMode":"phone","rows":32,"cols":48}]}}}}"#
            ]),
            RecordingWebSocket(messages: [
                #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
                #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"rename-1","ok":true,"data":{"tabs":[{"id":"default","title":"Claude","status":"running","widthMode":"phone","rows":32,"cols":48}]}}}}"#
            ]),
            RecordingWebSocket(messages: [
                #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
                #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"restart-1","ok":true,"data":{"tabs":[{"id":"default","title":"Claude","status":"running","widthMode":"phone","rows":32,"cols":48}]}}}}"#
            ]),
            RecordingWebSocket(messages: [
                #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
                #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"close-1","ok":true,"data":{"tabs":[{"id":"default","title":"Claude","status":"running","widthMode":"phone","rows":32,"cols":48}]}}}}"#
            ])
        ]
        let factory = QueueingWebSocketFactory(sockets: sockets)
        let requestIDs = RequestIDSequence(["create-1", "rename-1", "restart-1", "close-1"])
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { requestIDs.next() }
        )

        let createState = try await client.createTab(machine: activeMachine, title: "shell")
        let renameState = try await client.renameTab(machine: activeMachine, tabID: "default", title: "Claude")
        let restartState = try await client.restartTab(machine: activeMachine, tabID: "default")
        let closeState = try await client.closeTab(machine: activeMachine, tabID: "tab-2")

        let sent = sockets.flatMap(\.sent)
        #expect(sent.count == 4)
        #expect(sent[0].contains(#""type":"create_tab""#))
        #expect(sent[0].contains(#""title":"shell""#))
        // Plain-shell create-tab omits the optional cwd/launch fields entirely.
        #expect(!sent[0].contains("cwd"))
        #expect(!sent[0].contains("launch"))
        #expect(sent[1].contains(#""type":"rename_tab""#))
        #expect(sent[1].contains(#""tabId":"default""#))
        #expect(sent[1].contains(#""title":"Claude""#))
        #expect(sent[2].contains(#""type":"restart_tab""#))
        #expect(sent[2].contains(#""tabId":"default""#))
        #expect(sent[3].contains(#""type":"close_tab""#))
        #expect(sent[3].contains(#""tabId":"tab-2""#))
        #expect(createState.tabs.map(\.id) == ["default", "tab-2"])
        #expect(renameState.tabs.first?.title == "Claude")
        #expect(restartState.tabs.first?.state == .running)
        #expect(closeState.tabs.map(\.id) == ["default"])
        #expect(sockets.allSatisfy { $0.closed })
    }

    @Test func createTabWithAgentLaunchIncludesCwdAndLaunch() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.responses = [socketChallengeResponse()]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let socket = RecordingWebSocket(messages: [
            #"{"type":"connected","deviceId":"phone_1","bindingId":"bind_1"}"#,
            #"{"type":"message","message":{"payload":{"type":"daemon_response","requestId":"create-1","ok":true,"data":{"tabs":[{"id":"default","title":"shell","status":"running","widthMode":"phone","rows":32,"cols":48},{"id":"tab-2","title":"claude","status":"running","widthMode":"phone","rows":32,"cols":48}]}}}}"#
        ])
        let factory = QueueingWebSocketFactory(sockets: [socket])
        let requestIDs = RequestIDSequence(["create-1"])
        let client = HTTPRelayClient(
            urlSession: URLSession(configuration: configuration),
            identityStore: MemoryPhoneIdentityStore(publicKey: "phone-public-key"),
            webSocketFactory: factory,
            requestIDGenerator: { requestIDs.next() }
        )

        let state = try await client.createTab(
            machine: activeMachine,
            title: "Claude Code",
            cwd: "/Users/you/Projects/app",
            launch: "claude"
        )

        #expect(socket.sent.count == 1)
        #expect(socket.sent[0].contains(#""type":"create_tab""#))
        #expect(socket.sent[0].contains(#""cwd":"\/Users\/you\/Projects\/app""#))
        #expect(socket.sent[0].contains(#""launch":"claude""#))
        #expect(state.tabs.map(\.id) == ["default", "tab-2"])
        #expect(state.tabs.last?.title == "claude")
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
        #expect(query["authChallengeId"] == "challenge_1")
        #expect(query["authChallengeSignature"] == Data("signed:nudge.relay.websocket.challenge.v1\nphone_1\nbind_1\nchallenge_1\n2026-05-29T00:01:00Z".utf8).base64EncodedString())
        #expect(url.absoluteString.contains("authChallengeSignature="))
        #expect(!url.absoluteString.contains("+"))
    }

    private func socketChallengeResponse() -> StubResponse {
        StubResponse(
            path: "/api/ws/challenge",
            data: #"{"challenge":{"id":"challenge_1","message":"nudge.relay.websocket.challenge.v1\nphone_1\nbind_1\nchallenge_1\n2026-05-29T00:01:00Z","expiresAt":"2026-05-29T00:01:00Z"}}"#.data(using: .utf8)!
        )
    }

    private func liveIntegrationIdentityStore(environment: [String: String]) throws -> MemoryPhoneIdentityStore {
        let signingKeyData: Data
        if let signingKeyBase64 = environment["NUDGE_IOS_PHONE_SIGNING_KEY_BASE64"] {
            signingKeyData = try #require(Data(base64Encoded: signingKeyBase64))
            #expect(signingKeyData.count == 32)
        } else {
            signingKeyData = Data(repeating: 7, count: 32)
        }
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyData)
        return MemoryPhoneIdentityStore(
            publicKey: signingKey.publicKey.rawRepresentation.base64EncodedString(),
            signingKey: signingKeyData,
            usesRealSignature: true
        )
    }

    private func waitForActiveBinding(
        client: HTTPRelayClient,
        claim: BindingClaim,
        relayURL: URL
    ) async throws -> BindingClaim {
        var current = claim
        for _ in 0..<300 {
            current = try await client.fetchBindingStatus(
                binding: MachineBinding(claim: current),
                relayURL: relayURL
            )
            if current.status == .active {
                return current
            }
            if current.status == .revoked {
                throw LiveRelayIntegrationError.bindingRevoked
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw LiveRelayIntegrationError.timeout("timed out waiting for active binding")
    }

    private func waitForRelayDaemonSocket(relayURL: URL) async throws {
        let readyURL = relayURL.appending(path: "/readyz")
        for _ in 0..<150 {
            if let (data, response) = try? await URLSession.shared.data(from: readyURL),
               let httpResponse = response as? HTTPURLResponse,
               (200..<300).contains(httpResponse.statusCode),
               let readiness = try? JSONDecoder().decode(RelayReadiness.self, from: data),
               readiness.sockets >= 1 {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw LiveRelayIntegrationError.timeout("timed out waiting for daemon relay websocket")
    }

    private func receiveSessionState(from session: any RelaySession) async throws -> RemoteSessionState {
        for _ in 0..<40 {
            let event = try await receiveRelayEvent(from: session)
            if case .sessionState(let state) = event {
                return state
            }
        }
        throw LiveRelayIntegrationError.timeout("timed out waiting for session state")
    }

    private func receiveTerminalOutput(
        from session: any RelaySession,
        requireReplay: Bool = false
    ) async throws -> TerminalOutput {
        for _ in 0..<40 {
            let event = try await receiveRelayEvent(from: session)
            if case .terminalOutput(let output) = event,
               !requireReplay || output.isReplay {
                return output
            }
        }
        throw LiveRelayIntegrationError.timeout("timed out waiting for terminal output")
    }

    private func waitForInputAcceptedAndTerminalOutput(
        from session: any RelaySession,
        containing expectedText: String
    ) async throws {
        var accepted = false
        var outputText = ""
        for _ in 0..<80 {
            let event = try await receiveRelayEvent(from: session)
            switch event {
            case .terminalInputAccepted:
                accepted = true
            case .terminalOutput(let output):
                outputText += output.text
            case .terminalSnapshot(let snapshot):
                outputText += snapshot.text
            case .sessionState, .agentStatus:
                break
            }
            if accepted && outputText.contains(expectedText) {
                return
            }
        }
        throw LiveRelayIntegrationError.timeout("timed out waiting for accepted input and live output")
    }

    private func receiveRelayEvent(from session: any RelaySession) async throws -> RelaySessionEvent {
        try await withTimeout(seconds: 10) {
            try await session.receiveEvent()
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw LiveRelayIntegrationError.timeout("operation timed out")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private struct RelayReadiness: Decodable {
    var sockets: Int
}

private enum LiveRelayIntegrationError: Error {
    case bindingRevoked
    case timeout(String)
}

private final class MemoryPhoneIdentityStore: PhoneIdentityStore, @unchecked Sendable {
    var publicKey: String
    var signingKey: Data = Data(repeating: 3, count: 32)
    var usesRealSignature = false
    var rotationCandidatePublicKey = "rotated-phone-public-key"
    var rotationCandidateSigningKey = Data(repeating: 4, count: 32)

    init(
        publicKey: String,
        signingKey: Data = Data(repeating: 3, count: 32),
        usesRealSignature: Bool = false
    ) {
        self.publicKey = publicKey
        self.signingKey = signingKey
        self.usesRealSignature = usesRealSignature
    }

    func loadOrCreate() throws -> PhoneIdentity {
        PhoneIdentity(publicKey: publicKey)
    }

    func generateRotationCandidate() throws -> PhoneIdentityRotation {
        if usesRealSignature {
            let privateKey = Curve25519.Signing.PrivateKey()
            return PhoneIdentityRotation(
                identity: PhoneIdentity(publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()),
                privateKeyRaw: privateKey.rawRepresentation
            )
        }
        return PhoneIdentityRotation(
            identity: PhoneIdentity(publicKey: rotationCandidatePublicKey),
            privateKeyRaw: rotationCandidateSigningKey
        )
    }

    func commitRotation(_ rotation: PhoneIdentityRotation) throws {
        publicKey = rotation.identity.publicKey
        signingKey = rotation.privateKeyRaw
    }

    func sign(_ message: Data) throws -> Data {
        if usesRealSignature {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey)
            return try privateKey.signature(for: message)
        }
        return Data("signed:\(String(data: message, encoding: .utf8) ?? "")".utf8)
    }

    func signingPrivateKeyRaw() throws -> Data {
        signingKey
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

private final class QueueingWebSocketFactory: RelayWebSocketFactory, @unchecked Sendable {
    var urls: [URL] = []
    private let lock = NSLock()
    private var sockets: [RecordingWebSocket]

    init(sockets: [RecordingWebSocket]) {
        self.sockets = sockets
    }

    func webSocket(for url: URL) throws -> any RelayWebSocketTransport {
        urls.append(url)
        return lock.withLock {
            sockets.removeFirst()
        }
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
    var onSend: ((String) -> Void)?

    init(messages: [String]) {
        self.messages = messages
    }

    func sendString(_ value: String) async throws {
        sent.append(value)
        onSend?(value)
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

private final class E2ERelaySessionDaemonScript: @unchecked Sendable {
    let daemonSigningPrivateKey: Curve25519.Signing.PrivateKey
    let daemonEphemeral: E2EKeyPair
    private var daemonSession: E2ESession?
    var decryptedPayloads: [[String: Any]] = []
    var errors: [String] = []

    init(
        daemonSigningPrivateKey: Curve25519.Signing.PrivateKey,
        daemonEphemeral: E2EKeyPair
    ) {
        self.daemonSigningPrivateKey = daemonSigningPrivateKey
        self.daemonEphemeral = daemonEphemeral
    }

    func handle(sent: String, socket: RecordingWebSocket) {
        do {
            guard let payload = relayPayload(from: sent),
                  let type = payload["type"] as? String
            else {
                throw RelayClientError.invalidWebSocketMessage
            }
            switch type {
            case "e2e_handshake_start":
                try handleHandshakeStart(payload: payload, socket: socket)
            case "e2e_envelope":
                try handleEnvelope(payload: payload, socket: socket)
            default:
                throw RelayClientError.unsupportedRelayValue(type)
            }
        } catch {
            errors.append(String(describing: error))
        }
    }

    private func handleHandshakeStart(payload: [String: Any], socket: RecordingWebSocket) throws {
        let start = try JSONDecoder()
            .decode(E2EHandshakeStartRelayPayload.self, from: JSONSerialization.data(withJSONObject: payload))
            .start()
        var finish = Nudge_V1_E2EHandshakeFinish()
        finish.sessionID = start.sessionID
        finish.senderDeviceID = "daemon_1"
        finish.recipientDeviceID = "phone_1"
        finish.senderEphemeralPublicKey = daemonEphemeral.publicKey
        finish.acceptedAt = "2026-05-29T00:00:01.000Z"
        finish = try signE2EHandshakeFinish(
            signingPrivateKeyRaw: daemonSigningPrivateKey.rawRepresentation,
            start: start,
            finish: finish
        )
        let finishPayload = try jsonObjectString(E2EHandshakeFinishRelayPayload(finish: finish))
        socket.messages.append(#"{"type":"message","message":{"payload":\#(finishPayload)}}"#)
        daemonSession = try E2ESession(
            sessionID: start.sessionID,
            localDeviceID: "daemon_1",
            remoteDeviceID: "phone_1",
            localKeyPair: daemonEphemeral,
            remotePublicKey: start.senderEphemeralPublicKey,
            role: .daemon
        )
    }

    private func handleEnvelope(payload: [String: Any], socket: RecordingWebSocket) throws {
        guard var session = daemonSession else {
            throw RelayClientError.invalidWebSocketMessage
        }
        let envelope = try JSONDecoder()
            .decode(E2ERelayPayload.self, from: JSONSerialization.data(withJSONObject: payload))
            .envelope()
        let plaintext = try session.decrypt(envelope)
        guard let request = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let type = request["type"] as? String
        else {
            throw RelayClientError.invalidWebSocketMessage
        }
        daemonSession = session
        decryptedPayloads.append(request)
        switch type {
        case "terminal_input":
            try appendEncryptedResponse(
                socket: socket,
                messageType: "terminal_input_response",
                response: RelayDaemonPayloadFixture(
                    type: "daemon_response",
                    requestId: request["requestId"] as? String,
                    ok: true,
                    data: ["accepted": true]
                )
            )
            try appendEncryptedResponse(
                socket: socket,
                messageType: "terminal_output",
                response: RelayDaemonPayloadFixture(
                    type: "daemon_response",
                    requestId: nil,
                    ok: true,
                    data: [
                        "tabId": "default",
                        "bytesBase64": Data("live output".utf8).base64EncodedString()
                    ]
                )
            )
        case "terminal_output":
            try appendEncryptedResponse(
                socket: socket,
                messageType: "terminal_output",
                response: RelayDaemonPayloadFixture(
                    type: "daemon_response",
                    requestId: request["requestId"] as? String,
                    ok: true,
                    data: [
                        "tabId": "default",
                        "bytesBase64": Data("replayed output".utf8).base64EncodedString()
                    ]
                )
            )
        default:
            throw RelayClientError.unsupportedRelayValue(type)
        }
    }

    private func appendEncryptedResponse(
        socket: RecordingWebSocket,
        messageType: String,
        response: RelayDaemonPayloadFixture
    ) throws {
        guard var session = daemonSession else {
            throw RelayClientError.invalidWebSocketMessage
        }
        let responseData = try JSONEncoder().encode(response)
        let encrypted = try session.encrypt(messageType: messageType, plaintext: responseData)
        daemonSession = session
        let encryptedPayload = try jsonObjectString(E2ERelayPayload(envelope: encrypted))
        socket.messages.append(#"{"type":"message","message":{"payload":\#(encryptedPayload)}}"#)
    }
}

private struct RelayDaemonPayloadFixture: Encodable {
    var type: String
    var requestId: String?
    var ok: Bool
    var data: [String: RelayDaemonFixtureValue]

    init(type: String, requestId: String?, ok: Bool, data: [String: Bool]) {
        self.type = type
        self.requestId = requestId
        self.ok = ok
        self.data = data.mapValues { .bool($0) }
    }

    init(type: String, requestId: String?, ok: Bool, data: [String: String]) {
        self.type = type
        self.requestId = requestId
        self.ok = ok
        self.data = data.mapValues { .string($0) }
    }
}

private enum RelayDaemonFixtureValue: Encodable {
    case bool(Bool)
    case string(String)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }
}

private func relayPayload(from socketMessage: String) -> [String: Any]? {
    guard let data = socketMessage.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return object["payload"] as? [String: Any]
}

private func jsonObjectString<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let text = String(data: data, encoding: .utf8) else {
        throw RelayClientError.invalidWebSocketMessage
    }
    return text
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

    var jsonBody: [String: Any]? {
        guard let data = httpBodyString.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
