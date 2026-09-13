import Foundation

/// Reads a user-selected text file or retains a PDF for the capture boundary.
/// This performs no extraction and can be used on the phone.
public enum CaptureFileInput {
    public static let textExtensions: Set<String> = ["txt", "text", "md", "markdown"]

    public static func read(_ url: URL) throws -> ItemInputRequest {
        guard url.isFileURL else { throw CaptureFileError.unsupported }
        if url.pathExtension.lowercased() == "pdf" { return .init(source: .file(url)) }
        guard textExtensions.contains(url.pathExtension.lowercased()) else {
            throw CaptureFileError.unsupported
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= SharedCaptureInbox.maximumTextBytes else { throw SharedCaptureInboxError.textTooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= SharedCaptureInbox.maximumTextBytes else { throw SharedCaptureInboxError.textTooLarge }
        let text: String?
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard let text, !text.contains("\0") else { throw CaptureFileError.invalidText }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SharedCaptureInboxError.emptyText
        }
        return .init(source: .text(text), hints: .init(title: url.deletingPathExtension().lastPathComponent))
    }
}

public enum CaptureFileError: LocalizedError {
    case unsupported, invalidText
    public var errorDescription: String? {
        switch self {
        case .unsupported: "Choose a PDF, plain text (.txt), or Markdown (.md) file."
        case .invalidText: "This file could not be read as UTF-8 or UTF-16 text."
        }
    }
}
