import Foundation
import PDFKit

func ingestPDF(_ request: ItemInputRequest) throws -> ItemDraft {
    guard case .file(let url) = request.source, url.pathExtension.lowercased() == "pdf" else {
        throw NativeInputError.unsupportedInput
    }
    guard let document = PDFDocument(url: url), let content = document.string?.nativeNilIfEmpty else {
        throw NativeInputError.unreadableContent
    }
    let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
    return ItemDraft(
        inputID: .pdf,
        title: title?.nativeNilIfEmpty ?? url.deletingPathExtension().lastPathComponent,
        content: content
    )
}
