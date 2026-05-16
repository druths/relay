import Foundation

/// Per-field configuration descriptor. Decoded from the server's
/// `/v1/agents/{llm,tts,stt}/providers` endpoints — no hardcoded lists in
/// this client. To add or change a provider, edit the schema lists in
/// `backend/app/services/{llm,tts,stt}/__init__.py`.
struct ProviderField: Codable, Equatable {
    let key: String
    let label: String
    let fieldType: FieldType
    let placeholder: String
    let required: Bool

    enum FieldType: String, Codable {
        case text
        case password
        case select
    }

    private enum CodingKeys: String, CodingKey {
        case key, label, placeholder, required
        case fieldType = "type"
    }

    init(key: String, label: String, type: FieldType = .text, placeholder: String = "", required: Bool = false) {
        self.key = key
        self.label = label
        self.fieldType = type
        self.placeholder = placeholder
        self.required = required
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        fieldType = (try? c.decode(FieldType.self, forKey: .fieldType)) ?? .text
        placeholder = (try? c.decode(String.self, forKey: .placeholder)) ?? ""
        required = (try? c.decode(Bool.self, forKey: .required)) ?? false
    }
}

struct ProviderSchema: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let fields: [ProviderField]

    /// True for client-only providers (e.g. Apple on-device STT) — surfaced
    /// in the picker but skipped server-side.
    let clientOnly: Bool

    private enum CodingKeys: String, CodingKey {
        case id, label, fields
        case clientOnly = "client_only"
    }

    init(id: String, label: String, fields: [ProviderField], clientOnly: Bool = false) {
        self.id = id
        self.label = label
        self.fields = fields
        self.clientOnly = clientOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        fields = (try? c.decode([ProviderField].self, forKey: .fields)) ?? []
        clientOnly = (try? c.decode(Bool.self, forKey: .clientOnly)) ?? false
    }
}

/// Server-backed provider catalog. Singleton holds the in-memory cache;
/// callers usually go through `RelayViewModel` or an `AgentManagementViewModel`
/// which loads it on demand.
@Observable
@MainActor
final class ProviderCatalog {
    static let shared = ProviderCatalog()

    var llm: [ProviderSchema] = []
    var tts: [ProviderSchema] = []
    var stt: [ProviderSchema] = []
    var loaded: Bool = false

    private var loadTask: Task<Void, Never>?

    func ensureLoaded(via apiClient: APIClient) async {
        if loaded { return }
        if let task = loadTask {
            await task.value
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            do {
                async let llmFetch: [ProviderSchema] = apiClient.request("GET", path: "/v1/agents/llm/providers")
                async let ttsFetch: [ProviderSchema] = apiClient.request("GET", path: "/v1/agents/tts/providers")
                async let sttFetch: [ProviderSchema] = apiClient.request("GET", path: "/v1/agents/stt/providers")
                let (llmVal, ttsVal, sttVal) = try await (llmFetch, ttsFetch, sttFetch)
                self.llm = llmVal
                self.tts = ttsVal
                self.stt = sttVal
                self.loaded = true
            } catch {
                print("[Relay] Failed to load provider schemas: \(error)")
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    func llmSchema(for id: String) -> ProviderSchema? {
        llm.first { $0.id == id }
    }

    func ttsSchema(for id: String) -> ProviderSchema? {
        tts.first { $0.id == id }
    }

    func sttSchema(for id: String) -> ProviderSchema? {
        stt.first { $0.id == id }
    }
}
