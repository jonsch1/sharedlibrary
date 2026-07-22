import Foundation

final class LibraryStore {
    private let isoFormatter: ISO8601DateFormatter

    init() {
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func save(extracted: ExtractedContent) throws -> LibraryItem {
        let now = Date()
        let timestamp = Self.milliseconds(since1970: now)
        let item = LibraryItem(
            createdAt: timestamp,
            updatedAt: timestamp,
            url: extracted.url,
            title: Self.displayTitle(for: extracted),
            content: extracted.content
        )

        return try save(item: item, date: now)
    }

    func saveText(_ text: String, sourceURL: String?) throws -> LibraryItem {
        let now = Date()
        let timestamp = Self.milliseconds(since1970: now)
        let item = LibraryItem(
            type: "text",
            createdAt: timestamp,
            updatedAt: timestamp,
            url: sourceURL ?? "clipboard:",
            title: Self.displayTitle(forClipboardText: text),
            content: text
        )

        return try save(item: item, date: now)
    }

    func saveImagePNG(_ data: Data) throws -> LibraryItem {
        let folder = try AppSettings.ensureGatherFolder()
        return try saveImagePNG(data, in: folder)
    }

    func saveImagePNG(_ data: Data, in gatherFolder: URL, date: Date = Date()) throws -> LibraryItem {
        let fileManager = FileManager.default
        let imagesFolder = gatherFolder.appendingPathComponent("images", isDirectory: true)
        try fileManager.createDirectory(at: imagesFolder, withIntermediateDirectories: true)

        let imageURL = uniqueImageURL(in: imagesFolder, date: date, pathExtension: "png")
        let relativeImagePath = "images/\(imageURL.lastPathComponent)"
        let timestamp = Self.milliseconds(since1970: date)
        let item = LibraryItem(
            type: "image",
            createdAt: timestamp,
            updatedAt: timestamp,
            url: relativeImagePath,
            title: "Clipboard image",
            content: "![Clipboard image](\(relativeImagePath))"
        )

        do {
            try data.write(to: imageURL, options: .atomic)
            return try save(item: item, date: date, in: gatherFolder)
        } catch {
            try? fileManager.removeItem(at: imageURL)
            throw error
        }
    }

    private func save(item: LibraryItem, date: Date) throws -> LibraryItem {
        let folder = try AppSettings.ensureGatherFolder()
        return try save(item: item, date: date, in: folder)
    }

    private func save(item: LibraryItem, date: Date, in folder: URL) throws -> LibraryItem {
        var savedItem = item
        let fileURL = uniqueMarkdownURL(in: folder, for: savedItem, date: date)
        savedItem.fileURL = fileURL
        try markdown(for: savedItem).write(to: fileURL, atomically: true, encoding: .utf8)
        return savedItem
    }

    func recentItems(limit: Int = 200) throws -> [LibraryItem] {
        let folder = try AppSettings.ensureGatherFolder()
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let items = urls
            .filter { $0.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame }
            .compactMap { parseMarkdownItem(at: $0) }
            .sorted { $0.createdAt > $1.createdAt }

        return Array(items.prefix(limit))
    }

    func recentImageItems(limit: Int = 500) throws -> [LibraryItem] {
        try recentItems(limit: Int.max)
            .filter { $0.type == "image" }
            .prefix(limit)
            .map { $0 }
    }

    func snapshot(limit: Int = 500) throws -> LibrarySnapshot {
        let folder = try AppSettings.ensureGatherFolder()
        let items = try recentItems(limit: limit)

        let documents = items.map { item in
            let summary = readSummary(for: item, in: folder)

            return LibraryDocument(
                item: item,
                summary: summary?.text,
                summaryFileURL: summary?.fileURL
            )
        }

        return LibrarySnapshot(
            documents: documents
        )
    }

    func migrateLegacyClusterMetadata(workspaceRootURL: URL) throws {
        let fileManager = FileManager.default
        let gatherFolder = workspaceRootURL.appendingPathComponent("gather", isDirectory: true)
        let taxonomyURL = workspaceRootURL.appendingPathComponent("topics.md")
        let sourceURLs = try fileManager.contentsOfDirectory(
            at: gatherFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame }

        for sourceURL in sourceURLs {
            guard var item = parseMarkdownItem(at: sourceURL),
                  item.clusterID != nil || item.clusterName != nil || item.embeddingModel != nil else {
                continue
            }
            if item.topics.isEmpty,
               let clusterName = item.clusterName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !clusterName.isEmpty {
                let topic = try TaxonomyStore().ensureTopic(named: clusterName, at: taxonomyURL)
                item.topics = [topic.id]
            }
            item.clusterID = nil
            item.clusterName = nil
            item.embeddingModel = nil
            try markdown(for: item).write(to: sourceURL, atomically: true, encoding: .utf8)
        }

        let legacyIndexURL = gatherFolder.appendingPathComponent(".gather-capture-clusters.json")
        if fileManager.fileExists(atPath: legacyIndexURL.path) {
            try fileManager.removeItem(at: legacyIndexURL)
        }
    }

    func simplifyImageCaptures(workspaceRootURL: URL) throws {
        let fileManager = FileManager.default
        let gatherFolder = workspaceRootURL.appendingPathComponent("gather", isDirectory: true)
        let taxonomyURL = workspaceRootURL.appendingPathComponent("topics.md")
        let sourceURLs = try fileManager.contentsOfDirectory(
            at: gatherFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame }

        var imageTopicIDs = Set<String>()
        var nonImageTopicIDs = Set<String>()
        for sourceURL in sourceURLs {
            guard var item = parseMarkdownItem(at: sourceURL) else { continue }
            if item.type == "image" {
                imageTopicIDs.formUnion(item.topics)
                let needsMetadataCleanup = !item.topics.isEmpty || item.reviewedAt != nil
                item.topics = []
                item.reviewedAt = nil
                try removeImageSummaries(for: sourceURL, gatherFolder: gatherFolder)
                if needsMetadataCleanup {
                    try markdown(for: item).write(to: sourceURL, atomically: true, encoding: .utf8)
                }
            } else {
                nonImageTopicIDs.formUnion(item.topics)
            }
        }

        guard fileManager.fileExists(atPath: taxonomyURL.path) else { return }
        let taxonomyText = try String(contentsOf: taxonomyURL, encoding: .utf8)
        imageTopicIDs.formUnion(Self.scopedImageTopicIDs(in: taxonomyText))
        let taxonomyStore = TaxonomyStore(fileManager: fileManager)
        var taxonomy = try taxonomyStore.load(from: taxonomyURL)
        let removable = imageTopicIDs.subtracting(nonImageTopicIDs)
        let originalCount = taxonomy.topics.count
        taxonomy.topics.removeAll { removable.contains($0.id) }
        if originalCount != taxonomy.topics.count || taxonomyText.contains("scope:") || taxonomyText.contains("version: 2") {
            try taxonomyStore.save(taxonomy, to: taxonomyURL)
        }
    }

    @discardableResult
    func preparePromptTopicMigration(workspaceRootURL: URL) throws -> Bool {
        let fileManager = FileManager.default
        let gatherFolder = workspaceRootURL.appendingPathComponent("gather", isDirectory: true)
        let markerURL = gatherFolder.appendingPathComponent(".gather-capture-prompt-topics-v2")
        guard !fileManager.fileExists(atPath: markerURL.path) else { return false }

        let sourceURLs = try fileManager.contentsOfDirectory(
            at: gatherFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame }

        for sourceURL in sourceURLs {
            guard var item = parseMarkdownItem(at: sourceURL), !item.topics.isEmpty else { continue }
            item.topics = []
            try markdown(for: item).write(to: sourceURL, atomically: true, encoding: .utf8)
        }

        try "version: 1\n".write(to: markerURL, atomically: true, encoding: .utf8)
        return true
    }

    func delete(document: LibraryDocument) throws {
        guard let fileURL = document.item.fileURL else {
            throw LibraryStoreError.missingSourceFile(document.item.title)
        }

        try moveToTrashIfExists(fileURL)

        if let imageURL = imageAssetURL(for: document.item) {
            try moveToTrashIfExists(imageURL)
        }

        if let summaryFileURL = document.summaryFileURL {
            try moveToTrashIfExists(summaryFileURL)

            for level in SummaryDetailLevel.allCases {
                let levelURL = summaryFileURL.deletingLastPathComponent()
                    .appendingPathComponent(level.storageDirectoryName, isDirectory: true)
                    .appendingPathComponent(summaryFileURL.lastPathComponent)
                try moveToTrashIfExists(levelURL)
            }
        }
    }

    @discardableResult
    func processSource(
        at sourceURL: URL,
        workspaceRootURL: URL,
        suggestedFilename: String,
        summary: String,
        topicIDs: [String],
        date: Date = Date()
    ) throws -> URL {
        try processSource(
            at: sourceURL,
            workspaceRootURL: workspaceRootURL,
            suggestedFilename: suggestedFilename,
            summaries: CaptureSummaries(repeating: summary),
            topicIDs: topicIDs,
            markReviewed: false,
            date: date
        )
    }

    @discardableResult
    func processSource(
        at sourceURL: URL,
        workspaceRootURL: URL,
        suggestedFilename: String,
        summaries: CaptureSummaries,
        topicID: String,
        date: Date = Date()
    ) throws -> URL {
        try processSource(
            at: sourceURL,
            workspaceRootURL: workspaceRootURL,
            suggestedFilename: suggestedFilename,
            summaries: summaries,
            topicIDs: [topicID],
            markReviewed: true,
            date: date
        )
    }

    @discardableResult
    private func processSource(
        at sourceURL: URL,
        workspaceRootURL: URL,
        suggestedFilename: String,
        summaries: CaptureSummaries,
        topicIDs: [String]?,
        markReviewed: Bool,
        date: Date
    ) throws -> URL {
        let fileManager = FileManager.default
        let sourceURL = sourceURL.standardizedFileURL
        let gatherFolder = workspaceRootURL
            .appendingPathComponent("gather", isDirectory: true)
            .standardizedFileURL

        guard sourceURL.deletingLastPathComponent().path == gatherFolder.path else {
            throw LibraryStoreError.sourceOutsideWorkspace
        }
        guard var item = parseMarkdownItem(at: sourceURL) else {
            throw LibraryStoreError.invalidSourceFile
        }

        guard summaries.allAreNonempty else {
            throw LibraryStoreError.emptySummary
        }

        let summariesFolder = gatherFolder.appendingPathComponent("summaries", isDirectory: true)
        try fileManager.createDirectory(at: summariesFolder, withIntermediateDirectories: true)

        let destinationURL = uniqueProcessedMarkdownURL(
            in: gatherFolder,
            summariesFolder: summariesFolder,
            suggestedFilename: suggestedFilename,
            sourceURL: sourceURL
        )
        let destinationSummaryURL = summariesFolder.appendingPathComponent(destinationURL.lastPathComponent)
        let oldSummaryURL = summariesFolder.appendingPathComponent(sourceURL.lastPathComponent)
        let destinationLevelSummaryURLs = Dictionary(uniqueKeysWithValues: SummaryDetailLevel.allCases.map { level in
            (
                level,
                summariesFolder
                    .appendingPathComponent(level.storageDirectoryName, isDirectory: true)
                    .appendingPathComponent(destinationURL.lastPathComponent)
            )
        })
        let oldLevelSummaryURLs = Dictionary(uniqueKeysWithValues: SummaryDetailLevel.allCases.map { level in
            (
                level,
                summariesFolder
                    .appendingPathComponent(level.storageDirectoryName, isDirectory: true)
                    .appendingPathComponent(sourceURL.lastPathComponent)
            )
        })

        for level in SummaryDetailLevel.allCases {
            try fileManager.createDirectory(
                at: summariesFolder.appendingPathComponent(level.storageDirectoryName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        var summaryOutputs = [(url: destinationSummaryURL, text: summaries.concise)]
        summaryOutputs.append(contentsOf: SummaryDetailLevel.allCases.compactMap { level in
            destinationLevelSummaryURLs[level].map { (url: $0, text: summaries[level]) }
        })
        let createdSummaryURLs = summaryOutputs
            .map(\.url)
            .filter { !fileManager.fileExists(atPath: $0.path) }

        item.updatedAt = Self.milliseconds(since1970: date)
        item.reviewedAt = markReviewed ? Self.milliseconds(since1970: date) : nil
        if let topicIDs {
            item.topics = Array(Set(topicIDs.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })).sorted()
        }
        item.clusterID = nil
        item.clusterName = nil
        item.embeddingModel = nil
        item.fileURL = destinationURL

        var createdDestination = false
        do {
            for output in summaryOutputs {
                let normalized = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                try (normalized + "\n").write(
                    to: output.url,
                    atomically: true,
                    encoding: .utf8
                )
            }

            try markdown(for: item).write(to: destinationURL, atomically: true, encoding: .utf8)
            createdDestination = destinationURL != sourceURL

            if destinationURL != sourceURL {
                try fileManager.removeItem(at: sourceURL)
            }
            if oldSummaryURL != destinationSummaryURL,
               fileManager.fileExists(atPath: oldSummaryURL.path) {
                try fileManager.removeItem(at: oldSummaryURL)
            }
            for level in SummaryDetailLevel.allCases {
                guard let oldURL = oldLevelSummaryURLs[level],
                      let destinationURL = destinationLevelSummaryURLs[level],
                      oldURL != destinationURL,
                      fileManager.fileExists(atPath: oldURL.path) else {
                    continue
                }
                try fileManager.removeItem(at: oldURL)
            }
        } catch {
            if createdDestination {
                try? fileManager.removeItem(at: destinationURL)
            }
            for url in createdSummaryURLs {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }

        return destinationURL
    }

    @discardableResult
    func updateImageTitle(
        for savedItem: LibraryItem,
        title: String,
        date: Date = Date()
    ) throws -> LibraryItem {
        guard let sourceURL = savedItem.fileURL,
              var item = parseMarkdownItem(at: sourceURL),
              item.type == "image",
              let currentImageURL = imageAssetURL(for: item) else {
            throw LibraryStoreError.invalidSourceFile
        }

        let normalizedTitle = ImageNamingService.normalizedTitle(title)
        guard !normalizedTitle.isEmpty else { throw LibraryStoreError.invalidSourceFile }

        let imagesFolder = currentImageURL.deletingLastPathComponent()
        let imageExtension = currentImageURL.pathExtension.isEmpty ? "png" : currentImageURL.pathExtension
        let baseName = Self.processedFilenameBase(normalizedTitle, fallback: "image")
        let destinationImageURL = uniqueAssetURL(
            in: imagesFolder,
            baseName: baseName,
            pathExtension: imageExtension,
            currentURL: currentImageURL
        )
        let didMove = destinationImageURL.standardizedFileURL != currentImageURL.standardizedFileURL
        if didMove {
            try FileManager.default.moveItem(at: currentImageURL, to: destinationImageURL)
        }

        item.title = normalizedTitle
        item.updatedAt = Self.milliseconds(since1970: date)
        item.reviewedAt = nil
        item.topics = []
        item.url = "images/\(destinationImageURL.lastPathComponent)"
        let altText = normalizedTitle
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        item.content = "![\(altText)](\(item.url))"

        do {
            try markdown(for: item).write(to: sourceURL, atomically: true, encoding: .utf8)
        } catch {
            if didMove { try? FileManager.default.moveItem(at: destinationImageURL, to: currentImageURL) }
            throw error
        }
        return item
    }

    func markSourceReviewed(
        at sourceURL: URL,
        workspaceRootURL: URL,
        date: Date = Date()
    ) throws {
        let fileManager = FileManager.default
        let sourceURL = sourceURL.standardizedFileURL
        let gatherFolder = workspaceRootURL
            .appendingPathComponent("gather", isDirectory: true)
            .standardizedFileURL

        guard sourceURL.deletingLastPathComponent().path == gatherFolder.path else {
            throw LibraryStoreError.sourceOutsideWorkspace
        }
        guard var item = parseMarkdownItem(at: sourceURL) else {
            throw LibraryStoreError.invalidSourceFile
        }

        let summaryURL = gatherFolder
            .appendingPathComponent("summaries", isDirectory: true)
            .appendingPathComponent(sourceURL.lastPathComponent)
        guard fileManager.fileExists(atPath: summaryURL.path) else {
            throw LibraryStoreError.missingSummary
        }

        item.updatedAt = Self.milliseconds(since1970: date)
        item.reviewedAt = Self.milliseconds(since1970: date)
        try markdown(for: item).write(to: sourceURL, atomically: true, encoding: .utf8)
    }

    private func markdown(for item: LibraryItem) -> String {
        var lines = [
            "---",
            "id: \(Self.yamlString(item.id))",
            "type: \(Self.yamlString(item.type))",
            "title: \(Self.yamlString(item.title))",
            "created_at: \(Self.yamlString(isoFormatter.string(from: item.createdAtDate)))",
            "updated_at: \(Self.yamlString(isoFormatter.string(from: item.updatedAtDate)))"
        ]

        if let reviewedAtDate = item.reviewedAtDate {
            lines.append("reviewed_at: \(Self.yamlString(isoFormatter.string(from: reviewedAtDate)))")
        }

        if item.tags.isEmpty {
            lines.append("tags: []")
        } else {
            lines.append("tags:")
            lines.append(contentsOf: item.tags.map { "  - \(Self.yamlString($0))" })
        }

        if item.topics.isEmpty {
            lines.append("topics: []")
        } else {
            lines.append("topics:")
            lines.append(contentsOf: item.topics.map { "  - \(Self.yamlString($0))" })
        }

        lines.append("source_url: \(Self.yamlString(item.url))")
        lines.append("---")
        lines.append("")
        lines.append(item.content)
        return lines.joined(separator: "\n")
    }

    private func parseMarkdownItem(at url: URL) -> LibraryItem? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.hasPrefix("---\n") else {
            return nil
        }

        let metadataStart = text.index(text.startIndex, offsetBy: 4)
        guard let metadataEnd = text[metadataStart...].range(of: "\n---\n") else {
            return nil
        }

        let metadata = String(text[metadataStart..<metadataEnd.lowerBound])
        let content = String(text[metadataEnd.upperBound...])
        let fields = Self.parseFrontmatter(metadata)

        guard let id = fields["id"],
              let type = fields["type"],
              let title = fields["title"],
              let createdAtText = fields["created_at"],
              let updatedAtText = fields["updated_at"],
              let sourceURL = fields["source_url"],
              fields.keys.contains("tags"),
              let createdAt = parseDate(createdAtText),
              let updatedAt = parseDate(updatedAtText) else {
            return nil
        }

        return LibraryItem(
            id: id,
            type: type,
            createdAt: Self.milliseconds(since1970: createdAt),
            updatedAt: Self.milliseconds(since1970: updatedAt),
            reviewedAt: fields["reviewed_at"]
                .flatMap(parseDate)
                .map(Self.milliseconds(since1970:)),
            url: sourceURL,
            title: title,
            tags: Self.parseList(named: "tags", from: metadata),
            topics: Self.parseList(named: "topics", from: metadata),
            clusterID: fields["cluster_id"],
            clusterName: fields["cluster"],
            embeddingModel: fields["embedding_model"],
            content: content,
            fileURL: url
        )
    }

    private func readSummary(for item: LibraryItem, in folder: URL) -> (text: String, fileURL: URL)? {
        guard let sourceFilename = item.fileURL?.lastPathComponent else { return nil }
        let url = folder
            .appendingPathComponent("summaries", isDirectory: true)
            .appendingPathComponent(sourceFilename)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (text, url)
    }

    private func moveToTrashIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
    }

    func imageAssetURL(for item: LibraryItem) -> URL? {
        guard item.type == "image", !item.url.isEmpty, let sourceFileURL = item.fileURL else { return nil }
        let gatherFolder = sourceFileURL.deletingLastPathComponent().standardizedFileURL
        let imagesFolder = gatherFolder.appendingPathComponent("images", isDirectory: true).standardizedFileURL
        let candidate = gatherFolder.appendingPathComponent(item.url).standardizedFileURL
        guard candidate.path.hasPrefix(imagesFolder.path + "/"),
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func removeImageSummaries(for sourceURL: URL, gatherFolder: URL) throws {
        let summariesFolder = gatherFolder.appendingPathComponent("summaries", isDirectory: true)
        let urls = [summariesFolder.appendingPathComponent(sourceURL.lastPathComponent)]
            + SummaryDetailLevel.allCases.map {
                summariesFolder
                    .appendingPathComponent($0.storageDirectoryName, isDirectory: true)
                    .appendingPathComponent(sourceURL.lastPathComponent)
            }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func uniqueMarkdownURL(in folder: URL, for item: LibraryItem, date: Date) -> URL {
        let prefix = Self.fileDateFormatter.string(from: date)
        let sequence = nextSequenceNumber(in: folder, datePrefix: prefix)
        var candidate = folder.appendingPathComponent("\(prefix)-\(sequence)").appendingPathExtension("md")
        var fallbackSequence = sequence + 1

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder
                .appendingPathComponent("\(prefix)-\(fallbackSequence)")
                .appendingPathExtension("md")
            fallbackSequence += 1
        }

        return candidate
    }

    private func uniqueImageURL(in folder: URL, date: Date, pathExtension: String) -> URL {
        let prefix = Self.fileDateFormatter.string(from: date)
        var sequence = 1
        var candidate = folder.appendingPathComponent("\(prefix)-\(sequence)")
            .appendingPathExtension(pathExtension)

        while FileManager.default.fileExists(atPath: candidate.path) {
            sequence += 1
            candidate = folder.appendingPathComponent("\(prefix)-\(sequence)")
                .appendingPathExtension(pathExtension)
        }
        return candidate
    }

    private func uniqueAssetURL(
        in folder: URL,
        baseName: String,
        pathExtension: String,
        currentURL: URL
    ) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
        var sequence = 2
        while candidate.standardizedFileURL != currentURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName)-\(sequence)")
                .appendingPathExtension(pathExtension)
            sequence += 1
        }
        return candidate
    }

    private func uniqueProcessedMarkdownURL(
        in folder: URL,
        summariesFolder: URL,
        suggestedFilename: String,
        sourceURL: URL
    ) -> URL {
        let baseName = Self.processedFilenameBase(
            suggestedFilename,
            fallback: sourceURL.deletingPathExtension().lastPathComponent
        )
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension("md")
        var sequence = 2

        while candidate.standardizedFileURL != sourceURL.standardizedFileURL && (
            FileManager.default.fileExists(atPath: candidate.path) ||
            FileManager.default.fileExists(
                atPath: summariesFolder.appendingPathComponent(candidate.lastPathComponent).path
            )
        ) {
            candidate = folder
                .appendingPathComponent("\(baseName)-\(sequence)")
                .appendingPathExtension("md")
            sequence += 1
        }

        return candidate.standardizedFileURL
    }

    static func processedFilenameBase(_ suggestion: String, fallback: String = "capture") -> String {
        var value = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasSuffix(".md") {
            value.removeLast(3)
        }

        let folded = value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        let parts = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
        var result = parts.filter { !$0.isEmpty }.joined(separator: "-")

        if result.count > 64 {
            result = String(result.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        if result.isEmpty {
            let fallbackParts = fallback
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
            result = fallbackParts.filter { !$0.isEmpty }.joined(separator: "-")
        }
        return result.isEmpty ? "capture" : result
    }

    private func nextSequenceNumber(in folder: URL, datePrefix: String) -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let highestSequence = urls
            .filter { $0.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame }
            .compactMap { sequenceNumber(from: $0.deletingPathExtension().lastPathComponent, datePrefix: datePrefix) }
            .max() ?? 0

        return highestSequence + 1
    }

    private func sequenceNumber(from filename: String, datePrefix: String) -> Int? {
        let expectedPrefix = "\(datePrefix)-"
        guard filename.hasPrefix(expectedPrefix) else { return nil }
        let suffix = filename.dropFirst(expectedPrefix.count)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        return Int(suffix)
    }

    private func parseDate(_ value: String) -> Date? {
        if let date = isoFormatter.date(from: value) {
            return date
        }

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }

    private static func displayTitle(for extracted: ExtractedContent) -> String {
        if let title = extracted.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let host = URL(string: extracted.url)?.host(percentEncoded: false), !host.isEmpty {
            return host
        }
        return extracted.url
    }

    private static func displayTitle(forClipboardText text: String) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Clipboard text"

        let maxLength = 90
        guard firstLine.count > maxLength else { return firstLine }
        return "\(firstLine.prefix(maxLength - 1).trimmingCharacters(in: .whitespacesAndNewlines))..."
    }

    private static func milliseconds(since1970 date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd"
        return formatter
    }()

    private static func yamlString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func parseFrontmatter(_ metadata: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in metadata.components(separatedBy: .newlines) {
            guard !line.hasPrefix("  - "),
                  let separator = line.firstIndex(of: ":") else {
                continue
            }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            fields[key] = parseScalar(rawValue)
        }
        return fields
    }

    private static func parseList(named name: String, from metadata: String) -> [String] {
        let lines = metadata.components(separatedBy: .newlines)
        guard let listIndex = lines.firstIndex(where: { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("\(name):")
        }) else {
            return []
        }

        let listLine = lines[listIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = listLine.firstIndex(of: ":") {
            let rawValue = String(listLine[listLine.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !rawValue.isEmpty {
                return parseInlineTags(rawValue)
            }
        }

        return lines[(listIndex + 1)...]
            .prefix { $0.hasPrefix("  - ") }
            .map { parseScalar(String($0.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func parseInlineTags(_ value: String) -> [String] {
        guard value.hasPrefix("["),
              value.hasSuffix("]"),
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        return decoded
    }

    private static func parseScalar(_ value: String) -> String {
        guard value.hasPrefix("\""),
              let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return value
        }
        return decoded
    }

    private static func scopedImageTopicIDs(in text: String) -> Set<String> {
        var isInTopics = false
        var currentID: String?
        var currentScope: String?
        var result = Set<String>()

        func finish() {
            if currentScope == "image", let currentID { result.insert(currentID) }
            currentID = nil
            currentScope = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawLine.hasPrefix(" ") {
                if isInTopics { finish() }
                isInTopics = line == "topics:"
                continue
            }
            guard isInTopics else { continue }
            if line.hasPrefix("- id:") {
                finish()
                currentID = parseScalar(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("scope:") {
                currentScope = parseScalar(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            }
        }
        if isInTopics { finish() }
        return result
    }

    private static func markdownTitle(in content: String, fallback: String) -> String {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("# ") else { continue }
            let title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }

        return fallback
    }
}
