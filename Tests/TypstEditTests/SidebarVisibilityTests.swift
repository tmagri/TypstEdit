import XCTest
@testable import TypstEdit

final class SidebarVisibilityTests: XCTestCase {
    func testDefaultsKeepExistingToolsButRequireAIChatOptIn() {
        let visibility = SidebarVisibility()
        XCTAssertEqual(visibility.panels, [.files, .calculator])
        XCTAssertEqual(visibility.browserModes, [0, 1])
        XCTAssertTrue(visibility.showsSourceControl)
    }

    func testAIChatUsesExistingOptIn() {
        var visibility = SidebarVisibility()
        visibility.aiChat = true
        XCTAssertEqual(visibility.panels, [.files, .aiChat, .calculator])
        XCTAssertEqual(visibility.resolvedPanel(.aiChat), .aiChat)
        visibility.aiChat = false
        XCTAssertEqual(visibility.resolvedPanel(.aiChat), .files)
    }

    func testHidingCalculatorFallsBackWithoutShowingHiddenPanels() {
        let visibility = SidebarVisibility(files: false, calculator: false, aiChat: true)
        XCTAssertEqual(visibility.panels, [.aiChat])
        XCTAssertEqual(visibility.resolvedPanel(.calculator), .aiChat)
        XCTAssertEqual(visibility.resolvedPanel(.files), .aiChat)
    }

    func testHidingActiveBrowserModeChoosesVisibleMode() {
        let notebooksOnly = SidebarVisibility(projects: false)
        XCTAssertEqual(notebooksOnly.browserModes, [1])
        XCTAssertEqual(notebooksOnly.resolvedBrowserMode(0), 1)
        XCTAssertFalse(notebooksOnly.showsSourceControl)

        let projectsOnly = SidebarVisibility(notebooks: false)
        XCTAssertEqual(projectsOnly.browserModes, [0])
        XCTAssertEqual(projectsOnly.resolvedBrowserMode(1), 0)
    }

    func testFilesDisappearsWhenBothBrowserModesAreHidden() {
        let visibility = SidebarVisibility(projects: false, notebooks: false)
        XCTAssertEqual(visibility.panels, [.calculator])
        XCTAssertNil(visibility.resolvedBrowserMode(0))
        XCTAssertFalse(visibility.showsSourceControl)
    }

    func testAllPanelsCanBeHidden() {
        let visibility = SidebarVisibility(files: false, calculator: false)
        XCTAssertTrue(visibility.panels.isEmpty)
        XCTAssertNil(visibility.resolvedPanel(.files))
        XCTAssertNil(visibility.resolvedPanel(.calculator))
        XCTAssertNil(visibility.resolvedPanel(.aiChat))
    }

    func testGitVisibilityIsIndependentOfOtherTools() {
        let visibility = SidebarVisibility(sourceControl: false, aiChat: true)
        XCTAssertFalse(visibility.showsSourceControl)
        XCTAssertEqual(visibility.panels, [.files, .aiChat, .calculator])
        XCTAssertEqual(visibility.browserModes, [0, 1])
    }

    func testIssuesAreShownByDefaultAndCanBeHiddenIndependently() {
        XCTAssertTrue(SidebarVisibility().showsIssues)

        let hidden = SidebarVisibility(issues: false)
        XCTAssertFalse(hidden.showsIssues)
        XCTAssertTrue(hidden.showsSourceControl)
        XCTAssertEqual(hidden.panels, [.files, .calculator])
    }

    func testIssuesFollowTheFilesPanel() {
        // Notebooks alone still show the Files panel, so Issues stay.
        XCTAssertTrue(SidebarVisibility(projects: false).showsIssues)
        XCTAssertFalse(SidebarVisibility(files: false).showsIssues)
        XCTAssertFalse(SidebarVisibility(projects: false, notebooks: false).showsIssues)
    }

    func testEveryCombinationResolvesOnlyToVisibleFeatures() {
        for flags in 0..<128 {
            let visibility = SidebarVisibility(
                files: flags & 1 != 0,
                projects: flags & 2 != 0,
                notebooks: flags & 4 != 0,
                calculator: flags & 8 != 0,
                sourceControl: flags & 16 != 0,
                aiChat: flags & 32 != 0,
                issues: flags & 64 != 0
            )
            for panel: EditorController.SidebarContent in [.files, .aiChat, .calculator] {
                if let resolved = visibility.resolvedPanel(panel) {
                    XCTAssertTrue(visibility.panels.contains(resolved))
                    XCTAssertEqual(visibility.resolvedPanel(resolved), resolved)
                    if visibility.panels.contains(panel) { XCTAssertEqual(resolved, panel) }
                } else {
                    XCTAssertTrue(visibility.panels.isEmpty)
                }
            }
            for mode in [0, 1] {
                if let resolved = visibility.resolvedBrowserMode(mode) {
                    XCTAssertTrue(visibility.browserModes.contains(resolved))
                    XCTAssertEqual(visibility.resolvedBrowserMode(resolved), resolved)
                } else {
                    XCTAssertTrue(visibility.browserModes.isEmpty)
                }
            }
            XCTAssertEqual(visibility.showsSourceControl,
                           visibility.files && visibility.projects && visibility.sourceControl)
            XCTAssertEqual(visibility.showsIssues,
                           visibility.files && (visibility.projects || visibility.notebooks) && visibility.issues)
        }
    }
}
