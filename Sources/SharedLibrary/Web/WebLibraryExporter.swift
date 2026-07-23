import Foundation

enum WebLibraryExportState: Equatable {
    case idle
    case disabled
    case exporting(String)
    case succeeded(Date, Int, URL)
    case unavailable(String)
    case failed(String)

    var message: String {
        switch self {
        case .idle:
            return "Ready to update the web library snapshot."
        case .disabled:
            return "Web library export is turned off."
        case .exporting(let reason):
            return "Updating \(reason)..."
        case .succeeded(let date, let count, _):
            return "Exported \(count) \(count == 1 ? "item" : "items") at \(date.formatted(date: .omitted, time: .shortened))."
        case .unavailable(let message), .failed(let message):
            return message
        }
    }

    var isBusy: Bool {
        if case .exporting = self { return true }
        return false
    }
}

struct WebLibrarySnapshotWriter {
    static let fileName = "Shared Library Web.json"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    func write(_ projection: CloudLibraryProjection, to folderURL: URL) throws -> URL {
        try fileManager.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        let destinationURL = folderURL.appendingPathComponent(Self.fileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(projection).write(to: destinationURL, options: .atomic)
        return destinationURL
    }
}

@MainActor
final class WebLibraryExporter: ObservableObject {
    @Published private(set) var state: WebLibraryExportState

    private let settings: AppSettings
    private let builder: CloudLibraryProjectionBuilder
    private let writer: WebLibrarySnapshotWriter
    private var exportTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?
    private var pendingReason: String?

    init(
        settings: AppSettings,
        knowledgeStore: KnowledgeStore,
        sharingStore: SharingStore,
        writer: WebLibrarySnapshotWriter = WebLibrarySnapshotWriter()
    ) {
        self.settings = settings
        builder = CloudLibraryProjectionBuilder(
            knowledgeStore: knowledgeStore,
            sharingStore: sharingStore
        )
        self.writer = writer
        state = settings.webLibraryExportEnabled ? .idle : .disabled
    }

    var exportFolderURL: URL {
        settings.webLibraryExportFolderURL
    }

    var snapshotURL: URL {
        exportFolderURL.appendingPathComponent(WebLibrarySnapshotWriter.fileName)
    }

    func setEnabled(_ enabled: Bool) {
        settings.webLibraryExportEnabled = enabled
        if enabled {
            state = .idle
            requestAutomaticExport(reason: "the web library")
        } else {
            scheduledTask?.cancel()
            pendingReason = nil
            state = .disabled
        }
    }

    func setExportFolder(_ url: URL) {
        settings.webLibraryExportFolderURL = url
        requestAutomaticExport(reason: "the web library in its new folder")
    }

    func requestAutomaticExport(reason: String) {
        guard settings.webLibraryExportEnabled else {
            state = .disabled
            return
        }
        pendingReason = reason
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            scheduledTask = nil
            let reason = pendingReason ?? "the web library"
            pendingReason = nil
            startExport(reason: reason)
        }
    }

    func exportNow() {
        pendingReason = nil
        scheduledTask?.cancel()
        scheduledTask = nil
        startExport(reason: "the web library")
    }

    private func startExport(reason: String) {
        guard settings.webLibraryExportEnabled else {
            state = .disabled
            return
        }
        guard exportTask == nil else {
            pendingReason = reason
            return
        }

        let iCloudDriveURL = settings.defaultWebLibraryExportFolderURL.deletingLastPathComponent()
        if exportFolderURL.standardizedFileURL.path.hasPrefix(iCloudDriveURL.standardizedFileURL.path),
           !FileManager.default.fileExists(atPath: iCloudDriveURL.path) {
            state = .unavailable(
                "iCloud Drive is unavailable. Enable it in System Settings or choose another export folder."
            )
            return
        }

        state = .exporting(reason)
        let privateWorkspaceURL = settings.workspaceRootURL
        let sharedWorkspaceURL = settings.sharedWorkspaceRootURL
        let currentGitHubUserID = settings.currentGitHubUserID
        let exportFolderURL = exportFolderURL
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let projection = try builder.build(
                    privateWorkspaceURL: privateWorkspaceURL,
                    sharedWorkspaceURL: sharedWorkspaceURL,
                    currentGitHubUserID: currentGitHubUserID
                )
                let snapshotURL = try writer.write(projection, to: exportFolderURL)
                guard !Task.isCancelled else { return }
                settings.webLibraryLastExportedAt = projection.generatedAt
                state = .succeeded(projection.generatedAt, projection.entries.count, snapshotURL)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
            finishExport()
        }
    }

    private func finishExport() {
        exportTask = nil
        if let pendingReason {
            self.pendingReason = nil
            requestAutomaticExport(reason: pendingReason)
        }
    }
}
