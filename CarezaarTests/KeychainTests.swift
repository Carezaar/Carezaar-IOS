import XCTest
@testable import Carezaar

final class KeychainTests: XCTestCase {
    func testActualKeychainPairSurvivesNewStoreAndRejectsStaleRefreshAfterClear() {
        let service = "com.carezaar.qa.session." + UUID().uuidString
        let first = TokenStore(service: service)
        defer { first.clear(); UserDefaults.standard.removeObject(forKey: service + ".installMarker") }
        first.save(Session(accessToken: "fixture-access", refreshToken: "fixture-refresh"))
        XCTAssertTrue(first.hasSession, "Real simulator Keychain must persist the pair")
        let reopened = TokenStore(service: service)
        XCTAssertEqual(reopened.accessToken, "fixture-access")
        XCTAssertEqual(reopened.refreshToken, "fixture-refresh")
        let oldGeneration = reopened.generation
        reopened.clear()
        XCTAssertFalse(reopened.replace(Session(accessToken: "late", refreshToken: "late"), ifGeneration: oldGeneration, refreshToken: "fixture-refresh"))
        XCTAssertFalse(TokenStore(service: service).hasSession)
    }
}
