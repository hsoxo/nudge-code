import CryptoKit
import Foundation
import Testing
@testable import NudgeMobile

@Suite("Phone identity")
struct PhoneIdentityTests {
    @Test func keychainStoreReusesIdentityAndSignsMessages() throws {
        let store = KeychainPhoneIdentityStore(
            service: "dev.nudgecode.nudge.tests",
            account: UUID().uuidString
        )
        defer {
            try? store.reset()
        }

        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        let message = Data("bind challenge".utf8)
        let signature = try store.sign(message)
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: Data(base64Encoded: first.publicKey) ?? Data()
        )

        #expect(first == second)
        #expect(publicKey.isValidSignature(signature, for: message))
    }

    @Test func resetRemovesIdentity() throws {
        let store = KeychainPhoneIdentityStore(
            service: "dev.nudgecode.nudge.tests",
            account: UUID().uuidString
        )
        defer {
            try? store.reset()
        }

        let first = try store.loadOrCreate()
        try store.reset()
        let second = try store.loadOrCreate()

        #expect(first != second)
    }

    @Test func keychainStoreCommitsRotationCandidate() throws {
        let store = KeychainPhoneIdentityStore(
            service: "dev.nudgecode.nudge.tests",
            account: UUID().uuidString
        )
        defer {
            try? store.reset()
        }

        let first = try store.loadOrCreate()
        let rotation = try store.generateRotationCandidate()

        #expect(rotation.identity != first)
        #expect(try store.loadOrCreate() == first)

        try store.commitRotation(rotation)
        let rotated = try store.loadOrCreate()
        let message = Data("rotation challenge".utf8)
        let signature = try store.sign(message)
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: Data(base64Encoded: rotation.identity.publicKey) ?? Data()
        )

        #expect(rotated == rotation.identity)
        #expect(publicKey.isValidSignature(signature, for: message))
    }
}
