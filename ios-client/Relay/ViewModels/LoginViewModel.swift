import Foundation

@Observable
@MainActor
final class LoginViewModel {
    var username = ""
    var password = ""
    var serverURL = AppConfig.apiBase
    var error: String?
    var isLoading = false

    var accounts: [SavedAccount] = []
    var selectedAccountId: UUID?

    private let authService: AuthService

    init(authService: AuthService) {
        self.authService = authService
        accounts = AccountStore.shared.accounts
    }

    func selectAccount(_ account: SavedAccount) {
        selectedAccountId = account.id
        username = account.username
        serverURL = account.serverURL
        password = AccountStore.shared.password(for: account) ?? ""
    }

    func deleteAccount(_ account: SavedAccount) {
        AccountStore.shared.delete(account)
        accounts = AccountStore.shared.accounts
        if selectedAccountId == account.id {
            selectedAccountId = nil
        }
    }

    func login() async {
        let trimmedServer = serverURL.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedUser.isEmpty, !password.isEmpty else {
            error = "Username and password are required"
            return
        }

        isLoading = true
        error = nil

        // Persist the server URL so all services use it
        AppConfig.serverBase = trimmedServer

        do {
            try await authService.login(
                username: trimmedUser,
                password: password,
                baseURL: trimmedServer
            )
            // Save / update account on success
            let saved = AccountStore.shared.upsert(
                username: trimmedUser,
                serverURL: trimmedServer,
                password: password,
                existingId: selectedAccountId
            )
            selectedAccountId = saved.id
            accounts = AccountStore.shared.accounts
            AccountStore.shared.setCurrentAccount(saved)
        } catch let e as AuthService.AuthError {
            self.error = e.errorDescription
        } catch {
            self.error = "Connection failed"
        }

        isLoading = false
    }
}
