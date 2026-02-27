import Foundation

@Observable
@MainActor
final class AuthService {
    private(set) var isAuthenticated = false
    private(set) var token: String?

    private var onAuthFailure: (() -> Void)?

    /// Check Keychain for an existing token on app launch.
    func bootstrap() {
        if let stored = KeychainService.load() {
            token = stored
            isAuthenticated = true
            print("[Auth] Loaded token from Keychain")
        } else {
            isAuthenticated = false
            print("[Auth] No stored token")
        }
    }

    /// Log in with username/password. Throws on failure.
    func login(username: String, password: String, baseURL: String? = nil) async throws {
        let base = baseURL ?? AppConfig.apiBase
        let url = URL(string: "\(base)/v1/auth/login")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["username": username, "password": password]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw AuthError.loginFailed
        }

        struct LoginResponse: Codable {
            let access_token: String
        }

        let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
        try KeychainService.save(token: loginResponse.access_token)
        token = loginResponse.access_token
        isAuthenticated = true
        print("[Auth] Login successful")
    }

    func logout() {
        KeychainService.delete()
        token = nil
        isAuthenticated = false
        print("[Auth] Logged out")
    }

    /// Called by APIClient when a 401 is received.
    func handleUnauthorized() {
        logout()
    }

    enum AuthError: LocalizedError {
        case loginFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .loginFailed: "Invalid username or password"
            case .invalidResponse: "Connection failed"
            }
        }
    }
}
