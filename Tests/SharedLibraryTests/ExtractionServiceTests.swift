import AppKit
import XCTest
@testable import SharedLibrary

final class ExtractionServiceTests: XCTestCase {
    func testLikelyPDFURLRecognizesPDFExtensionsAndDirectArxivLinks() throws {
        XCTAssertTrue(
            ExtractionService.isLikelyPDFURL(
                try XCTUnwrap(URL(string: "https://example.com/report.PDF?download=1"))
            )
        )
        XCTAssertTrue(
            ExtractionService.isLikelyPDFURL(
                try XCTUnwrap(URL(string: "https://arxiv.org/pdf/2607.12441"))
            )
        )
        XCTAssertFalse(
            ExtractionService.isLikelyPDFURL(
                try XCTUnwrap(URL(string: "https://arxiv.org/abs/2607.12441"))
            )
        )
    }

    func testMarkxivURLConvertsArxivPDFLinks() throws {
        let versionedPDF = try XCTUnwrap(URL(string: "https://arxiv.org/pdf/1706.03762v7.pdf?download=1"))
        let extensionlessPDF = try XCTUnwrap(URL(string: "https://www.arxiv.org/pdf/2607.12441"))

        XCTAssertEqual(
            ExtractionService.markxivURL(forArxivPDFURL: versionedPDF)?.absoluteString,
            "https://www.markxiv.org/abs/1706.03762v7"
        )
        XCTAssertEqual(
            ExtractionService.markxivURL(forArxivPDFURL: extensionlessPDF)?.absoluteString,
            "https://www.markxiv.org/abs/2607.12441"
        )
        XCTAssertNil(
            ExtractionService.markxivURL(
                forArxivPDFURL: try XCTUnwrap(URL(string: "https://example.com/paper.pdf"))
            )
        )
        XCTAssertNil(
            ExtractionService.markxivURL(
                forArxivPDFURL: try XCTUnwrap(URL(string: "https://arxiv.org/abs/1706.03762"))
            )
        )
    }

    func testBioRxivArticleURLConvertsToFullPDF() throws {
        let article = try XCTUnwrap(
            URL(string: "https://www.biorxiv.org/content/10.64898/2026.07.09.737605v1")
        )
        let directPDF = try XCTUnwrap(
            URL(string: "https://biorxiv.org/content/10.1101/2025.01.02.123456v3.full.pdf?download=1")
        )

        XCTAssertEqual(
            ExtractionService.bioRxivPDFURL(forArticleURL: article)?.absoluteString,
            "https://www.biorxiv.org/content/10.64898/2026.07.09.737605v1.full.pdf"
        )
        XCTAssertEqual(
            ExtractionService.bioRxivPDFURL(forArticleURL: directPDF)?.absoluteString,
            "https://www.biorxiv.org/content/10.1101/2025.01.02.123456v3.full.pdf"
        )
    }

    func testBioRxivPDFURLRejectsNonArticleURLs() throws {
        XCTAssertNil(
            ExtractionService.bioRxivPDFURL(
                forArticleURL: try XCTUnwrap(URL(string: "https://example.com/content/10.64898/2026.07.09.737605v1"))
            )
        )
        XCTAssertNil(
            ExtractionService.bioRxivPDFURL(
                forArticleURL: try XCTUnwrap(URL(string: "https://www.biorxiv.org/about-biorxiv"))
            )
        )
        XCTAssertNil(
            ExtractionService.bioRxivPDFURL(
                forArticleURL: try XCTUnwrap(URL(string: "https://www.biorxiv.org/content/10.64898/2026.07.09.737605"))
            )
        )
    }

    func testMarkdownTitleUsesFirstLevelOneHeading() {
        let markdown = """
        Intro text
        ## Authors
        # Attention Is All You Need
        """

        XCTAssertEqual(
            ExtractionService.markdownTitle(in: markdown),
            "Attention Is All You Need"
        )
        XCTAssertNil(ExtractionService.markdownTitle(in: "## Section only"))
    }

    func testExtractedPDFContentReadsText() throws {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        view.string = "Shared Library can extract this PDF text."
        let data = view.dataWithPDF(inside: view.bounds)
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/paper.pdf"))

        let extracted = try ExtractionService.extractedPDFContent(from: data, sourceURL: sourceURL)

        XCTAssertEqual(extracted.url, sourceURL.absoluteString)
        XCTAssertTrue(extracted.content.contains("Shared Library can extract this PDF text."))
        XCTAssertEqual(extracted.siteName, "example.com")
        XCTAssertGreaterThan(extracted.wordCount ?? 0, 0)
    }

    func testExtractedPDFContentRejectsInvalidData() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/not-a-pdf.pdf"))

        XCTAssertThrowsError(
            try ExtractionService.extractedPDFContent(from: Data("not a PDF".utf8), sourceURL: sourceURL)
        ) { error in
            XCTAssertEqual(error.localizedDescription, "The downloaded file is not a valid PDF.")
        }
    }
}
