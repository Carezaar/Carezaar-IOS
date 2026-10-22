import XCTest
@testable import Carezaar

/// Captures the actual URLSession request from a public service call; never contacts production.
final class StubHTTP: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHTTP.self]
        return URLSession(configuration: config)
    }
    static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return String(decoding: result, as: UTF8.self)
    }
}
final class NetworkTests: XCTestCase {
    /// P07-009: actual public service transport, with no live API calls.
    @MainActor func testTypedServiceRejectsMalformedEmptyNullAndInvalidFieldsWithoutReplay() async throws {
        let fixtures: [(String, Data)] = [
            ("empty-body", Data()),
            ("malformed-json", Data("{".utf8)),
            ("null-envelope", Data("null".utf8)),
            ("missing-result", Data("{}".utf8)),
            ("null-result", Data(#"{"result":null}"#.utf8)),
            ("wrong-result-shape", Data(#"{"result":{}}"#.utf8)),
            ("invalid-identity-type", Data(#"{"result":[{"id":{"unexpected":1}}]}"#.utf8)),
            ("html-success-body", Data("<html>internal fixture</html>".utf8))
        ]
        for (name, body) in fixtures {
            var attempts = 0
            StubHTTP.handler = { request in
                attempts += 1
                XCTAssertEqual(request.httpMethod, "GET", name)
                XCTAssertEqual(request.url?.path, "/api/base/roles", name)
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), name)
                return (200, body)
            }
            let service = BaseService(client: APIClient(session: StubHTTP.session()))
            do {
                _ = try await service.items(.roles)
                XCTFail(name + ": unusable typed results must not become success")
            } catch let error as APIError {
                guard case .decoding = error else { XCTFail(name + ": expected decoding failure"); continue }
                let message = Feedback.message(error)
                XCTAssertFalse(message.isEmpty, name)
                XCTAssertFalse(message.contains("internal fixture"), name)
                XCTAssertFalse(message.contains("base/roles"), name)
            } catch { XCTFail(name + ": unexpected error type") }
            XCTAssertEqual(attempts, 1, name + ": decoding failures must not replay")
        }
        // Empty typed lists and no-content write acknowledgements are valid.
        StubHTTP.handler = { _ in (200, Data(#"{"result":[]}"#.utf8)) }
        let service = BaseService(client: APIClient(session: StubHTTP.session()))
        let items = try await service.items(.roles)
        XCTAssertTrue(items.isEmpty)
        StubHTTP.handler = { _ in (204, Data()) }
        try await UserService(client: APIClient(session: StubHTTP.session())).sendOTP(email: "decoder@example.test")
    }

    /// Exercises the production service/URLSession boundary without sending mail.
    /// Acceptance proves request handling, not delivery to the recipient's inbox.
    @MainActor func testYahooOTPPreservesEmailAndSurfacesServerFailureWithoutReplay() async throws {
        for email in ["fixture@yahoo.com", "fixture+tag@yahoo.com", "Fixture@Yahoo.com"] {
            XCTAssertNil(FieldValidator.email(email))
            for status in [204, 500] {
                var attempts = 0
                StubHTTP.handler = { request in
                    attempts += 1
                    XCTAssertEqual(request.httpMethod, "POST")
                    XCTAssertEqual(request.url?.path, "/api/users/otp/send")
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                    let form = URLComponents(string: "https://fixture.invalid/?" + StubHTTP.body(request))!.queryItems!
                    XCTAssertEqual(form.map(\.name), ["email"])
                    XCTAssertEqual(form.first?.value, email)
                    return (status, status == 204 ? Data() : Data(#"{"message":"Fixture delivery service unavailable"}"#.utf8))
                }
                let service = UserService(client: APIClient(session: StubHTTP.session()))
                do {
                    try await service.sendOTP(email: email)
                    XCTAssertEqual(status, 204, "Server failure must not be treated as OTP success")
                } catch {
                    XCTAssertEqual(status, 500, "Successful empty response must be accepted")
                    if let apiError = error as? APIError, case .server = apiError {} else {
                        XCTFail("HTTP 500 must surface as a server failure")
                    }
                    let message = Feedback.message(error)
                    XCTAssertFalse(message.isEmpty)
                    XCTAssertFalse(message.contains("Fixture delivery service unavailable"),
                                   "Internal delivery details must not replace the managed error")
                }
                XCTAssertEqual(attempts, 1, "OTP submission must not silently send duplicate email")
            }
        }
    }

    /// Exercises the actual multipart service with early/late times on the local
    /// selected day. Expected UTC-midnight epochs are independent literals.
    @MainActor func testProfileBirthDatePreservesSelectedLocalDayInMultipartTransport() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        let cases = ["1990-10-12 00:05:00", "1990-10-12 23:55:00"]
        for localSelection in cases {
            let selected = try XCTUnwrap(formatter.date(from: localSelection))
            var attempts = 0
            StubHTTP.handler = { request in
                attempts += 1
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/api/users/profile")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
                let body = StubHTTP.body(request)
                let pattern = #"name="([^"]+)"\r\n\r\n([^\r\n]*)\r\n"#
                let regex = try NSRegularExpression(pattern: pattern)
                let matches = regex.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body))
                var fields = [String: String]()
                for match in matches {
                    let key = String(body[try XCTUnwrap(Range(match.range(at: 1), in: body))])
                    let value = String(body[try XCTUnwrap(Range(match.range(at: 2), in: body))])
                    XCTAssertNil(fields.updateValue(value, forKey: key), "Multipart fields must not be duplicated")
                }
                XCTAssertEqual(fields, ["email": "fixture@example.com", "gender_id": "2",
                    "first_name": "Synthetic", "last_name": "Calendar", "bio": "Object-only fixture",
                    "date_of_birth": "655689600"],
                    "Selected date must survive the actual profile wire body in \(TimeZone.current.identifier) at \(localSelection)")
                return (422, Data(#"{"message":"Fixture only","errors":{"date_of_birth":["Fixture refusal"]}}"#.utf8))
            }
            let service = UserService(client: APIClient(session: StubHTTP.session()))
            do {
                _ = try await service.setProfile(email: "fixture@example.com", genderId: 2,
                    firstName: "Synthetic", lastName: "Calendar", bio: "Object-only fixture",
                    dateOfBirth: selected, photo: nil, anonymous: true)
                XCTFail("The explicit fixture refusal must remain a refusal")
            } catch {
                guard case APIError.validation = error else {
                    XCTFail("Actual profile transport must reach the fixture's validation response"); continue
                }
            }
            XCTAssertEqual(attempts, 1, "A date conversion must not retry profile submission")
        }
    }

    func testProfileDateOnlyEpochPreservesCalendarDayAcrossTimeZoneBoundaries() throws {
        // Literal UTC-midnight results independently checked with Python calendar.timegm.
        let cases: [(zone: String, selected: String, epoch: String)] = [
            ("GMT", "1990-10-12T00:00:00Z", "655689600"),
            ("GMT", "1990-10-12T23:59:59Z", "655689600"),
            ("Asia/Kolkata", "1990-10-12T00:05:00+05:30", "655689600"),
            ("Asia/Kolkata", "1990-10-12T23:55:00+05:30", "655689600"),
            ("America/Los_Angeles", "1990-10-12T23:55:00-07:00", "655689600"),
            ("Pacific/Kiritimati", "2026-01-01T00:05:00+14:00", "1767225600"),
            ("America/New_York", "2026-03-08T03:15:00-04:00", "1772928000"),
            ("America/New_York", "2026-11-01T23:55:00-05:00", "1793491200"),
            ("Pacific/Auckland", "2000-02-29T00:05:00+13:00", "951782400"),
            ("America/Adak", "2026-12-31T23:55:00-10:00", "1798675200")
        ]
        for fixture in cases {
            let zone = try XCTUnwrap(TimeZone(identifier: fixture.zone))
            let selected = try XCTUnwrap(ISO8601DateFormatter().date(from: fixture.selected))
            XCTAssertEqual(UserService.epochDay(selected, timeZone: zone), fixture.epoch,
                           "Keep the selected date across UTC, local-midnight, DST and calendar boundaries: \(fixture.zone) \(fixture.selected)")
        }
    }

    func testClientCertificationsUseOnlyDocumentedSnakeCaseForNoneOneAndMany() async {
        for ids in [[], [1], [1, 3]] {
            let captured = expectation(description: "captured actual preference body")
            StubHTTP.handler = { request in
                let body = StubHTTP.body(request)
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertTrue(body.contains("certification_ids="))
                XCTAssertFalse(body.contains("certificationIds="))
                let components = URLComponents(string: "https://fixture.invalid/?" + body)!
                let items = components.queryItems ?? []
                let actual = items.reduce(into: [String: String]()) { fields, item in
                    fields[item.name] = item.value ?? ""
                }
                let expected: [String: String] = [
                    "clienttype_id": "1", "lat": "12.5", "lng": "77.5",
                    "salary_min": "20", "salary_max": "40",
                    "carecondition_ids": "2,4", "careday_ids": "1,5",
                    "carespecial_ids": "3", "certification_ids": ids.map(String.init).joined(separator: ","),
                    "commute_ids": "2", "experience_ids": "4", "gender_ids": "1,2",
                    "languageskill_ids": "1,3", "role_ids": "2,5",
                    "shift_ids": "1,3", "worktype_ids": "2"
                ]
                XCTAssertEqual(request.url?.path, "/api/clients/profile")
                XCTAssertEqual(items.count, actual.count, "Form keys must not be duplicated")
                XCTAssertEqual(actual, expected, "Changing certification cardinality must preserve every other field")
                captured.fulfill()
                return (422, Data(#"{"message":"Fixture validation","errors":{"lat":["Fixture validation"]}}"#.utf8))
            }
            let service = ClientService(client: APIClient(session: StubHTTP.session()))
            do {
                _ = try await service.updateProfile(ClientPreferences(
                    clienttypeId: 1, lat: 12.5, lng: 77.5, salaryMin: 20, salaryMax: 40,
                    careconditionIds: [2, 4], caredayIds: [1, 5], carespecialIds: [3],
                    certificationIds: ids, commuteIds: [2], experienceIds: [4],
                    genderIds: [1, 2], languageskillIds: [1, 3], roleIds: [2, 5],
                    shiftIds: [1, 3], worktypeIds: [2]
                ))
                XCTFail("Fixture must reject to avoid changing profile")
            } catch {}
            await fulfillment(of: [captured], timeout: 2)
        }
    }
    func testServerTimestampsRemainExactlyAsStored() {
        for value in ["2026-10-10 02:16:52", "2:22 10/10", "2026-10-10T02:16:52Z", "2026-10-10T02:16:52+03:30", "2026-10-10", "", "۱۰ اکتبر"] {
            XCTAssertEqual(ServerTime.local(value), value)
        }
        XCTAssertEqual(ServerTime.local(nil), "")
    }
}

final class DelayedHealthyProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var attempts: [String: Int] = [:]
    private static var timeouts: [String: TimeInterval] = [:]
    private static let queue = DispatchQueue(label: "qa.delayed-healthy-response")
    private var work: DispatchWorkItem?
    static func reset() { lock.lock(); defer { lock.unlock() }; attempts = [:]; timeouts = [:] }
    static func snapshot() -> ([String: Int], [String: TimeInterval]) {
        lock.lock(); defer { lock.unlock() }; return (attempts, timeouts)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let name = request.url!.lastPathComponent
        Self.lock.lock()
        Self.attempts[name, default: 0] += 1
        Self.timeouts[name] = request.timeoutInterval
        Self.lock.unlock()
        let responseWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(#"{"message":"Successful Operation"}"#.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = responseWork
        // Return immediately from startLoading; do not block the URLSession delegate.
        Self.queue.asyncAfter(deadline: .now() + (name == "healthy-hold" ? 110 : 0), execute: responseWork)
    }
    override func stopLoading() { work?.cancel() }
}


final class NetworkPolicyTests: XCTestCase {
    func testHealthyResponseHeld110SecondsCompletesOnceWithin120AndFastControlReturns() async throws {
        executionTimeAllowance = 145
        DelayedHealthyProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DelayedHealthyProtocol.self]
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = APIClient(session: session)
        let fastStart = ProcessInfo.processInfo.systemUptime
        _ = try await api.sendIgnoringResult(Endpoint(method: .get, path: "fixture/healthy-fast", requiresAuth: false))
        let fastElapsed = ProcessInfo.processInfo.systemUptime - fastStart
        XCTAssertLessThan(fastElapsed, 2, "A healthy fast response is not deliberately held")
        let holdStart = ProcessInfo.processInfo.systemUptime
        _ = try await api.sendIgnoringResult(Endpoint(method: .get, path: "fixture/healthy-hold", requiresAuth: false))
        let heldElapsed = ProcessInfo.processInfo.systemUptime - holdStart
        print("QA_HEALTHY_RESPONSE_TIMING fastSeconds=\(fastElapsed) heldSeconds=\(heldElapsed)")
        XCTAssertGreaterThanOrEqual(heldElapsed, 109, "Real monotonic elapsed time, not fake clock")
        XCTAssertLessThan(heldElapsed, 120, "Healthy release occurs below the two-minute boundary")
        let (attempts, timeouts) = DelayedHealthyProtocol.snapshot()
        XCTAssertEqual(attempts, ["healthy-fast": 1, "healthy-hold": 1], "No automatic retry for a still-healthy response")
        XCTAssertEqual(timeouts, ["healthy-fast": 120, "healthy-hold": 120])
    }

    func testDroppedReadRecoversOnFirstRetryWithBoundedBackoff() async {
        await assertDroppedReadRecovers(drops: 1)
    }
    func testDroppedReadRecoversOnSecondRetryWithBoundedBackoff() async {
        await assertDroppedReadRecovers(drops: 2)
    }
    func testDroppedReadRecoversAfterUpToThreeRetries() async {
        await assertDroppedReadRecovers(drops: 3)
    }

    private func assertDroppedReadRecovers(drops: Int) async {
        var starts: [TimeInterval] = []
        StubHTTP.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            starts.append(ProcessInfo.processInfo.systemUptime)
            if starts.count <= drops { throw URLError(.networkConnectionLost) }
            return (200, Data(#"{"message":"Successful Operation"}"#.utf8))
        }
        do { _ = try await APIClient(session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .get, path: "fixture", requiresAuth: false)) }
        catch { XCTFail("Read should recover: \(error)") }
        XCTAssertEqual(starts.count, drops + 1)
        let intervals = zip(starts, starts.dropFirst()).map { $1 - $0 }
        for (index, interval) in intervals.enumerated() {
            let scheduled = 0.25 * Double(1 << index)
            XCTAssertGreaterThanOrEqual(interval, scheduled - 0.01, "Retries must respect the shared backoff")
            XCTAssertLessThan(interval, 10, "An immediate fixture response must not stall retry recovery")
        }
        let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: [
            "droppedReadCount": drops, "attemptCount": starts.count,
            "monotonicRetryIntervalsSeconds": intervals, "productionNetworkContacted": false
        ], options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "P07-004-recovery-after-\(drops)-drops"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testDroppedReadStopsAfterThreeRetries() async throws {
        var starts: [TimeInterval] = []
        var failure: APIError?
        StubHTTP.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            starts.append(ProcessInfo.processInfo.systemUptime)
            throw URLError(.networkConnectionLost)
        }
        let started = ProcessInfo.processInfo.systemUptime
        do { _ = try await APIClient(session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .get, path: "fixture", requiresAuth: false)); XCTFail("Must fail") }
        catch let error as APIError { failure = error }
        catch { XCTFail("Exhaustion must return the standard API error category: \(error)") }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(starts.count, 4)
        XCTAssertLessThan(elapsed, 10, "Exhaustion must terminate after the bounded retry budget")
        let error = try XCTUnwrap(failure)
        guard case .network = error else {
            XCTFail("A lost read connection must end as a network error")
            return
        }
        let mapped = await MainActor.run { () -> (String, String) in
            let original = Feedback.translate
            defer { Feedback.translate = original }
            Feedback.translate = { _, fallback in fallback }
            let fallback = Feedback.message(error)
            Feedback.translate = { key, _ in "managed:\(key)" }
            return (fallback, Feedback.message(error))
        }
        XCTAssertEqual(mapped.0, "Cannot communicate with server.")
        XCTAssertEqual(mapped.1, "managed:general_network_title")
        let intervals = zip(starts, starts.dropFirst()).map { $1 - $0 }
        for (index, interval) in intervals.enumerated() {
            XCTAssertGreaterThanOrEqual(interval, 0.25 * Double(1 << index) - 0.01)
            XCTAssertLessThan(interval, 10)
        }
        let proof: [String: Any] = ["attemptCount": starts.count,
            "elapsedSeconds": elapsed, "monotonicRetryIntervalsSeconds": intervals,
            "exhaustedCategory": "network", "managedKey": "general_network_title",
            "canonicalFallbackVerified": true, "managedRoutingVerified": true,
            "scope": "Controlled fixture client; no production endpoint contacted"]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]),
            uniformTypeIdentifier: "public.json")
        attachment.name = "P07-005-bounded-exhaustion-managed-error"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testAmbiguousMutationIsNeverAutomaticallyReplayed() async {
        var attempts = 0
        StubHTTP.handler = { _ in attempts += 1; throw URLError(.networkConnectionLost) }
        do { _ = try await APIClient(session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .post, path: "users/matches", requiresAuth: false)); XCTFail("Must fail") }
        catch {}
        XCTAssertEqual(attempts, 1)
    }
    /// Client review 22 Oct 2026: a 403 that names a field is renewed and sent once more like
    /// any other refusal; refused again, it shows the managed text and the session is kept.
    func testRecordForbidden403WithFieldErrorsRenewsOnceReplaysOnceThenManagedRefusal() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "valid-access", refreshToken: "valid-refresh"))
        var refreshes = 0, writes: [String?] = []
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" { refreshes += 1; return (200, Data(#"{"result":{"access_token":"renewed-access","refresh_token":"renewed-refresh"}}"#.utf8)) }
            writes.append(request.value(forHTTPHeaderField: "Authorization"))
            return (403, Data(#"{"result":null,"message":"The selected id is invalid.","errors":{"id":["The selected id is invalid."]}}"#.utf8))
        }
        var failure: APIError?
        do {
            try await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(
                Endpoint(method: .delete, path: "users/matches/1/withdraw"))
            XCTFail("A refused record change must fail")
        } catch let error as APIError { failure = error } catch { XCTFail("Unexpected \(error)") }
        guard case .forbidden = failure else { return XCTFail("Expected the managed refusal, got \(String(describing: failure))") }
        let shown = await MainActor.run { () -> String in
            let original = Feedback.translate
            defer { Feedback.translate = original }
            Feedback.translate = { _, fallback in fallback }
            return Feedback.message(failure!)
        }
        XCTAssertEqual(shown, "You can't do this right now.")
        XCTAssertEqual(refreshes, 1, "One renewal")
        XCTAssertEqual(writes, ["Bearer valid-access", "Bearer renewed-access"], "The original request, then one replay with the renewed sign-in")
        XCTAssertTrue(tokens.hasSession, "The user stays signed in")
        XCTAssertEqual(tokens.accessToken, "renewed-access")
    }

    func testRecordForbidden403WithFieldErrorsSucceedsAfterRenewal() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "expired-access", refreshToken: "valid-refresh"))
        var refreshes = 0, writes = 0
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" { refreshes += 1; return (200, Data(#"{"result":{"access_token":"renewed-access","refresh_token":"renewed-refresh"}}"#.utf8)) }
            writes += 1
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired-access" {
                return (403, Data(#"{"result":null,"message":"Token is invalid!","errors":{"token":["Token is invalid!"]}}"#.utf8))
            }
            return (204, Data())
        }
        try await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(
            Endpoint(method: .delete, path: "users/matches/1/withdraw"))
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(writes, 2, "Refused once, carried out once")
    }

    func testConcurrent403sShareOneRenewalAndReplayEachRequestOnce() async {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "valid-access", refreshToken: "valid-refresh"))
        let counts = LockedCounts()
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" {
                counts.add("refresh")
                return (200, Data(#"{"result":{"access_token":"renewed-access","refresh_token":"renewed-refresh"}}"#.utf8))
            }
            counts.add(String(request.url!.path.split(separator: "/").suffix(4).joined(separator: "/")))
            return (403, Data(#"{"result":null,"message":"Not allowed","errors":{"id":["Not allowed"]}}"#.utf8))
        }
        let client = APIClient(tokens: tokens, session: StubHTTP.session())
        await withTaskGroup(of: Void.self) { group in
            for id in 1...3 {
                group.addTask { _ = try? await client.sendIgnoringResult(Endpoint(method: .delete, path: "users/matches/\(id)/withdraw")) }
            }
        }
        XCTAssertEqual(counts.value("refresh"), 1, "Concurrent refusals share one renewal")
        for id in 1...3 { XCTAssertEqual(counts.value("users/matches/\(id)/withdraw"), 2, "Request \(id): original + one replay") }
        XCTAssertTrue(tokens.hasSession)
    }

    func testSignInFieldErrorOn403IsShownWithoutRenewal() async {
        var refreshes = 0
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" { refreshes += 1 }
            return (403, Data(#"{"result":null,"message":"Invalid","errors":{"email":["Not verified"]}}"#.utf8))
        }
        do {
            try await APIClient(session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .post, path: "auth/login", requiresAuth: false))
            XCTFail("Must fail")
        } catch let error as APIError {
            XCTAssertEqual(error.fieldError("email"), "Not verified")
        } catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(refreshes, 0)
    }

    func testPermanentValidationIsNotRetried() async {
        var attempts = 0
        StubHTTP.handler = { _ in attempts += 1; return (422, Data(#"{"message":"Invalid input","errors":{"email":["Invalid email"]}}"#.utf8)) }
        do { _ = try await APIClient(session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .get, path: "fixture", requiresAuth: false)); XCTFail("Must fail") }
        catch {}
        XCTAssertEqual(attempts, 1)
    }
    func testIndividualResponseTimeoutIsTwoMinutes() async throws {
        StubHTTP.handler = { request in
            XCTAssertEqual(request.timeoutInterval, 120)
            return (200, Data(#"{"message":"Successful Operation"}"#.utf8))
        }
        _ = try await APIClient(session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .get, path: "fixture", requiresAuth: false))
    }
    func testRefreshSendsOnlyAppVersionAndPreservesRequiredBearer() async throws {
        let tokens = FixtureTokens()
        tokens.save(Session(accessToken: "fixture-access", refreshToken: "fixture-refresh"))
        defer { tokens.clear() }
        var infoCalls = 0
        StubHTTP.handler = { request in
            if request.url!.lastPathComponent == "refresh" {
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-refresh")
                let form = URLComponents(string: "https://fixture.invalid/?" + StubHTTP.body(request))!.queryItems!
                XCTAssertEqual(form.map(\.name), ["version_app"])
                XCTAssertFalse(form[0].value?.isEmpty ?? true)
                return (200, Data(#"{"result":{"access_token":"new-fixture-access","refresh_token":"new-fixture-refresh"}}"#.utf8))
            }
            infoCalls += 1
            if infoCalls == 1 { return (403, Data(#"{"message":"Expired"}"#.utf8)) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-fixture-access")
            return (200, Data(#"{"message":"Successful Operation"}"#.utf8))
        }
        _ = try await APIClient(tokens: tokens, session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .get, path: "auth/info"))
        XCTAssertEqual(infoCalls, 2)
        XCTAssertEqual(tokens.accessToken, "new-fixture-access")
    }
}

final class LockedCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ key: String) { lock.lock(); defer { lock.unlock() }; counts[key, default: 0] += 1 }
    func value(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }
}

final class FixtureTokens: SessionTokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var pair: Session?
    private var revision = UUID()
    var generation: UUID { lock.lock(); defer { lock.unlock() }; return revision }
    var accessToken: String? { lock.lock(); defer { lock.unlock() }; return pair?.accessToken }
    var refreshToken: String? { lock.lock(); defer { lock.unlock() }; return pair?.refreshToken }
    var hasSession: Bool { lock.lock(); defer { lock.unlock() }; return !(pair?.accessToken.isEmpty ?? true) && !(pair?.refreshToken.isEmpty ?? true) }
    func save(_ session: Session) { lock.lock(); defer { lock.unlock() }; revision = UUID(); pair = session }
    func clear() { lock.lock(); defer { lock.unlock() }; revision = UUID(); pair = nil }
    func replace(_ session: Session, ifGeneration expected: UUID, refreshToken: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard revision == expected, pair?.refreshToken == refreshToken,
              !session.accessToken.isEmpty, !session.refreshToken.isEmpty else { return false }
        pair = session; return true
    }
    func clear(ifGeneration expected: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard revision == expected else { return false }
        revision = UUID(); pair = nil; return true
    }
}

#if DEBUG
extension NetworkTests {
    func testOwnedMatchAcknowledgementLossRequiresExactScopeAndConsumesOnlyOneSuccessfulResponse() throws {
        let fault = try XCTUnwrap(QAMatchAcknowledgementLoss(method: "POST", path: "users/matches", partnerID: "owned-peer", ownedIDs: ["owned-primary", "owned-peer"]))
        var request = URLRequest(url: APIConfiguration.baseURL.appendingPathComponent("users/matches"))
        request.httpMethod = "POST"
        request.httpBody = Data("partner_id=foreign&introduction=synthetic".utf8)
        XCTAssertFalse(fault.shouldDrop(request, statusCode: 200))
        request.httpBody = Data("partner_id=owned-peer&introduction=synthetic".utf8)
        XCTAssertFalse(fault.shouldDrop(request, statusCode: 422), "A rejected mutation must not consume the later successful loss")
        request.httpMethod = "GET"
        XCTAssertFalse(fault.shouldDrop(request, statusCode: 200))
        request.httpMethod = "POST"
        request.url = APIConfiguration.baseURL.appendingPathComponent("users/matches/42/accept")
        XCTAssertFalse(fault.shouldDrop(request, statusCode: 200))
        request.url = APIConfiguration.baseURL.appendingPathComponent("users/matches")
        XCTAssertTrue(fault.shouldDrop(request, statusCode: 201))
        XCTAssertFalse(fault.shouldDrop(request, statusCode: 200), "Second successful response must be delivered normally")
    }

    func testOwnedMatchAcknowledgementLossRejectsUnsafeConfigurationAndDuplicateTargetFields() throws {
        for (method, path, partner, ids) in [
            ("DELETE", "users/matches", "peer", ["primary", "peer"]),
            ("POST", "users/profile", "peer", ["primary", "peer"]),
            ("POST", "users/matches", "foreign", ["primary", "peer"]),
            ("POST", "users/matches", "peer", ["peer", "peer"]),
            ("POST", "users/matches", "peer", ["", "peer"])
        ] {
            XCTAssertNil(QAMatchAcknowledgementLoss(method: method, path: path, partnerID: partner, ownedIDs: ids))
        }
        let fault = try XCTUnwrap(QAMatchAcknowledgementLoss(method: "POST", path: "users/matches", partnerID: "owned peer", ownedIDs: ["primary", "owned peer"]))
        var request = URLRequest(url: APIConfiguration.baseURL.appendingPathComponent("users/matches"))
        request.httpMethod = "POST"
        request.httpBody = Data("partner_id=owned%20peer&partner_id=foreign".utf8)
        XCTAssertFalse(fault.shouldDrop(request, statusCode: 200))
        request.httpBody = Data("partner_id=owned%20peer".utf8)
        XCTAssertTrue(fault.shouldDrop(request, statusCode: 200), "Decode the actual form field before comparing the exact owned ID")
    }

    func testMissingNotificationTargetFaultPreservesOwnershipAndUnrelatedRowsAndRequiresExactRead() throws {
        let original = Data(#"{"result":[{"id":7,"user":{"id":"owner"},"partner":{"id":"owned-peer"},"chat":{"id":42},"subject_id":3,"seen_at":"original","created_at":"timestamp"},{"id":8,"partner":{"id":"another"},"chat":{"id":43}}],"meta":{"total":2}}"#.utf8)
        for kind in ["person", "chat"] {
            let fault = try XCTUnwrap(QANotificationMissingTarget(id: 7, kind: kind))
            let transformed = fault.apply(original, path: "users/notifications", method: .get, statusCode: 200, page: "1")
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: transformed) as? [String: Any])
            let records = try XCTUnwrap(envelope["result"] as? [[String: Any]])
            XCTAssertTrue(records[0]["partner"] is NSNull)
            XCTAssertTrue(records[0]["chat"] is NSNull)
            XCTAssertEqual((records[0]["user"] as? [String: String])?["id"], "owner")
            XCTAssertEqual(records[0]["seen_at"] as? String, "original")
            XCTAssertEqual(records[0]["created_at"] as? String, "timestamp")
            XCTAssertEqual(records[0]["subject_id"] as? Int, 3)
            XCTAssertEqual((records[1]["partner"] as? [String: String])?["id"], "another")
            XCTAssertEqual((envelope["meta"] as? [String: Int])?["total"], 2)
            for (path, method, status, page) in [
                ("users/chats", HTTPMethod.get, 200, "1"),
                ("users/notifications", .post, 200, "1"),
                ("users/notifications", .get, 422, "1"),
                ("users/notifications", .get, 200, "2")
            ] {
                XCTAssertEqual(fault.apply(original, path: path, method: method, statusCode: status, page: page), original)
            }
        }
        XCTAssertNil(QANotificationMissingTarget(id: 0, kind: "person"))
        XCTAssertNil(QANotificationMissingTarget(id: 7, kind: "unknown"))
        let absent = try XCTUnwrap(QANotificationMissingTarget(id: 99, kind: "chat"))
        XCTAssertEqual(absent.apply(original, path: "users/notifications", method: .get, statusCode: 200, page: "1"), original)
    }
}
#endif

#if DEBUG
final class ControlledLocationFaultTests: XCTestCase {
    func testSyntheticFixesUseActualCoordinateAndAgeValidation() throws {
        for mode in ["available", "stale", "negative-accuracy", "out-of-range", "future", "none", "late-valid"] {
            let fixture = try XCTUnwrap(QALocationFixture(mode: mode))
            let fix = fixture.location()
            let coordinate = LocationProvider.usableCoordinate(from: fix)
            if mode == "available" || mode == "stale" {
                XCTAssertEqual(try XCTUnwrap(coordinate).latitude, 39.8283)
                XCTAssertEqual(try XCTUnwrap(coordinate).longitude, -98.5795)
                XCTAssertEqual(LocationProvider.isStale(try XCTUnwrap(fix)), mode == "stale")
            } else {
                XCTAssertNil(coordinate, "Invalid/unavailable or not-yet-delivered input must not seed a selected point: \(mode)")
            }
        }
        let late = try XCTUnwrap(QALocationFixture(mode: "late-valid"))
        XCTAssertNil(late.location())
        XCTAssertNotNil(LocationProvider.usableCoordinate(from: late.location(late: true)))
        XCTAssertNil(QALocationFixture(mode: "unknown"))
    }

    func testProfileCoordinateRemovalRequiresExactOwnedIdentityRoleAndSuccessfulRead() throws {
        for (path, role, ownerID) in [("clients/profile", "client", "client-owner"), ("caregivers/profile", "caregiver", "caregiver-owner")] {
            let fault = try XCTUnwrap(QAOwnedProfileWithoutLocation(method: "GET", path: path, clientID: "client-owner", caregiverID: "caregiver-owner"))
            func response(id: String, role: String) throws -> Data {
                try JSONSerialization.data(withJSONObject: ["result": ["user": ["id": id, "role": role], "lat": 51.5, "lng": -0.12, "certification_ids": [1, 3], "salary_min": 10, "salary_max": 12], "meta": ["sentinel": "preserved"]])
            }
            let original = try response(id: ownerID, role: role)
            let transformed = fault.apply(original, path: path, method: .get, statusCode: 200)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: transformed) as? [String: Any])
            let profile = try XCTUnwrap(envelope["result"] as? [String: Any])
            XCTAssertTrue(profile["lat"] is NSNull && profile["lng"] is NSNull)
            XCTAssertEqual((profile["user"] as? [String: String])?["id"], ownerID)
            XCTAssertEqual(profile["certification_ids"] as? [Int], [1, 3])
            XCTAssertEqual(profile["salary_min"] as? Int, 10)
            XCTAssertEqual((envelope["meta"] as? [String: String])?["sentinel"], "preserved")
            let foreign = try response(id: "foreign", role: role)
            XCTAssertEqual(fault.apply(foreign, path: path, method: .get, statusCode: 200), foreign)
            let wrongRole = try response(id: ownerID, role: "other-role")
            XCTAssertEqual(fault.apply(wrongRole, path: path, method: .get, statusCode: 200), wrongRole)
            XCTAssertEqual(fault.apply(original, path: path, method: .put, statusCode: 200), original)
            XCTAssertEqual(fault.apply(original, path: path, method: .get, statusCode: 422), original)
            XCTAssertEqual(fault.apply(original, path: "clients/caregivers/peer", method: .get, statusCode: 200), original)
        }
        XCTAssertNil(QAOwnedProfileWithoutLocation(method: "PUT", path: "clients/profile", clientID: "c", caregiverID: "g"))
        XCTAssertNil(QAOwnedProfileWithoutLocation(method: "GET", path: "clients/profile", clientID: "same", caregiverID: "same"))
    }
}
#endif
