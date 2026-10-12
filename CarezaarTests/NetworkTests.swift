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

    func testClientCertificationsUseOnlyDocumentedSnakeCaseForNoneOneAndMany() async {
        for ids in [[], [1], [1, 3]] {
            let captured = expectation(description: "captured actual preference body")
            StubHTTP.handler = { request in
                let body = StubHTTP.body(request)
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertTrue(body.contains("certification_ids="))
                XCTAssertFalse(body.contains("certificationIds="))
                let components = URLComponents(string: "https://fixture.invalid/?" + body)!
                XCTAssertEqual(components.queryItems?.first { $0.name == "certification_ids" }?.value, ids.map(String.init).joined(separator: ","))
                XCTAssertTrue(body.contains("clienttype_id=1"))
                captured.fulfill()
                return (422, Data(#"{"message":"Fixture validation","errors":{"lat":["Fixture validation"]}}"#.utf8))
            }
            let service = ClientService(client: APIClient(session: StubHTTP.session()))
            do {
                _ = try await service.updateProfile(ClientPreferences(clienttypeId: 1, lat: 12.5, lng: 77.5, certificationIds: ids))
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

final class NetworkPolicyTests: XCTestCase {
    func testDroppedReadRecoversAfterUpToThreeRetries() async {
        var attempts = 0
        StubHTTP.handler = { _ in
            attempts += 1
            if attempts <= 3 { throw URLError(.networkConnectionLost) }
            return (200, Data(#"{"message":"Successful Operation"}"#.utf8))
        }
        do { _ = try await APIClient(session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .get, path: "fixture", requiresAuth: false)) }
        catch { XCTFail("Read should recover: \(error)") }
        XCTAssertEqual(attempts, 4)
    }
    func testDroppedReadStopsAfterThreeRetries() async {
        var attempts = 0
        StubHTTP.handler = { _ in attempts += 1; throw URLError(.networkConnectionLost) }
        do { _ = try await APIClient(session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .get, path: "fixture", requiresAuth: false)); XCTFail("Must fail") }
        catch {}
        XCTAssertEqual(attempts, 4)
    }
    func testAmbiguousMutationIsNeverAutomaticallyReplayed() async {
        var attempts = 0
        StubHTTP.handler = { _ in attempts += 1; throw URLError(.networkConnectionLost) }
        do { _ = try await APIClient(session: StubHTTP.session()).sendIgnoringResult(Endpoint(method: .post, path: "users/matches", requiresAuth: false)); XCTFail("Must fail") }
        catch {}
        XCTAssertEqual(attempts, 1)
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
