import Foundation

struct PrivateKeyStore {
    static let live = PrivateKeyStore()

    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let indexKey = "native.private-key.index"

    init(
        keychain: KeychainStore = KeychainStore(),
        defaults: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.defaults = defaults
    }

    func records() throws -> [PrivateKeyRecord] {
        guard let data = defaults.data(forKey: indexKey) else { return [] }
        return try JSONDecoder().decode([PrivateKeyRecord].self, from: data)
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    func secret(for record: PrivateKeyRecord) throws -> PrivateKeySecret {
        guard let value = try keychain.value(for: account(for: record.id)),
              let data = value.data(using: .utf8) else {
            throw PrivateKeyStoreError.missingSecret
        }
        return try JSONDecoder().decode(PrivateKeySecret.self, from: data)
    }

    func save(
        record: PrivateKeyRecord,
        key: String,
        passphrase: String?
    ) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw PrivateKeyStoreError.emptyKey
        }

        let secret = PrivateKeySecret(
            key: trimmedKey,
            passphrase: passphrase?.isEmpty == true ? nil : passphrase
        )
        let data = try JSONEncoder().encode(secret)
        guard let value = String(data: data, encoding: .utf8) else {
            throw PrivateKeyStoreError.invalidSecret
        }
        try keychain.set(value, for: account(for: record.id))

        var current = try records()
        current.removeAll { $0.id == record.id }
        current.append(record)
        defaults.set(try JSONEncoder().encode(current), forKey: indexKey)
    }

    func delete(_ record: PrivateKeyRecord) throws {
        try keychain.removeValue(for: account(for: record.id))
        var current = try records()
        current.removeAll { $0.id == record.id }
        defaults.set(try JSONEncoder().encode(current), forKey: indexKey)
    }

    private func account(for id: String) -> String {
        "private-key.\(id)"
    }
}

struct PrivateKeySecret: Codable, Equatable, Sendable {
    let key: String
    let passphrase: String?
}

enum PrivateKeyStoreError: LocalizedError, Equatable, Sendable {
    case emptyKey
    case invalidSecret
    case missingSecret

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "请输入私钥。"
        case .invalidSecret:
            return "私钥无法编码。"
        case .missingSecret:
            return "私钥不在钥匙串中。"
        }
    }
}
