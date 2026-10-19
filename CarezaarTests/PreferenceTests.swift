import XCTest
import CoreLocation
@testable import Carezaar

final class PreferenceTests: XCTestCase {
    func testPeopleArtworkRemainsExcludedFromProductResources() {
        // Explicit product requirement: retain the intentional artwork removals.
        for name in ["bg_intro", "client_pregnancy", "client_senior", "client_adult", "client_child", "header_pregnancy", "header_senior", "header_adult", "header_child"] {
            XCTAssertNil(AppImage.load(name), "People artwork must stay out of the app bundle: \(name)")
        }
        for name in ["ic_caregiver", "ic_client", "ic_condition_personal_care", "ic_condition_feeding", "ic_condition_companionship", "ic_condition_assessment", "ic_support"] {
            XCTAssertNil(AndroidVectors.shared.vector(name), "Removed people vector must not be restored: \(name)")
        }
        for name in ["brainstorm-needs-quality-9.png", "brainstorm-needs-quality-2.png", "1dd97cfcd4eda6b7fff530d0d8ccb8f25c100ce5.jpg"] {
            XCTAssertNil(Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Assets"),
                         "Facial or unapproved people imagery must not ship: \(name)")
        }
        XCTAssertEqual(SourceStore.assetURL("92bf103484e337567f379617f79c6c37ba10484d.jpg")?.lastPathComponent, "intro-room.jpg")
        XCTAssertNotNil(AppImage.load("header_messages"), "Keep the supplied hands-only Messages image")
        XCTAssertNotNil(AndroidVectors.shared.vector("ic_user"), "Keep the faceless person outline")
    }

    func testEqualAndReversedPayUseManagedRangeError() {
        for role in [UserRole.client, .caregiver] {
            XCTAssertEqual(PreferenceValidation.payProblem(minimum: 10, maximum: 10, role: role), "general_salary_min_max")
            XCTAssertEqual(PreferenceValidation.payProblem(minimum: 12, maximum: 10, role: role), "general_salary_min_max")
            XCTAssertNil(PreferenceValidation.payProblem(minimum: 10, maximum: 12, role: role))
        }
    }

    func testExistingRoleSpecificMissingPayRulesRemain() {
        XCTAssertNil(PreferenceValidation.payProblem(minimum: nil, maximum: nil, role: .client))
        XCTAssertEqual(PreferenceValidation.payProblem(minimum: nil, maximum: 12, role: .caregiver), "general_required")
        XCTAssertEqual(PreferenceValidation.payProblem(minimum: 10, maximum: nil, role: .caregiver), "general_required")
    }

    func testClientSkillsProceedWithoutCertificationsAndKeepOtherRequirements() {
        XCTAssertNil(PreferenceValidation.skillsProblem(role: .client, conditions: [1], specials: [1], experiences: [1], roles: [1], certifications: [], languages: [1]))
        for certificates in [[1], [1, 2]] {
            XCTAssertNil(PreferenceValidation.skillsProblem(role: .client, conditions: [1], specials: [1], experiences: [1], roles: [1], certifications: certificates, languages: [1]))
        }
        XCTAssertEqual(PreferenceValidation.skillsProblem(role: .client, conditions: [1], specials: [1], experiences: [], roles: [1], certifications: [], languages: [1]), "signup_form_client_minimum_experience")
        XCTAssertEqual(PreferenceValidation.skillsProblem(role: .caregiver, conditions: [1], specials: [1], experiences: [1], roles: [], certifications: [], languages: [1]), "signup_form_caregiver_role")
    }

    func testRealCachedLocationCanBeUsedWithoutManualSelection() {
        let location = CLLocation(coordinate: .init(latitude: 51.5, longitude: -0.12), altitude: 0, horizontalAccuracy: 20, verticalAccuracy: -1, timestamp: Date())
        XCTAssertEqual(LocationProvider.usableCoordinate(from: location)?.latitude, 51.5)
        XCTAssertFalse(LocationProvider.isStale(location))
    }

    func testInvalidCoordinatesAndFutureFixCannotSeedTheMap() {
        for point in [CLLocationCoordinate2D(latitude: .nan, longitude: 1),
                      CLLocationCoordinate2D(latitude: 91, longitude: 1),
                      CLLocationCoordinate2D(latitude: 1, longitude: 181)] {
            XCTAssertNil(LocationProvider.initialMapCoordinate(point))
        }
        let future = CLLocation(coordinate: .init(latitude: 51.5, longitude: -0.12), altitude: 0, horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: Date(timeIntervalSinceNow: 3_600))
        XCTAssertNil(LocationProvider.usableCoordinate(from: future))
    }

    func testMissingLocationDoesNotBecomeAFabricatedMapSelection() {
        XCTAssertNil(LocationProvider.initialMapCoordinate(nil))
        let actual = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        XCTAssertEqual(LocationProvider.initialMapCoordinate(actual)?.longitude, -0.12)
    }

    func testStaleLastKnownLocationRetainsHonestAgeAndInvalidFixIsRejected() {
        let stale = CLLocation(coordinate: .init(latitude: 51.5, longitude: -0.12), altitude: 0, horizontalAccuracy: 100, verticalAccuracy: -1, timestamp: Date(timeIntervalSinceNow: -3_600))
        XCTAssertNotNil(LocationProvider.usableCoordinate(from: stale))
        XCTAssertTrue(LocationProvider.isStale(stale))
        let invalid = CLLocation(coordinate: .init(latitude: 51.5, longitude: -0.12), altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: Date())
        XCTAssertNil(LocationProvider.usableCoordinate(from: invalid))
        XCTAssertNil(LocationProvider.usableCoordinate(from: nil))
    }
}
