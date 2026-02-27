import Foundation

@Observable
@MainActor
final class AppViewModel {
    var isLoading = true
    let authService = AuthService()

    func bootstrap() {
        authService.bootstrap()
        isLoading = false
    }
}
