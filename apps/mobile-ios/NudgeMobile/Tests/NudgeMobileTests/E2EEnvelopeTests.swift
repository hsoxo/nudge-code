import CryptoKit
import Foundation
import Testing
@testable import NudgeMobile

@Suite("E2E envelope")
struct E2EEnvelopeTests {
    @Test func x25519SessionEncryptsAndDecryptsDirectionalPayloads() throws {
        let phoneKeys = try E2EKeyPair(rawRepresentation: Data(repeating: 7, count: 32))
        let daemonKeys = try E2EKeyPair(rawRepresentation: Data(repeating: 9, count: 32))
        var phoneSession = try E2ESession(
            sessionID: "session-1",
            localDeviceID: "phone_1",
            remoteDeviceID: "daemon_1",
            localKeyPair: phoneKeys,
            remotePublicKey: daemonKeys.publicKey,
            role: .phone
        )
        var daemonSession = try E2ESession(
            sessionID: "session-1",
            localDeviceID: "daemon_1",
            remoteDeviceID: "phone_1",
            localKeyPair: daemonKeys,
            remotePublicKey: phoneKeys.publicKey,
            role: .daemon
        )

        let envelope = try phoneSession.encrypt(
            messageType: "terminal_input",
            plaintext: Data(#"{"type":"terminal_input"}"#.utf8)
        )
        let plaintext = try daemonSession.decrypt(envelope)

        #expect(envelope.sequence == 1)
        #expect(envelope.nonce.count == 12)
        #expect(plaintext == Data(#"{"type":"terminal_input"}"#.utf8))
    }

    @Test func decryptRejectsReplayedSequence() throws {
        let phoneKeys = try E2EKeyPair(rawRepresentation: Data(repeating: 7, count: 32))
        let daemonKeys = try E2EKeyPair(rawRepresentation: Data(repeating: 9, count: 32))
        var phoneSession = try E2ESession(
            sessionID: "session-1",
            localDeviceID: "phone_1",
            remoteDeviceID: "daemon_1",
            localKeyPair: phoneKeys,
            remotePublicKey: daemonKeys.publicKey,
            role: .phone
        )
        var daemonSession = try E2ESession(
            sessionID: "session-1",
            localDeviceID: "daemon_1",
            remoteDeviceID: "phone_1",
            localKeyPair: daemonKeys,
            remotePublicKey: phoneKeys.publicKey,
            role: .daemon
        )
        let envelope = try phoneSession.encrypt(messageType: "terminal_input", plaintext: Data("hello".utf8))

        _ = try daemonSession.decrypt(envelope)
        #expect(throws: E2EEnvelopeError.replayDetected) {
            _ = try daemonSession.decrypt(envelope)
        }
    }

    @Test func decryptRejectsRouteMetadataMismatch() throws {
        let phoneKeys = try E2EKeyPair(rawRepresentation: Data(repeating: 7, count: 32))
        let daemonKeys = try E2EKeyPair(rawRepresentation: Data(repeating: 9, count: 32))
        var phoneSession = try E2ESession(
            sessionID: "session-1",
            localDeviceID: "phone_1",
            remoteDeviceID: "daemon_1",
            localKeyPair: phoneKeys,
            remotePublicKey: daemonKeys.publicKey,
            role: .phone
        )
        var daemonSession = try E2ESession(
            sessionID: "session-1",
            localDeviceID: "daemon_1",
            remoteDeviceID: "phone_1",
            localKeyPair: daemonKeys,
            remotePublicKey: phoneKeys.publicKey,
            role: .daemon
        )
        var envelope = try phoneSession.encrypt(messageType: "terminal_input", plaintext: Data("hello".utf8))
        envelope.recipientDeviceID = "other_daemon"

        #expect(throws: E2EEnvelopeError.routeMismatch) {
            _ = try daemonSession.decrypt(envelope)
        }
    }

    @Test func relayPayloadUsesCanonicalE2EJSONFields() throws {
        var envelope = Nudge_V1_E2EEncryptedEnvelope()
        envelope.sessionID = "session-1"
        envelope.senderDeviceID = "phone_1"
        envelope.recipientDeviceID = "daemon_1"
        envelope.messageType = "terminal_input"
        envelope.sequence = UInt64.max
        envelope.nonce = Data("nonce-000001".utf8)
        envelope.ciphertext = Data("ciphertext".utf8)

        let payload = E2ERelayPayload(envelope: envelope)
        let data = try JSONEncoder().encode(payload)
        let decodedPayload = try JSONDecoder().decode(E2ERelayPayload.self, from: data)
        let decodedEnvelope = try decodedPayload.envelope()
        let json = String(data: data, encoding: .utf8) ?? ""

        #expect(decodedPayload.type == "e2e_envelope")
        #expect(decodedPayload.sessionID == "session-1")
        #expect(decodedPayload.senderDeviceID == "phone_1")
        #expect(decodedPayload.recipientDeviceID == "daemon_1")
        #expect(decodedPayload.sequence == String(UInt64.max))
        #expect(!json.contains("senderKeyId"))
        #expect(!json.contains("version"))
        #expect(decodedEnvelope.sequence == UInt64.max)
        #expect(decodedEnvelope.nonce == Data("nonce-000001".utf8))
        #expect(decodedEnvelope.ciphertext == Data("ciphertext".utf8))
    }

    @Test func handshakeTranscriptSignaturesVerifyAndBindRouteFields() throws {
        let phoneSigningPrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32))
        let daemonSigningPrivateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 4, count: 32))
        let phoneEphemeral = try E2EKeyPair(rawRepresentation: Data(repeating: 7, count: 32))
        let daemonEphemeral = try E2EKeyPair(rawRepresentation: Data(repeating: 9, count: 32))

        var start = Nudge_V1_E2EHandshakeStart()
        start.sessionID = "session-1"
        start.senderDeviceID = "phone_1"
        start.recipientDeviceID = "daemon_1"
        start.senderIdentityPublicKey = phoneSigningPrivateKey.publicKey.rawRepresentation
        start.senderEphemeralPublicKey = phoneEphemeral.publicKey
        start.createdAt = "2026-05-29T00:00:00.000Z"
        start = try signE2EHandshakeStart(
            signingPrivateKeyRaw: phoneSigningPrivateKey.rawRepresentation,
            start: start
        )
        try verifyE2EHandshakeStart(start, expectedIdentityPublicKey: phoneSigningPrivateKey.publicKey.rawRepresentation)

        var tamperedStart = start
        tamperedStart.recipientDeviceID = "daemon_2"
        #expect(throws: E2EEnvelopeError.invalidHandshakeSignature) {
            try verifyE2EHandshakeStart(tamperedStart, expectedIdentityPublicKey: phoneSigningPrivateKey.publicKey.rawRepresentation)
        }

        var finish = Nudge_V1_E2EHandshakeFinish()
        finish.sessionID = "session-1"
        finish.senderDeviceID = "daemon_1"
        finish.recipientDeviceID = "phone_1"
        finish.senderEphemeralPublicKey = daemonEphemeral.publicKey
        finish.acceptedAt = "2026-05-29T00:00:01.000Z"
        finish = try signE2EHandshakeFinish(
            signingPrivateKeyRaw: daemonSigningPrivateKey.rawRepresentation,
            start: start,
            finish: finish
        )
        try verifyE2EHandshakeFinish(
            start: start,
            finish: finish,
            expectedIdentityPublicKey: daemonSigningPrivateKey.publicKey.rawRepresentation
        )

        var tamperedFinish = finish
        tamperedFinish.senderEphemeralPublicKey[0] ^= 1
        #expect(throws: E2EEnvelopeError.invalidHandshakeSignature) {
            try verifyE2EHandshakeFinish(
                start: start,
                finish: tamperedFinish,
                expectedIdentityPublicKey: daemonSigningPrivateKey.publicKey.rawRepresentation
            )
        }
    }

    @Test func handshakeRelayPayloadsUseCanonicalJSONFields() throws {
        var start = Nudge_V1_E2EHandshakeStart()
        start.sessionID = "session-1"
        start.senderDeviceID = "phone_1"
        start.recipientDeviceID = "daemon_1"
        start.senderIdentityPublicKey = Data(repeating: 1, count: 32)
        start.senderEphemeralPublicKey = Data(repeating: 2, count: 32)
        start.transcriptSignature = Data(repeating: 3, count: 64)
        start.createdAt = "2026-05-29T00:00:00.000Z"
        var finish = Nudge_V1_E2EHandshakeFinish()
        finish.sessionID = "session-1"
        finish.senderDeviceID = "daemon_1"
        finish.recipientDeviceID = "phone_1"
        finish.senderEphemeralPublicKey = Data(repeating: 4, count: 32)
        finish.transcriptSignature = Data(repeating: 5, count: 64)
        finish.acceptedAt = "2026-05-29T00:00:01.000Z"

        let startPayload = E2EHandshakeStartRelayPayload(start: start)
        let finishPayload = E2EHandshakeFinishRelayPayload(finish: finish)
        let encodedStart = try JSONEncoder().encode(startPayload)
        let encodedFinish = try JSONEncoder().encode(finishPayload)
        let decodedStartPayload = try JSONDecoder().decode(E2EHandshakeStartRelayPayload.self, from: encodedStart)
        let decodedFinishPayload = try JSONDecoder().decode(E2EHandshakeFinishRelayPayload.self, from: encodedFinish)
        let decodedStart = try decodedStartPayload.start()
        let decodedFinish = try decodedFinishPayload.finish()
        let startJSON = String(data: encodedStart, encoding: .utf8) ?? ""

        #expect(decodedStartPayload.type == "e2e_handshake_start")
        #expect(decodedStartPayload.senderIdentityPublicKeyBase64 == Data(repeating: 1, count: 32).base64EncodedString())
        #expect(!startJSON.contains("senderKeyId"))
        #expect(decodedStart.senderEphemeralPublicKey == Data(repeating: 2, count: 32))
        #expect(decodedFinishPayload.type == "e2e_handshake_finish")
        #expect(decodedFinish.senderEphemeralPublicKey == Data(repeating: 4, count: 32))
    }
}
