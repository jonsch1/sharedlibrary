import Foundation

public struct LibraryProjection: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let files: [LibraryFile]
    public let entries: [LibraryEntry]

    public static func decode(_ data: Data) throws -> LibraryProjection {
        let projection: LibraryProjection
        do {
            projection = try JSONDecoder().decode(LibraryProjection.self, from: data)
        } catch {
            throw LibraryContractError.incompatible
        }
        try projection.validate()
        return projection
    }

    public static let demo: LibraryProjection = {
        guard
            let url = Bundle.module.url(forResource: "demo-library", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let projection = try? decode(data)
        else {
            preconditionFailure("The bundled Briefly demo library is invalid.")
        }
        return projection
    }()

    public static let empty = LibraryProjection(
        schemaVersion: 1,
        generatedAt: "",
        files: [],
        entries: []
    )

    public var topics: [String] {
        Array(Set(entries.flatMap(\.topicNames))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    public var documentTopics: [String] {
        topics.filter { topic in
            entries.contains { $0.isMainLibraryEntry && $0.topicNames.contains(topic) }
        }
    }

    public var channelSources: [String] {
        Array(Set(entries.flatMap { $0.channelSources ?? [] })).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    public func entries(forChannel source: String) -> [LibraryEntry] {
        entries.filter { $0.channelSources?.contains(source) == true }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    private func validate() throws {
        guard schemaVersion == librarySchemaVersion,
              isISO8601(generatedAt), files.allSatisfy(\.isValid), entries.allSatisfy(\.isValid)
        else { throw LibraryContractError.incompatible }
    }
}

public enum LibraryContractError: LocalizedError {
    case incompatible

    public var errorDescription: String? {
        "This is not a compatible Briefly library index. Open Briefly and let it synchronize again."
    }
}

private extension LibraryFile {
    var isValid: Bool { isSafeRelativePath(path) && isSHA256(contentHash) && byteCount >= 0 }
}

private extension LibraryEntry {
    var isValid: Bool {
        audio?.isValid ?? true && favicon?.isValid ?? true && texts.allSatisfy(\.isValid)
    }
}

private extension LibraryText {
    var isValid: Bool {
        if text != nil { return true }
        guard let path, let contentHash, let wordCount else { return false }
        return isSafeRelativePath(path) && isSHA256(contentHash) && wordCount >= 0
    }
}

private extension LibraryMedia {
    var isValid: Bool {
        let directory = kind == .audio ? "library/audio/" : "library/favicons/"
        return path.hasPrefix(directory) && isSafeRelativePath(path) && isSHA256(contentHash) &&
            byteCount > 0 && contentType.hasPrefix(kind == .audio ? "audio/" : "image/")
    }
}

private func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func isSafeRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("/") else { return false }
    return !value.split(separator: "/", omittingEmptySubsequences: false)
        .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
}

private func isISO8601(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) != nil
}
