import BrieflyCore
import Foundation
import Observation

@MainActor
@Observable
final class LibraryChannelModel {
    let session: LibrarySession
    var libraryChannels = [LibraryChannel]()
    var newChannelSources = [String]()
    var channelBrowserAddress = ""
    var channelBrowserStagesSource = false
    var isCheckingChannel = false
    var hasLoadedChannels = false

    weak var navigation: LibraryNavigationModel?
    weak var processing: LibraryProcessingModel?
    weak var lifecycle: LibraryLifecycleModel?
    weak var voiceBriefs: LibraryVoiceBriefModel?

    init(
        session: LibrarySession,
        navigation: LibraryNavigationModel,
        processing: LibraryProcessingModel
    ) {
        self.session = session
        self.navigation = navigation
        self.processing = processing
    }

    var channels: [LibraryChannel] {
        if session.library != nil { return libraryChannels }
        return session.projection.channelSources.map {
            LibraryChannel(source: $0, title: channelTitle($0))
        }
    }

    var selectedChannel: LibraryChannel? {
        channels.first { $0.source == navigation?.selectedChannelSource }
    }

    var filteredChannels: [LibraryChannel] {
        let needle = navigation?.query.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    func addChannel(_ source: String) async {
        stageChannelSource(source)
        await createChannel()
    }

    func createChannel() async {
        guard let library = session.library else {
            session.errorMessage = "Open a Briefly library before adding channels."
            return
        }
        guard !newChannelSources.isEmpty else { return }
        do {
            let groupID = try await library.addChannel(newChannelSources)
            try await refreshChannels(from: library)
            guard let added = libraryChannels.first(where: { $0.source == groupID }) else {
                throw LibraryError.missingChannel
            }
            navigation?.selectedChannelSource = added.source
            newChannelSources = []
            navigation?.showingChannelSettings = false
            session.status = added.sources.count == 1
                ? "Channel added"
                : "Channel added with \(added.sources.count) sources"
            lifecycle?.requestSync()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func updateSelectedChannel(
        title: String,
        sources: [String],
        retrievalCount: Int,
        autoSummarize: Bool,
        schedule: String
    ) async {
        guard let library = session.library, let channel = selectedChannel else { return }
        do {
            try await library.updateChannelGroup(
                channel.source,
                title: title,
                sources: sources,
                retrievalCount: retrievalCount,
                autoSummarize: autoSummarize,
                schedule: schedule
            )
            try await refreshChannels(from: library)
            session.status = "Channel settings saved"
            lifecycle?.requestSync()
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func checkSelectedChannel(loadMore: Bool = false) async {
        guard
            let library = session.library,
            let channel = selectedChannel,
            !isCheckingChannel
        else { return }
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
            navigation?.selectedChannelSource = channel.source
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
            if channel.autoSummarize {
                await processing?.enqueueProcessing(newEntryIDs)
            }
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func removeSelectedChannel() async {
        guard let library = session.library, let channel = selectedChannel else { return }
        do {
            let deletedItemCount = try await library.removeChannelGroup(channel.source)
            session.projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            navigation?.selectedChannelSource = ""
            navigation?.showingChannelSettings = false
            processing?.selection.clear()
            session.status = deletedItemCount == 1
                ? "Channel removed and 1 downloaded item deleted"
                : "Channel removed and \(deletedItemCount) downloaded items deleted"
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func retrieveChannel(
        _ library: SQLiteLibraryStore,
        source: String,
        loadMore: Bool = false
    ) async throws -> LibraryChannelRefresh {
        guard let processing else { throw LibraryError.invalidChannel }
        let ingest: @Sendable (LibraryChannelCandidate) async throws -> String = { candidate in
            guard let url = URL(string: candidate.url) else {
                throw LibraryError.invalidChannel
            }
            return try await processing.ingestURL(url, in: library, candidate: candidate)
        }
        let channel = channels.first { $0.source == source }
        let maximum = loadMore
            ? min(100, (channel?.items.count ?? 0) + (channel?.retrievalCount ?? 5))
            : nil
        return try await library.checkChannelInput(
            source,
            maximumItems: maximum,
            discover: { limit in
                return try await NativeChannelInputRouter().enumerate(
                    source: source,
                    maximumItems: limit,
                    context: processing.channelInputContext()
                )
            },
            ingest: ingest
        )
    }

    func runDueChannelChecks() async {
        guard
            let library = session.library,
            !isCheckingChannel,
            voiceBriefs?.isRunningVoiceBrief != true
        else { return }
        guard let due = try? await library.dueChannelSources(), !due.isEmpty else { return }
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
        await processing?.enqueueProcessing(newEntryIDs.filter(autoSummarizeIDs.contains))
        if !newEntryIDs.isEmpty { lifecycle?.requestSync() }
    }
}
