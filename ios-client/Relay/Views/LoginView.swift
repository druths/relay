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
                    TextField("Server URL", text: $vm.serverURL)
                        .textFieldStyle(RelayTextFieldStyle())
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

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

                // Saved accounts
                if !vm.accounts.isEmpty {
                    savedAccountsList
                }

                Spacer()
            }
        }
    }

    private var savedAccountsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Saved accounts")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.relayTextTertiary)
                .padding(.horizontal, 32)

            ForEach(vm.accounts) { account in
                HStack {
                    Button(action: { vm.selectAccount(account) }) {
                        HStack(spacing: 8) {
                            if vm.selectedAccountId == account.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.relayPrimary)
                            } else {
                                Image(systemName: "person.circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.relayTextTertiary)
                            }
                            Text(account.displayLabel)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.relayTextSecondary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    Button(action: { vm.deleteAccount(account) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.relayTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 6)
                .background(
                    vm.selectedAccountId == account.id
                        ? Color.relayElevated.opacity(0.6)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 28)
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
