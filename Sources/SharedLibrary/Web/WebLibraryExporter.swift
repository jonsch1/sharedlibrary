import Foundation

enum GoogleDriveLibraryState: Equatable {
    case idle
    case updating(String)
    case upToDate(Date, Int, URL)
    case succeeded(Date, Int, URL)
    case failed(String)

    var message: String {
        switch self {
        case .idle:
            return "Google Drive library synchronization is ready."
        case .updating(let reason):
            return "Synchronizing \(reason) with Google Drive..."
        case .upToDate(let date, let count, _):
            return "\(count) \(count == 1 ? "item is" : "items are") up to date as of \(date.formatted(date: .omitted, time: .shortened))."
        case .succeeded(let date, let count, _):
            return "Synchronized \(count) \(count == 1 ? "item" : "items") at \(date.formatted(date: .omitted, time: .shortened))."
        case .failed(let message):
            return message
        }
    }

    var isBusy: Bool {
        if case .updating = self { return true }
        return false
    }
}

struct DriveLibraryMirror {
    var index: DriveLibraryIndex
    var indexData: Data
    var indexHash: String
    var files: [GoogleDriveWorkspaceFile]
}

struct DriveLibraryMirrorBuilder {
    private let knowledgeStore: KnowledgeStore
    private let projectionBuilder: CloudLibraryProjectionBuilder
    private let fileManager: FileManager

    init(
        knowledgeStore: KnowledgeStore,
        sharingStore: SharingStore,
        fileManager: FileManager = .default
    ) {
        self.knowledgeStore = knowledgeStore
        projectionBuilder = CloudLibraryProjectionBuilder(
            knowledgeStore: knowledgeStore,
            sharingStore: sharingStore,
            fileManager: fileManager
        )
        self.fileManager = fileManager
    }

    func build(workspaceURL: URL) throws -> DriveLibraryMirror {
        let workspaceURL = workspaceURL.standardizedFileURL
        let localFiles = try mirroredFiles(in: workspaceURL)
        let filesByPath = Dictionary(uniqueKeysWithValues: localFiles.map { ($0.relativePath, $0) })
        let snapshot = try knowledgeStore.snapshot(workspaceRootURL: workspaceURL)
        let recordsByID = Dictionary(uniqueKeysWithValues: snapshot.records.map { record in
            ("personal:\(record.captureID ?? record.fileURL.lastPathComponent)", record)
        })
        let projection = try projectionBuilder.build(
            privateWorkspaceURL: workspaceURL,
            sharedWorkspaceURL: workspaceURL,
            currentUserID: nil
        )

        let entries = projection.entries.compactMap { entry -> DriveLibraryIndexEntry? in
            guard let record = recordsByID[entry.id],
                  let sourcePath = relativePath(for: record.fileURL, in: workspaceURL),
                  let sourceFile = filesByPath[sourcePath] else {
                return nil
            }

            let references = entry.texts.compactMap { payload -> DriveLibraryTextReference? in
                let path: String?
                if payload.variant == .source {
                    path = sourcePath
                } else {
                    path = summaryPath(
                        variant: payload.variant,
                        filename: record.fileURL.lastPathComponent,
                        filesByPath: filesByPath
                    )
                }
                guard let path, let file = filesByPath[path] else { return nil }
                return DriveLibraryTextReference(
                    variant: payload.variant,
                    path: path,
                    contentHash: file.contentHash,
                    wordCount: payload.wordCount
                )
            }

            guard references.contains(where: { $0.variant == .source }),
                  sourceFile.byteCount > 0 else {
                return nil
            }
            return DriveLibraryIndexEntry(
                id: entry.id,
                captureID: entry.captureID,
                title: entry.title,
                excerpt: entry.excerpt,
                topicIDs: entry.topicIDs,
                topicNames: entry.topicNames,
                tags: entry.tags,
                sourceURL: entry.sourceURL,
                createdAt: entry.createdAt,
                updatedAt: entry.updatedAt,
                reviewedAt: entry.reviewedAt,
                origin: entry.origin,
                sharedByUsername: entry.sharedByUsername,
                texts: references.sorted {
                    (CloudLibraryVariant.allCases.firstIndex(of: $0.variant) ?? .max)
                        < (CloudLibraryVariant.allCases.firstIndex(of: $1.variant) ?? .max)
                }
            )
        }

        let generatedAt = localFiles.compactMap(\.modifiedAt).max() ?? Date()
        let index = DriveLibraryIndex(
            generatedAt: generatedAt,
            files: localFiles.map {
                DriveLibraryFileRecord(
                    path: $0.relativePath,
                    contentHash: $0.contentHash,
                    byteCount: $0.byteCount
                )
            },
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let indexData = try encoder.encode(index)
        return DriveLibraryMirror(
            index: index,
            indexData: indexData,
            indexHash: CloudLibrarySchema.sha256(indexData),
            files: localFiles.map(\.workspaceFile)
        )
    }

    private func mirroredFiles(in workspaceURL: URL) throws -> [LocalMirrorFile] {
        var urls = [URL]()
        let topicsURL = workspaceURL.appendingPathComponent("topics.md")
        if fileManager.fileExists(atPath: topicsURL.path) {
            urls.append(topicsURL)
        }

        let libraryURL = workspaceURL.appendingPathComponent("library", isDirectory: true)
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .contentModificationDateKey
        ]
        if let enumerator = fileManager.enumerator(
            at: libraryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                guard url.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame,
                      try url.resourceValues(forKeys: Set(keys)).isRegularFile == true else {
                    continue
                }
                urls.append(url)
            }
        }

        return try urls.compactMap { url in
            guard let relativePath = relativePath(for: url, in: workspaceURL) else { return nil }
            let data = try Data(contentsOf: url)
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            return LocalMirrorFile(
                relativePath: relativePath,
                data: data,
                modifiedAt: values.contentModificationDate
            )
        }
        .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func summaryPath(
        variant: CloudLibraryVariant,
        filename: String,
        filesByPath: [String: LocalMirrorFile]
    ) -> String? {
        let primary = "library/summaries/\(variant.rawValue)/\(filename)"
        if filesByPath[primary] != nil { return primary }
        let legacy = "library/summaries/\(filename)"
        return variant == .concise && filesByPath[legacy] != nil ? legacy : nil
    }

    private func relativePath(for url: URL, in workspaceURL: URL) -> String? {
        let path = url.standardizedFileURL.path
        let root = workspaceURL.standardizedFileURL.path + "/"
        guard path.hasPrefix(root) else { return nil }
        return String(path.dropFirst(root.count))
    }
}

private struct LocalMirrorFile {
    var relativePath: String
    var data: Data
    var modifiedAt: Date?

    var contentHash: String { CloudLibrarySchema.sha256(data) }
    var byteCount: Int { data.count }
    var workspaceFile: GoogleDriveWorkspaceFile {
        GoogleDriveWorkspaceFile(
            relativePath: relativePath,
            data: data,
            contentHash: contentHash,
            contentType: "text/markdown"
        )
    }
}

@MainActor
final class GoogleDriveLibraryPublisher: ObservableObject {
    @Published private(set) var state = GoogleDriveLibraryState.idle

    private let settings: AppSettings
    private let builder: DriveLibraryMirrorBuilder
    private let driveStore: GoogleDriveMediaStore
    private var updateTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?
    private var pendingReason: String?

    init(
        settings: AppSettings,
        knowledgeStore: KnowledgeStore,
        sharingStore: SharingStore,
        driveStore: GoogleDriveMediaStore
    ) {
        self.settings = settings
        builder = DriveLibraryMirrorBuilder(
            knowledgeStore: knowledgeStore,
            sharingStore: sharingStore
        )
        self.driveStore = driveStore
    }

    var snapshotURL: URL {
        settings.workspaceRootURL
            .appendingPathComponent(".shared-library", isDirectory: true)
            .appendingPathComponent("index.json")
    }

    func requestAutomaticUpdate(reason: String) {
        pendingReason = reason
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            scheduledTask = nil
            let reason = pendingReason ?? "the library"
            pendingReason = nil
            startUpdate(reason: reason)
        }
    }

    func updateNow() {
        pendingReason = nil
        scheduledTask?.cancel()
        scheduledTask = nil
        startUpdate(reason: "the library")
    }

    private func startUpdate(reason: String) {
        guard updateTask == nil else {
            pendingReason = reason
            return
        }

        state = .updating(reason)
        let workspaceURL = settings.workspaceRootURL
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer { finishUpdate() }
            do {
                let personalMerge = try await driveStore.synchronizePersonalWorkspace(
                    at: workspaceURL
                )
                let mirror = try builder.build(workspaceURL: workspaceURL)
                let result = try await driveStore.syncWorkspaceMirror(
                    files: mirror.files,
                    indexData: mirror.indexData,
                    indexHash: mirror.indexHash
                )
                try FileManager.default.createDirectory(
                    at: snapshotURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try mirror.indexData.write(to: snapshotURL, options: .atomic)
                let legacySnapshotURL = snapshotURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("library.json")
                if FileManager.default.fileExists(atPath: legacySnapshotURL.path) {
                    try FileManager.default.removeItem(at: legacySnapshotURL)
                }
                _ = try await driveStore.synchronizeLocalAudioMirror()
                guard !Task.isCancelled else { return }
                if personalMerge.downloadedItemCount > 0
                    || personalMerge.deletedLocalItemCount > 0 {
                    NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                }
                settings.repositorySnapshotLastUpdatedAt = mirror.index.generatedAt
                let changedItemCount = result.changedItemCount
                    + personalMerge.changedItemCount
                if changedItemCount == 0 {
                    state = .upToDate(
                        mirror.index.generatedAt,
                        mirror.index.entries.count,
                        snapshotURL
                    )
                } else {
                    state = .succeeded(
                        mirror.index.generatedAt,
                        mirror.index.entries.count,
                        snapshotURL
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func finishUpdate() {
        updateTask = nil
        if let pendingReason {
            self.pendingReason = nil
            requestAutomaticUpdate(reason: pendingReason)
        }
    }
}
