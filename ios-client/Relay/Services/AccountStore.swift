import Foundation

struct SavedAccount: Codable, Identifiable, Equatable {
    let id: UUID
    var username: String
    var serverURL: String

    /// Display label: "username @ hostname"
    var displayLabel: String {
        let host = URL(string: serverURL)?.host ?? serverURL
        return "\(username) @ \(host)"
    }
}

@MainActor
final class AccountStore {
    static let shared = AccountStore()

    private let defaultsKey = "relay.savedAccounts"
    private let currentAccountKey = "relay.currentAccountId"
    private(set) var accounts: [SavedAccount] = []

    var currentAccount: SavedAccount? {
        guard let raw = UserDefaults.standard.string(forKey: currentAccountKey),
              let id = UUID(uuidString: raw) else { return nil }
        return accounts.first { $0.id == id }
    }

    private init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedAccount].self, from: data) else { return }
        accounts = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: - Public API

    func password(for account: SavedAccount) -> String? {
        KeychainService.loadPassword(forKey: account.id.uuidString)
    }

    /// Save or update an account. Pass `existingId` to update in-place.
    @discardableResult
    func upsert(username: String, serverURL: String, password: String, existingId: UUID? = nil) -> SavedAccount {
        // Update in-place if username + serverURL unchanged for the existing account
        if let id = existingId, let idx = accounts.firstIndex(where: { $0.id == id }) {
            let existing = accounts[idx]
            if existing.username == username && existing.serverURL == serverURL {
                try? KeychainService.savePassword(password, forKey: id.uuidString)
                persist()
                return existing
            }
        }

        // Check if an account with the same username+server already exists
        if let idx = accounts.firstIndex(where: { $0.username == username && $0.serverURL == serverURL }) {
            let existing = accounts[idx]
            try? KeychainService.savePassword(password, forKey: existing.id.uuidString)
            persist()
            return existing
        }

        // Create new
        let account = SavedAccount(id: UUID(), username: username, serverURL: serverURL)
        try? KeychainService.savePassword(password, forKey: account.id.uuidString)
        accounts.insert(account, at: 0)
        persist()
        return account
    }

    func setCurrentAccount(_ account: SavedAccount) {
        UserDefaults.standard.set(account.id.uuidString, forKey: currentAccountKey)
    }

    func clearCurrentAccount() {
        UserDefaults.standard.removeObject(forKey: currentAccountKey)
    }

    func delete(_ account: SavedAccount) {
        KeychainService.deletePassword(forKey: account.id.uuidString)
        accounts.removeAll { $0.id == account.id }
        persist()
    }
}
