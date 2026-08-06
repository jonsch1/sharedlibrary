import BrieflyCore
import Foundation
import Observation

struct LibraryChannelCheckResult {
    let source: String
    let candidates: [LibraryChannelReviewItem]
    let errorMessage: String?
}

struct LibraryDueChannelResult {
    let candidates: [LibraryChannelReviewItem]
}

typealias ChannelReviewSummaryRequester = @MainActor ([String]) async -> Void

struct LibraryChannelReviewItem: Hashable, Identifiable, Sendable {
    let channelID: String
    let item: LibraryChannelItem

    var id: String { item.id }

    var reviewKey: String { "\(channelID)\u{1F}\(item.id)" }

    var url: URL? { URL(string: item.url) }

    var host: String {
        url?.host?.replacingOccurrences(of: "www.", with: "") ?? item.url
    }

    var previewText: String {
        (item.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var candidate: LibraryChannelCandidate {
        item.candidate()
    }

    init(
        channelID: String,
        item: LibraryChannelItem
    ) {
        self.channelID = channelID
        self.item = item
    }
}

@MainActor
@Observable
final class LibraryChannelModel {
    static let maximumReviewWindow = channelReviewLimitRange.upperBound

    let session: LibrarySession
    let inputService: LibraryInputService

    var libraryChannels = [LibraryChannel]()
    var newChannelSources = [String]()
    var channelBrowserAddress = ""
    var channelBrowserStagesSource = false
    var isCheckingChannel = false
    var hasLoadedChannels = false
    var isAcceptingReviewCandidate = false

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

    func reviewWindow(for channel: LibraryChannel) -> Int {
        min(
            Self.maximumReviewWindow,
            max(channelReviewLimitRange.lowerBound, channel.reviewLimit)
        )
    }

    func reviewCandidates(for channel: LibraryChannel) -> [LibraryChannelReviewItem] {
        channel.items
            .filter(\.isPending)
            .map { LibraryChannelReviewItem(channelID: channel.source, item: $0) }
    }

    func reviewCandidatesAcrossChannels() -> [LibraryChannelReviewItem] {
        channels
            .flatMap(reviewCandidates)
            .sorted { $0.item.ingestedAt > $1.item.ingestedAt }
    }

    func reviewCandidateCount(for channel: LibraryChannel) -> Int {
        reviewCandidates(for: channel).count
    }

    func resolvedPreview(for item: LibraryChannelReviewItem) async -> String? {
        guard let url = item.url else { return nil }
        let host = url.host?.lowercased() ?? ""
        guard host == "x.com" || host.hasSuffix(".x.com") ||
                host == "twitter.com" || host.hasSuffix(".twitter.com")
        else { return nil }
        let candidate = item.candidate
        let hints = ItemInputHints(
            preferredInput: .x,
            title: candidate.title,
            content: candidate.content
        )
        return try? await NativeItemInputRouter().ingest(
            ItemInputRequest(source: .url(url), hints: hints),
            context: inputService.itemInputContext()
        ).content
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
        let channelSources = Set(channel.sources)
        return session.projection.entries
            .filter { entry in
                guard let entrySources = entry.channelSources else { return false }
                return !channelSources.isDisjoint(with: entrySources)
            }
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
        reviewWindow: Int,
        schedule: String
    ) async -> Bool {
        guard let library = session.library else { return false }
        guard selectedChannel(for: source) != nil else { return false }
        let boundedWindow = min(Self.maximumReviewWindow, max(1, reviewWindow))
        do {
            try await library.updateChannelGroup(
                source,
                title: title,
                sources: sources,
                reviewLimit: boundedWindow,
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
    func checkChannel(source: String) async -> LibraryChannelCheckResult? {
        guard
            let library = session.library,
            let channel = selectedChannel(for: source),
            !isCheckingChannel
        else { return nil }
        isCheckingChannel = true
        session.status = "Finding candidates in \(channel.title)…"
        defer { isCheckingChannel = false }
        do {
            var newItemIDs = [String]()
            var lastError: Error?
            for source in channel.sources {
                do {
                    let result = try await retrieveChannel(
                        library,
                        source: source
                    )
                    newItemIDs.append(contentsOf: result.newItemIDs)
                } catch {
                    lastError = error
                }
            }
            try await refreshChannels(from: library)
            let candidates = reviewCandidates(for: selectedChannel(for: source) ?? channel)
                .filter { newItemIDs.contains($0.id) }
            if let lastError {
                session.errorMessage = lastError.localizedDescription
                session.status = candidates.isEmpty
                    ? "Candidate check failed."
                    : "Found \(candidates.count) candidates; some sources failed and will retry."
            } else {
                session.status = candidates.isEmpty
                    ? "No new candidates to review."
                    : "Found \(candidates.count) new " +
                        (candidates.count == 1 ? "candidate" : "candidates")
            }
            return LibraryChannelCheckResult(
                source: channel.source,
                candidates: candidates,
                errorMessage: lastError?.localizedDescription
            )
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func loadMoreChannel(source: String) async -> LibraryChannelCheckResult? {
        guard
            let library = session.library,
            let channel = selectedChannel(for: source),
            !isCheckingChannel
        else { return nil }
        isCheckingChannel = true
        session.status = "Finding more candidates in \(channel.title)…"
        defer { isCheckingChannel = false }
        do {
            var newItemIDs = [String]()
            var lastError: Error?
            for source in channel.sources {
                do {
                    let refresh = try await library.loadMoreChannel(source)
                    newItemIDs.append(contentsOf: refresh.newItemIDs)
                } catch {
                    lastError = error
                }
            }
            try await refreshChannels(from: library)
            let candidates = reviewCandidates(for: selectedChannel(for: source) ?? channel)
                .filter { newItemIDs.contains($0.id) }
            if let lastError {
                session.errorMessage = lastError.localizedDescription
                session.status = candidates.isEmpty
                    ? "Could not find more candidates."
                    : "Found \(candidates.count) more candidates; some sources failed and will retry."
            } else {
                session.status = candidates.isEmpty
                    ? "No more candidates to review."
                    : "Found \(candidates.count) more " +
                        (candidates.count == 1 ? "candidate" : "candidates")
            }
            return LibraryChannelCheckResult(
                source: channel.source,
                candidates: candidates,
                errorMessage: lastError?.localizedDescription
            )
        } catch {
            session.errorMessage = error.localizedDescription
            session.status = "Could not find more candidates."
            return nil
        }
    }

    func checkAllChannels(loadMore: Bool = false) async {
        let channelIDs = channels.compactMap { channel in
            loadMore && !channel.canLoadMore ? nil : channel.source
        }
        for channelID in channelIDs {
            if loadMore {
                _ = await loadMoreChannel(source: channelID)
            } else {
                _ = await checkChannel(source: channelID)
            }
        }
    }

    @discardableResult
    func removeChannel(source: String) async -> Int? {
        guard let library = session.library, selectedChannel(for: source) != nil else { return nil }
        do {
            let deletedItemCount = try await library.removeChannelGroup(source)
            try await refreshChannels(from: library)
            session.status = deletedItemCount == 1
                ? "Channel removed and 1 pending candidate removed"
                : "Channel removed and \(deletedItemCount) pending candidates removed"
            return deletedItemCount
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    func retrieveChannel(
        _ library: SQLiteLibraryStore,
        source: String
    ) async throws -> LibraryChannelRefresh {
        return try await library.checkChannelInput(
            source,
            maximumItems: nil,
            discover: { limit in
                try await NativeChannelInputRouter().enumerate(
                    source: source,
                    maximumItems: limit,
                    context: self.inputService.channelInputContext()
                )
            }
        )
    }

    func runDueChannelChecks() async -> LibraryDueChannelResult {
        guard let library = session.library, !isCheckingChannel else {
            return LibraryDueChannelResult(candidates: [])
        }
        guard let due = try? await library.dueChannelSources(), !due.isEmpty else {
            return LibraryDueChannelResult(candidates: [])
        }
        isCheckingChannel = true
        defer { isCheckingChannel = false }
        var newItemIDs = [String]()
        for source in due {
            do {
                newItemIDs += try await retrieveChannel(library, source: source).newItemIDs
            } catch {
                continue
            }
        }
        try? await refreshChannels(from: library)
        let candidates = libraryChannels.flatMap { channel in
            reviewCandidates(for: channel).filter { newItemIDs.contains($0.id) }
        }
        if !candidates.isEmpty {
            session.status = "Candidates ready to review"
        }
        return LibraryDueChannelResult(candidates: candidates)
    }

    @discardableResult
    func acceptCandidate(
        _ item: LibraryChannelReviewItem,
        requestSummary: ChannelReviewSummaryRequester? = nil
    ) async -> String? {
        guard
            let library = session.library,
            selectedChannel(for: item.channelID)?.items.contains(where: {
                $0.id == item.id && $0.isPending
            }) == true,
            item.url != nil,
            !isAcceptingReviewCandidate
        else { return nil }

        isAcceptingReviewCandidate = true
        session.status = "Saving \(item.item.title)…"
        defer { isAcceptingReviewCandidate = false }
        do {
            let entryID = try await library.acceptChannelItem(
                channelID: item.channelID,
                itemID: item.item.id,
                ingest: { candidate in
                    try await self.captureAcceptedCandidate(candidate, in: library)
                }
            )
            session.projection = try await library.loadLibraryIndex()
            try await refreshChannels(from: library)
            if let requestSummary {
                session.status = "Accepted. Preparing summaries…"
                await requestSummary([entryID])
            } else {
                session.status = "Accepted. Summary queued."
            }
            return entryID
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func rejectCandidate(_ item: LibraryChannelReviewItem) async -> Bool {
        guard selectedChannel(for: item.channelID)?.items.contains(where: {
            $0.id == item.id && $0.isPending
        }) == true else {
            return false
        }
        do {
            guard let library = session.library else { return false }
            try await library.rejectChannelItem(channelID: item.channelID, itemID: item.item.id)
            try await refreshChannels(from: library)
            session.status = "Removed from the pending review queue"
            return true
        } catch {
            session.errorMessage = error.localizedDescription
            return false
        }
    }

    private func captureAcceptedCandidate(
        _ candidate: LibraryChannelCandidate,
        in library: SQLiteLibraryStore
    ) async throws -> String {
        guard let url = URL(string: candidate.url) else {
            throw LibraryError.invalidChannel
        }
        let hints = ItemInputHints(
            preferredInput: candidate.preferredInput,
            title: candidate.title,
            content: candidate.content,
            mediaURL: candidate.mediaURL.flatMap(URL.init(string:)),
            transcriptURL: candidate.transcriptURL.flatMap(URL.init(string:)),
            transcriptType: candidate.transcriptType,
            transcriptLanguage: candidate.transcriptLanguage
        )
        let draft = try await NativeItemInputRouter().ingest(
            ItemInputRequest(source: .url(url), hints: hints),
            context: inputService.itemInputContext()
        )
        return try await library.captureItem(draft)
    }

}
