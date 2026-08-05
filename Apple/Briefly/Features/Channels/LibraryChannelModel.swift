import BrieflyCore
import Foundation
import Observation

struct LibraryChannelCheckResult {
    let source: String
    let newEntryIDs: [String]
    let errorMessage: String?
    let autoSummarize: Bool
}

struct LibraryDueChannelResult {
    let newEntryIDs: [String]
    let autoSummarizeIDs: Set<String>
}

@MainActor
@Observable
final class LibraryChannelModel {
    let session: LibrarySession
    let inputService: LibraryInputService

    var libraryChannels = [LibraryChannel]()
    var newChannelSources = [String]()
    var channelBrowserAddress = ""
    var channelBrowserStagesSource = false
    var isCheckingChannel = false
    var hasLoadedChannels = false

    init(session: LibrarySession, inputService: LibraryInputService) {
        self.session = session
        self.inputService = inputService
    }

    var channels: [LibraryChannel] {
        if session.library != nil { return libraryChannels }
        return session.projection.channelSources.map {
            LibraryChannel(source: $0, title: channelTitle($0))
        }
    }

    func selectedChannel(for source: String) -> LibraryChannel? {
        channels.first { $0.source == source }
    }

    func filteredChannels(query: String) -> [LibraryChannel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return channels }
        return channels.filter {
            $0.matches(needle) || channelEntries(for: $0.source).contains { $0.matches(needle) }
        }
    }

    func channelEntries(for source: String) -> [LibraryEntry] {
        guard let channel = channels.first(where: { $0.source == source }) else {
            return session.projection.entries(forChannel: source)
        }
        let entryIDs = Set(channel.entryIDs)
        if entryIDs.isEmpty { return session.projection.entries(forChannel: source) }
        return session.projection.entries
            .filter { entryIDs.contains($0.id) }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    func refreshChannels(from store: SQLiteLibraryStore) async throws {
        libraryChannels = try await store.loadChannels()
        hasLoadedChannels = true
    }

    func loadChannels() async {
        guard let library = session.library, !hasLoadedChannels else { return }
        do {
            try await refreshChannels(from: library)
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func stageChannelSource(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme) else {
            session.errorMessage = LibraryError.invalidChannel.localizedDescription
            return
        }
        let normalized = url.absoluteString
        guard !newChannelSources.contains(normalized) else { return }
        newChannelSources.append(normalized)
    }

    func removeStagedChannelSource(_ source: String) {
        newChannelSources.removeAll { $0 == source }
    }

    func addChannel(_ source: String) async -> LibraryChannel? {
        stageChannelSource(source)
        return await createChannel()
    }

    @discardableResult
    func createChannel() async -> LibraryChannel? {
        guard let library = session.library else {
            session.errorMessage = "Open a Briefly library before adding channels."
            return nil
        }
        guard !newChannelSources.isEmpty else { return nil }
        do {
            let groupID = try await library.addChannel(newChannelSources)
            try await refreshChannels(from: library)
            guard let added = libraryChannels.first(where: { $0.source == groupID }) else {
                throw LibraryError.missingChannel
            }
            newChannelSources = []
            session.status = added.sources.count == 1
                ? "Channel added"
                : "Channel added with \(added.sources.count) sources"
            return added
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func updateChannel(
        source: String,
        title: String,
        sources: [String],
        retrievalCount: Int,
        autoSummarize: Bool,
        schedule: String
    ) async -> Bool {
        guard let library = session.library else { return false }
        guard selectedChannel(for: source) != nil else { return false }
        do {
            try await library.updateChannelGroup(
                source,
                title: title,
                sources: sources,
                retrievalCount: retrievalCount,
                autoSummarize: autoSummarize,
                schedule: schedule
            )
            try await refreshChannels(from: library)
            session.status = "Channel settings saved"
            return true
        } catch {
            session.errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func checkChannel(source: String, loadMore: Bool = false) async -> LibraryChannelCheckResult? {
        guard
            let library = session.library,
            let channel = selectedChannel(for: source),
            !isCheckingChannel
        else { return nil }
        isCheckingChannel = true
        session.status = loadMore
            ? "Loading more from \(channel.title)…"
            : "Checking \(channel.title)…"
        defer { isCheckingChannel = false }
        do {
            var newEntryIDs = [String]()
            var lastError: Error?
            for source in channel.sources {
                do {
                    let result = try await retrieveChannel(
                        library,
                        source: source,
                        loadMore: loadMore
                    )
                    newEntryIDs.append(contentsOf: result.newEntryIDs)
                } catch {
                    lastError = error
                }
            }
            session.projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            if let lastError {
                session.errorMessage = lastError.localizedDescription
                session.status = newEntryIDs.isEmpty
                    ? "Channel check failed."
                    : "Gathered \(newEntryIDs.count) items; some sources failed and will retry."
            } else {
                session.status = newEntryIDs.isEmpty
                    ? "Channel checked. No new items."
                    : "Gathered \(newEntryIDs.count) new " +
                        (newEntryIDs.count == 1 ? "item" : "items")
            }
            return LibraryChannelCheckResult(
                source: channel.source,
                newEntryIDs: newEntryIDs,
                errorMessage: lastError?.localizedDescription,
                autoSummarize: channel.autoSummarize
            )
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func removeChannel(source: String) async -> Int? {
        guard let library = session.library, selectedChannel(for: source) != nil else { return nil }
        do {
            let deletedItemCount = try await library.removeChannelGroup(source)
            session.projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            session.status = deletedItemCount == 1
                ? "Channel removed and 1 downloaded item deleted"
                : "Channel removed and \(deletedItemCount) downloaded items deleted"
            return deletedItemCount
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    func retrieveChannel(
        _ library: SQLiteLibraryStore,
        source: String,
        loadMore: Bool = false
    ) async throws -> LibraryChannelRefresh {
        let ingest: @Sendable (LibraryChannelCandidate) async throws -> String = { candidate in
            guard let url = URL(string: candidate.url) else {
                throw LibraryError.invalidChannel
            }
            return try await self.inputService.ingestURL(
                url,
                in: library,
                candidate: candidate
            )
        }
        let channel = channels.first { $0.source == source }
        let maximum = loadMore
            ? min(100, (channel?.items.count ?? 0) + (channel?.retrievalCount ?? 5))
            : nil
        return try await library.checkChannelInput(
            source,
            maximumItems: maximum,
            discover: { limit in
                try await NativeChannelInputRouter().enumerate(
                    source: source,
                    maximumItems: limit,
                    context: self.inputService.channelInputContext()
                )
            },
            ingest: ingest
        )
    }

    func runDueChannelChecks() async -> LibraryDueChannelResult {
        guard let library = session.library, !isCheckingChannel else {
            return LibraryDueChannelResult(newEntryIDs: [], autoSummarizeIDs: [])
        }
        guard let due = try? await library.dueChannelSources(), !due.isEmpty else {
            return LibraryDueChannelResult(newEntryIDs: [], autoSummarizeIDs: [])
        }
        isCheckingChannel = true
        defer { isCheckingChannel = false }
        var newEntryIDs = [String]()
        for source in due {
            do {
                newEntryIDs += try await retrieveChannel(library, source: source).newEntryIDs
            } catch {
                continue
            }
        }
        session.projection = (try? await library.loadLibraryIndex()) ?? session.projection
        try? await refreshChannels(from: library)
        let autoSummarizeIDs = Set(libraryChannels.filter(\.autoSummarize).flatMap(\.entryIDs))
        return LibraryDueChannelResult(
            newEntryIDs: newEntryIDs,
            autoSummarizeIDs: autoSummarizeIDs
        )
    }
}
