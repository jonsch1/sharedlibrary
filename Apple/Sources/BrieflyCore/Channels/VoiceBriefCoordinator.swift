import Foundation

struct LibraryVoiceBriefCoordinator {
    let voiceBriefs: SQLiteVoiceBriefRepository
    let state: LibraryChannelStateRepository
    let projection: LibraryProjectionService
    let channels: LibraryChannelCoordinator

    func run(id: String) async throws -> LibraryVoiceBriefEpisodeResult {
        guard let brief = try state.voiceBriefs().first(where: { $0.id == id }) else {
            throw LibraryError.missingVoiceBrief
        }
        var currentState = state.read()
        var run = currentState.voiceBriefs[id] ?? .init()
        run.lastAttemptAt = Date().iso8601
        currentState.voiceBriefs[id] = run
        try state.write(currentState)
        let consumed = Set(run.consumed)
        let pending = brief.sources.flatMap { source in
            (currentState.sources[source]?.items ?? [])
                .filter { !consumed.contains(voiceBriefItemKey(source, $0.id)) }
                .map { (source, $0) }
        }
        guard !pending.isEmpty else { throw LibraryError.noVoiceBriefItems }

        let library = try projection.loadProjection()
        let entries = Dictionary(uniqueKeysWithValues: library.entries.map { ($0.id, $0) })
        var sections = [LibraryVariant: [String]]()
        var selected = [(String, LibraryChannelItem)]()
        var characterCounts = [LibraryVariant: Int]()
        for (source, item) in pending {
            let entry = entries[item.entryID]
            var included = false
            for variant in [LibraryVariant.concise, .detailed] {
                guard let text = entry?.text(for: variant)?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                let section = """
                ## \(item.title)

                \(text)
                """
                let count = characterCounts[variant, default: 0]
                guard count < 120_000 else { continue }
                let fitted = String(section.prefix(120_000 - count))
                sections[variant, default: []].append(fitted)
                characterCounts[variant] = count + fitted.count
                included = true
            }
            if included { selected.append((source, item)) }
        }
        guard sections.values.contains(where: { !$0.isEmpty }) else {
            throw LibraryError.noVoiceBriefItems
        }

        run.status = "generating"
        run.message = "Generating \(brief.title)"
        currentState.voiceBriefs[id] = run
        try state.write(currentState)
        do {
            let scripts = sections.mapValues { "# \(brief.title)\n\n" + $0.joined(separator: "\n\n") }
            let entryID = try state.saveVoiceBriefEpisode(
                brief: brief,
                scripts: scripts,
                sources: selected.map(\.1)
            )
            run.consumed = Array(Set(run.consumed + selected.map {
                voiceBriefItemKey($0.0, $0.1.id)
            }))
            run.pendingEpisodeID = nil
            run.lastRunAt = Date().iso8601
            run.status = "ready"
            run.message = "Brief ready."
            currentState.voiceBriefs[id] = run
            try state.write(currentState)
            return LibraryVoiceBriefEpisodeResult(
                entryID: entryID,
                script: scripts[.concise] ?? scripts[.detailed] ?? ""
            )
        } catch {
            run.status = "error"
            run.message = error.localizedDescription
            currentState.voiceBriefs[id] = run
            try? state.write(currentState)
            throw error
        }
    }

    func queue(id: String) throws {
        guard try state.voiceBriefs().contains(where: { $0.id == id }) else {
            throw LibraryError.missingVoiceBrief
        }
        var currentState = state.read()
        var run = currentState.voiceBriefs[id] ?? .init()
        if run.pendingEpisodeID == nil {
            run.status = "queued"
            run.message = "Waiting to prepare"
        }
        currentState.voiceBriefs[id] = run
        try state.write(currentState)
    }

    func cancel(id: String) throws {
        guard try state.voiceBriefs().contains(where: { $0.id == id }) else {
            throw LibraryError.missingVoiceBrief
        }
        var currentState = state.read()
        var run = currentState.voiceBriefs[id] ?? .init()
        run.status = "cancelled"
        run.message = "Preparation cancelled."
        currentState.voiceBriefs[id] = run
        try state.write(currentState)
    }

    func pendingIDs() -> [String] {
        let active = Set(["queued", "generating"])
        return state.read().voiceBriefs.compactMap { id, run in
            run.status.map(active.contains) == true ? id : nil
        }
    }

    func dueIDs(at date: Date) throws -> [String] {
        let currentState = state.read()
        return try state.voiceBriefs().compactMap { brief in
            guard let scheduled = mostRecentScheduledDate(brief.schedule, at: date) else { return nil }
            let run = currentState.voiceBriefs[brief.id]
            let attempted = [run?.lastAttemptAt, run?.lastRunAt]
                .compactMap { $0.flatMap(ISO8601DateFormatter().date(from:)) }.max()
            return attempted == nil || attempted! < scheduled ? brief.id : nil
        }
    }

    func dueChannelSources(at date: Date) throws -> [String] {
        try channels.loadChannels().flatMap { channel -> [String] in
            guard let scheduled = mostRecentScheduledDate(channel.schedule, at: date) else { return [] }
            let checked = channel.lastCheckedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
            return checked == nil || checked! < scheduled ? channel.sources : []
        }
    }

    func markAttempt(id: String, at date: Date) throws {
        guard try state.voiceBriefs().contains(where: { $0.id == id }) else {
            throw LibraryError.missingVoiceBrief
        }
        var currentState = state.read()
        var run = currentState.voiceBriefs[id] ?? .init()
        run.lastAttemptAt = date.iso8601
        currentState.voiceBriefs[id] = run
        try state.write(currentState)
    }

    func moveToTrash(id: String) throws {
        guard try state.voiceBriefs().contains(where: { $0.id == id }) else {
            throw LibraryError.missingVoiceBrief
        }
        try voiceBriefs.delete(id)
    }
}
