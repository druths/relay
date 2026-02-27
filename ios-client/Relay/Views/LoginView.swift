import SwiftUI

struct LoginView: View {
    @State private var vm: LoginViewModel

    init(authService: AuthService) {
        _vm = State(initialValue: LoginViewModel(authService: authService))
    }

    var body: some View {
        ZStack {
            Color.relayBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Text("Relay")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color.relayTextPrimary)

                VStack(spacing: 12) {
                    TextField("Username", text: $vm.username)
                        .textFieldStyle(RelayTextFieldStyle())
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $vm.password)
                        .textFieldStyle(RelayTextFieldStyle())
                        .textContentType(.password)

                    if let error = vm.error {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.relayError)
                    }

                    Button(action: { Task { await vm.login() } }) {
                        Group {
                            if vm.isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Sign In")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.relayPrimary)
                    .disabled(vm.isLoading)
                }
                .padding(.horizontal, 32)

                Spacer()

                TextField("Server URL", text: $vm.serverURL)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.relayTextTertiary)
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }
        }
    }
}

struct RelayTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.relayElevated)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(Color.relayTextSecondary)
            .font(.system(size: 14))
    }
}
