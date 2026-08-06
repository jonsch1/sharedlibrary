import Foundation

/// The persisted channel definition plus its durable review queue. Accepted
/// items stay in `items` for channel provenance, while the public channel
/// projection exposes only items whose `entryID` is empty.
struct LibraryChannelStateRepository {
    let channels: SQLiteChannelRepository

    func records() throws -> [SQLiteChannelRecord] {
        try channels.records()
    }

    func write(_ records: [SQLiteChannelRecord]) throws {
        try channels.saveRecords(records)
    }

    func merge(
        _ discovered: DiscoveredChannel,
        into current: inout SQLiteChannelRecord,
        limit: Int
    ) -> [String] {
        var seen = Set(current.seen)
        var newItemIDs = [String]()

        for item in discovered.items.prefix(limit).reversed() {
            guard !item.id.isEmpty, httpURL(item.url) != nil else { continue }
            let identity = canonicalItemIdentity(URL(string: item.url))
            let replacementIDs: Set<String> = Set(current.items.compactMap { existing in
                guard existing.isPending,
                      let identity,
                      canonicalItemIdentity(URL(string: existing.url)) == identity
                else { return nil }
                return existing.id == item.id ? nil : existing.id
            })
            let isKnown = seen.contains(item.id) && replacementIDs.isEmpty
            if isKnown {
                if let index = current.items.firstIndex(where: {
                    $0.isPending && $0.id == item.id
                }) {
                    let existing = current.items[index]
                    current.items[index] = LibraryChannelItem(
                        id: item.id,
                        title: item.title,
                        url: item.url,
                        publishedAt: item.publishedAt,
                        content: item.content,
                        linkedURL: item.linkedURL,
                        preferredInput: item.preferredInput,
                        mediaURL: item.mediaURL,
                        transcriptURL: item.transcriptURL,
                        transcriptType: item.transcriptType,
                        transcriptLanguage: item.transcriptLanguage,
                        entryID: "",
                        ingestedAt: existing.ingestedAt
                    )
                }
                continue
            }

            current.items.removeAll { existing in
                existing.id == item.id || replacementIDs.contains(existing.id)
            }
            current.items.insert(
                LibraryChannelItem(
                    id: item.id,
                    title: item.title,
                    url: item.url,
                    publishedAt: item.publishedAt,
                    content: item.content,
                    linkedURL: item.linkedURL,
                    preferredInput: item.preferredInput,
                    mediaURL: item.mediaURL,
                    transcriptURL: item.transcriptURL,
                    transcriptType: item.transcriptType,
                    transcriptLanguage: item.transcriptLanguage,
                    entryID: "",
                    ingestedAt: Date().iso8601
                ),
                at: 0
            )
            current.seen.removeAll { $0 == item.id || replacementIDs.contains($0) }
            current.seen.insert(item.id, at: 0)
            seen.insert(item.id)
            newItemIDs.append(item.id)
        }

        current.title = discovered.title
        current.kind = discovered.kind
        current.canLoadMore = discovered.items.count >= limit && limit < 50
        return newItemIDs
    }

    func repair(_ record: inout SQLiteChannelRecord) {
        record.reviewLimit = normalizedReviewLimit(record.reviewLimit)
        record.seen = orderedUnique(record.seen)
        record.items = record.items.filter { item in
            !item.id.isEmpty && httpURL(item.url) != nil
        }
    }

    func buildChannels(from records: [SQLiteChannelRecord]) -> [LibraryChannel] {
        let groups = Dictionary(grouping: records) { $0.groupID }
        return groups.compactMap { groupID, values in
            guard let primary = values.sorted(by: { $0.source < $1.source }).first else {
                return nil
            }
            let sources = values.map(\.source).sorted()
            let items = values
                .flatMap { record in
                    record.items
                        .filter(\.isPending)
                        .map { (record.source, $0) }
                }
                .sorted { $0.1.ingestedAt > $1.1.ingestedAt }
                .prefix(normalizedReviewLimit(primary.reviewLimit))
                .map { source, item in
                    LibraryChannelItem(
                        id: item.id,
                        title: item.title,
                        url: item.url,
                        publishedAt: item.publishedAt,
                        content: item.content,
                        linkedURL: item.linkedURL,
                        preferredInput: item.preferredInput,
                        mediaURL: item.mediaURL,
                        transcriptURL: item.transcriptURL,
                        transcriptType: item.transcriptType,
                        transcriptLanguage: item.transcriptLanguage,
                        entryID: item.entryID,
                        acceptedAt: item.acceptedAt,
                        ingestedAt: item.ingestedAt
                    )
                }
            return LibraryChannel(
                source: groupID,
                sources: sources,
                title: primary.groupTitle ?? primary.title ?? channelDisplayTitle(primary.source),
                kind: Set(values.compactMap(\.kind)).count == 1 ? primary.kind : nil,
                schedule: primary.schedule,
                lastCheckedAt: values.compactMap(\.lastCheckedAt).max(),
                error: values.compactMap(\.error).first,
                reviewLimit: normalizedReviewLimit(primary.reviewLimit),
                canLoadMore: values.contains { $0.canLoadMore },
                items: items
            )
        }
        .sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func normalizedReviewLimit(_ value: Int) -> Int {
        min(channelReviewLimitRange.upperBound, max(channelReviewLimitRange.lowerBound, value))
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        Array(NSOrderedSet(array: values).array.compactMap { $0 as? String })
    }
}
