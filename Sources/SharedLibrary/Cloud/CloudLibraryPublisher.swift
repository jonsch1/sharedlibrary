import CloudKit
import Foundation
import Security

enum CloudLibraryPublishState: Equatable {
    case idle
    case disabled
    case publishing(String)
    case succeeded(Date, Int)
    case unavailable(String)
    case failed(String)

    var message: String {
        switch self {
        case .idle:
            return "Ready to publish the mobile library."
        case .disabled:
            return "iCloud mobile sync is turned off."
        case .publishing(let reason):
            return "Publishing \(reason)..."
        case .succeeded(let date, let count):
            return "Published \(count) \(count == 1 ? "item" : "items") at \(date.formatted(date: .omitted, time: .shortened))."
        case .unavailable(let message), .failed(let message):
            return message
        }
    }

    var isBusy: Bool {
        if case .publishing = self { return true }
        return false
    }
}

final class CloudKitLibraryClient {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    init(containerIdentifier: String = CloudLibrarySchema.containerIdentifier) {
        let container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(
            zoneName: CloudLibrarySchema.zoneName,
            ownerName: CKCurrentUserDefaultName
        )
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await CKContainer(identifier: CloudLibrarySchema.containerIdentifier).accountStatus()
    }

    func replace(with projection: CloudLibraryProjection) async throws {
        _ = try await database.save(CKRecordZone(zoneID: zoneID))

        let existingEntries = try await fetchRecords(
            recordType: CloudLibrarySchema.entryRecordType,
            desiredKeys: [CloudLibrarySchema.Field.contentHash]
        )
        let existingTexts = try await fetchRecords(
            recordType: CloudLibrarySchema.textRecordType,
            desiredKeys: [CloudLibrarySchema.Field.contentHash]
        )
        let existingByID = Dictionary(
            uniqueKeysWithValues: (existingEntries + existingTexts).map { ($0.recordID, $0) }
        )

        let assetDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-library-cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: assetDirectory) }

        var desiredRecords: [CKRecord] = []
        for entry in projection.entries {
            desiredRecords.append(entryRecord(for: entry))
            for text in entry.texts {
                desiredRecords.append(try textRecord(
                    for: text,
                    entry: entry,
                    assetDirectory: assetDirectory
                ))
            }
        }
        let desiredIDs = Set(desiredRecords.map(\.recordID))
        let recordsToSave = desiredRecords.filter { desired in
            let existingHash = existingByID[desired.recordID]?[CloudLibrarySchema.Field.contentHash] as? String
            let desiredHash = desired[CloudLibrarySchema.Field.contentHash] as? String
            return existingHash != desiredHash
        }
        let recordIDsToDelete = existingByID.keys.filter { !desiredIDs.contains($0) }

        for records in recordsToSave.chunked(maximumSize: 200) {
            try await modify(recordsToSave: records, recordIDsToDelete: [])
        }
        for recordIDs in recordIDsToDelete.chunked(maximumSize: 200) {
            try await modify(recordsToSave: [], recordIDsToDelete: recordIDs)
        }
    }

    private func entryRecord(for entry: CloudLibraryEntryPayload) -> CKRecord {
        let recordID = CKRecord.ID(recordName: entry.recordName, zoneID: zoneID)
        let record = CKRecord(recordType: CloudLibrarySchema.entryRecordType, recordID: recordID)
        record[CloudLibrarySchema.Field.schemaVersion] = CloudLibraryProjection.schemaVersion as CKRecordValue
        record[CloudLibrarySchema.Field.contentHash] = entry.metadataContentHash as CKRecordValue
        record[CloudLibrarySchema.Field.entryID] = entry.id as CKRecordValue
        record[CloudLibrarySchema.Field.captureID] = entry.captureID as CKRecordValue?
        record[CloudLibrarySchema.Field.title] = entry.title as CKRecordValue
        record[CloudLibrarySchema.Field.excerpt] = entry.excerpt as CKRecordValue
        record[CloudLibrarySchema.Field.topicIDs] = entry.topicIDs as CKRecordValue
        record[CloudLibrarySchema.Field.topicNames] = entry.topicNames as CKRecordValue
        record[CloudLibrarySchema.Field.tags] = entry.tags as CKRecordValue
        record[CloudLibrarySchema.Field.sourceURL] = entry.sourceURL as CKRecordValue?
        record[CloudLibrarySchema.Field.createdAt] = entry.createdAt as CKRecordValue?
        record[CloudLibrarySchema.Field.updatedAt] = entry.updatedAt as CKRecordValue?
        record[CloudLibrarySchema.Field.reviewedAt] = entry.reviewedAt as CKRecordValue?
        record[CloudLibrarySchema.Field.origin] = entry.origin.rawValue as CKRecordValue
        record[CloudLibrarySchema.Field.sharedByGitHubID] = entry.sharedByGitHubID as CKRecordValue?
        record[CloudLibrarySchema.Field.sharedByDisplayName] = entry.sharedByDisplayName as CKRecordValue?
        return record
    }

    private func textRecord(
        for text: CloudLibraryTextPayload,
        entry: CloudLibraryEntryPayload,
        assetDirectory: URL
    ) throws -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: entry.textRecordName(for: text.variant),
            zoneID: zoneID
        )
        let assetURL = assetDirectory
            .appendingPathComponent(recordID.recordName)
            .appendingPathExtension("txt")
        try Data(text.text.utf8).write(to: assetURL, options: .atomic)
        let record = CKRecord(recordType: CloudLibrarySchema.textRecordType, recordID: recordID)
        record[CloudLibrarySchema.Field.schemaVersion] = CloudLibraryProjection.schemaVersion as CKRecordValue
        record[CloudLibrarySchema.Field.contentHash] = text.contentHash as CKRecordValue
        record[CloudLibrarySchema.Field.entryID] = entry.id as CKRecordValue
        record[CloudLibrarySchema.Field.variant] = text.variant.rawValue as CKRecordValue
        record[CloudLibrarySchema.Field.textAsset] = CKAsset(fileURL: assetURL)
        record[CloudLibrarySchema.Field.wordCount] = text.wordCount as CKRecordValue
        return record
    }

    private func fetchRecords(
        recordType: String,
        desiredKeys: [String]
    ) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var output: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        do {
            repeat {
            let page: (
                matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
                queryCursor: CKQueryOperation.Cursor?
            )
                if let cursor {
                    page = try await database.records(
                        continuingMatchFrom: cursor,
                        desiredKeys: desiredKeys,
                        resultsLimit: CKQueryOperation.maximumResults
                    )
                } else {
                    page = try await database.records(
                        matching: query,
                        inZoneWith: zoneID,
                        desiredKeys: desiredKeys,
                        resultsLimit: CKQueryOperation.maximumResults
                    )
                }
                for (_, result) in page.matchResults {
                    output.append(try result.get())
                }
                cursor = page.queryCursor
            } while cursor != nil
        } catch let error as CKError where error.code == .unknownItem {
            return []
        }

        return output
    }

    private func modify(
        recordsToSave: [CKRecord],
        recordIDsToDelete: [CKRecord.ID]
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(
                recordsToSave: recordsToSave,
                recordIDsToDelete: recordIDsToDelete
            )
            operation.savePolicy = .changedKeys
            operation.isAtomic = false
            operation.modifyRecordsResultBlock = { result in
                continuation.resume(with: result)
            }
            database.add(operation)
        }
    }
}

enum CloudKitEntitlementStatus {
    static var isAvailable: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
              ) as? [String] else {
            return false
        }
        return value.contains(CloudLibrarySchema.containerIdentifier)
    }
}

@MainActor
final class CloudLibraryPublisher: ObservableObject {
    @Published private(set) var state: CloudLibraryPublishState

    private let settings: AppSettings
    private let builder: CloudLibraryProjectionBuilder
    private let client: CloudKitLibraryClient?
    private let hasCloudKitEntitlement: Bool
    private var publishTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?
    private var pendingReason: String?

    init(
        settings: AppSettings,
        knowledgeStore: KnowledgeStore,
        sharingStore: SharingStore,
        client: CloudKitLibraryClient? = nil,
        hasCloudKitEntitlement: Bool = CloudKitEntitlementStatus.isAvailable
    ) {
        self.settings = settings
        builder = CloudLibraryProjectionBuilder(
            knowledgeStore: knowledgeStore,
            sharingStore: sharingStore
        )
        self.hasCloudKitEntitlement = hasCloudKitEntitlement
        self.client = hasCloudKitEntitlement ? (client ?? CloudKitLibraryClient()) : nil
        if !settings.cloudLibrarySyncEnabled {
            state = .disabled
        } else if hasCloudKitEntitlement {
            state = .idle
        } else {
            state = .unavailable(Self.missingEntitlementMessage)
        }
    }

    func setEnabled(_ enabled: Bool) {
        settings.cloudLibrarySyncEnabled = enabled
        if enabled {
            if hasCloudKitEntitlement {
                state = .idle
                requestAutomaticPublish(reason: "the mobile library")
            } else {
                state = .unavailable(Self.missingEntitlementMessage)
            }
        } else {
            scheduledTask?.cancel()
            pendingReason = nil
            state = .disabled
        }
    }

    func requestAutomaticPublish(reason: String) {
        guard settings.cloudLibrarySyncEnabled else {
            state = .disabled
            return
        }
        guard hasCloudKitEntitlement else {
            state = .unavailable(Self.missingEntitlementMessage)
            return
        }
        pendingReason = reason
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            scheduledTask = nil
            let reason = pendingReason ?? "the mobile library"
            pendingReason = nil
            startPublish(reason: reason)
        }
    }

    func publishNow() {
        pendingReason = nil
        scheduledTask?.cancel()
        scheduledTask = nil
        startPublish(reason: "the mobile library")
    }

    private func startPublish(reason: String) {
        guard settings.cloudLibrarySyncEnabled else {
            state = .disabled
            return
        }
        guard hasCloudKitEntitlement, let client else {
            state = .unavailable(Self.missingEntitlementMessage)
            return
        }
        guard publishTask == nil else {
            pendingReason = reason
            return
        }

        state = .publishing(reason)
        let privateWorkspaceURL = settings.workspaceRootURL
        let sharedWorkspaceURL = settings.sharedWorkspaceRootURL
        let currentGitHubUserID = settings.currentGitHubUserID
        publishTask = Task { [weak self] in
            guard let self else { return }
            do {
                let accountStatus = try await client.accountStatus()
                guard accountStatus == .available else {
                    state = .unavailable(Self.message(for: accountStatus))
                    finishPublish()
                    return
                }
                let projection = try builder.build(
                    privateWorkspaceURL: privateWorkspaceURL,
                    sharedWorkspaceURL: sharedWorkspaceURL,
                    currentGitHubUserID: currentGitHubUserID
                )
                try await client.replace(with: projection)
                guard !Task.isCancelled else { return }
                settings.cloudLibraryLastPublishedAt = projection.generatedAt
                state = .succeeded(projection.generatedAt, projection.entries.count)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
            finishPublish()
        }
    }

    private func finishPublish() {
        publishTask = nil
        if let pendingReason {
            self.pendingReason = nil
            requestAutomaticPublish(reason: pendingReason)
        }
    }

    private static func message(for status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return "iCloud is available."
        case .noAccount:
            return "Sign in to iCloud in System Settings to publish the mobile library."
        case .restricted:
            return "This iCloud account is restricted from using CloudKit."
        case .couldNotDetermine:
            return "Shared Library could not determine the current iCloud account status."
        case .temporarilyUnavailable:
            return "iCloud is temporarily unavailable. Shared Library will try again later."
        @unknown default:
            return "iCloud is unavailable."
        }
    }

    private static let missingEntitlementMessage =
        "This build is not provisioned for iCloud. Sign in to the configured Apple team in Xcode, then reinstall Shared Library."
}

private extension Array {
    func chunked(maximumSize: Int) -> [[Element]] {
        guard maximumSize > 0 else { return [self] }
        return stride(from: 0, to: count, by: maximumSize).map {
            Array(self[$0..<Swift.min($0 + maximumSize, count)])
        }
    }
}
