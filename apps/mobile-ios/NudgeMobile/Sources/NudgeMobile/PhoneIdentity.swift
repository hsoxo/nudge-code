import CryptoKit
import Foundation
import Security

struct PhoneIdentity: Equatable, Sendable {
    var publicKey: String
}

protocol PhoneIdentityStore: Sendable {
    func loadOrCreate() throws -> PhoneIdentity
    func sign(_ message: Data) throws -> Data
    func reset() throws
}

final class KeychainPhoneIdentityStore: PhoneIdentityStore, @unchecked Sendable {
    private let service: String
    private let account: String

    init(
        service: String = "dev.nudgecode.nudge.phone-identity",
        account: String = "default-signing-key"
    ) {
        self.service = service
        self.account = account
    }

    func loadOrCreate() throws -> PhoneIdentity {
        if let data = try readPrivateKeyData() {
            return try identity(from: data)
        }

        let privateKey = Curve25519.Signing.PrivateKey()
        let data = privateKey.rawRepresentation
        try savePrivateKeyData(data)
        return try identity(from: data)
    }

    func sign(_ message: Data) throws -> Data {
        guard let data = try readPrivateKeyData() else {
            throw PhoneIdentityError.missingIdentity
        }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        return try privateKey.signature(for: message)
    }

    func reset() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PhoneIdentityError.keychainStatus(status)
        }
    }

    private func identity(from data: Data) throws -> PhoneIdentity {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        return PhoneIdentity(publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString())
    }

    private func readPrivateKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw PhoneIdentityError.invalidKeychainData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw PhoneIdentityError.keychainStatus(status)
        }
    }

    private func savePrivateKeyData(_ data: Data) throws {
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try updatePrivateKeyData(data)
            return
        }
        guard status == errSecSuccess else {
            throw PhoneIdentityError.keychainStatus(status)
        }
    }

    private func updatePrivateKeyData(_ data: Data) throws {
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            throw PhoneIdentityError.keychainStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum PhoneIdentityError: Error, Equatable {
    case missingIdentity
    case invalidKeychainData
    case keychainStatus(OSStatus)
}
