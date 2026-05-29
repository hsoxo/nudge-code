import CryptoKit
import Foundation

enum E2EEnvelopeError: Error, Equatable {
    case identityKeyMismatch
    case invalidHandshakeSignature
    case invalidNonceLength
    case invalidRelayPayload
    case routeMismatch
    case replayDetected
    case sessionMismatch
}

enum E2ESessionRole {
    case phone
    case daemon
}

struct E2EKeyPair {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    static func generate() -> E2EKeyPair {
        E2EKeyPair(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    private init(privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.privateKey = privateKey
    }

    init(rawRepresentation: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    var publicKey: Data {
        privateKey.publicKey.rawRepresentation
    }
}

struct E2ESession {
    let sessionID: String
    let localDeviceID: String
    let remoteDeviceID: String
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var nextSequence: UInt64 = 1
    private var highestReceivedBySender: [String: UInt64] = [:]

    init(
        sessionID: String,
        localDeviceID: String,
        remoteDeviceID: String,
        localKeyPair: E2EKeyPair,
        remotePublicKey: Data,
        role: E2ESessionRole
    ) throws {
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let sharedSecret = try localKeyPair.privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let keys = Self.deriveDirectionalKeys(
            sessionID: Data(sessionID.utf8),
            sharedSecret: sharedSecret,
            localPublicKey: localKeyPair.publicKey,
            remotePublicKey: remotePublicKey,
            role: role
        )
        self.sessionID = sessionID
        self.localDeviceID = localDeviceID
        self.remoteDeviceID = remoteDeviceID
        switch role {
        case .phone:
            sendKey = keys.phoneToDaemon
            receiveKey = keys.daemonToPhone
        case .daemon:
            sendKey = keys.daemonToPhone
            receiveKey = keys.phoneToDaemon
        }
    }

    mutating func encrypt(messageType: String, plaintext: Data) throws -> Nudge_V1_E2EEncryptedEnvelope {
        let sequence = nextSequence
        nextSequence = nextSequence &+ 1
        let nonce = sequenceNonce(sequence)
        let aad = associatedData(
            sessionID: sessionID,
            senderDeviceID: localDeviceID,
            recipientDeviceID: remoteDeviceID,
            messageType: messageType,
            sequence: sequence,
            nonce: nonce
        )
        let sealed = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
        var envelope = Nudge_V1_E2EEncryptedEnvelope()
        envelope.sessionID = sessionID
        envelope.senderDeviceID = localDeviceID
        envelope.recipientDeviceID = remoteDeviceID
        envelope.messageType = messageType
        envelope.sequence = sequence
        envelope.nonce = nonce
        envelope.ciphertext = sealed.ciphertext + sealed.tag
        return envelope
    }

    mutating func decrypt(_ envelope: Nudge_V1_E2EEncryptedEnvelope) throws -> Data {
        guard envelope.sessionID == sessionID else {
            throw E2EEnvelopeError.sessionMismatch
        }
        guard envelope.senderDeviceID == remoteDeviceID,
              envelope.recipientDeviceID == localDeviceID
        else {
            throw E2EEnvelopeError.routeMismatch
        }
        guard envelope.nonce.count == 12 else {
            throw E2EEnvelopeError.invalidNonceLength
        }
        if envelope.sequence <= highestReceivedBySender[envelope.senderDeviceID, default: 0] {
            throw E2EEnvelopeError.replayDetected
        }
        let aad = associatedData(
            sessionID: envelope.sessionID,
            senderDeviceID: envelope.senderDeviceID,
            recipientDeviceID: envelope.recipientDeviceID,
            messageType: envelope.messageType,
            sequence: envelope.sequence,
            nonce: envelope.nonce
        )
        let sealed = try ChaChaPoly.SealedBox(
            combined: envelope.nonce + envelope.ciphertext
        )
        let plaintext = try ChaChaPoly.open(sealed, using: receiveKey, authenticating: aad)
        highestReceivedBySender[envelope.senderDeviceID] = envelope.sequence
        return plaintext
    }

    private static func deriveDirectionalKeys(
        sessionID: Data,
        sharedSecret: SharedSecret,
        localPublicKey: Data,
        remotePublicKey: Data,
        role: E2ESessionRole
    ) -> (phoneToDaemon: SymmetricKey, daemonToPhone: SymmetricKey) {
        var salt = Data()
        salt.append(sessionID)
        switch role {
        case .phone:
            salt.append(localPublicKey)
            salt.append(remotePublicKey)
        case .daemon:
            salt.append(remotePublicKey)
            salt.append(localPublicKey)
        }
        return (
            sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("nudge e2e phone-to-daemon v1".utf8),
                outputByteCount: 32
            ),
            sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("nudge e2e daemon-to-phone v1".utf8),
                outputByteCount: 32
            )
        )
    }
}

struct E2ERelayPayload: Codable, Equatable {
    let type: String
    let sessionID: String
    let senderDeviceID: String
    let recipientDeviceID: String
    let messageType: String
    let sequence: String
    let nonceBase64: String
    let ciphertextBase64: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "sessionId"
        case senderDeviceID = "senderDeviceId"
        case recipientDeviceID = "recipientDeviceId"
        case messageType
        case sequence
        case nonceBase64
        case ciphertextBase64
    }

    init(
        type: String,
        sessionID: String,
        senderDeviceID: String,
        recipientDeviceID: String,
        messageType: String,
        sequence: String,
        nonceBase64: String,
        ciphertextBase64: String
    ) {
        self.type = type
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.recipientDeviceID = recipientDeviceID
        self.messageType = messageType
        self.sequence = sequence
        self.nonceBase64 = nonceBase64
        self.ciphertextBase64 = ciphertextBase64
    }

    init(envelope: Nudge_V1_E2EEncryptedEnvelope) {
        type = "e2e_envelope"
        sessionID = envelope.sessionID
        senderDeviceID = envelope.senderDeviceID
        recipientDeviceID = envelope.recipientDeviceID
        messageType = envelope.messageType
        sequence = String(envelope.sequence)
        nonceBase64 = envelope.nonce.base64EncodedString()
        ciphertextBase64 = envelope.ciphertext.base64EncodedString()
    }

    func envelope() throws -> Nudge_V1_E2EEncryptedEnvelope {
        guard type == "e2e_envelope",
              let sequence = UInt64(sequence),
              let nonce = Data(base64Encoded: nonceBase64),
              let ciphertext = Data(base64Encoded: ciphertextBase64)
        else {
            throw E2EEnvelopeError.invalidRelayPayload
        }
        var envelope = Nudge_V1_E2EEncryptedEnvelope()
        envelope.sessionID = sessionID
        envelope.senderDeviceID = senderDeviceID
        envelope.recipientDeviceID = recipientDeviceID
        envelope.messageType = messageType
        envelope.sequence = sequence
        envelope.nonce = nonce
        envelope.ciphertext = ciphertext
        return envelope
    }
}

struct E2EHandshakeStartRelayPayload: Codable, Equatable {
    let type: String
    let sessionID: String
    let senderDeviceID: String
    let recipientDeviceID: String
    let senderIdentityPublicKeyBase64: String
    let senderEphemeralPublicKeyBase64: String
    let transcriptSignatureBase64: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "sessionId"
        case senderDeviceID = "senderDeviceId"
        case recipientDeviceID = "recipientDeviceId"
        case senderIdentityPublicKeyBase64
        case senderEphemeralPublicKeyBase64
        case transcriptSignatureBase64
        case createdAt
    }

    init(start: Nudge_V1_E2EHandshakeStart) {
        type = "e2e_handshake_start"
        sessionID = start.sessionID
        senderDeviceID = start.senderDeviceID
        recipientDeviceID = start.recipientDeviceID
        senderIdentityPublicKeyBase64 = start.senderIdentityPublicKey.base64EncodedString()
        senderEphemeralPublicKeyBase64 = start.senderEphemeralPublicKey.base64EncodedString()
        transcriptSignatureBase64 = start.transcriptSignature.base64EncodedString()
        createdAt = start.createdAt
    }

    func start() throws -> Nudge_V1_E2EHandshakeStart {
        guard type == "e2e_handshake_start",
              let senderIdentityPublicKey = Data(base64Encoded: senderIdentityPublicKeyBase64),
              let senderEphemeralPublicKey = Data(base64Encoded: senderEphemeralPublicKeyBase64),
              let transcriptSignature = Data(base64Encoded: transcriptSignatureBase64)
        else {
            throw E2EEnvelopeError.invalidRelayPayload
        }
        var start = Nudge_V1_E2EHandshakeStart()
        start.sessionID = sessionID
        start.senderDeviceID = senderDeviceID
        start.recipientDeviceID = recipientDeviceID
        start.senderIdentityPublicKey = senderIdentityPublicKey
        start.senderEphemeralPublicKey = senderEphemeralPublicKey
        start.transcriptSignature = transcriptSignature
        start.createdAt = createdAt
        return start
    }
}

struct E2EHandshakeFinishRelayPayload: Codable, Equatable {
    let type: String
    let sessionID: String
    let senderDeviceID: String
    let recipientDeviceID: String
    let senderEphemeralPublicKeyBase64: String
    let transcriptSignatureBase64: String
    let acceptedAt: String

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "sessionId"
        case senderDeviceID = "senderDeviceId"
        case recipientDeviceID = "recipientDeviceId"
        case senderEphemeralPublicKeyBase64
        case transcriptSignatureBase64
        case acceptedAt
    }

    init(
        type: String,
        sessionID: String,
        senderDeviceID: String,
        recipientDeviceID: String,
        senderEphemeralPublicKeyBase64: String,
        transcriptSignatureBase64: String,
        acceptedAt: String
    ) {
        self.type = type
        self.sessionID = sessionID
        self.senderDeviceID = senderDeviceID
        self.recipientDeviceID = recipientDeviceID
        self.senderEphemeralPublicKeyBase64 = senderEphemeralPublicKeyBase64
        self.transcriptSignatureBase64 = transcriptSignatureBase64
        self.acceptedAt = acceptedAt
    }

    init(finish: Nudge_V1_E2EHandshakeFinish) {
        type = "e2e_handshake_finish"
        sessionID = finish.sessionID
        senderDeviceID = finish.senderDeviceID
        recipientDeviceID = finish.recipientDeviceID
        senderEphemeralPublicKeyBase64 = finish.senderEphemeralPublicKey.base64EncodedString()
        transcriptSignatureBase64 = finish.transcriptSignature.base64EncodedString()
        acceptedAt = finish.acceptedAt
    }

    func finish() throws -> Nudge_V1_E2EHandshakeFinish {
        guard type == "e2e_handshake_finish",
              let senderEphemeralPublicKey = Data(base64Encoded: senderEphemeralPublicKeyBase64),
              let transcriptSignature = Data(base64Encoded: transcriptSignatureBase64)
        else {
            throw E2EEnvelopeError.invalidRelayPayload
        }
        var finish = Nudge_V1_E2EHandshakeFinish()
        finish.sessionID = sessionID
        finish.senderDeviceID = senderDeviceID
        finish.recipientDeviceID = recipientDeviceID
        finish.senderEphemeralPublicKey = senderEphemeralPublicKey
        finish.transcriptSignature = transcriptSignature
        finish.acceptedAt = acceptedAt
        return finish
    }
}

func signE2EHandshakeStart(
    signingPrivateKeyRaw: Data,
    start: Nudge_V1_E2EHandshakeStart
) throws -> Nudge_V1_E2EHandshakeStart {
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKeyRaw)
    var signed = start
    signed.transcriptSignature = Data()
    signed.transcriptSignature = try privateKey.signature(for: handshakeStartTranscript(signed))
    return signed
}

func verifyE2EHandshakeStart(
    _ start: Nudge_V1_E2EHandshakeStart,
    expectedIdentityPublicKey: Data
) throws {
    guard start.senderIdentityPublicKey == expectedIdentityPublicKey else {
        throw E2EEnvelopeError.identityKeyMismatch
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: expectedIdentityPublicKey)
    guard publicKey.isValidSignature(start.transcriptSignature, for: handshakeStartTranscript(start)) else {
        throw E2EEnvelopeError.invalidHandshakeSignature
    }
}

func signE2EHandshakeFinish(
    signingPrivateKeyRaw: Data,
    start: Nudge_V1_E2EHandshakeStart,
    finish: Nudge_V1_E2EHandshakeFinish
) throws -> Nudge_V1_E2EHandshakeFinish {
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKeyRaw)
    var signed = finish
    signed.transcriptSignature = Data()
    signed.transcriptSignature = try privateKey.signature(for: handshakeFinishTranscript(start: start, finish: signed))
    return signed
}

func verifyE2EHandshakeFinish(
    start: Nudge_V1_E2EHandshakeStart,
    finish: Nudge_V1_E2EHandshakeFinish,
    expectedIdentityPublicKey: Data
) throws {
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: expectedIdentityPublicKey)
    guard publicKey.isValidSignature(
        finish.transcriptSignature,
        for: handshakeFinishTranscript(start: start, finish: finish)
    ) else {
        throw E2EEnvelopeError.invalidHandshakeSignature
    }
}

private func sequenceNonce(_ sequence: UInt64) -> Data {
    var nonce = Data(repeating: 0, count: 12)
    var bigEndian = sequence.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
        nonce.replaceSubrange(4 ..< 12, with: bytes)
    }
    return nonce
}

private func associatedData(
    sessionID: String,
    senderDeviceID: String,
    recipientDeviceID: String,
    messageType: String,
    sequence: UInt64,
    nonce: Data
) -> Data {
    var sequence = sequence.bigEndian
    var chunks: [Data] = [
        Data("nudge.e2e.envelope.v1".utf8),
        Data(sessionID.utf8),
        Data(senderDeviceID.utf8),
        Data(recipientDeviceID.utf8),
        Data(messageType.utf8),
        withUnsafeBytes(of: &sequence) { Data($0) },
        nonce
    ]
    return chunks.removeFirst() + chunks.reduce(into: Data()) { result, chunk in
        result.append(0)
        result.append(chunk)
    }
}

private func handshakeStartTranscript(_ start: Nudge_V1_E2EHandshakeStart) -> Data {
    joinTranscriptFields([
        Data("nudge.e2e.handshake.start.v1".utf8),
        Data(start.sessionID.utf8),
        Data(start.senderDeviceID.utf8),
        Data(start.recipientDeviceID.utf8),
        start.senderIdentityPublicKey,
        start.senderEphemeralPublicKey,
        Data(start.createdAt.utf8)
    ])
}

private func handshakeFinishTranscript(
    start: Nudge_V1_E2EHandshakeStart,
    finish: Nudge_V1_E2EHandshakeFinish
) -> Data {
    joinTranscriptFields([
        Data("nudge.e2e.handshake.finish.v1".utf8),
        handshakeStartTranscript(start),
        start.transcriptSignature,
        Data(finish.sessionID.utf8),
        Data(finish.senderDeviceID.utf8),
        Data(finish.recipientDeviceID.utf8),
        finish.senderEphemeralPublicKey,
        Data(finish.acceptedAt.utf8)
    ])
}

private func joinTranscriptFields(_ fields: [Data]) -> Data {
    guard var result = fields.first else {
        return Data()
    }
    for field in fields.dropFirst() {
        result.append(0)
        result.append(field)
    }
    return result
}
