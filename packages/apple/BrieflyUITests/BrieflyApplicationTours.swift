import XCTest

final class BrieflyApplicationTours: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testSeededLibraryTour() {
        launch(scenario: "seeded-library", reset: true)

        let article = element("library.entry.fixture:article")
        XCTAssertTrue(article.waitForExistence(timeout: 10))
        article.tap()

        let detailed = firstExisting(
            element("reader.depth.detailed"),
            app.buttons["Detailed"]
        )
        XCTAssertTrue(detailed.waitForExistence(timeout: 5))
        detailed.tap()
        XCTAssertTrue(detailed.isSelected)
    }

    func testPrimarySectionsTour() {
        launch(scenario: "primary-sections", reset: true)

        openSection("channels")
        XCTAssertTrue(
            element("library.entry.fixture:channel-article").waitForExistence(timeout: 10)
        )

        openSection("briefs")
        XCTAssertTrue(
            element("library.entry.fixture:brief-episode").waitForExistence(timeout: 10)
        )

        openSection("library")
        let capture = captureButton()
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        capture.tap()
        XCTAssertTrue(element("capture.text").waitForExistence(timeout: 5))
        XCTAssertTrue(element("capture.save").waitForExistence(timeout: 5))
    }

    private func launch(scenario: String, reset: Bool) {
        app.terminate()
        app.launchArguments = [
            "--ui-testing",
            "--ui-test-scenario", scenario
        ] + (reset ? ["--ui-test-reset"] : [])
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func captureButton() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier == %@ OR label == %@",
                "capture.open",
                "Capture"
            ))
            .firstMatch
    }

    private func firstExisting(
        _ preferred: XCUIElement,
        _ fallback: @autoclosure () -> XCUIElement
    ) -> XCUIElement {
        preferred.exists ? preferred : fallback()
    }

    private func openSection(_ section: String) {
        #if os(macOS)
        let macSection = section == "library" ? "items" : section
        let fallbackLabel = macSection == "items" ? "Home" : macSection.capitalized
        let button = firstExisting(
            element("navigation.\(macSection)"),
            app.buttons[fallbackLabel]
        )
        #else
        let button = app.tabBars.buttons[section.capitalized]
        #endif
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }
}
