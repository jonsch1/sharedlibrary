import Foundation

/// Owns channel lifecycle and refresh workflows. Refresh only enumerates and
/// persists review candidates; capture is intentionally deferred to accept.
struct LibraryChannelCoordinator {
    let channels: SQLiteChannelRepository
    let state: LibraryChannelStateRepository
    let processing: SQLiteProcessingRepository

    func loadChannels() throws -> [LibraryChannel] {
        var records = try state.records()
        var changed = false
        for index in records.indices {
            let before = records[index]
            state.repair(&records[index])
            changed = changed || !sameChannelState(before, records[index])
        }
        changed = trimGroups(&records) || changed
        if changed { try state.write(records) }
        return state.buildChannels(from: records)
    }

    func addChannel(_ values: [String]) throws -> String {
        let normalized = try values.map(normalizedChannelSource)
        let sources = Array(NSOrderedSet(array: normalized).array.compactMap { $0 as? String })
        guard !sources.isEmpty else { throw LibraryError.invalidChannel }
        var records = try state.records()
        if sources.count == 1,
           let existing = records.first(where: { $0.source == sources[0] }) {
            return existing.groupID
        }
        for source in sources where records.contains(where: { $0.source == source }) {
            throw LibraryError.channelAlreadyExists
        }
        let groupID = sources.count == 1 ? sources[0] : UUID().uuidString.uppercased()
        records += sources.map {
            SQLiteChannelRecord(
                source: $0,
                groupID: groupID,
                schedule: "manual",
                reviewLimit: defaultChannelReviewLimit,
                canLoadMore: false
            )
        }
        try state.write(records)
        return groupID
    }

    func updateChannel(
        _ value: String,
        reviewLimit: Int,
        schedule valueSchedule: String
    ) throws {
        let source = try normalizedChannelSource(value)
        try validateReviewLimit(reviewLimit)
        let schedule = normalizedSchedule(valueSchedule)
        var records = try state.records()
        guard let index = records.firstIndex(where: { $0.source == source }) else {
            throw LibraryError.missingChannel
        }
        guard validSchedule(schedule) else { throw LibraryError.invalidChannelSchedule }
        records[index].reviewLimit = reviewLimit
        records[index].schedule = schedule
        let groupID = records[index].groupID
        for index in records.indices where records[index].groupID == groupID {
            records[index].reviewLimit = reviewLimit
        }
        _ = trimGroups(&records)
        try state.write(records)
    }

    func updateChannelGroup(
        _ groupID: String,
        title valueTitle: String,
        sources values: [String],
        reviewLimit: Int,
        schedule valueSchedule: String
    ) throws {
        let title = valueTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { throw LibraryError.invalidChannelTitle }
        let normalized = try values.map(normalizedChannelSource)
        let sources = Array(Set(normalized)).sorted()
        guard !sources.isEmpty else { throw LibraryError.invalidChannel }
        try validateReviewLimit(reviewLimit)
        let schedule = normalizedSchedule(valueSchedule)
        guard validSchedule(schedule) else { throw LibraryError.invalidChannelSchedule }

        var records = try state.records()
        let previous = records.filter { $0.groupID == groupID }
        guard !previous.isEmpty else { throw LibraryError.missingChannel }
        let conflicts = sources.filter { source in
            records.contains { $0.source == source && $0.groupID != groupID }
        }
        guard conflicts.isEmpty else { throw LibraryError.channelAlreadyExists }

        for source in Set(previous.map(\.source)).subtracting(sources) {
            _ = try removeChannel(source)
        }
        records = try state.records()
        let template = records.first(where: { $0.groupID == groupID }) ?? previous[0]
        for source in sources {
            if let index = records.firstIndex(where: { $0.source == source }) {
                records[index].groupID = groupID
                records[index].groupTitle = title
                records[index].reviewLimit = reviewLimit
                records[index].schedule = schedule
            } else {
                records.append(SQLiteChannelRecord(
                    source: source,
                    groupID: groupID,
                    groupTitle: title,
                    schedule: schedule,
                    reviewLimit: reviewLimit,
                    canLoadMore: template.canLoadMore
                ))
            }
        }
        for index in records.indices where records[index].groupID == groupID {
            records[index].groupTitle = title
            records[index].reviewLimit = reviewLimit
            records[index].schedule = schedule
        }
        _ = trimGroups(&records)
        try state.write(records)
    }

    @discardableResult
    func removeChannel(_ value: String) throws -> Int {
        let source = try normalizedChannelSource(value)
        let records = try state.records()
        guard records.contains(where: { $0.source == source }) else {
            throw LibraryError.missingChannel
        }
        try channels.delete(source)
        return records.first(where: { $0.source == source })?.items.filter(\.isPending).count ?? 0
    }

    @discardableResult
    func removeChannelGroup(_ groupID: String) throws -> Int {
        let sources = try state.records()
            .filter { $0.groupID == groupID }
            .map(\.source)
        guard !sources.isEmpty else { throw LibraryError.missingChannel }
        return try sources.reduce(0) { total, source in
            total + (try removeChannel(source))
        }
    }

    func checkChannel(
        _ value: String,
        maximumItems: Int?
    ) async throws -> LibraryChannelRefresh {
        let source = try normalizedChannelSource(value)
        let limit = try refreshLimit(maximumItems, source: source)
        return try await refresh(source: source, maximumItems: limit) {
            try await ChannelDiscovery().discover(source, maximumItems: limit)
        }
    }

    func checkChannelInput(
        _ value: String,
        maximumItems: Int?,
        discover: @Sendable (Int) async throws -> ChannelInputBatch
    ) async throws -> LibraryChannelRefresh {
        let source = try normalizedChannelSource(value)
        let limit = try refreshLimit(maximumItems, source: source)
        return try await refresh(source: source, maximumItems: limit) {
            let batch = try await discover(limit)
            return DiscoveredChannel(
                title: batch.title,
                kind: batch.kind,
                items: batch.items.map { item in
                    .init(
                        id: item.id,
                        title: item.title,
                        url: item.url.absoluteString,
                        publishedAt: item.publishedAt,
                        content: item.hints.content,
                        linkedURL: nil,
                        preferredInput: item.hints.preferredInput,
                        mediaURL: item.hints.mediaURL?.absoluteString,
                        transcriptURL: item.hints.transcriptURL?.absoluteString,
                        transcriptType: item.hints.transcriptType,
                        transcriptLanguage: item.hints.transcriptLanguage
                    )
                }
            )
        }
    }

    func captureSignedInChannelPage(
        source value: String,
        title: String,
        content: String
    ) async throws -> LibraryChannelRefresh {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LibraryError.emptyCapture }
        return try await captureSignedInChannelItems(
            source: value,
            title: title,
            items: [LibraryChannelCandidate(
                id: channelItemKey(value, text),
                title: title,
                url: value,
                content: text
            )]
        )
    }

    func captureSignedInChannelItems(
        source value: String,
        title: String,
        items: [LibraryChannelCandidate]
    ) async throws -> LibraryChannelRefresh {
        let source = try normalizedChannelSource(value)
        let candidates = items.filter {
            !$0.id.isEmpty && httpURL($0.url) != nil
        }
        guard !candidates.isEmpty else { throw LibraryError.emptyCapture }
        let current = try channelRecord(source)
        let limit = max(current.reviewLimit, min(defaultChannelReviewLimit, candidates.count))
        return try await refresh(source: source, maximumItems: limit) {
            DiscoveredChannel(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ??
                    channelDisplayTitle(source),
                kind: .page,
                items: candidates.map { item in
                    .init(
                        id: item.id,
                        title: item.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ??
                            channelDisplayTitle(source),
                        url: item.url,
                        publishedAt: item.publishedAt,
                        content: item.content,
                        linkedURL: item.linkedURL,
                        preferredInput: item.preferredInput,
                        mediaURL: item.mediaURL,
                        transcriptURL: item.transcriptURL,
                        transcriptType: item.transcriptType,
                        transcriptLanguage: item.transcriptLanguage
                    )
                }
            )
        }
    }

    func loadMoreChannel(_ value: String) async throws -> LibraryChannelRefresh {
        try await checkChannel(value, maximumItems: nil)
    }

    func acceptChannelItem(
        channelID: String,
        itemID: String,
        ingest: @Sendable (LibraryChannelCandidate) async throws -> String
    ) async throws -> String {
        let (source, item) = try pendingItem(channelID: channelID, itemID: itemID)
        let entryID = try await ingest(item.candidate())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entryID.isEmpty else { throw LibraryError.emptyCapture }
        try channels.acceptItem(source: source, itemID: itemID, entryID: entryID)
        #if os(macOS)
        try processing.enqueue(documentID: entryID, selectWhenFinished: false)
        #endif
        return entryID
    }

    func rejectChannelItem(channelID: String, itemID: String) throws {
        let (source, _) = try pendingItem(channelID: channelID, itemID: itemID)
        try channels.rejectItem(source: source, itemID: itemID)
    }

    func dueChannelSources(at date: Date) throws -> [String] {
        try loadChannels().flatMap { (channel: LibraryChannel) -> [String] in
            guard let scheduled = mostRecentScheduledDate(channel.schedule, at: date) else {
                return []
            }
            let checked = channel.lastCheckedAt.flatMap(ISO8601DateFormatter().date(from:))
            return checked == nil || checked! < scheduled ? channel.sources : []
        }
    }

    private func refresh(
        source: String,
        maximumItems limit: Int,
        discover: @Sendable () async throws -> DiscoveredChannel
    ) async throws -> LibraryChannelRefresh {
        _ = try channelRecord(source)
        let discovered: DiscoveredChannel
        do {
            discovered = try await discover()
        } catch {
            try state.update { records in
                guard let index = records.firstIndex(where: { $0.source == source }) else { return }
                records[index].lastCheckedAt = Date().iso8601
                records[index].error = error.localizedDescription
            }
            throw error
        }
        return try state.update { records in
            guard let index = records.firstIndex(where: { $0.source == source }) else {
                throw LibraryError.missingChannel
            }
            var record = records[index]
            let newItemIDs = state.merge(discovered, into: &record, limit: limit)
            record.lastCheckedAt = Date().iso8601
            record.reviewLimit = normalizedReviewLimit(record.reviewLimit)
            record.error = nil
            records[index] = record
            _ = trimGroups(&records)
            guard let channel = state.buildChannels(from: records).first(where: {
                $0.id == record.groupID
            }) else { throw LibraryError.missingChannel }
            return LibraryChannelRefresh(channel: channel, newItemIDs: newItemIDs)
        }
    }

    private func pendingItem(channelID: String, itemID: String) throws -> (String, LibraryChannelItem) {
        let records = try state.records()
        let matches = records.filter { record in
            (record.source == channelID || record.groupID == channelID) &&
                record.items.contains { $0.id == itemID && $0.isPending }
        }
        guard let record = matches.first,
              let item = record.items.first(where: { $0.id == itemID && $0.isPending })
        else { throw LibraryError.missingChannelItem }
        return (record.source, item)
    }

    private func channelRecord(_ source: String) throws -> SQLiteChannelRecord {
        guard let record = try state.records().first(where: { $0.source == source }) else {
            throw LibraryError.missingChannel
        }
        return record
    }

    private func refreshLimit(_ value: Int?, source: String) throws -> Int {
        let record = try channelRecord(source)
        if let value {
            try validateReviewLimit(value)
            return value
        }
        return normalizedReviewLimit(record.reviewLimit)
    }

    private func validateReviewLimit(_ value: Int) throws {
        guard channelReviewLimitRange.contains(value) else {
            throw LibraryError.invalidChannelReviewLimit
        }
    }

    private func normalizedSchedule(_ value: String) -> String {
        let schedule = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return schedule.isEmpty ? "manual" : schedule
    }

    private func normalizedReviewLimit(_ value: Int) -> Int {
        min(channelReviewLimitRange.upperBound, max(channelReviewLimitRange.lowerBound, value))
    }

    private func trimGroups(_ records: inout [SQLiteChannelRecord]) -> Bool {
        var changed = false
        for groupID in Set(records.map(\.groupID)) {
            let indices = records.indices.filter { records[$0].groupID == groupID }
            guard let first = indices.first else { continue }
            let limit = normalizedReviewLimit(records[first].reviewLimit)
            var pending = [(recordIndex: Int, itemIndex: Int, item: LibraryChannelItem)]()
            for index in indices {
                for itemIndex in records[index].items.indices
                    where records[index].items[itemIndex].isPending
                {
                    pending.append((index, itemIndex, records[index].items[itemIndex]))
                }
            }
            pending.sort { $0.item.ingestedAt > $1.item.ingestedAt }
            for pendingItem in pending.dropFirst(limit) {
                let itemID = pendingItem.item.id
                records[pendingItem.recordIndex].items.removeAll { $0.id == itemID }
                changed = true
            }
        }
        return changed
    }

    private func sameChannelState(_ lhs: SQLiteChannelRecord, _ rhs: SQLiteChannelRecord) -> Bool {
        lhs.source == rhs.source && lhs.groupID == rhs.groupID && lhs.groupTitle == rhs.groupTitle &&
            lhs.title == rhs.title && lhs.kind == rhs.kind && lhs.schedule == rhs.schedule &&
            lhs.lastCheckedAt == rhs.lastCheckedAt && lhs.error == rhs.error &&
            lhs.reviewLimit == rhs.reviewLimit && lhs.canLoadMore == rhs.canLoadMore &&
            lhs.seen == rhs.seen && lhs.items == rhs.items
    }
}
