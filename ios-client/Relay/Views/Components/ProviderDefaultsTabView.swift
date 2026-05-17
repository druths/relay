import SwiftUI

/// Settings tab: edit platform-wide default values for each provider's
/// fields (API keys, base URLs). Fully schema-driven — adding a new provider
/// on the backend automatically surfaces here with no client change.
struct ProviderDefaultsTabView: View {
    let apiClient: APIClient
    let catalog: ProviderCatalog

    @Environment(\.relayTheme) private var theme
    @State private var groups: [ProviderDefaultsGroup] = []
    @State private var edits: [String: String] = [:]
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("These values are used as fallbacks when an agent doesn't specify its own. Leave any field blank to clear that default.")
                        .font(theme.bodyFont(size: 13))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    if !loaded {
                        Text("Loading…")
                            .font(theme.bodyFont(size: 14))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 16)
                    } else if groups.isEmpty {
                        Text("No platform-defaultable fields.")
                            .font(theme.bodyFont(size: 14))
                            .foregroundStyle(theme.textTertiary)
                            .padding(.horizontal, 16)
                    } else {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(group.label.uppercased())
                                    .font(theme.labelFont(size: 12))
                                    .tracking(1.5)
                                    .foregroundStyle(theme.textQuaternary)
                                    .padding(.horizontal, 16)
                                ForEach(group.providers) { provider in
                                    providerSection(provider)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
            }

            Divider().background(theme.border)
            HStack {
                if let error {
                    Text(error)
                        .font(theme.bodyFont(size: 12))
                        .foregroundStyle(theme.error)
                }
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    Text(saving ? "Saving…" : "Save Defaults")
                        .font(theme.bodyFont(size: 16, weight: .semibold))
                        .foregroundStyle(theme.sendButtonInverted ? theme.background : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(edits.isEmpty || saving ? theme.border : theme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
                .disabled(edits.isEmpty || saving)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .task { if !loaded { await load() } }
    }

    @ViewBuilder
    private func providerSection(_ provider: ProviderDefaultsProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(provider.label)
                .font(theme.bodyFont(size: 14, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 16)
            ForEach(provider.fields) { field in
                let editing = edits[field.platformKey] != nil
                let value = editing ? (edits[field.platformKey] ?? "") : (field.value ?? "")
                let isPassword = field.fieldType == "password" && !editing
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label)
                        .font(theme.bodyFont(size: 12))
                        .foregroundStyle(theme.textQuaternary)
                    Group {
                        if isPassword {
                            SecureField(field.placeholder, text: Binding(
                                get: { value },
                                set: { edits[field.platformKey] = $0 },
                            ))
                        } else {
                            TextField(field.placeholder, text: Binding(
                                get: { value },
                                set: { edits[field.platformKey] = $0 },
                            ))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        }
                    }
                    .font(theme.bodyFont(size: 16))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(theme.elevated)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
        .background(theme.surface.opacity(0.3))
    }

    private func load() async {
        do {
            struct Response: Decodable { let groups: [ProviderDefaultsGroup] }
            let resp: Response = try await apiClient.request(
                "GET", path: "/v1/platform/provider-defaults",
            )
            groups = resp.groups
            edits = [:]
            loaded = true
        } catch {
            self.error = "Failed to load defaults."
            loaded = true
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        error = nil
        // Ignore values that look masked — the UI would re-send the bullet
        // string and accidentally overwrite the real stored key.
        var payload: [String: String] = [:]
        for (k, v) in edits {
            if v.contains("\u{2022}") { continue }
            payload[k] = v
        }
        struct Body: Encodable { let values: [String: String] }
        do {
            struct Response: Decodable { let groups: [ProviderDefaultsGroup] }
            let resp: Response = try await apiClient.request(
                "PUT", path: "/v1/platform/provider-defaults",
                body: Body(values: payload),
            )
            groups = resp.groups
            edits = [:]
            catalog.invalidate()
            // Re-fetch the schemas so the per-agent screen picks up new
            // platform_default_set flags immediately.
            await catalog.ensureLoaded(via: apiClient)
        } catch {
            self.error = "Save failed."
        }
    }
}
