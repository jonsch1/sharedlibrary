import CloudKit
import Foundation

struct MobileLibraryEntry: Identifiable, Codable, Hashable {
    var id: String
    var captureID: String?
    var title: String
    var excerpt: String
    var topicIDs: [String]
    var topicNames: [String]
    var tags: [String]
    var sourceURL: String?
    var createdAt: Date?
    var updatedAt: Date?
    var reviewedAt: Date?
    var origin: CloudLibraryOrigin
    var sharedByGitHubID: String?
    var sharedByDisplayName: String?
    var texts: [CloudLibraryVariant: String]

    static func == (lhs: MobileLibraryEntry, rhs: MobileLibraryEntry) -> Bool {
        lhs.id == rhs.id && lhs.updatedAt == rhs.updatedAt && lhs.texts == rhs.texts
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var preferredVariant: CloudLibraryVariant? {
        [.concise, .brief, .detailed, .comprehensive, .source].first {
            !(texts[$0] ?? "").isEmpty
        }
    }

    var sortDate: Date {
        createdAt ?? updatedAt ?? .distantPast
    }

    func estimatedDuration(for variant: CloudLibraryVariant) -> TimeInterval {
        let words = texts[variant]?.split { $0.isWhitespace || $0.isNewline }.count ?? 0
        return Double(words) / 155 * 60
    }
}

enum MobileLibrarySyncState: Equatable {
    case loading
    case ready(Date)
    case empty
    case failed(String)

    var message: String {
        switch self {
        case .loading:
            return "Checking iCloud..."
        case .ready(let date):
            return "Updated \(date.formatted(date: .omitted, time: .shortened))"
        case .empty:
            return "No mobile library has been published yet."
        case .failed(let message):
            return message
        }
    }

    var isLoading: Bool {
        self == .loading
    }
}

enum MobileLibraryError: LocalizedError {
    case iCloudUnavailable(CKAccountStatus)

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable(.noAccount):
            return "Sign in to iCloud to open your Shared Library."
        case .iCloudUnavailable(.restricted):
            return "This iCloud account is restricted from using CloudKit."
        case .iCloudUnavailable(.temporarilyUnavailable):
            return "iCloud is temporarily unavailable. Try again shortly."
        case .iCloudUnavailable:
            return "Shared Library could not access iCloud."
        }
    }
}

actor MobileCloudLibraryClient {
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    init(containerIdentifier: String = CloudLibrarySchema.containerIdentifier) {
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(
            zoneName: CloudLibrarySchema.zoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }

    func fetchLibrary() async throws -> [MobileLibraryEntry] {
        let status = try await container.accountStatus()
        guard status == .available else {
            throw MobileLibraryError.iCloudUnavailable(status)
        }

        async let entryRecords = fetchRecords(recordType: CloudLibrarySchema.entryRecordType)
        async let textRecords = fetchRecords(recordType: CloudLibrarySchema.textRecordType)
        let (entries, texts) = try await (entryRecords, textRecords)

        var textsByEntry: [String: [CloudLibraryVariant: String]] = [:]
        for record in texts {
            guard let entryID = record[CloudLibrarySchema.Field.entryID] as? String,
                  let rawVariant = record[CloudLibrarySchema.Field.variant] as? String,
                  let variant = CloudLibraryVariant(rawValue: rawVariant),
                  let text = text(from: record) else {
                continue
            }
            textsByEntry[entryID, default: [:]][variant] = text
        }

        return entries.compactMap { record in
            guard let id = record[CloudLibrarySchema.Field.entryID] as? String,
                  let title = record[CloudLibrarySchema.Field.title] as? String,
                  let rawOrigin = record[CloudLibrarySchema.Field.origin] as? String,
                  let origin = CloudLibraryOrigin(rawValue: rawOrigin) else {
                return nil
            }
            return MobileLibraryEntry(
                id: id,
                captureID: record[CloudLibrarySchema.Field.captureID] as? String,
                title: title,
                excerpt: record[CloudLibrarySchema.Field.excerpt] as? String ?? "",
                topicIDs: record[CloudLibrarySchema.Field.topicIDs] as? [String] ?? [],
                topicNames: record[CloudLibrarySchema.Field.topicNames] as? [String] ?? [],
                tags: record[CloudLibrarySchema.Field.tags] as? [String] ?? [],
                sourceURL: record[CloudLibrarySchema.Field.sourceURL] as? String,
                createdAt: record[CloudLibrarySchema.Field.createdAt] as? Date,
                updatedAt: record[CloudLibrarySchema.Field.updatedAt] as? Date,
                reviewedAt: record[CloudLibrarySchema.Field.reviewedAt] as? Date,
                origin: origin,
                sharedByGitHubID: record[CloudLibrarySchema.Field.sharedByGitHubID] as? String,
                sharedByDisplayName: record[CloudLibrarySchema.Field.sharedByDisplayName] as? String,
                texts: textsByEntry[id] ?? [:]
            )
        }
        .sorted {
            if $0.sortDate == $1.sortDate {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.sortDate > $1.sortDate
        }
    }

    private func text(from record: CKRecord) -> String? {
        if let text = record[CloudLibrarySchema.Field.text] as? String {
            return text
        }
        guard let asset = record[CloudLibrarySchema.Field.textAsset] as? CKAsset,
              let fileURL = asset.fileURL else {
            return nil
        }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    private func fetchRecords(recordType: String) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var output: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let page: (
                matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
                queryCursor: CKQueryOperation.Cursor?
            )
            if let cursor {
                page = try await database.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: nil,
                    resultsLimit: CKQueryOperation.maximumResults
                )
            } else {
                page = try await database.records(
                    matching: query,
                    inZoneWith: zoneID,
                    desiredKeys: nil,
                    resultsLimit: CKQueryOperation.maximumResults
                )
            }
            for (_, result) in page.matchResults {
                output.append(try result.get())
            }
            cursor = page.queryCursor
        } while cursor != nil

        return output
    }
}

@MainActor
final class MobileLibraryStore: ObservableObject {
    @Published private(set) var entries: [MobileLibraryEntry]
    @Published private(set) var state: MobileLibrarySyncState

    private let client: MobileCloudLibraryClient
    private var refreshTask: Task<Void, Never>?
    private var lastRefreshAt: Date?

    init(client: MobileCloudLibraryClient = MobileCloudLibraryClient()) {
        self.client = client
        let cachedEntries = Self.loadCache()
        entries = cachedEntries
        state = cachedEntries.isEmpty ? .empty : .ready(Date())
    }

    func refreshIfNeeded(maximumAge: TimeInterval = 300) async {
        if let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < maximumAge {
            return
        }
        await refresh()
    }

    func refresh() async {
        guard refreshTask == nil else { return }
        state = .loading
        let client = client
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await client.fetchLibrary()
                entries = fetched
                lastRefreshAt = Date()
                state = fetched.isEmpty ? .empty : .ready(lastRefreshAt ?? Date())
                try Self.saveCache(fetched)
            } catch {
                if entries.isEmpty {
                    state = .failed(Self.message(for: error))
                } else {
                    state = .failed("\(Self.message(for: error)) Showing the last downloaded library.")
                }
            }
            refreshTask = nil
        }
        await refreshTask?.value
    }

    private static func cacheURL() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("SharedLibraryMobile", isDirectory: true)
            .appendingPathComponent("library-cache.json")
    }

    private static func loadCache() -> [MobileLibraryEntry] {
        guard let data = try? Data(contentsOf: cacheURL()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([MobileLibraryEntry].self, from: data)) ?? []
    }

    private static func saveCache(_ entries: [MobileLibraryEntry]) throws {
        let url = cacheURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    private static func message(for error: Error) -> String {
        if let cloudError = error as? CKError, cloudError.code == .zoneNotFound {
            return "Open Shared Library on your Mac and publish the mobile library first."
        }
        return error.localizedDescription
    }
}
