import XCTest
@testable import Paladala

/// Tests for the pure helpers in `AppVersion.swift`.
///
/// We deliberately don't exercise `AppVersion.current` or
/// `detectReleaseType` here — both depend on the running
/// bundle's Info.plist and on the simulator's provisioning
/// state, which is brittle in CI.  The functions below are
/// the parts of the build-identity flow that need to stay
/// stable: the SHA-1 fingerprint, the formatted serial, and
/// the dotted-version comparator used by the update checker.
final class AppVersionTests: XCTestCase {

    // MARK: - makeIdentifier

    func test_makeIdentifier_isDeterministicForSameInputs() {
        let a = AppVersion.makeIdentifier(inputs: [
            "bundleId": "com.dt.paladala",
            "marketingVersion": "0.5.1",
            "buildNumber": "195",
            "releaseType": "sideload",
            "commit": "6cf275c0",
            "epoch": "1700000000",
            "salt": ""
        ])
        let b = AppVersion.makeIdentifier(inputs: [
            "bundleId": "com.dt.paladala",
            "marketingVersion": "0.5.1",
            "buildNumber": "195",
            "releaseType": "sideload",
            "commit": "6cf275c0",
            "epoch": "1700000000",
            "salt": ""
        ])
        XCTAssertEqual(a, b, "Same inputs must produce the same fingerprint")
        XCTAssertEqual(a.count, 12, "Identifier should be 12 hex chars (6 bytes)")
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit }, "Identifier must be lowercase hex")
    }

    func test_makeIdentifier_changesWhenAnyInputChanges() {
        let base: [String: String] = [
            "bundleId": "com.dt.paladala",
            "marketingVersion": "0.5.1",
            "buildNumber": "195",
            "releaseType": "sideload",
            "commit": "6cf275c0",
            "epoch": "1700000000",
            "salt": ""
        ]
        let baseID = AppVersion.makeIdentifier(inputs: base)
        for key in ["bundleId", "marketingVersion", "buildNumber",
                    "releaseType", "commit", "epoch", "salt"] {
            var mutated = base
            mutated[key] = (base[key] ?? "") + "-x"
            let mutatedID = AppVersion.makeIdentifier(inputs: mutated)
            XCTAssertNotEqual(mutatedID, baseID,
                "Changing \(key) must change the identifier")
        }
    }

    // MARK: - formatIdentifier

    func test_formatIdentifier_groupsIntoPDDashFourDashFour() {
        let formatted = AppVersion.formatIdentifier("deadbeef1234")
        XCTAssertEqual(formatted, "PD-DEAD-BEEF-1234")
    }

    func test_formatIdentifier_padsShortInputs() {
        let formatted = AppVersion.formatIdentifier("ab")
        // 2 hex chars → padded to 12, all but the first 2 land in the trailing groups
        XCTAssertEqual(formatted, "PD-0000-00AB-0000")
    }

    // MARK: - VersionComparator

    func test_versionComparator_ordersByComponent() {
        XCTAssertEqual(
            VersionComparator.compare("0.5.1.195", "0.5.1.200"),
            .orderedAscending
        )
        XCTAssertEqual(
            VersionComparator.compare("0.5.1.200", "0.5.1.195"),
            .orderedDescending
        )
        XCTAssertEqual(
            VersionComparator.compare("0.5.1.200", "0.5.1.200"),
            .orderedSame
        )
    }

    func test_versionComparator_padsShorterVersions() {
        // The CI's clean "0.5.1" marketing version is older than
        // a prerelease "0.5.1.200" — the trailing 200 makes the
        // prerelease win.
        XCTAssertEqual(
            VersionComparator.compare("0.5.1", "0.5.1.200"),
            .orderedAscending
        )
        XCTAssertEqual(
            VersionComparator.compare("0.5.1.200", "0.5.1"),
            .orderedDescending
        )
    }

    func test_versionComparator_stripsLeadingV() {
        XCTAssertEqual(
            VersionComparator.compare("v0.5.1.195", "0.5.1.195"),
            .orderedSame
        )
        XCTAssertEqual(
            VersionComparator.compare("V0.5.1.196", "v0.5.1.195"),
            .orderedDescending
        )
    }
}
