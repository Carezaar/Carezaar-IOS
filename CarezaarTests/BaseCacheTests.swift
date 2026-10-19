import XCTest
@testable import Carezaar

@MainActor
final class BaseCacheTests: XCTestCase {
    private var folder: URL!
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testBootstrapLoadsEveryReferenceDatasetBeforeReadyAndReusesUnchangedSnapshot() async {
        let lock = NSLock()
        var paths: [String] = []
        StubHTTP.handler = { request in
            let path = request.url!.lastPathComponent
            lock.lock(); paths.append(path); lock.unlock()
            return (200, Self.response(path: path, stamp: 10))
        }
        let service = BaseService(client: APIClient(session: StubHTTP.session()))
        let url = folder.appendingPathComponent("base.json")
        let store = BaseDataStore(service: service, cacheURL: url)
        await store.bootstrap()
        XCTAssertTrue(store.isReady)
        for table in BaseTable.allCases { XCTAssertNotNil(store.tables[table]) }
        for path in ["languages", "states", "media", "faqs", "faq_categories"] {
            XCTAssertTrue(paths.contains(path), "Startup omitted \(path)")
        }
        let downloaded = paths.count
        let next = BaseDataStore(service: service, cacheURL: url)
        await next.bootstrap()
        XCTAssertTrue(next.isReady)
        XCTAssertEqual(paths.count, downloaded + 1, "Unchanged snapshot should request only base/info")
    }

    func testUncachedOfflineBootstrapRecoversOnSameStoreWithoutPartialData() async throws {
        let lock = NSLock()
        var paths: [String] = []
        StubHTTP.handler = { request in
            lock.lock(); paths.append(request.url!.lastPathComponent); lock.unlock()
            throw URLError(.notConnectedToInternet)
        }
        let url = folder.appendingPathComponent("base.json")
        let service = BaseService(client: APIClient(session: StubHTTP.session()))
        let store = BaseDataStore(service: service, cacheURL: url)
        await store.bootstrap()
        XCTAssertFalse(store.isReady)
        XCTAssertTrue(store.failed)
        XCTAssertTrue(store.tables.isEmpty)
        XCTAssertTrue(store.languages.isEmpty && store.media.isEmpty && store.faqs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(paths, ["info", "info", "info", "info"])

        StubHTTP.handler = { request in
            let path = request.url!.lastPathComponent
            lock.lock(); paths.append(path); lock.unlock()
            return (200, Self.response(path: path, stamp: 10))
        }
        // Keep the same public store instance: reconstructing it would hide a
        // stale in-flight bootstrap task left behind by the failed attempt.
        await store.bootstrap()
        XCTAssertTrue(store.isReady)
        XCTAssertFalse(store.failed)
        let datasets = ["careconditions", "caredays", "carespecials", "certifications",
                        "clienttypes", "commutes", "contents", "countries", "experiences",
                        "genders", "issuetypes", "languageskills", "reasons", "roles",
                        "shifts", "subjects", "worktypes", "languages", "states", "media",
                        "faqs", "faq_categories"]
        XCTAssertEqual(paths.filter { $0 == "info" }.count, 5)
        XCTAssertEqual(paths.filter { $0 != "info" }.sorted(), datasets.sorted())
        let saved = try Data(contentsOf: url)
        let reopened = BaseDataStore(service: service, cacheURL: url)
        XCTAssertFalse(reopened.isReady, "Loaded disk data must still pass the bootstrap readiness gate")
        XCTAssertFalse(reopened.tables.isEmpty, "The validated snapshot must be restored from disk")
        await reopened.bootstrap()
        XCTAssertTrue(reopened.isReady)
        XCTAssertEqual(paths.filter { $0 == "info" }.count, 6)
        XCTAssertEqual(paths.filter { $0 != "info" }.sorted(), datasets.sorted())
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    func testChangedMarkerReplacesEveryDatasetAndPersistsNewSnapshot() async throws {
        var stamp = 10
        StubHTTP.handler = { request in (200, Self.response(path: request.url!.lastPathComponent, stamp: stamp)) }
        let url = folder.appendingPathComponent("base.json")
        let service = BaseService(client: APIClient(session: StubHTTP.session()))
        let store = BaseDataStore(service: service, cacheURL: url)
        await store.bootstrap()
        let original = try Data(contentsOf: url)
        stamp = 11
        await store.bootstrap()
        XCTAssertEqual(store.items(.roles).first?.code, "stamp-11")
        XCTAssertNotEqual(try Data(contentsOf: url), original)
        let reopened = BaseDataStore(service: service, cacheURL: url)
        await reopened.bootstrap()
        XCTAssertEqual(reopened.items(.roles).first?.code, "stamp-11")
    }

    func testFailedChangedRefreshPreservesWholeMemoryAndDiskSnapshot() async throws {
        var stamp = 10
        StubHTTP.handler = { request in (200, Self.response(path: request.url!.lastPathComponent, stamp: stamp)) }
        let url = folder.appendingPathComponent("base.json")
        let service = BaseService(client: APIClient(session: StubHTTP.session()))
        let store = BaseDataStore(service: service, cacheURL: url)
        await store.bootstrap()
        let original = try Data(contentsOf: url)
        stamp = 11
        StubHTTP.handler = { request in
            let path = request.url!.lastPathComponent
            return path == "media" ? (500, Data(#"{"message":"Unavailable"}"#.utf8)) : (200, Self.response(path: path, stamp: stamp))
        }
        await store.bootstrap()
        XCTAssertTrue(store.isReady)
        XCTAssertFalse(store.failed)
        XCTAssertEqual(store.items(.roles).first?.code, "stamp-10")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testIncompleteSuccessfulChangedRefreshCannotReplaceValidCache() async throws {
        let url = folder.appendingPathComponent("base.json")
        let service = BaseService(client: APIClient(session: StubHTTP.session()))
        StubHTTP.handler = { request in (200, Self.response(path: request.url!.lastPathComponent, stamp: 10)) }
        let store = BaseDataStore(service: service, cacheURL: url)
        await store.bootstrap()
        let original = try Data(contentsOf: url)
        for missing in ["media", "faqs", "faq_categories", "states", "roles"] {
            StubHTTP.handler = { request in
                let path = request.url!.lastPathComponent
                return (200, path == missing ? Data(#"{"result":[],"message":"Successful Operation"}"#.utf8) : Self.response(path: path, stamp: 11))
            }
            await store.bootstrap()
            XCTAssertEqual(store.items(.roles).first?.code, "stamp-10", "Incomplete \(missing) changed the snapshot")
            XCTAssertEqual(try Data(contentsOf: url), original, "Incomplete \(missing) replaced persisted data")
            XCTAssertTrue(store.isReady)
        }
        StubHTTP.handler = { request in (200, Self.response(path: request.url!.lastPathComponent, stamp: 11)) }
        await store.bootstrap()
        XCTAssertEqual(store.items(.roles).first?.code, "stamp-11", "Rejected marker must remain eligible for a complete retry")
    }

    func testDuplicateIdsCannotSatisfyAdvertisedRowCount() async {
        StubHTTP.handler = { request in
            let path = request.url!.lastPathComponent
            var envelope = try! JSONSerialization.jsonObject(with: Self.response(path: path, stamp: 10)) as! [String: Any]
            if path == "info" {
                var info = envelope["result"] as! [String: Int]; info["roles"] = 2; envelope["result"] = info
            } else if path == "roles" {
                let rows = envelope["result"] as! [[String: Any]]; envelope["result"] = rows + rows
            }
            return (200, try! JSONSerialization.data(withJSONObject: envelope))
        }
        let store = BaseDataStore(service: BaseService(client: APIClient(session: StubHTTP.session())), cacheURL: folder.appendingPathComponent("base.json"))
        await store.bootstrap()
        XCTAssertFalse(store.isReady)
        XCTAssertTrue(store.failed)
    }

    func testAdvertisedEmptyOptionalDatasetsRemainValid() async {
        let empty = Set(["media", "faqs", "faq_categories", "states", "roles"])
        StubHTTP.handler = { request in
            let path = request.url!.lastPathComponent
            var envelope = try! JSONSerialization.jsonObject(with: Self.response(path: path, stamp: 10)) as! [String: Any]
            if path == "info" {
                var info = envelope["result"] as! [String: Int]
                for key in empty { info[key] = 0 }; envelope["result"] = info
            } else if empty.contains(path) { envelope["result"] = [] as [Int] }
            return (200, try! JSONSerialization.data(withJSONObject: envelope))
        }
        let store = BaseDataStore(service: BaseService(client: APIClient(session: StubHTTP.session())), cacheURL: folder.appendingPathComponent("base.json"))
        await store.bootstrap()
        XCTAssertTrue(store.isReady)
        XCTAssertTrue(store.media.isEmpty)
        XCTAssertTrue(store.faqs.isEmpty)
    }

    func testCompleteCacheWorksOfflineButCorruptCacheDoesNot() async throws {
        let url = folder.appendingPathComponent("base.json")
        let service = BaseService(client: APIClient(session: StubHTTP.session()))
        StubHTTP.handler = { request in (200, Self.response(path: request.url!.lastPathComponent, stamp: 10)) }
        let store = BaseDataStore(service: service, cacheURL: url)
        await store.bootstrap()
        let original = try Data(contentsOf: url)
        StubHTTP.handler = { _ in throw URLError(.notConnectedToInternet) }
        let offline = BaseDataStore(service: service, cacheURL: url)
        await offline.bootstrap()
        XCTAssertTrue(offline.isReady)
        XCTAssertFalse(offline.failed)
        XCTAssertEqual(try Data(contentsOf: url), original)
        try Data("broken cache".utf8).write(to: url)
        let corrupt = BaseDataStore(service: service, cacheURL: url)
        await corrupt.bootstrap()
        XCTAssertFalse(corrupt.isReady)
        XCTAssertTrue(corrupt.failed)
        XCTAssertTrue(corrupt.tables.isEmpty)
    }

    func testDamagedDecodedCacheIsNotTrustedOffline() async throws {
        let url = folder.appendingPathComponent("base.json")
        let service = BaseService(client: APIClient(session: StubHTTP.session()))
        StubHTTP.handler = { request in (200, Self.response(path: request.url!.lastPathComponent, stamp: 10)) }
        let store = BaseDataStore(service: service, cacheURL: url)
        await store.bootstrap()
        var cache = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        cache["media"] = [] as [Int]
        try JSONSerialization.data(withJSONObject: cache).write(to: url)
        StubHTTP.handler = { _ in throw URLError(.notConnectedToInternet) }
        let corrupt = BaseDataStore(service: service, cacheURL: url)
        await corrupt.bootstrap()
        XCTAssertFalse(corrupt.isReady, "A decodable but incomplete persisted snapshot is still corrupt")
        XCTAssertTrue(corrupt.failed)
    }

    func testConcurrentBootstrapRequestsShareOneCompleteDownload() async {
        let lock = NSLock()
        var paths: [String] = []
        StubHTTP.handler = { request in
            let path = request.url!.lastPathComponent
            lock.lock(); paths.append(path); lock.unlock()
            return (200, Self.response(path: path, stamp: 10))
        }
        let store = BaseDataStore(service: BaseService(client: APIClient(session: StubHTTP.session())), cacheURL: folder.appendingPathComponent("base.json"))
        async let first: Void = store.bootstrap()
        async let second: Void = store.bootstrap()
        _ = await (first, second)
        XCTAssertTrue(store.isReady)
        XCTAssertEqual(paths.filter { $0 == "info" }.count, 1)
        for table in BaseTable.allCases { XCTAssertEqual(paths.filter { $0 == table.rawValue }.count, 1) }
        for path in ["languages", "states", "media", "faqs", "faq_categories"] { XCTAssertEqual(paths.filter { $0 == path }.count, 1) }
    }

    func testMalformedChangedSnapshotsStayAtomicAndConcurrentFreshRetryRecovers() async throws {
        let variants: [(String, Data)] = [
            ("malformed-json", Data("{".utf8)),
            ("null-result", Data(#"{"result":null,"message":"Successful Operation"}"#.utf8)),
            ("invalid-id-type", Data(#"{"result":[{"id":{"unexpected":1},"translations":[]}],"message":"Successful Operation"}"#.utf8))
        ]
        let datasets = BaseTable.allCases.map(\.rawValue)
            + ["languages", "states", "media", "faqs", "faq_categories"]
        XCTAssertEqual(datasets.count, 22)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func memory(_ store: BaseDataStore) throws -> [String: Data] {
            var result: [String: Data] = [:]
            for table in BaseTable.allCases { result[table.rawValue] = try encoder.encode(store.items(table)) }
            result["languages"] = try encoder.encode(store.languages)
            result["states"] = try encoder.encode(store.states)
            result["media"] = try encoder.encode(store.media)
            result["faqs"] = try encoder.encode(store.faqs)
            result["faq_categories"] = try encoder.encode(store.faqCategories)
            return result
        }
        let service = BaseService(client: APIClient(session: StubHTTP.session()))
        let oldURL = folder.appendingPathComponent("valid-before-malformed.json")
        StubHTTP.handler = { request in (200, Self.response(path: request.url!.lastPathComponent, stamp: 10)) }
        let old = BaseDataStore(service: service, cacheURL: oldURL)
        await old.bootstrap()
        XCTAssertTrue(old.isReady)
        let oldMemory = try memory(old)
        let oldBytes = try Data(contentsOf: oldURL)

        for (name, bad) in variants {
            // A changed marker must not expose partial new lists or commit its marker.
            StubHTTP.handler = { request in
                let path = request.url!.lastPathComponent
                return (200, path == "roles" ? bad : Self.response(path: path, stamp: 11))
            }
            await old.bootstrap()
            XCTAssertTrue(old.isReady, name + ": valid old snapshot remains usable")
            XCTAssertFalse(old.failed, name + ": this is not an uncached failure")
            XCTAssertEqual(try memory(old), oldMemory, name + ": all22 public datasets remain atomic")
            XCTAssertEqual(try Data(contentsOf: oldURL), oldBytes, name + ": disk/marker unchanged")

            let freshURL = folder.appendingPathComponent("fresh-" + name + ".json")
            let fresh = BaseDataStore(service: service, cacheURL: freshURL)
            let firstInfoStarted = expectation(description: name + " first info held")
            let secondCallerEntered = expectation(description: name + " second bootstrap entered")
            let releaseInfo = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var calls: [String] = []
            var gateReleased = false
            StubHTTP.handler = { request in
                let path = request.url!.lastPathComponent
                lock.lock(); calls.append(path); let first = path == "info" && calls.filter { $0 == "info" }.count == 1; lock.unlock()
                if first {
                    firstInfoStarted.fulfill()
                    let released = releaseInfo.wait(timeout: .now() + 5) == .success
                    lock.lock(); gateReleased = released; lock.unlock()
                }
                return (200, path == "roles" ? bad : Self.response(path: path, stamp: 11))
            }
            // Begin one public call, keep info pending, then enter the second on MainActor.
            // Fulfilling secondCallerEntered is synchronous immediately before bootstrap;
            // bootstrap must join the installed task before its first suspension.
            let first = Task { await fresh.bootstrap() }
            await fulfillment(of: [firstInfoStarted], timeout: 2)
            let second = Task { secondCallerEntered.fulfill(); await fresh.bootstrap() }
            await fulfillment(of: [secondCallerEntered], timeout: 2)
            releaseInfo.signal()
            await first.value
            await second.value
            XCTAssertTrue(gateReleased, name + ": barrier must not expire")
            XCTAssertEqual(calls.filter { $0 == "info" }.count, 1, name + ": two failed callers share one info request")
            XCTAssertEqual(calls.filter { $0 != "info" }.sorted(), datasets.sorted(), name + ": one complete attempt, no decoding retries/duplicate lists")
            XCTAssertFalse(fresh.isReady)
            XCTAssertTrue(fresh.failed)
            XCTAssertTrue(fresh.tables.isEmpty && fresh.languages.isEmpty && fresh.media.isEmpty && fresh.states.isEmpty && fresh.faqs.isEmpty && fresh.faqCategories.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: freshURL.path), name + ": invalid first snapshot must not persist")

            // Same instance: a stale completed failed task must not suppress a real retry.
            calls = []
            StubHTTP.handler = { request in
                let path = request.url!.lastPathComponent
                lock.lock(); calls.append(path); lock.unlock()
                return (200, Self.response(path: path, stamp: 11))
            }
            await fresh.bootstrap()
            XCTAssertTrue(fresh.isReady)
            XCTAssertFalse(fresh.failed)
            XCTAssertEqual(calls.filter { $0 == "info" }.count, 1)
            XCTAssertEqual(calls.filter { $0 != "info" }.sorted(), datasets.sorted(), name + ": healthy retry downloads each required dataset exactly once")
            XCTAssertEqual(fresh.items(.roles).first?.code, "stamp-11")
            let persisted = try Data(contentsOf: freshURL)
            let reopened = BaseDataStore(service: service, cacheURL: freshURL)
            XCTAssertEqual(try memory(reopened), try memory(fresh), name + ": persisted complete snapshot reopens exactly")
            XCTAssertEqual(try Data(contentsOf: freshURL), persisted)
        }
        // The rejected changed marker remains eligible: one final healthy retry commits it.
        StubHTTP.handler = { request in (200, Self.response(path: request.url!.lastPathComponent, stamp: 11)) }
        await old.bootstrap()
        XCTAssertTrue(old.isReady)
        XCTAssertEqual(old.items(.roles).first?.code, "stamp-11")
        XCTAssertNotEqual(try Data(contentsOf: oldURL), oldBytes)
    }

    func testMissingReferenceInfoCannotCreateUnversionedFirstSnapshot() async {
        let lock = NSLock()
        var paths: [String] = []
        StubHTTP.handler = { request in
            let path = request.url!.lastPathComponent
            lock.lock(); paths.append(path); lock.unlock()
            return path == "info" ? (500, Data(#"{"message":"Unavailable"}"#.utf8)) : (200, Self.response(path: path, stamp: 10))
        }
        let url = folder.appendingPathComponent("base.json")
        let store = BaseDataStore(service: BaseService(client: APIClient(session: StubHTTP.session())), cacheURL: url)
        await store.bootstrap()
        XCTAssertFalse(store.isReady)
        XCTAssertTrue(store.failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(Set(paths), ["info"], "Do not download lists when their completeness/version cannot be verified")
    }

    func testUnverifiedLegacyCacheRequiresOneCompleteRefresh() async throws {
        let url = folder.appendingPathComponent("base.json")
        let service = BaseService(client: APIClient(session: StubHTTP.session()))
        StubHTTP.handler = { request in (200, Self.response(path: request.url!.lastPathComponent, stamp: 10)) }
        let store = BaseDataStore(service: service, cacheURL: url)
        await store.bootstrap()
        var cache = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        cache["schemaVersion"] = 2
        cache.removeValue(forKey: "expectedCounts")
        try JSONSerialization.data(withJSONObject: cache).write(to: url)
        let upgraded = BaseDataStore(service: service, cacheURL: url)
        XCTAssertTrue(upgraded.tables.isEmpty, "Old unverified schema must not be treated as a complete snapshot")
        await upgraded.bootstrap()
        XCTAssertTrue(upgraded.isReady)
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(persisted["schemaVersion"] as? Int, 3)
        XCTAssertNotNil(persisted["expectedCounts"])
    }

    nonisolated static func response(path: String, stamp: Int) -> Data {
        let result: Any
        switch path {
        case "info":
            var info: [String: Int] = [:]
            for key in ["total", "careconditions", "caredays", "carespecials", "certifications", "cities", "clienttypes", "commutes", "contents", "countries", "experiences", "faq_categories", "faqs", "genders", "issuetypes", "languages", "languageskills", "media", "roles", "shifts", "states", "subjects", "worktypes"] { info[key] = 1 }
            info["ts_cache"] = stamp
            result = info
        case "languages": result = [["id": 1, "code": "en", "name": "English", "is_default": true, "is_rtl": false]]
        case "states": result = [["id": 1, "country_id": 1, "translations": []]]
        case "media": result = [["id": 1, "slug": "usertype_caregiver", "path": "https://fixture.invalid/image.png"]]
        case "faqs": result = [["id": 1, "faq_category_id": 1, "translations": []]]
        case "faq_categories": result = [["id": 1, "slug": "sample", "translations": []]]
        default: result = [["id": 1, "code": "stamp-\(stamp)", "translations": []]]
        }
        return try! JSONSerialization.data(withJSONObject: ["result": result, "message": "Successful Operation"])
    }
}


/// Controlled missing-translation branches of real Localization. These private
/// instances never change UserDefaults, the shared base store or native fixtures.
/// Service behavior does not establish forced-fallback native rendering coverage.
@MainActor
final class LocalizationFallbackTests: XCTestCase {
    func testMissingCurrentLanguageFallsBackToEnglishForManagedSlugResolvers() throws {
        let loc = Localization()
        loc.languageId = 3
        loc.apply(try content(slug: "bottom_navigation_matches", translations: [(1, "Matches"), (2, "Correspondances")]))
        XCTAssertEqual(loc.t("bottom_navigation_matches", "Unused fallback"), "Matches")
        XCTAssertEqual(loc("bottom_navigation_matches", languageId: 3), "Matches")
        XCTAssertEqual(loc("bottom_navigation_matches", languageId: 2), "Correspondances")
    }

    func testEnglishSceneReverseLookupUsesTranslationOrEnglishWhenEntryMissing() throws {
        let loc = Localization()
        loc.languageId = 3
        loc.apply(try content(slug: "match_match_button", translations: [(1, "Request a Match"), (2, "Demander une mise en relation")]))
        XCTAssertEqual(loc.translating(english: "Request a Match", languageId: 2), "Demander une mise en relation")
        XCTAssertEqual(loc.translating(english: "Request\n a Match!", languageId: 3), "Request a Match")
        XCTAssertNil(loc.translating(english: "Request a Match", languageId: 1),
                     "English scene nodes do not need replacement in the English language")
    }

    func testMissingSlugUsesProvidedFallbackAndDoesNotInventSceneTranslation() throws {
        let loc = Localization()
        loc.languageId = 3
        loc.apply(try content(slug: "bottom_navigation_matches", translations: [(1, "Matches")]))
        XCTAssertEqual(loc.t("chat_screen_match_check", "You can only send messages to your current matches."),
                       "You can only send messages to your current matches.")
        XCTAssertEqual(loc.t("chat_screen_match_check"), "chat_screen_match_check")
        XCTAssertEqual(loc("chat_screen_match_check", languageId: 3), "chat_screen_match_check")
        XCTAssertNil(loc.translating(english: "Unknown synthetic scene copy", languageId: 3))
    }

    func testLanguageSwitchAndReferenceReplacementDoNotKeepRemovedTranslation() throws {
        let loc = Localization()
        loc.languageId = 1
        loc.apply(try content(slug: "bottom_navigation_messages", translations: [(1, "Messages"), (2, "Messages synthétiques")]))
        XCTAssertEqual(loc.t("bottom_navigation_messages", "Unused fallback"), "Messages")
        loc.languageId = 2
        XCTAssertEqual(loc.t("bottom_navigation_messages", "Unused fallback"), "Messages synthétiques")
        XCTAssertEqual(loc("bottom_navigation_messages", languageId: 2), "Messages synthétiques")
        XCTAssertEqual(loc.translating(english: "Messages", languageId: 2), "Messages synthétiques")
        loc.apply(try content(slug: "bottom_navigation_messages", translations: [(1, "Messages")]))
        XCTAssertEqual(loc.t("bottom_navigation_messages", "Unused fallback"), "Messages")
        XCTAssertEqual(loc("bottom_navigation_messages", languageId: 2), "Messages")
        XCTAssertEqual(loc.translating(english: "Messages", languageId: 2), "Messages",
                       "Reverse scene translation must use the newly supplied English fallback, not old translated copy")
        loc.languageId = 3
        XCTAssertEqual(loc.t("bottom_navigation_messages", "Unused fallback"), "Messages")
    }

    /// Decode the production wire shape rather than bypassing BaseItem decoding.
    private func content(slug: String, translations: [(Int, String)]) throws -> [BaseItem] {
        let rows: [[String: Any]] = [["id": 1, "slug": slug,
            "translations": translations.enumerated().map { index, entry in
                ["id": index + 1, "language_id": entry.0, "name": entry.1] as [String: Any]
            }]]
        return try JSONDecoder().decode([BaseItem].self, from: JSONSerialization.data(withJSONObject: rows))
    }
}
