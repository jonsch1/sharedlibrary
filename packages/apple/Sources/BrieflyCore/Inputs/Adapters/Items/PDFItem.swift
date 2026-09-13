#if os(macOS)
import Foundation
import PDFKit

private let maximumPDFBytes = 20_000_000

func ingestPDF(_ request: ItemInputRequest) throws -> ItemDraft {
    guard case .file(let url) = request.source, url.pathExtension.lowercased() == "pdf" else {
        throw NativeInputError.unsupportedInput
    }
    return try ingestPDFFile(at: url, maximumBytes: maximumPDFBytes)
}

func ingestPDFFile(at url: URL, maximumBytes: Int) throws -> ItemDraft {
    guard url.pathExtension.lowercased() == "pdf" else {
        throw NativeInputError.unsupportedInput
    }

    let resourceValues: URLResourceValues
    do {
        resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    } catch {
        throw NativeInputError.unreadableContent
    }
    guard resourceValues.isRegularFile == true else { throw NativeInputError.unreadableContent }
    guard let fileSize = resourceValues.fileSize else { throw NativeInputError.unreadableContent }
    guard fileSize <= maximumBytes else { throw NativeInputError.responseTooLarge }

    guard let document = PDFDocument(url: url), !document.isLocked else {
        throw NativeInputError.unreadableContent
    }

    let pages = (0..<document.pageCount).compactMap { index -> String? in
        guard let page = document.page(at: index), let text = page.string else { return nil }
        return cleanPDFText(text)
    }
    guard !pages.isEmpty else { throw NativeInputError.unreadableContent }
    let content = pages.joined(separator: "\n\n")
    guard !content.isEmpty else { throw NativeInputError.unreadableContent }

    let title = cleanPDFText(
        document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
    ) ?? pdfFilenameTitle(url)
    return ItemDraft(
        inputID: .pdf,
        title: title ?? "PDF document",
        content: content
    )
}

private func cleanPDFText(_ value: String?) -> String? {
    guard let value else { return nil }
    let text = value
        .replacingOccurrences(of: "\u{00A0}", with: " ")
        .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.nativeNilIfEmpty
}

private func pdfFilenameTitle(_ url: URL) -> String? {
    let filename = url.deletingPathExtension().lastPathComponent
        .removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
    return cleanPDFText(
        filename.replacingOccurrences(of: #"[-_]+"#, with: " ", options: .regularExpression)
    )
}

#endif
