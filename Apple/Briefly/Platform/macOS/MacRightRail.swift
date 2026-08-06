import SwiftUI

#if os(macOS)
struct MacXRightRail: View {
    @Bindable var model: LibraryModel
    @State private var topicBeingRenamed: String?
    @State private var renamedTopic = ""
    @State private var topicBeingDeleted: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search your library", text: $model.navigation.query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("library.search")
                if !model.navigation.query.isEmpty {
                    Button {
                        model.navigation.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(Color.primary.opacity(0.10)) }

            if let entry = model.selection.selectedEntry {
                FeedRailCard(title: "About this post") {
                    if let source = entry.sourceURL,
                        let url = URL(string: source)
                    {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .foregroundStyle(.secondary)
                                Text(url.host ?? source)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                    }
                    ForEach(Array(entry.topicNames.prefix(5)), id: \.self) { topic in
                        Button {
                            Task {
                                await model.workflows.showTopic(topic)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "number")
                                    .foregroundStyle(.secondary)
                                Text(topic).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                contextualCard
            }

            Spacer()
        }
        .padding(.top, 16)
        .frame(maxHeight: .infinity)
        .alert("Rename collection", isPresented: renamingCollection) {
            TextField("Collection name", text: $renamedTopic)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let topicBeingRenamed else { return }
                Task { await model.workflows.renameTopic(topicBeingRenamed, to: renamedTopic) }
            }
            .disabled(renamedTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete collection?", isPresented: deletingCollection) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let topicBeingDeleted else { return }
                Task { await model.workflows.deleteTopic(topicBeingDeleted) }
            }
        } message: {
            Text("The collection will be removed, but its notes will stay in your library.")
        }
    }

    private var renamingCollection: Binding<Bool> {
        Binding(
            get: { topicBeingRenamed != nil },
            set: { if !$0 { topicBeingRenamed = nil } }
        )
    }

    private var deletingCollection: Binding<Bool> {
        Binding(
            get: { topicBeingDeleted != nil },
            set: { if !$0 { topicBeingDeleted = nil } }
        )
    }

    @ViewBuilder
    private var contextualCard: some View {
        switch model.navigation.activeSection {
        case .items:
            FeedRailCard(title: "Collections") {
                ForEach(Array(model.session.projection.documentTopics.prefix(6)), id: \.self) { topic in
                    collectionRow(topic)
                }
            }
        case .channels:
            FeedRailCard(title: "Main channels") {
                ForEach(Array(model.channels.channels.prefix(6))) { channel in
                    railButton(compactLabel(channel.title), icon: channel.kind == .podcast ? "waveform" : "dot.radiowaves.left.and.right") {
                        model.workflows.selectChannel(channel.source)
                    }
                }
            }
        }
    }

    private func collectionRow(_ topic: String) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.workflows.showTopic(topic) }
            } label: {
                railRowLabel(topic, icon: "folder")
            }
            .buttonStyle(.plain)

            Menu {
                Button("Rename", systemImage: "pencil") {
                    renamedTopic = topic
                    topicBeingRenamed = topic
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    topicBeingDeleted = topic
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Settings for \(topic)")
            .help("Settings for \(topic)")
        }
    }

    private func railButton(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            railRowLabel(title, icon: icon, showsDisclosure: true)
        }
        .buttonStyle(.plain)
    }

    private func railRowLabel(
        _ title: String,
        icon: String,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }
}
#endif
