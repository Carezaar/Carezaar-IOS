import Foundation

/// Signals that the session could not be recovered and the app must return to `Intro`.
/// `SessionManager` observes this to mirror the Android behaviour of dropping to the
/// unauthenticated graph when a refresh fails.
extension Notification.Name {
    static let carezaarSessionExpired = Notification.Name("Carezaar.sessionExpired")
}

actor APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let tokens: TokenStore
    /// Single-flight refresh: concurrent 403s must not fire parallel refresh calls.
    private var refreshTask: Task<Bool, Never>?

    init(tokens: TokenStore = .shared) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = APIConfiguration.requestTimeout
        config.timeoutIntervalForResource = APIConfiguration.requestTimeout * 1.5
        // Fail fast offline: waiting for connectivity would leave a screen spinning
        // with no way for the user to know or retry.
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.tokens = tokens
        self.decoder = JSONDecoder()
    }

    // MARK: - Public

    /// Sends a request and unwraps the envelope's `result`.
    func send<T: Decodable>(_ endpoint: Endpoint, as type: T.Type = T.self) async throws -> T {
        let envelope: APIEnvelope<T> = try await sendEnvelope(endpoint)
        guard let result = envelope.result else {
            throw APIError.decoding("Response contained no result for \(endpoint.path).")
        }
        return result
    }

    /// Sends a request whose `result` is empty or ignored (logout, reject, delete…).
    @discardableResult
    func sendIgnoringResult(_ endpoint: Endpoint) async throws -> String? {
        let envelope: APIEnvelope<EmptyPayload> = try await sendEnvelope(endpoint)
        return envelope.message
    }

    /// Sends a request and returns the full envelope, for callers that need `meta`
    /// to drive pagination.
    func sendPaged<T: Decodable>(_ endpoint: Endpoint, as type: T.Type = T.self) async throws -> (T, APIMeta?) {
        let envelope: APIEnvelope<T> = try await sendEnvelope(endpoint)
        guard let result = envelope.result else {
            throw APIError.decoding("Response contained no result for \(endpoint.path).")
        }
        return (result, envelope.meta)
    }

    // MARK: - Core

    private func sendEnvelope<T: Decodable>(_ endpoint: Endpoint) async throws -> APIEnvelope<T> {
        do {
            return try await perform(endpoint)
        } catch APIError.unauthenticated(let message) {
            // The backend answers 403 for an absent or expired token. Refresh once,
            // then replay the original request.
            // An unauthenticated endpoint (login, register) says nothing about the session.
            guard endpoint.requiresAuth, tokens.accessToken != nil else { throw APIError.unauthenticated(message) }
            guard tokens.refreshToken != nil else {
                await expireSession()
                throw APIError.unauthenticated(message)
            }
            guard await refreshSession() else {
                await expireSession()
                throw APIError.unauthenticated(message)
            }
            return try await perform(endpoint)
        }
    }

    private func perform<T: Decodable>(_ endpoint: Endpoint) async throws -> APIEnvelope<T> {
        var request = try buildRequest(endpoint)
        #if DEBUG
        request = QANetworkFault.apply(request)
        if let latency = QANetworkFault.latency { try await Task.sleep(for: .seconds(latency)) }
        #endif
        var data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // A view that went away cancelled its task; not a connectivity problem.
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw APIError.timeout
        } catch let error as URLError {
            throw APIError.network(error.localizedDescription)
        } catch {
            throw APIError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.unknown("Malformed response.")
        }
        #if DEBUG
        data = QANetworkFault.corruptMatchState(data, path: endpoint.path)
        #endif

        // Several write endpoints answer 204 with an empty body instead of the envelope.
        if http.statusCode == 204 || data.isEmpty {
            if (200..<300).contains(http.statusCode) { return .empty }
        }

        // Decode the envelope first: the backend returns it for errors too.
        let envelope = try? decoder.decode(APIEnvelope<T>.self, from: data)
        let message = envelope?.message ?? Self.rawMessage(from: data) ?? ""

        switch http.statusCode {
        case 200..<300:
            guard let envelope else {
                throw APIError.decoding("Could not decode \(T.self) from \(endpoint.path).")
            }
            return envelope
        case 401, 403:
            throw APIError.unauthenticated(message)
        case 404:
            throw APIError.notFound(message)
        case 422:
            let fields = envelope?.errors ?? Self.rawErrors(from: data) ?? [:]
            throw APIError.validation(message: message, fields: fields)
        case 500...:
            throw APIError.server(message)
        default:
            throw APIError.unknown(message)
        }
    }

    // MARK: - Refresh

    private func refreshSession() async -> Bool {
        if let existing = refreshTask { return await existing.value }
        let task = Task<Bool, Never> { [tokens] in
            guard let refresh = tokens.refreshToken else { return false }
            var request = URLRequest(url: APIConfiguration.baseURL.appendingPathComponent("auth/refresh"))
            request.httpMethod = HTTPMethod.put.rawValue
            // The refresh token is presented as the bearer credential.
            request.setValue("Bearer \(refresh)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(AppLanguage.currentCode, forHTTPHeaderField: "Accept-Language")
            // The live backend answers 422 ("The version app field is required.") to a
            // refresh without the login device fields, although Android sends none and
            // so signs its users out on every expiry (BE-06).
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncode(DeviceInfo.loginFields)
            guard let (data, response) = try? await self.session.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let envelope = try? self.decoder.decode(APIEnvelope<Session>.self, from: data),
                  let session = envelope.result
            else { return false }
            tokens.save(session)
            return true
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    private func expireSession() async {
        tokens.clear()
        await MainActor.run {
            NotificationCenter.default.post(name: .carezaarSessionExpired, object: nil)
        }
    }

    // MARK: - Request building

    private func buildRequest(_ endpoint: Endpoint) throws -> URLRequest {
        var components = URLComponents(
            url: APIConfiguration.baseURL.appendingPathComponent(endpoint.path),
            resolvingAgainstBaseURL: false
        )
        let items = endpoint.query.compactMapValues { $0 }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !items.isEmpty { components?.queryItems = items.sorted { $0.name < $1.name } }
        guard let url = components?.url else {
            throw APIError.unknown("Could not build a URL for \(endpoint.path).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The backend localises from this header and 500s on "*".
        request.setValue(AppLanguage.currentCode, forHTTPHeaderField: "Accept-Language")

        if endpoint.requiresAuth, let token = tokens.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        switch endpoint.body {
        case .none:
            break
        case .form(let fields):
            request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                             forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncode(fields)
        case .multipart(let fields, let file):
            let boundary = "Boundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)",
                             forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipartEncode(fields: fields, file: file, boundary: boundary)
        }
        return request
    }

    /// Percent-encodes a form body. Nil values are dropped, matching Retrofit's
    /// handling of nullable `@Field` parameters.
    static func formEncode(_ fields: [String: FormValue?]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.compactMap { key, value -> String? in
            guard let value else { return nil }
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.encoded.addingPercentEncoding(withAllowedCharacters: allowed) ?? value.encoded
            return "\(k)=\(v)"
        }
        return Data(pairs.sorted().joined(separator: "&").utf8)
    }

    static func multipartEncode(fields: [String: String?], file: MultipartFile?, boundary: String) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (key, value) in fields.compactMapValues({ $0 }).sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        if let file {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
            append("Content-Type: \(file.mimeType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Error parsing fallbacks

    private static func rawMessage(from data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
    }

    private static func rawErrors(from data: Data) -> [String: [String]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = object["errors"] as? [String: Any] else { return nil }
        return errors.compactMapValues { $0 as? [String] }
    }
}
