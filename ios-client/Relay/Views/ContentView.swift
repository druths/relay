import SwiftUI

struct ContentView: View {
    @State private var appVM = AppViewModel()

    var body: some View {
        Group {
            if appVM.isLoading {
                Color.relayBackground.ignoresSafeArea()
            } else if appVM.authService.isAuthenticated {
                RelayView(authService: appVM.authService)
            } else {
                LoginView(authService: appVM.authService)
            }
        }
        .onAppear { appVM.bootstrap() }
    }
}
