import BrieflyCore
import Observation

@MainActor
@Observable
final class LibrarySharingModel {
    let session: LibrarySession

    init(session: LibrarySession) {
        self.session = session
    }

    func shareStatus(for entry: LibraryEntry) async throws -> BrieflyShareLinkStatus {
        guard let captureID = entry.captureID else {
            throw BrieflyBackendError.message("This document cannot be published.")
        }
        return try await session.backend.shareStatus(captureID: captureID)
    }

    func publishShare(for entry: LibraryEntry) async throws -> BrieflyShareLinkStatus {
        guard let captureID = entry.captureID else {
            throw BrieflyBackendError.message("This document cannot be published.")
        }
        guard let library = session.library else {
            throw BrieflyBackendError.message("Open the local library before publishing.")
        }
        let document = try await library.getDocument(entry.id)
        let filename = "\(captureID).md"
        var texts = [BrieflyShareSource.Text]()
        for variant in LibraryVariant.allCases where variant != .source {
            let markdown = (document.texts[variant] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !markdown.isEmpty {
                texts.append(.init(variant: variant.rawValue, markdown: markdown))
            }
        }
        guard !texts.isEmpty else {
            throw BrieflyBackendError.message(
                "Create at least one summary before publishing this document."
            )
        }
        let source = BrieflyShareSource(
            filename: filename,
            title: entry.title,
            excerpt: entry.excerpt,
            topicIDs: entry.topicIDs,
            topicNames: entry.topicNames,
            tags: entry.tags,
            sourceURL: entry.sourceURL,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            texts: texts
        )
        let result = try await session.backend.publishShare(
            captureID: captureID,
            source: source
        )
        if result.status == "failed" {
            throw BrieflyBackendError.message(
                result.error ?? "The shareable reader could not be prepared."
            )
        }
        return result
    }

    func revokeShare(_ token: String) async throws {
        try await session.backend.revokeShare(token: token)
    }
}
