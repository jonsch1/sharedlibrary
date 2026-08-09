import Foundation

public protocol BrieflyAgentAPI: Sendable {
    func ingest(_ request: BrieflyAgentIngestRequest) async throws -> BrieflyAgentWriteResult
    func save(_ request: BrieflyAgentSaveRequest) async throws -> BrieflyAgentWriteResult
    func search(_ request: BrieflyAgentSearchRequest) async throws -> BrieflyAgentSearchResult
    func read(_ request: BrieflyAgentReadRequest) async throws -> BrieflyAgentReadResult
}

public struct BrieflyAgentIngestRequest: Codable, Equatable, Sendable {
    public let url: String

    public init(url: String) {
        self.url = url
    }
}

public struct BrieflyAgentSaveRequest: Codable, Equatable, Sendable {
    public let title: String
    public let content: String
    public let url: String?
    public let concise: String?
    public let detailed: String?

    public init(
        title: String,
        content: String,
        url: String? = nil,
        concise: String? = nil,
        detailed: String? = nil
    ) {
        self.title = title
        self.content = content
        self.url = url
        self.concise = concise
        self.detailed = detailed
    }
}

public struct BrieflyAgentWriteResult: Codable, Equatable, Sendable {
    public let id: String
    public let status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

public struct BrieflyAgentSearchRequest: Codable, Equatable, Sendable {
    public let q: String?
    public let limit: Int?

    public init(q: String? = nil, limit: Int? = nil) {
        self.q = q
        self.limit = limit
    }
}

public struct BrieflyAgentSearchItem: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let snippet: String?

    public init(id: String, title: String, snippet: String? = nil) {
        self.id = id
        self.title = title
        self.snippet = snippet
    }
}

public struct BrieflyAgentSearchResult: Codable, Equatable, Sendable {
    public let items: [BrieflyAgentSearchItem]

    public init(items: [BrieflyAgentSearchItem]) {
        self.items = items
    }
}

public struct BrieflyAgentReadRequest: Codable, Equatable, Sendable {
    public let id: String
    public let detail: Bool?
    public let cursor: Int?

    public init(id: String, detail: Bool? = nil, cursor: Int? = nil) {
        self.id = id
        self.detail = detail
        self.cursor = cursor
    }
}

public struct BrieflyAgentReadResult: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let text: String?
    public let next: Int?
    public let status: String?

    public init(
        id: String,
        title: String,
        text: String? = nil,
        next: Int? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.next = next
        self.status = status
    }
}

public struct BrieflyAgentFailure: Codable, Equatable, Error, LocalizedError, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    public static func invalid(_ message: String) -> Self {
        .init(code: "invalid_input", message: message)
    }

    public static let unavailable = Self(
        code: "library_unavailable",
        message: "Briefly's library is not ready."
    )

    public static let notFound = Self(
        code: "not_found",
        message: "That Briefly document was not found."
    )
}

/// Read-only agent operations over the library. Saving remains app-owned because
/// it needs the production native input and processing workflow.
public struct BrieflyAgentLibrary: Sendable {
    private static let defaultSearchLimit = 5
    private static let maximumSearchLimit = 10
    private static let readChunkSize = 12_000

    private let store: SQLiteLibraryStore

    public init(store: SQLiteLibraryStore) {
        self.store = store
    }

    public func writeResult(id: String) async throws -> BrieflyAgentWriteResult {
        let document = try await document(id)
        return BrieflyAgentWriteResult(
            id: document.id,
            status: summary(in: document) == nil ? "processing" : "ready"
        )
    }

    public func save(_ request: BrieflyAgentSaveRequest) async throws -> BrieflyAgentWriteResult {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = request.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else {
            throw BrieflyAgentFailure.invalid("title must contain between 1 and 200 characters.")
        }
        guard !content.isEmpty, content.count <= 500_000 else {
            throw BrieflyAgentFailure.invalid(
                "content must contain between 1 and 500,000 characters."
            )
        }
        let concise = try optionalText(
            request.concise,
            name: "concise",
            maximum: 100_000
        )
        let detailed = try optionalText(
            request.detailed,
            name: "detailed",
            maximum: 500_000
        )
        let sourceURL = try optionalHTTPURL(request.url)
        let summaries: [LibraryVariant: String] = [
            .concise: concise,
            .detailed: detailed
        ].compactMapValues { $0 }
        let texts = summaries.merging([.source: content]) { _, supplied in supplied }
        let database = try await store.documentDatabase()
        let existing = sourceURL.flatMap { requestedURL in
            let key = canonicalItemIdentity(requestedURL)
            return try? database.allDocuments().first { document in
                canonicalItemIdentity(document.sourceURL.flatMap(URL.init(string:))) == key
            }
        }
        let document: SQLiteDocument
        if let existing {
            document = try database.commitDocument(SQLiteDocumentCommit(
                id: existing.id,
                baseRevision: existing.revision,
                title: title,
                type: sourceURL == nil ? "text" : "link",
                sourceURL: sourceURL?.absoluteString,
                texts: texts,
                removedTexts: Set([LibraryVariant.concise, .detailed])
                    .subtracting(summaries.keys)
            ))
        } else {
            document = try database.createDocument(
                title: title,
                body: content,
                texts: texts,
                type: sourceURL == nil ? "text" : "link",
                sourceURL: sourceURL?.absoluteString
            )
        }
        if summaries.isEmpty {
            try await store.enqueueProcessingJob(entryID: document.id, selectWhenFinished: false)
        } else {
            try await store.completeProcessingJob(entryID: document.id)
        }
        return BrieflyAgentWriteResult(
            id: document.id,
            status: summaries.isEmpty ? "processing" : "ready"
        )
    }

    public func search(
        _ request: BrieflyAgentSearchRequest
    ) async throws -> BrieflyAgentSearchResult {
        let limit = request.limit ?? Self.defaultSearchLimit
        guard (1...Self.maximumSearchLimit).contains(limit) else {
            throw BrieflyAgentFailure.invalid("limit must be between 1 and 10.")
        }
        let query = request.q?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (query?.count ?? 0) <= 500 else {
            throw BrieflyAgentFailure.invalid("q must contain at most 500 characters.")
        }

        let projection = try await store.loadLibraryIndex()
        let entries = projection.entries.filter(\.isMainLibraryEntry)
        guard let query, !query.isEmpty else {
            return BrieflyAgentSearchResult(items: entries
                .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
                .prefix(limit)
                .map(searchItem))
        }

        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let matches = (try? await store.search(ftsQuery(query), limit: 50)) ?? []
        let summaryMatches = matches
            .filter { $0.variant != .source }
        var items = [BrieflyAgentSearchItem]()
        var seen = Set<String>()
        for match in summaryMatches {
            guard let entry = byID[match.id], seen.insert(match.id).inserted else { continue }
            items.append(BrieflyAgentSearchItem(
                id: entry.id,
                title: entry.title,
                snippet: compact(match.snippet, maximum: 360)
            ))
            if items.count == limit { return BrieflyAgentSearchResult(items: items) }
        }

        for entry in entries where !seen.contains(entry.id) && metadata(entry, matches: query) {
            seen.insert(entry.id)
            items.append(searchItem(entry))
            if items.count == limit { break }
        }
        return BrieflyAgentSearchResult(items: items)
    }

    public func read(_ request: BrieflyAgentReadRequest) async throws -> BrieflyAgentReadResult {
        guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrieflyAgentFailure.invalid("id is required.")
        }
        let cursor = request.cursor ?? 0
        guard cursor >= 0 else {
            throw BrieflyAgentFailure.invalid("cursor must be zero or greater.")
        }
        let document = try await document(request.id)
        let variants: [LibraryVariant] = request.detail == true
            ? [.detailed, .concise]
            : [.concise, .detailed]
        guard let text = variants.compactMap({ document.texts[$0] }).first else {
            return BrieflyAgentReadResult(
                id: document.id,
                title: document.title,
                status: "processing"
            )
        }
        guard cursor <= text.count else {
            throw BrieflyAgentFailure.invalid("cursor is past the end of the document.")
        }
        let start = text.index(text.startIndex, offsetBy: cursor)
        let end = text.index(
            start,
            offsetBy: min(Self.readChunkSize, text.distance(from: start, to: text.endIndex))
        )
        let next = end == text.endIndex ? nil : text.distance(from: text.startIndex, to: end)
        return BrieflyAgentReadResult(
            id: document.id,
            title: document.title,
            text: String(text[start..<end]),
            next: next
        )
    }

    private func document(_ id: String) async throws -> SQLiteDocument {
        do {
            return try await store.getDocument(id)
        } catch SQLiteLibraryError.missingDocument {
            throw BrieflyAgentFailure.notFound
        }
    }

    private func summary(in document: SQLiteDocument) -> String? {
        [document.texts[.concise], document.texts[.detailed]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func optionalText(
        _ value: String?,
        name: String,
        maximum: Int
    ) throws -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximum else {
            throw BrieflyAgentFailure.invalid(
                "\(name) must contain between 1 and \(maximum) characters when supplied."
            )
        }
        return text
    }

    private func optionalHTTPURL(_ value: String?) throws -> URL? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            text.count <= 2_048,
            !text.contains(where: \.isWhitespace),
            let url = URL(string: text),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil,
            url.user == nil,
            url.password == nil
        else {
            throw BrieflyAgentFailure.invalid("url must be an absolute HTTP(S) URL.")
        }
        return url
    }

    private func searchItem(_ entry: LibraryEntry) -> BrieflyAgentSearchItem {
        let hasSummary = entry.text(for: .concise) != nil || entry.text(for: .detailed) != nil
        return BrieflyAgentSearchItem(
            id: entry.id,
            title: entry.title,
            snippet: hasSummary ? compact(entry.excerpt, maximum: 360) : nil
        )
    }

    private func metadata(_ entry: LibraryEntry, matches query: String) -> Bool {
        let haystack = ([entry.title] + entry.topicNames + entry.tags)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let needle = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return haystack.contains(needle)
    }

    private func ftsQuery(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace)
            .map { token in
                "\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            .joined(separator: " ")
    }

    private func compact(_ value: String, maximum: Int) -> String? {
        let compacted = value
            .replacingOccurrences(of: "‹", with: "")
            .replacingOccurrences(of: "›", with: "")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !compacted.isEmpty else { return nil }
        return String(compacted.prefix(maximum))
    }
}

public struct BrieflyAgentCall: Codable, Equatable, Sendable {
    public let version: Int
    public let op: String
    public let ingest: BrieflyAgentIngestRequest?
    public let save: BrieflyAgentSaveRequest?
    public let search: BrieflyAgentSearchRequest?
    public let read: BrieflyAgentReadRequest?

    public init(
        version: Int = 1,
        op: String,
        ingest: BrieflyAgentIngestRequest? = nil,
        save: BrieflyAgentSaveRequest? = nil,
        search: BrieflyAgentSearchRequest? = nil,
        read: BrieflyAgentReadRequest? = nil
    ) {
        self.version = version
        self.op = op
        self.ingest = ingest
        self.save = save
        self.search = search
        self.read = read
    }
}

public struct BrieflyAgentReply: Codable, Equatable, Sendable {
    public let ingest: BrieflyAgentWriteResult?
    public let save: BrieflyAgentWriteResult?
    public let search: BrieflyAgentSearchResult?
    public let read: BrieflyAgentReadResult?
    public let error: BrieflyAgentFailure?

    public init(
        ingest: BrieflyAgentWriteResult? = nil,
        save: BrieflyAgentWriteResult? = nil,
        search: BrieflyAgentSearchResult? = nil,
        read: BrieflyAgentReadResult? = nil,
        error: BrieflyAgentFailure? = nil
    ) {
        self.ingest = ingest
        self.save = save
        self.search = search
        self.read = read
        self.error = error
    }
}
