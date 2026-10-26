import Foundation

/// `users/` — mirrors the Android `cu3` interface.
struct UserService: Sendable {
    let client: APIClient

    init(client: APIClient = .shared) { self.client = client }

    // MARK: - OTP and password

    func sendOTP(email: String) async throws {
        try await client.sendIgnoringResult(
            Endpoint(method: .post, path: "users/otp/send",
                     body: .form(["email": .string(email)]), requiresAuth: false)
        )
    }

    func verifyOTP(email: String, otp: String) async throws {
        try await client.sendIgnoringResult(
            Endpoint(method: .post, path: "users/otp/verify",
                     body: .form(["email": .string(email), "otp": .string(otp)]),
                     requiresAuth: false)
        )
    }

    /// Served since 2026-10-01 (it was a 404 before). The server checks `otp` itself
    /// and refuses a code that `otp/verify` has already used up.
    func resetPassword(email: String, otp: String, newPassword: String) async throws {
        try await client.sendIgnoringResult(
            Endpoint(method: .post, path: "users/password/reset",
                     body: .form(["email": .string(email), "otp": .string(otp),
                                  "password": .string(newPassword)]),
                     requiresAuth: false)
        )
    }

    /// Sends the password mutation; SessionManager owns confirmation and sign-out.
    func changePassword(oldPassword: String, newPassword: String, ifGeneration: UUID? = nil) async throws {
        try await client.sendIgnoringResult(
            Endpoint(method: .patch, path: "users/password/change",
                     body: .form(["old_password": .string(oldPassword),
                                  "new_password": .string(newPassword)])), ifGeneration: ifGeneration
        )
    }

    // MARK: - Profile

    /// The only multipart endpoint in the product.
    ///
    /// `date_of_birth` goes over the wire as **unix epoch seconds at UTC midnight**,
    /// not as a formatted date. (`users/verify` takes a *string* date for the same
    /// concept — the inconsistency is the backend's, and both are reproduced as-is.)
    ///
    /// During signup there is no session yet: the backend attaches the profile to
    /// the account identified by `email` (`anonymous: true`, verified live). The
    /// endpoint only accepts an email whose signup is still in progress.
    func setProfile(email: String, genderId: Int?, firstName: String, lastName: String,
                    bio: String?, dateOfBirth: Date?, photo: MultipartFile?,
                    anonymous: Bool = false) async throws -> User {
        try await client.send(
            Endpoint(method: .post, path: "users/profile",
                     body: .multipart(
                        fields: ["email": email,
                                 "gender_id": genderId.map(String.init),
                                 "first_name": firstName,
                                 "last_name": lastName,
                                 "bio": bio,
                                 "date_of_birth": dateOfBirth.map { Self.epochDay($0) }],
                        file: photo),
                     requiresAuth: !anonymous)
        )
    }

    /// Fetches an uploaded file (a profile photo under `/uploads/`) so it can be sent
    /// back unchanged.
    static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: APIConfiguration.requestTimeout)
        request.setValue(AppLanguage.currentCode, forHTTPHeaderField: "Accept-Language")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch let error as URLError where error.code == .timedOut { throw APIError.timeout }
        catch { throw APIError.network(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw APIError.notFound("")
        }
        return data
    }

    /// Preserve the selected local calendar day, then encode its UTC midnight.
    /// Rounding the Date's instant in UTC can move a date-only picker to the
    /// preceding/following day because it also carries an unshown clock time.
    /// This matches Android's LocalDate.atStartOfDay(ZoneOffset.UTC).
    static func epochDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        var selectedCalendar = Calendar(identifier: .gregorian)
        selectedCalendar.timeZone = timeZone
        let day = selectedCalendar.dateComponents([.era, .year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        // Components extracted from a Gregorian date always form a valid UTC day.
        let start = utc.date(from: day)!
        return String(Int(start.timeIntervalSince1970))
    }

    /// Android's call takes a non-optional reason id (a role-specific `base/reasons` row).
    func deleteAccount(reasonId: Int, ifGeneration: UUID? = nil) async throws {
        try await client.sendIgnoringResult(
            Endpoint(method: .delete, path: "users", query: ["reason_id": String(reasonId)]), ifGeneration: ifGeneration
        )
    }

    // MARK: - Matches

    func matches(type: MatchListType, page: Int = 1,
                 perPage: Int = APIConfiguration.defaultPageSize) async throws -> ([Match], APIMeta?) {
        try await client.sendPaged(
            Endpoint(method: .get, path: "users/matches",
                     query: ["type": type.rawValue, "page": String(page), "perPage": String(perPage)])
        )
    }

    func match(id: Int) async throws -> Match {
        try await client.send(Endpoint(method: .get, path: "users/matches/\(id)"))
    }

    /// The introduction is optional (the server stores an empty one as null) and at most
    /// 1000 characters; the partner sees it with the request.
    /// Sent with an Idempotency-Key (IdempotencyStore): a retry after a lost answer can't
    /// create a second request.
    @MainActor
    func requestMatch(partnerId: String, introduction: String? = nil, ifGeneration: UUID? = nil) async throws -> Match {
        var form: [String: FormValue?] = ["partner_id": .string(partnerId)]
        let text = introduction?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty { form["introduction"] = .string(text) }
        let client = self.client
        return try await IdempotencyStore.shared.submit(.matchRequest, target: partnerId, form: form, draft: text) { key in
            try await client.send(Endpoint(method: .post, path: "users/matches", body: .form(form), idempotencyKey: key), ifGeneration: ifGeneration)
        } reconcile: { _ in
            // After an expired key: a request (or match) with this partner means it went through.
            for type in [MatchListType.requests, .matches] {
                let (list, _): ([Match], APIMeta?) = try await client.sendPaged(Endpoint(method: .get, path: "users/matches",
                    query: ["type": type.rawValue, "page": "1", "perPage": "50"]))
                if let found = list.first(where: { $0.client?.id == partnerId || $0.caregiver?.id == partnerId }) { return found }
            }
            return nil
        }
    }

    func acceptMatch(id: Int, ifGeneration: UUID? = nil) async throws -> Match {
        try await client.send(Endpoint(method: .patch, path: "users/matches/\(id)/accept"), ifGeneration: ifGeneration)
    }

    func rejectMatch(id: Int, ifGeneration: UUID? = nil) async throws {
        try await client.sendIgnoringResult(Endpoint(method: .delete, path: "users/matches/\(id)/reject"), ifGeneration: ifGeneration)
    }

    func withdrawMatch(id: Int, ifGeneration: UUID? = nil) async throws {
        try await client.sendIgnoringResult(Endpoint(method: .delete, path: "users/matches/\(id)/withdraw"), ifGeneration: ifGeneration)
    }

    /// Break an active match. The reason comes from `base/reasons`.
    func breakMatch(id: Int, ifGeneration: UUID? = nil) async throws -> Match {
        try await client.send(Endpoint(method: .delete, path: "users/matches/\(id)"), ifGeneration: ifGeneration)
    }

    func submitReview(matchId: Int, score: Int, comment: String?) async throws -> Match {
        try await client.send(
            Endpoint(method: .post, path: "users/matches/\(matchId)",
                     body: .form(["score": .int(score),
                                  "comment": comment.map { .string($0) } ?? nil]))
        )
    }

    // MARK: - Chats

    func chats(page: Int = 1,
               perPage: Int = APIConfiguration.defaultPageSize) async throws -> ([ChatBrief], APIMeta?) {
        try await client.sendPaged(
            Endpoint(method: .get, path: "users/chats",
                     query: ["page": String(page), "perPage": String(perPage)])
        )
    }

    func chat(id: Int, ifGeneration: UUID? = nil) async throws -> ChatFull {
        try await client.send(Endpoint(method: .get, path: "users/chats/\(id)"), ifGeneration: ifGeneration)
    }

    func createChat(partnerId: String) async throws -> ChatFull {
        try await client.send(
            Endpoint(method: .post, path: "users/chats",
                     body: .form(["partner_id": .string(partnerId)]))
        )
    }

    /// `parentId` threads the message as a reply. Sent with an Idempotency-Key: one message per
    /// submission however often it is retried. `fromCaregiver` (the sender's side) and `after`
    /// (the newest message on screen) let an expired key be reconciled.
    @MainActor
    func sendMessage(chatId: Int, message: String, parentId: Int? = nil, ifGeneration: UUID? = nil,
                     fromCaregiver: Bool? = nil, after: Int? = nil) async throws -> ChatFull {
        let form: [String: FormValue?] = ["message": .string(message), "parent_id": parentId.map { .int($0) } ?? nil]
        let client = self.client
        return try await IdempotencyStore.shared.submit(.chatMessage, target: String(chatId), form: form,
                                                         draft: message, after: after, parent: parentId) { key in
            try await client.send(Endpoint(method: .post, path: "users/chats/\(chatId)", body: .form(form), idempotencyKey: key),
                                  ifGeneration: ifGeneration)
        } reconcile: { record in
            let chat: ChatFull = try await client.send(Endpoint(method: .get, path: "users/chats/\(chatId)"))
            let sent = chat.messages.contains { $0.id > (record.after ?? 0) && $0.message == message
                && (fromCaregiver == nil || $0.isFromCaregiver == fromCaregiver) && $0.parent?.value.id == parentId }
            return sent ? chat : nil
        }
    }

    // MARK: - Bookmarks

    func bookmarks(page: Int = 1,
                   perPage: Int = APIConfiguration.defaultPageSize) async throws -> ([User], APIMeta?) {
        try await client.sendPaged(
            Endpoint(method: .get, path: "users/bookmarks",
                     query: ["page": String(page), "perPage": String(perPage)])
        )
    }

    func addBookmark(partnerId: String, ifGeneration: UUID? = nil) async throws {
        try await client.sendIgnoringResult(
            Endpoint(method: .post, path: "users/bookmarks",
                     body: .form(["partner_id": .string(partnerId)])), ifGeneration: ifGeneration
        )
    }

    func removeBookmark(partnerId: String, ifGeneration: UUID? = nil) async throws {
        try await client.sendIgnoringResult(
            Endpoint(method: .delete, path: "users/bookmarks/\(partnerId)"), ifGeneration: ifGeneration
        )
    }

    // MARK: - Notifications

    func notifications(page: Int = 1,
                       perPage: Int = APIConfiguration.defaultPageSize) async throws -> ([AppNotification], APIMeta?) {
        try await client.sendPaged(
            Endpoint(method: .get, path: "users/notifications",
                     query: ["page": String(page), "perPage": String(perPage)])
        )
    }

    /// Badge count for notifications newer than `checkedAt` (unix seconds).
    func notificationCount(checkedAt: Int) async throws -> Int {
        try await client.send(
            Endpoint(method: .get, path: "users/notifications/count",
                     query: ["checked_at": String(checkedAt)])
        )
    }

    func markNotificationSeen(id: Int) async throws -> AppNotification {
        try await client.send(Endpoint(method: .patch, path: "users/notifications/\(id)/see"))
    }

    // MARK: - Issues

    func issues(ifGeneration: UUID? = nil) async throws -> [Issue] {
        try await client.send(Endpoint(method: .get, path: "users/issues"), ifGeneration: ifGeneration)
    }

    /// A predefined issue type and a free-text title are mutually exclusive — the
    /// backend rejects both together. "Other" sends a title; any type sends the id.
    /// Sent with an Idempotency-Key; `after` is the newest issue id the person had. It is nil
    /// when the screen's list hasn't loaded, and then read here before anything is sent, so an
    /// older issue with the same words is never taken for this one after an expired key.
    @MainActor
    func createIssue(issuetypeId: Int?, title: String?, description: String, ifGeneration: UUID? = nil, after: Int? = nil) async throws -> Issue {
        let fields: [String: FormValue?] = issuetypeId.map {
            ["issuetype_id": .int($0), "description": .string(description)]
        } ?? ["title": .string(title ?? ""), "description": .string(description)]
        let client = self.client
        let baseline: Int
        if let after { baseline = after } else { baseline = try await issues(ifGeneration: ifGeneration).map(\.id).max() ?? 0 }
        return try await IdempotencyStore.shared.submit(.issue, target: "issues", form: fields, draft: description, after: baseline,
                                                         title: title, issuetypeId: issuetypeId) { key in
            try await client.send(Endpoint(method: .post, path: "users/issues", body: .form(fields), idempotencyKey: key), ifGeneration: ifGeneration)
        } reconcile: { record in
            let all: [Issue] = try await client.send(Endpoint(method: .get, path: "users/issues"))
            return all.first { $0.id > (record.after ?? 0) && $0.description == description
                && (issuetypeId != nil ? $0.issuetypeId == issuetypeId : $0.title == title) }
        }
    }
}
