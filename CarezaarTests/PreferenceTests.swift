import XCTest
import CoreLocation
@testable import Carezaar

final class PreferenceTests: XCTestCase {
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
