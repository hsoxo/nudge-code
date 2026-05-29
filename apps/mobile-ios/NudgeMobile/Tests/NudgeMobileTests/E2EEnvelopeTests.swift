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
}
