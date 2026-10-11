import XCTest
@testable import Carezaar

@MainActor
final class StartupTests: XCTestCase {
    func testRejectedSavedSessionShowsWelcomeEvenWhenReferencesAreUnavailable() {
        XCTAssertEqual(StartupDestination.resolve(state: .signedOut, referencesReady: false, savedSessionRejected: true), .welcome)
    }
    func testNewInstallWaitsForAllReferencesBeforeWelcome() {
        XCTAssertEqual(StartupDestination.resolve(state: .signedOut, referencesReady: false, savedSessionRejected: false), .splash)
        XCTAssertEqual(StartupDestination.resolve(state: .signedOut, referencesReady: true, savedSessionRejected: false), .welcome)
        XCTAssertEqual(StartupDestination.resolve(state: .loading, referencesReady: true, savedSessionRejected: false), .splash)
    }
}
