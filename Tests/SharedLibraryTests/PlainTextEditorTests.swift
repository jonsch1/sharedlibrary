import AppKit
import XCTest
@testable import SharedLibrary

@MainActor
final class PlainTextEditorTests: XCTestCase {
    func testEditorUsesTextKit1CompatibilityMode() {
        let textView = PlainTextEditor.makeTextView()

        XCTAssertNotNil(textView.layoutManager)
        XCTAssertNil(textView.textLayoutManager)
    }
}
