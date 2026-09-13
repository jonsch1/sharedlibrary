import BrieflyCore
import Foundation
import Observation

@MainActor
@Observable
final class LibraryLifecycleModel {
    let session: LibrarySession

    var started = false
    var isReady = false
    var isSyncing = false
    var syncError: String?
    var syncCompleted = 0
    var syncTotal = 0

    @ObservationIgnored
    private var syncRequested = false

    init(session: LibrarySession) {
        self.session = session
    }

    var runsScheduledWork: Bool {
        !session.environment.isUITesting && !session.environment.isAppReviewTesting
    }

    func beginStart() -> Bool {
        guard !started else { return false }
        started = true
        return true
    }

    func openLibrary(databaseURL: URL, cloudSyncEnabled: Bool = true) async -> Bool {
        do {
            let next = SQLiteLibraryStore(databaseURL: databaseURL)
            session.projection = try await next.loadLibraryIndex()
            session.library = next
            try await refreshUploadState()
            session.status = "Opened local SQLite library"
            isReady = true
            let database = try await next.documentDatabase()
            session.cloud = cloudSyncEnabled &&
                !session.environment.isUITesting &&
                LibrarySession.cloudKitAvailable
                ? CloudDocumentSync(
                    store: database,
                    containerIdentifier: "iCloud.fyi.readbriefly"
                )
                : nil
            return true
        } catch {
            session.library = nil
            session.cloud = nil
            isReady = true
            session.errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshSession() async throws {
        guard let library = session.library else { return }
        try await refreshUploadState()
        updateProjectionIfNeeded(try await library.loadLibraryIndex())
    }

    func sync() async {
        guard !isSyncing else {
            syncRequested = true
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            syncCompleted = 0
            syncTotal = 0
        }

        repeat {
            syncRequested = false
            syncCompleted = 0
            syncTotal = 0
            await synchronizeOnce()
        } while syncRequested
        try? await refreshUploadState()
    }

    private func synchronizeOnce() async {
        syncError = nil
        do {
            guard let library = session.library else { return }
            guard let cloud = session.cloud else {
                session.status = "Using the local SQLite library"
                return
            }
            guard try await cloud.accountStatus() == .available else {
                throw NativeLibraryError.iCloudUnavailable
            }
            session.status = "Checking iCloud for changes…"
            try await cloud.synchronize(
                onProgress: { [weak self] completed, total in
                    guard let self else { return }
                    syncCompleted = completed
                    syncTotal = total
                    session.status = total > 0
                        ? "Uploading \(completed) of \(total) changes…"
                        : "Finishing iCloud sync…"
                },
                onFetchedChanges: { [weak self] in
                    guard let self else { return }
                    updateProjectionIfNeeded(try await library.loadLibraryIndex())
                }
            )
            updateProjectionIfNeeded(try await library.loadLibraryIndex())
            try await refreshUploadState()
            session.status = "Sync complete"
        } catch {
            syncError = error.localizedDescription
            session.status = "Using the local library. Sync is unavailable."
        }
    }

    func refreshUploadState() async throws {
        guard let library = session.library else { return }
        let database = try await library.documentDatabase()
        session.pendingUploadIDs = Set(try database.outbox().filter { $0.recordType == "document" }.map(\.documentID))
    }

    private func updateProjectionIfNeeded(_ next: LibraryProjection) {
        guard next.entries != session.projection.entries else { return }
        session.projection = next
    }

    func clearError() {
        session.errorMessage = nil
    }
}
