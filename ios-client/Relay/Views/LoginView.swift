import SwiftUI

struct LoginView: View {
    @Environment(\.relayTheme) private var theme
    @State private var vm: LoginViewModel

    init(authService: AuthService) {
        _vm = State(initialValue: LoginViewModel(authService: authService))
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Text("Relay")
                    .font(theme.headingFont(size: 32, weight: .bold))
                    .foregroundStyle(theme.textPrimary)

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
                            .font(theme.bodyFont(size: 13))
                            .foregroundStyle(theme.error)
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
                    .tint(theme.primary)
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
                .font(theme.bodyFont(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 32)

            ForEach(vm.accounts) { account in
                HStack {
                    Button(action: { vm.selectAccount(account) }) {
                        HStack(spacing: 8) {
                            if vm.selectedAccountId == account.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(theme.bodyFont(size: 14))
                                    .foregroundStyle(theme.primary)
                            } else {
                                Image(systemName: "person.circle")
                                    .font(theme.bodyFont(size: 14))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Text(account.displayLabel)
                                .font(theme.bodyFont(size: 13))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    Button(action: { vm.deleteAccount(account) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(theme.bodyFont(size: 16))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 6)
                .background(
                    vm.selectedAccountId == account.id
                        ? theme.elevated.opacity(0.6)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                .padding(.horizontal, 28)
            }
        }
    }
}

struct RelayTextFieldStyle: TextFieldStyle {
    @Environment(\.relayTheme) private var theme
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
            .foregroundStyle(theme.textSecondary)
            .font(theme.bodyFont(size: 14))
    }
}
