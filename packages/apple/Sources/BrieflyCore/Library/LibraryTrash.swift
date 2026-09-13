import Foundation
import SQLite3

extension SQLiteDocument {
    /// A content-free sync marker prevents an offline device from restoring deleted data.
    var isPermanentlyDeleted: Bool { type == "tombstone" && deleted }
}

extension SQLiteLibraryStore {
    public func permanentlyDelete(_ entryIDs: [String]) throws {
        try database().permanentlyDelete(entryIDs)
    }

    public func emptyTrash() throws {
        let database = try database()
        try database.permanentlyDelete(database.deletedDocuments().map(\.id))
    }
}

extension SQLiteLibrary {
    public func permanentlyDelete(_ ids: [String]) throws {
        try locked {
            try transaction {
                // Validate the whole selection before deleting anything.
                let documents = try Set(ids).map { id in
                    guard let document = try readDocument(id), document.deleted else {
                        throw SQLiteLibraryError.invalidDocument
                    }
                    return document
                }
                for document in documents where !document.isPermanentlyDeleted {
                    let marker = SQLiteDocument(
                        id: document.id, captureID: document.captureID, type: "tombstone", title: "",
                        createdAt: document.createdAt, updatedAt: Date(), revision: document.revision + 1,
                        deleted: true, texts: [:], cloudRecordData: document.cloudRecordData
                    )
                    try eraseDocumentContent(marker)
                    try enqueue(id: marker.id, revision: marker.revision, operation: "delete")
                }
            }
        }
    }

    func eraseDocumentContent(_ marker: SQLiteDocument) throws {
        try run("DELETE FROM document_texts WHERE document_id = ?", bindings: [.text(marker.id)])
        try run("DELETE FROM processing_jobs WHERE document_id = ?", bindings: [.text(marker.id)])
        try run("UPDATE channel_items SET entry_id = NULL WHERE entry_id = ?", bindings: [.text(marker.id)])
        let attachments = try query("SELECT id, revision FROM attachments WHERE document_id = ?", bindings: [.text(marker.id)]) {
            (columnText($0, 0), sqlite3_column_int64($0, 1))
        }
        for (id, revision) in attachments {
            try enqueue(recordType: "attachment", id: id, revision: revision + 1, operation: "delete")
        }
        try run("DELETE FROM attachments WHERE document_id = ?", bindings: [.text(marker.id)])
        if try readDocument(marker.id) == nil { try insert(marker) }
        else { try update(marker) }
    }

    /// A late attachment upload must never reintroduce data for a purged document.
    func rejectAttachmentForPurgedDocument(_ attachment: SQLiteAttachment) throws -> Bool {
        guard try readDocument(attachment.documentID)?.isPermanentlyDeleted == true else { return false }
        try enqueue(recordType: "attachment", id: attachment.id, revision: attachment.revision + 1, operation: "delete")
        return true
    }
}
