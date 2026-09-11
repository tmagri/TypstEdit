import XCTest
@testable import TypstEdit

@MainActor
final class TypstUpdaterTests: XCTestCase {

    func testVersionComparisonOlder() {
        XCTAssertTrue(TypstUpdater.isVersion("0.12.0", strictlyOlderThan: "0.15.1"))
        XCTAssertTrue(TypstUpdater.isVersion("v0.12.0", strictlyOlderThan: "v0.15.1"))
        XCTAssertTrue(TypstUpdater.isVersion("0.12.0", strictlyOlderThan: "v0.15.1"))
        XCTAssertTrue(TypstUpdater.isVersion("0.15.0", strictlyOlderThan: "0.15.1"))
        XCTAssertTrue(TypstUpdater.isVersion("0.9.0", strictlyOlderThan: "0.10.0"))
        XCTAssertTrue(TypstUpdater.isVersion("0.12", strictlyOlderThan: "0.12.1"))
    }

    func testVersionComparisonSameOrNewer() {
        XCTAssertFalse(TypstUpdater.isVersion("0.15.1", strictlyOlderThan: "0.15.1"))
        XCTAssertFalse(TypstUpdater.isVersion("v0.15.1", strictlyOlderThan: "0.15.1"))
        XCTAssertFalse(TypstUpdater.isVersion("0.15.1", strictlyOlderThan: "v0.15.1"))
        XCTAssertFalse(TypstUpdater.isVersion("0.16.0", strictlyOlderThan: "0.15.1"))
        XCTAssertFalse(TypstUpdater.isVersion("1.0.0", strictlyOlderThan: "0.15.1"))
    }

    func testVersionComparisonWithBuildMetadataOrPrerelease() {
        XCTAssertTrue(TypstUpdater.isVersion("0.12.0-rc1", strictlyOlderThan: "0.15.1"))
        XCTAssertFalse(TypstUpdater.isVersion("0.15.1-rc1", strictlyOlderThan: "0.15.1"))
    }

    func testCheckOnLaunchSettingDefaultAndToggle() {
        let settings = GeneralSettingsManager.shared
        let original = settings.checkForTypstUpdatesOnLaunch

        settings.checkForTypstUpdatesOnLaunch = true
        XCTAssertTrue(settings.checkForTypstUpdatesOnLaunch)

        // User asks to not ask again
        settings.checkForTypstUpdatesOnLaunch = false
        XCTAssertFalse(settings.checkForTypstUpdatesOnLaunch)

        // User re-enables in settings
        settings.checkForTypstUpdatesOnLaunch = true
        XCTAssertTrue(settings.checkForTypstUpdatesOnLaunch)

        // Restore original
        settings.checkForTypstUpdatesOnLaunch = original
    }

    func testDetectCurrentVersionOnActiveBinary() async {
        let updater = TypstUpdater.shared
        let version = await updater.detectCurrentVersion()
        // If a Typst binary exists in bundle or system or test environment,
        // it should detect a non-empty version string (e.g. "0.12.0")
        if let version = version {
            XCTAssertFalse(version.isEmpty)
            print("[TEST] Detected Typst version: \(version)")
        }
    }
}
