import Foundation

@Observable
@MainActor
final class LoginViewModel {
    var username = ""
    var password = ""
    var serverURL = AppConfig.apiBase
    var error: String?
    var isLoading = false

    private let authService: AuthService

    init(authService: AuthService) {
        self.authService = authService
    }

    func login() async {
        let trimmedServer = serverURL.trimmingCharacters(in: .whitespaces)
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty,
              !password.isEmpty else {
            error = "Username and password are required"
            return
        }

        isLoading = true
        error = nil

        // Persist the server URL so all services use it
        AppConfig.serverBase = trimmedServer

        do {
            try await authService.login(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password,
                baseURL: trimmedServer
            )
        } catch let e as AuthService.AuthError {
            self.error = e.errorDescription
        } catch {
            self.error = "Connection failed"
        }

        isLoading = false
    }
}
