import SwiftUI

struct ContentView: View {
    let themeManager: ThemeManager
    @State private var appVM = AppViewModel()
    @Environment(\.relayTheme) private var theme

    var body: some View {
        Group {
            if appVM.isLoading {
                theme.background.ignoresSafeArea()
            } else if appVM.authService.isAuthenticated {
                RelayView(authService: appVM.authService, themeManager: themeManager)
            } else {
                LoginView(authService: appVM.authService)
            }
        }
        .onAppear { appVM.bootstrap() }
    }
}
