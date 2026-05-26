import Foundation

actor APIClient {
    private let session: URLSession
    private let authService: AuthService

    init(authService: AuthService) {
        self.session = URLSession.shared
        self.authService = authService
    }

    /// Make an authenticated API request and decode the response.
    func request<T: Decodable>(_ method: String, path: String, body: (any Encodable)? = nil) async throws -> T {
        let (data, _) = try await rawRequest(method, path: path, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Make an authenticated API request and return raw data + response.
    func rawRequest(_ method: String, path: String, body: (any Encodable)? = nil) async throws -> (Data, HTTPURLResponse) {
        let token = await authService.token
        let url = URL(string: "\(AppConfig.apiBase)\(path)")!

        var request = URLRequest(url: url)
        request.httpMethod = method

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            await authService.handleUnauthorized()
            throw APIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        return (data, httpResponse)
    }

    /// Make a DELETE request (no response body expected).
    func delete(path: String) async throws {
        let _ = try await rawRequest("DELETE", path: path)
    }

    /// PUT raw bytes with an explicit Content-Type. Mirrors `rawRequest` but
    /// skips JSON-encoding the body — used for `writeFile` (project /
    /// workspace filesystem PUT) where the body is raw file bytes.
    func putRawBytes(
        path: String, body: Data,
        contentType: String = "application/octet-stream",
    ) async throws {
        let token = await authService.token
        let url = URL(string: "\(AppConfig.apiBase)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 {
            await authService.handleUnauthorized()
            throw APIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.httpError(http.statusCode)
        }
    }

    /// Upload a single file via multipart/form-data and decode the JSON response.
    func uploadMultipart<T: Decodable>(
        _ method: String, path: String,
        field: String, filename: String, mimeType: String, data: Data,
    ) async throws -> T {
        let token = await authService.token
        let url = URL(string: "\(AppConfig.apiBase)\(path)")!

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (respData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if http.statusCode == 401 {
            await authService.handleUnauthorized()
            throw APIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: respData)
    }

    enum APIError: LocalizedError {
        case invalidResponse
        case unauthorized
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "Invalid server response"
            case .unauthorized: "Authentication required"
            case .httpError(let code): "Server error (\(code))"
            }
        }
    }
}

// Helper for encoding PATCH bodies with snake_case keys
struct AgentUpdateBody: Encodable, Sendable {
    var values: [String: AnyCodableValue]

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

// A type-erased Codable value for dynamic JSON bodies
enum AnyCodableValue: Codable, Equatable, Sendable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)
    case dict([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([String: AnyCodableValue].self) {
            self = .dict(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported value")
        }
    }

    var stringValue: String {
        switch self {
        case .string(let v): v
        case .double(let v): String(v)
        case .int(let v): String(v)
        case .bool(let v): String(v)
        case .dict: "{}"
        case .null: ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .dict(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}
