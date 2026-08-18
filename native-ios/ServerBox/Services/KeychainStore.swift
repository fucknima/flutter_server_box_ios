import Foundation
import Security

struct KeychainStore: Sendable {
    private let service: String

    init(service: String = "tech.lolli.serverbox.native") {
        self.service = service
    }

    func set(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidValue
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    func value(for account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unhandledStatus(status)
        }
        return value
    }

    func removeValue(for account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }
}

struct SSHCredentialStore: Sendable {
    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    func save(_ credential: ServerCredentialInput, for serverID: UUID) throws {
        let stored: StoredCredential
        switch credential {
        case .password(let value):
            stored = StoredCredential(password: value)
        case .privateKey(let value, let passphrase):
            stored = StoredCredential(privateKey: value, passphrase: passphrase)
        }

        let data = try JSONEncoder().encode(stored)
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidValue
        }
        try keychain.set(value, for: account(for: serverID))
    }

    func load(for serverID: UUID) throws -> ServerCredentialInput? {
        guard let value = try keychain.value(for: account(for: serverID)),
              let data = value.data(using: .utf8) else {
            return nil
        }

        let stored = try JSONDecoder().decode(StoredCredential.self, from: data)
        if let password = stored.password {
            return .password(password)
        }
        if let privateKey = stored.privateKey {
            return .privateKey(privateKey, passphrase: stored.passphrase)
        }
        return nil
    }

    func remove(for serverID: UUID) throws {
        try keychain.removeValue(for: account(for: serverID))
    }

    private func account(for serverID: UUID) -> String {
        "ssh-credential.\(serverID.uuidString)"
    }
}

struct AgentCredentialStore: Sendable {
    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    func save(apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.removeValue(for: "agent-api-key")
        } else {
            try keychain.set(trimmed, for: "agent-api-key")
        }
    }

    func loadAPIKey() throws -> String? {
        try keychain.value(for: "agent-api-key")
    }
}

private struct StoredCredential: Codable {
    let password: String?
    let privateKey: String?
    let passphrase: String?

    init(
        password: String? = nil,
        privateKey: String? = nil,
        passphrase: String? = nil
    ) {
        self.password = password
        self.privateKey = privateKey
        self.passphrase = passphrase
    }
}

enum KeychainError: LocalizedError, Equatable, Sendable {
    case invalidValue
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            return "凭据无法编码。"
        case .unhandledStatus(let status):
            return "钥匙串操作失败（\(status)）。"
        }
    }
}
