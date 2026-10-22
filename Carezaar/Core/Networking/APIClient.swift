import Foundation

/// Signals that the session could not be recovered and the app must return to `Intro`.
/// `SessionManager` observes this to mirror the Android behaviour of dropping to the
/// unauthenticated graph when a refresh fails.
extension Notification.Name {
    static let carezaarSessionExpired = Notification.Name("Carezaar.sessionExpired")
}

actor APIClient {
    static let shared = APIClient(reportRenewalUnreachable: { generation in
        await SessionRecoveryCoordinator.shared.present(generation: generation)
    })

    /// Result of a renewal requested from the "Connection Problem" window.
    enum RenewalRetryOutcome: Equatable, Sendable {
        /// New credentials are stored; the window closes.
        case renewed
        /// The server answered with an error; the session has been ended.
        case rejected
        /// The server still cannot be reached; the window stays.
        case unreachable
        /// A received but unusable answer (malformed, local storage); credentials kept.
        case failed
    }

    private let session: URLSession
    private let decoder: JSONDecoder
    private let tokens: any SessionTokenStorage
    /// Shows the "Connection Problem" window when renewal could not reach the server.
    /// It never holds the failed request: that request reports its own error and is
    /// not repeated after Retry (parity review v3, Q2).
    private let reportRenewalUnreachable: (@Sendable (UUID) async -> Void)?
    /// Single-flight refresh: concurrent 403s must not fire parallel refresh calls.
    private var refreshTask: (generation: UUID, id: UUID, task: Task<Result<Bool, APIError>, Never>)?

    init(tokens: any SessionTokenStorage = TokenStore.shared, session: URLSession? = nil,
         reportRenewalUnreachable: (@Sendable (UUID) async -> Void)? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = APIConfiguration.requestTimeout
        config.timeoutIntervalForResource = APIConfiguration.requestTimeout
        // Fail fast offline: waiting for connectivity would leave a screen spinning
        // with no way for the user to know or retry.
        config.waitsForConnectivity = false
        self.session = session ?? URLSession(configuration: config)
        self.tokens = tokens
        self.reportRenewalUnreachable = reportRenewalUnreachable
        self.decoder = JSONDecoder()
    }

    // MARK: - Public

    /// Verify a candidate login credential without installing it, refreshing the
    /// global session, or borrowing its generation. The owning handoff validates
    /// identity/revision before committing the returned pair.
    func verifyUser(accessToken: String) async throws -> User {
        guard !accessToken.isEmpty else { throw APIError.unauthenticated("") }
        let envelope: APIEnvelope<User> = try await perform(
            Endpoint(method: .get, path: "auth/info"), generation: nil, accessToken: accessToken)
        guard let user = envelope.result else { throw APIError.decoding("Login did not return an authenticated user.") }
        return user
    }


    /// Captures an operation owner without exposing any credential value.
    func credentialGeneration() -> UUID { tokens.generation }

    /// Sends a request and unwraps the envelope's `result`.
    func send<T: Decodable>(_ endpoint: Endpoint, as type: T.Type = T.self, ifGeneration: UUID? = nil) async throws -> T {
        let envelope: APIEnvelope<T> = try await sendEnvelope(endpoint, ifGeneration: ifGeneration)
        guard let result = envelope.result else {
            throw APIError.decoding("Response contained no result for \(endpoint.path).")
        }
        return result
    }

    /// Sends a request whose `result` is empty or ignored (logout, reject, delete…).
    @discardableResult
    func sendIgnoringResult(_ endpoint: Endpoint, ifGeneration: UUID? = nil) async throws -> String? {
        let envelope: APIEnvelope<EmptyPayload> = try await sendEnvelope(endpoint, ifGeneration: ifGeneration)
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

    /// Revoke only the captured signed-out credential. Never refresh or borrow a
    /// subsequent account's session to finish an old logout request.
    func revoke(accessToken: String?) async {
        guard let accessToken else { return }
        guard var request = try? buildRequest(Endpoint(method: .delete, path: "auth/logout", requiresAuth: false)) else { return }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await transfer(request, safeToReplay: false)
    }

    // MARK: - Core

    private func sendEnvelope<T: Decodable>(_ endpoint: Endpoint, ifGeneration expected: UUID? = nil) async throws -> APIEnvelope<T> {
        let attemptedGeneration = tokens.generation
        guard expected == nil || expected == attemptedGeneration else { throw CancellationError() }
        let attemptedAccess = tokens.accessToken
        do {
            return try await performChecked(endpoint, generation: attemptedGeneration, accessToken: attemptedAccess)
        } catch APIError.unauthenticated(let message) {
            // The backend answers 403 for an absent or expired token. Refresh once,
            // then replay the original request.
            // An unauthenticated endpoint (login, register) says nothing about the session.
            guard endpoint.requiresAuth, tokens.generation == attemptedGeneration, tokens.accessToken != nil else { throw APIError.unauthenticated(message) }
            // Another caller already renewed the rejected credential while this
            // response was in flight. Reuse it instead of rotating again.
            if tokens.accessToken != attemptedAccess { return try await replayAfterRenewal(endpoint, generation: attemptedGeneration) }
            guard tokens.refreshToken != nil else {
                await expireSession(ifGeneration: attemptedGeneration)
                throw APIError.unauthenticated(message)
            }
            try Task.checkCancellation()
            let renewal = await refreshSession(ifGeneration: attemptedGeneration)
            guard tokens.generation == attemptedGeneration else { throw CancellationError() }
            switch renewal {
            case .success(true): break
            case .success(false):
                // Q1: the server answered the renewal with an error: sign out.
                await expireSession(ifGeneration: attemptedGeneration)
                throw APIError.unauthenticated(message)
            case .failure(let error):
                try Task.checkCancellation()
                // Q1/Q2: only an unreachable server opens "Connection Problem". This
                // request fails now with its own error; Retry in the window renews
                // the session but never repeats it.
                if error.isUnreachable { await reportRenewalUnreachable?(attemptedGeneration) }
                throw endpoint.method == .get ? error : AuthorizationRejectedMutationError(cause: error)
            }
            guard tokens.generation == attemptedGeneration else { throw CancellationError() }
            return try await replayAfterRenewal(endpoint, generation: attemptedGeneration)
        }
    }

    /// The session was just renewed, so a refused replay means this request is not allowed
    /// (for example the other role's screen): report it and keep the session, as the web does.
    /// Only the identity check (`auth/info`) refused with a renewed token ends the captured
    /// session, never a newer login.
    private func replayAfterRenewal<T: Decodable>(_ endpoint: Endpoint, generation: UUID) async throws -> APIEnvelope<T> {
        guard tokens.generation == generation else { throw CancellationError() }
        do {
            return try await performChecked(endpoint, generation: generation, accessToken: tokens.accessToken)
        } catch APIError.unauthenticated(let message) {
            guard endpoint.path == "auth/info" else { throw APIError.forbidden(message) }
            await expireSession(ifGeneration: generation)
            throw APIError.unauthenticated(message)
        }
    }

    private func performChecked<T: Decodable>(_ endpoint: Endpoint, generation: UUID, accessToken: String?) async throws -> APIEnvelope<T> {
        do {
            let result: APIEnvelope<T> = try await perform(endpoint, generation: generation, accessToken: accessToken)
            guard !endpoint.requiresAuth || tokens.generation == generation else { throw CancellationError() }
            return result
        } catch {
            // Failures belong to the captured account too. A late validation or
            // authorization response must not reach a newer account's screen.
            guard !endpoint.requiresAuth || tokens.generation == generation else { throw CancellationError() }
            throw error
        }
    }

    private func perform<T: Decodable>(_ endpoint: Endpoint, generation: UUID?, accessToken: String?) async throws -> APIEnvelope<T> {
        // Pin the bearer to this operation. A later login must never lend its
        // credential to an old request, even if its result is later discarded.
        var request = try buildRequest(endpoint, accessToken: accessToken)
        #if DEBUG
        request = QANetworkFault.apply(request)
        if let latency = QANetworkFault.latency { try await Task.sleep(for: .seconds(latency)) }
        #endif
        // Nil is reserved for independent candidate-bearer verification. Every
        // ordinary authenticated request continues to use its captured generation.
        guard !endpoint.requiresAuth || generation == nil || tokens.generation == generation else { throw CancellationError() }
        var data: Data
        let response: URLResponse
        do {
            (data, response) = try await transfer(request, safeToReplay: endpoint.method == .get,
                                                      generation: endpoint.requiresAuth ? generation : nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // A view that went away cancelled its task; not a connectivity problem.
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw APIError.timeout
        } catch let error as URLError {
            throw Self.transportError(error)
        } catch {
            throw APIError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.unknown("Malformed response.")
        }
        #if DEBUG
        if QANetworkFault.loseOwnedMatchAcknowledgement(request, statusCode: http.statusCode) {
            await QARequestLedger.shared.recordLostOwnedMatchAcknowledgement()
            throw APIError.network("The network connection was lost.")
        }
        let locationScenario = QANetworkFault.ownedProfileLocationScenario(data, path: endpoint.path,
            method: endpoint.method, statusCode: http.statusCode)
        data = locationScenario.data
        if let attestation = locationScenario.attestation {
            await QARequestLedger.shared.recordProfileWithoutLocation(attestation)
        }
        let notificationScenario = QANetworkFault.notificationMissingTargetScenario(data, path: endpoint.path,
            method: endpoint.method, statusCode: http.statusCode, page: endpoint.query["page"] ?? nil)
        data = notificationScenario.data
        if let attestation = notificationScenario.attestation {
            await QARequestLedger.shared.recordNotificationFallback(attestation)
        }
        data = QANetworkFault.corruptMatchState(data, path: endpoint.path)
        data = QANetworkFault.profileResponseScenario(data, path: endpoint.path,
                                                    method: endpoint.method, statusCode: http.statusCode)
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
        case 403 where !endpoint.requiresAuth && !(envelope?.errors ?? Self.rawErrors(from: data) ?? [:]).isEmpty:
            // Sign-in and sign-up carry no session to renew: their field errors are shown.
            throw APIError.validation(message: message, fields: envelope?.errors ?? Self.rawErrors(from: data) ?? [:])
        // The server answers an expired sign-in and an action that is no longer allowed with
        // the same 403, with or without a field name (client review 22 Oct 2026). Either way:
        // renew once, replay once, and a second refusal shows "You can't do this right now."
        // with the session kept (sendEnvelope / replayAfterRenewal), as the web app does.
        case 401, 403:
            throw APIError.unauthenticated(message)
        case 404:
            throw APIError.notFound(message)
        case 409 where endpoint.path == "auth/login":
            // B1: email verified but the profile/role entity was never finished.
            throw RegistrationIncompleteError(message: message, role: Self.rawMetaRole(from: data))
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

    /// Retry from the "Connection Problem" window: renew the captured session once.
    /// Nothing that failed while the window was open is replayed.
    func retryRenewal(generation: UUID) async -> RenewalRetryOutcome {
        guard tokens.generation == generation, tokens.refreshToken != nil else { return .failed }
        let renewal = await refreshSession(ifGeneration: generation)
        guard tokens.generation == generation else { return .failed }
        switch renewal {
        case .success(true): return .renewed
        case .success(false):
            await expireSession(ifGeneration: generation)
            return .rejected
        case .failure(let error): return error.isUnreachable ? .unreachable : .failed
        }
    }

    /// A lost response to a mutation is ambiguous: it may already have committed.
    /// Retry reads, or failures that establish no connection was made, only.
    private static func transportError(_ error: URLError) -> APIError {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .notConnectedToInternet:
            return .connectionUnavailable
        default: return .network(error.localizedDescription)
        }
    }

    private func transfer(_ request: URLRequest, safeToReplay: Bool, generation: UUID? = nil) async throws -> (Data, URLResponse) {
        var retries = 0
        while true {
            try Task.checkCancellation()
            if let generation, tokens.generation != generation { throw CancellationError() }
            do {
                #if DEBUG
                await QARequestLedger.shared.record(request)
                if let refused = QANetworkFault.refusal(request) { return refused }
                #endif
                if let generation, tokens.generation != generation { throw CancellationError() }
                return try await session.data(for: request)
            }
            catch let error as URLError {
                let beforeConnection: Set<URLError.Code> = [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .notConnectedToInternet]
                let retryable = beforeConnection.contains(error.code)
                    || (safeToReplay && error.code == .networkConnectionLost)
                guard retryable, retries < 3 else { throw error }
                try await Task.sleep(for: .milliseconds(250 * (1 << retries)))
                retries += 1
            }
        }
    }

    /// Any HTTP error answer to renewal (4xx or 5xx) rejects the session, as on
    /// Android (parity review v3, Q1). Transport failures (server unreachable),
    /// malformed success bodies and local storage failures preserve the saved pair.
    private func refreshSession(ifGeneration expected: UUID) async -> Result<Bool, APIError> {
        if let existing = refreshTask, existing.generation == expected { return await existing.task.value }
        let id = UUID()
        let task = Task<Result<Bool, APIError>, Never> { [tokens] in
            guard tokens.generation == expected, let refresh = tokens.refreshToken else { return .success(false) }
            var request = URLRequest(url: APIConfiguration.baseURL.appendingPathComponent("auth/refresh"))
            request.timeoutInterval = APIConfiguration.requestTimeout
            request.httpMethod = HTTPMethod.put.rawValue
            request.setValue("Bearer \(refresh)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(AppLanguage.currentCode, forHTTPHeaderField: "Accept-Language")
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncode(["version_app": .string(DeviceInfo.appVersion)])
            #if DEBUG
            request = QANetworkFault.refreshRequest(request)
            #endif
            guard tokens.generation == expected else { return .success(false) }
            do {
                let (data, response) = try await self.transfer(request, safeToReplay: false, generation: expected)
                guard let http = response as? HTTPURLResponse else { return .failure(.unknown("")) }
                guard (200..<300).contains(http.statusCode) else { return .success(false) }
                guard let envelope = try? self.decoder.decode(APIEnvelope<Session>.self, from: data),
                      let session = envelope.result, !session.accessToken.isEmpty, !session.refreshToken.isEmpty else {
                    return .failure(.decoding(""))
                }
                guard tokens.replace(session, ifGeneration: expected, refreshToken: refresh) else {
                    // Persistence can fail without the server rejecting renewal.
                    // Preserve the captured pair and let the standard recovery UI retry.
                    return .failure(.unknown(""))
                }
                return .success(true)
            } catch let error as URLError where error.code == .timedOut {
                return .failure(.timeout)
            } catch let error as URLError {
                return .failure(Self.transportError(error))
            } catch {
                return .failure(.unknown(""))
            }
        }
        refreshTask = (expected, id, task)
        let result = await task.value
        if refreshTask?.id == id { refreshTask = nil }
        return result
    }

    private func expireSession(ifGeneration expected: UUID) async {
        guard tokens.clear(ifGeneration: expected) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .carezaarSessionExpired, object: nil)
        }
    }

    // MARK: - Request building

    private func buildRequest(_ endpoint: Endpoint, accessToken: String? = nil) throws -> URLRequest {
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
        request.timeoutInterval = APIConfiguration.requestTimeout
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The backend localises from this header and 500s on "*".
        request.setValue(AppLanguage.currentCode, forHTTPHeaderField: "Accept-Language")

        if endpoint.requiresAuth, let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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

    private static func rawMetaRole(from data: Data) -> UserRole? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((object?["meta"] as? [String: Any])?["role"] as? String).flatMap { UserRole(rawValue: $0.lowercased()) }
    }

    private static func rawErrors(from data: Data) -> [String: [String]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = object["errors"] as? [String: Any] else { return nil }
        return errors.compactMapValues { $0 as? [String] }
    }
}
