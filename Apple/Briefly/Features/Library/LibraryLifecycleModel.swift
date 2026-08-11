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
        session.projection = try await library.loadLibraryIndex()
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
    }

    private func synchronizeOnce() async {
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
                    session.projection = try await library.loadLibraryIndex()
                }
            )
            session.projection = try await library.loadLibraryIndex()
            session.status = "Sync complete"
        } catch {
            session.errorMessage = error.localizedDescription
            session.status = "Using the last complete offline library"
        }
    }

    func clearError() {
        session.errorMessage = nil
    }
}
