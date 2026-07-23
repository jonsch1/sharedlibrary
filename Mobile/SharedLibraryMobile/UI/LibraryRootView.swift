import AVFoundation
import SwiftUI

struct LibraryRootView: View {
    @EnvironmentObject private var libraryStore: MobileLibraryStore
    @EnvironmentObject private var speechPlayer: SpeechPlayer
    @State private var searchText = ""
    @State private var showingQueue = false

    private var filteredEntries: [MobileLibraryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return libraryStore.entries }
        return libraryStore.entries.filter { entry in
            [
                entry.title,
                entry.excerpt,
                entry.topicNames.joined(separator: " "),
                entry.tags.joined(separator: " "),
                entry.sharedByDisplayName ?? ""
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if libraryStore.entries.isEmpty {
                    ContentUnavailableView {
                        Label("My Library", systemImage: "books.vertical")
                    } description: {
                        Text(libraryStore.state.message)
                    } actions: {
                        Button("Check iCloud") {
                            Task { await libraryStore.refresh() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(filteredEntries) { entry in
                        NavigationLink(value: entry) {
                            LibraryEntryRow(entry: entry)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await libraryStore.refresh()
                    }
                    .overlay(alignment: .bottom) {
                        if case .failed(let message) = libraryStore.state {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .background(.regularMaterial, in: Capsule())
                                .padding()
                        }
                    }
                }
            }
            .navigationTitle("My Library")
            .searchable(text: $searchText, prompt: "Titles, topics, tags")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if libraryStore.state.isLoading {
                        ProgressView()
                    }
                    Button {
                        Task { await libraryStore.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button {
                        showingQueue = true
                    } label: {
                        Label("Listening queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                }
            }
            .navigationDestination(for: MobileLibraryEntry.self) { entry in
                LibraryEntryDetailView(entry: entry)
            }
            .safeAreaInset(edge: .bottom) {
                if speechPlayer.currentItem != nil {
                    MiniPlayer(showingQueue: $showingQueue)
                }
            }
            .sheet(isPresented: $showingQueue) {
                ListeningQueueView()
                    .environmentObject(speechPlayer)
            }
        }
    }
}

private struct LibraryEntryRow: View {
    let entry: MobileLibraryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if entry.origin == .shared {
                    Label("Shared", systemImage: "person.2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !entry.topicNames.isEmpty {
                Text(entry.topicNames.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }

            Text(entry.excerpt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                if let date = entry.createdAt {
                    Text(date, style: .date)
                }
                if let sharedBy = entry.sharedByDisplayName {
                    Text("Shared by \(sharedBy)")
                }
                Spacer()
                if let variant = entry.preferredVariant {
                    Label(
                        duration(entry.estimatedDuration(for: variant)),
                        systemImage: "headphones"
                    )
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

struct LibraryEntryDetailView: View {
    @EnvironmentObject private var speechPlayer: SpeechPlayer
    let entry: MobileLibraryEntry
    @State private var selectedVariant: CloudLibraryVariant

    init(entry: MobileLibraryEntry) {
        self.entry = entry
        _selectedVariant = State(initialValue: entry.preferredVariant ?? .source)
    }

    private var availableVariants: [CloudLibraryVariant] {
        CloudLibraryVariant.allCases.filter { !(entry.texts[$0] ?? "").isEmpty }
    }

    private var selectedText: String {
        entry.texts[selectedVariant] ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.title)
                        .font(.largeTitle.bold())
                    if !entry.topicNames.isEmpty {
                        Text(entry.topicNames.joined(separator: " · "))
                            .foregroundStyle(.tint)
                    }
                    if let sharedBy = entry.sharedByDisplayName {
                        Label("Shared by \(sharedBy)", systemImage: "person.2")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Picker("Length", selection: $selectedVariant) {
                        ForEach(availableVariants, id: \.self) { variant in
                            Text(variant.title).tag(variant)
                        }
                    }
                    .pickerStyle(.menu)

                    Spacer()

                    Text(duration(entry.estimatedDuration(for: selectedVariant)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        speechPlayer.play(entry, variant: selectedVariant)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        speechPlayer.enqueue(entry, variant: selectedVariant)
                    } label: {
                        Label("Add to Queue", systemImage: "text.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                Text(markdown: selectedText)
                    .font(.body)
                    .textSelection(.enabled)

                if let rawURL = entry.sourceURL,
                   let url = URL(string: rawURL),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    Link(destination: url) {
                        Label("Open original source", systemImage: "safari")
                    }
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MiniPlayer: View {
    @EnvironmentObject private var speechPlayer: SpeechPlayer
    @Binding var showingQueue: Bool

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: speechPlayer.progress)
                .progressViewStyle(.linear)
            HStack(spacing: 14) {
                Button {
                    showingQueue = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speechPlayer.currentItem?.title ?? "")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(speechPlayer.currentItem?.variant.title ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    speechPlayer.togglePlayback()
                } label: {
                    Image(systemName: speechPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }

                Button {
                    speechPlayer.playNext()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 36, height: 36)
                }
                .disabled(speechPlayer.queue.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }
}

private struct ListeningQueueView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var speechPlayer: SpeechPlayer

    var body: some View {
        NavigationStack {
            List {
                if let current = speechPlayer.currentItem {
                    Section("Now Playing") {
                        VStack(alignment: .leading) {
                            Text(current.title)
                                .font(.headline)
                            Text(current.variant.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Up Next") {
                    if speechPlayer.queue.isEmpty {
                        Text("The listening queue is empty.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(speechPlayer.queue) { item in
                            VStack(alignment: .leading) {
                                Text(item.title)
                                Text(item.variant.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onDelete(perform: speechPlayer.removeFromQueue)
                        .onMove(perform: speechPlayer.moveQueue)
                    }
                }

                Section("Playback") {
                    HStack {
                        Text("Speed")
                        Slider(value: $speechPlayer.rate, in: 0.35...0.62)
                        Text(String(format: "%.1fx", speechPlayer.rate / AVSpeechUtteranceDefaultSpeechRate))
                            .font(.caption.monospacedDigit())
                            .frame(width: 42)
                    }
                }
            }
            .navigationTitle("Listening Queue")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
    }
}

private extension Text {
    init(markdown: String) {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        ) {
            self.init(attributed)
        } else {
            self.init(markdown)
        }
    }
}

private func duration(_ interval: TimeInterval) -> String {
    let minutes = max(1, Int(interval / 60))
    if minutes < 60 {
        return "\(minutes) min"
    }
    return "\(minutes / 60) hr \(minutes % 60) min"
}
