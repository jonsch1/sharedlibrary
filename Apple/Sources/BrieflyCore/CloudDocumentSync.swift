import CloudKit
import CryptoKit
import Foundation

@available(macOS 14.0, iOS 17.0, *)
public final actor CloudDocumentSync: CKSyncEngineDelegate {
    private struct Payload: Codable {
        let topicIDs: [String]
        let tags: [String]
        let sourceIDs: [String]
        let sourceURLs: [String]
        let texts: [LibraryVariant: String]
    }

    private let store: SQLiteLibrary
    private let zoneID = CKRecordZone.ID(
        zoneName: "BrieflyDocuments",
        ownerName: CKCurrentUserDefaultName
    )
    private let assetDirectory: URL
    private var assets = Set<URL>()
    private var eventError: Error?
    private lazy var engine: CKSyncEngine = {
        let serialization = try? store.syncState().flatMap {
            try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization ?? nil,
            delegate: self
        )
        configuration.automaticallySync = true
        return CKSyncEngine(configuration)
    }()
    private let container: CKContainer

    public init(store: SQLiteLibrary, containerIdentifier: String) {
        self.store = store
        container = CKContainer(identifier: containerIdentifier)
        assetDirectory = FileManager.default.temporaryDirectory
            .appending(path: "briefly-cloud-assets", directoryHint: .isDirectory)
    }

    public func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    public func synchronize() async throws {
        eventError = nil
        try store.enqueueInitialCloudUploadIfNeeded()
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        let pending = try store.outbox().map { item in
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                recordID(item.recordType, item.documentID)
            )
        }
        engine.state.add(pendingRecordZoneChanges: pending)
        try await engine.fetchChanges()
        if let eventError { throw eventError }
        try await engine.sendChanges()
        if let eventError { throw eventError }
        try store.markInitialCloudUploadCompleted()
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let update):
                if eventError == nil {
                    try store.saveSyncState(try JSONEncoder().encode(update.stateSerialization))
                }
            case .fetchedRecordZoneChanges(let changes):
                for modification in changes.modifications
                {
                    if modification.record.recordType == "BrieflyDocument" {
                        try apply(modification.record)
                    } else if modification.record.recordType == "BrieflyAttachment" {
                        try applyAttachment(modification.record)
                    } else if let type = logicalType(modification.record.recordType) {
                        try applyLogical(modification.record, recordType: type)
                    }
                }
            case .sentRecordZoneChanges(let changes):
                for record in changes.savedRecords
                {
                    guard
                        let localID = record["localID"] as? String,
                        let revision = (record["revision"] as? NSNumber)?.int64Value
                    else {
                        continue
                    }
                    if record.recordType == "BrieflyDocument" {
                        try store.saveCloudRecordData(
                            documentID: localID, revision: revision, data: try archived(record)
                        )
                    } else if record.recordType == "BrieflyAttachment" {
                        try store.saveAttachmentCloudRecordData(
                            id: localID, revision: revision, data: try archived(record)
                        )
                    } else if let type = logicalType(record.recordType) {
                        try store.saveLogicalCloudRecordData(
                            recordType: type, id: localID, revision: revision,
                            data: try archived(record)
                        )
                    }
                }
            case .didSendChanges:
                removeTemporaryAssets()
            case .didFetchRecordZoneChanges(let result):
                if let error = result.error { throw error }
            default:
                break
            }
        } catch {
            eventError = eventError ?? error
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) {
            [weak self] recordID in
            try? await self?.record(for: recordID)
        }
    }

    private func record(for id: CKRecord.ID) throws -> CKRecord {
        guard let item = try store.outbox().first(where: {
            recordID($0.recordType, $0.documentID) == id
        }) else { throw SQLiteLibraryError.invalidDocument }
        if item.recordType == "attachment" {
            return try attachmentRecord(item.documentID, id: id)
        }
        if item.recordType != "document" {
            return try logicalRecord(item.recordType, item.documentID, id: id)
        }
        let document = try store.getDocument(item.documentID, includeDeleted: true)
        let record = try document.cloudRecordData.flatMap {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: $0)
        } ?? CKRecord(recordType: "BrieflyDocument", recordID: id)
        record["captureID"] = document.captureID as CKRecordValue
        record["localID"] = document.id as CKRecordValue
        record["type"] = document.type as CKRecordValue
        record["title"] = document.title as CKRecordValue
        record["revision"] = document.revision as CKRecordValue
        record["createdAt"] = document.createdAt as CKRecordValue
        record["updatedAt"] = document.updatedAt as CKRecordValue
        record["deleted"] = document.deleted as CKRecordValue
        record["voiceBriefID"] = document.voiceBriefID as CKRecordValue?
        record["sourceURL"] = document.sourceURL as CKRecordValue?
        record["mediaURL"] = document.mediaURL as CKRecordValue?
        let payload = try JSONEncoder().encode(Payload(
            topicIDs: document.topicIDs,
            tags: document.tags,
            sourceIDs: document.sourceIDs,
            sourceURLs: document.sourceURLs,
            texts: document.texts
        ))
        try FileManager.default.createDirectory(
            at: assetDirectory,
            withIntermediateDirectories: true
        )
        let url = assetDirectory.appending(path: UUID().uuidString)
        try payload.write(to: url, options: .atomic)
        assets.insert(url)
        record["payload"] = CKAsset(fileURL: url)
        return record
    }

    private func logicalRecord(_ type: String, _ localID: String, id: CKRecord.ID) throws -> CKRecord {
        let value = try store.logicalRecord(recordType: type, id: localID)
        let record = try value.cloudRecordData.flatMap {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: $0)
        } ?? CKRecord(recordType: cloudType(type), recordID: id)
        record["localID"] = value.id as CKRecordValue
        record["revision"] = value.revision as CKRecordValue
        record["deleted"] = value.deleted as CKRecordValue
        record["payload"] = value.payload as CKRecordValue
        return record
    }

    private func attachmentRecord(_ localID: String, id: CKRecord.ID) throws -> CKRecord {
        guard let attachment = try store.attachment(localID) else {
            throw SQLiteLibraryError.invalidDocument
        }
        let record = try attachment.cloudRecordData.flatMap {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: $0)
        } ?? CKRecord(recordType: "BrieflyAttachment", recordID: id)
        record["localID"] = attachment.id as CKRecordValue
        record["documentID"] = attachment.documentID as CKRecordValue
        record["kind"] = attachment.kind as CKRecordValue
        record["mimeType"] = attachment.mimeType as CKRecordValue
        record["revision"] = attachment.revision as CKRecordValue
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        let url = assetDirectory.appending(path: UUID().uuidString)
        try attachment.data.write(to: url, options: .atomic)
        assets.insert(url)
        record["payload"] = CKAsset(fileURL: url)
        return record
    }

    private func apply(_ record: CKRecord) throws {
        guard
            let localID = record["localID"] as? String,
            let captureID = record["captureID"] as? String,
            let type = record["type"] as? String,
            let title = record["title"] as? String,
            let revision = (record["revision"] as? NSNumber)?.int64Value,
            let createdAt = record["createdAt"] as? Date,
            let updatedAt = record["updatedAt"] as? Date,
            let asset = record["payload"] as? CKAsset,
            let url = asset.fileURL
        else { return }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        try store.applyRemote(SQLiteDocument(
            id: localID,
            captureID: captureID,
            type: type,
            voiceBriefID: record["voiceBriefID"] as? String,
            title: title,
            sourceURL: record["sourceURL"] as? String,
            mediaURL: record["mediaURL"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt,
            revision: revision,
            deleted: (record["deleted"] as? NSNumber)?.boolValue ?? false,
            topicIDs: payload.topicIDs,
            tags: payload.tags,
            sourceIDs: payload.sourceIDs,
            sourceURLs: payload.sourceURLs,
            texts: payload.texts,
            cloudRecordData: try archived(record)
        ))
    }

    private func applyAttachment(_ record: CKRecord) throws {
        guard
            let localID = record["localID"] as? String,
            let documentID = record["documentID"] as? String,
            let kind = record["kind"] as? String,
            let mimeType = record["mimeType"] as? String,
            let revision = (record["revision"] as? NSNumber)?.int64Value,
            let asset = record["payload"] as? CKAsset,
            let url = asset.fileURL
        else { return }
        try store.applyRemote(SQLiteAttachment(
            id: localID,
            documentID: documentID,
            kind: kind,
            mimeType: mimeType,
            data: try Data(contentsOf: url),
            revision: revision,
            cloudRecordData: try archived(record)
        ))
    }

    private func applyLogical(_ record: CKRecord, recordType: String) throws {
        guard
            let localID = record["localID"] as? String,
            let revision = (record["revision"] as? NSNumber)?.int64Value,
            let payload = record["payload"] as? Data
        else { return }
        try store.applyRemote(
            recordType: recordType,
            id: localID,
            revision: revision,
            deleted: (record["deleted"] as? NSNumber)?.boolValue ?? false,
            payload: payload,
            cloudRecordData: try archived(record)
        )
    }

    private func recordID(_ type: String, _ localID: String) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data("\(type)\n\(localID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "\(type)-\(digest)", zoneID: zoneID)
    }

    private func cloudType(_ type: String) -> String {
        switch type {
        case "topic": "BrieflyTopic"
        case "channel": "BrieflyChannel"
        case "voice_brief": "BrieflyVoiceBrief"
        default: "BrieflyDocument"
        }
    }

    private func logicalType(_ cloudType: String) -> String? {
        switch cloudType {
        case "BrieflyTopic": "topic"
        case "BrieflyChannel": "channel"
        case "BrieflyVoiceBrief": "voice_brief"
        default: nil
        }
    }

    private func archived(_ record: CKRecord) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
    }

    private func removeTemporaryAssets() {
        let urls = assets
        assets.removeAll()
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
