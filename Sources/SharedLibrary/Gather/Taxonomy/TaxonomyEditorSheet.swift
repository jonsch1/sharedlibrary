import AppKit
import SwiftUI

struct TaxonomyEditorSheet: View {
    let yamlURL: URL
    let topicUsageCounts: [String: Int]
    let onCancel: () -> Void
    let onSave: (KnowledgeTaxonomy) throws -> Void

    @State private var taxonomy: KnowledgeTaxonomy
    @State private var selectedAreaID: String?
    @State private var selectedTopicID: String?
    @State private var isAddingArea = false
    @State private var isAddingTopic = false
    @State private var newAreaName = ""
    @State private var newTopicName = ""
    @State private var errorMessage: String?

    init(
        taxonomy: KnowledgeTaxonomy,
        yamlURL: URL,
        topicUsageCounts: [String: Int],
        onCancel: @escaping () -> Void,
        onSave: @escaping (KnowledgeTaxonomy) throws -> Void
    ) {
        self.yamlURL = yamlURL
        self.topicUsageCounts = topicUsageCounts
        self.onCancel = onCancel
        self.onSave = onSave
        _taxonomy = State(initialValue: taxonomy)
        _selectedAreaID = State(initialValue: taxonomy.areas.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            HStack(spacing: 0) {
                areaColumn
                    .frame(width: 220)

                Divider()

                topicColumn
                    .frame(width: 270)

                Divider()

                inspector
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            footer
        }
        .frame(width: 900, height: 610)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .alert("New area", isPresented: $isAddingArea) {
            TextField("Area name", text: $newAreaName)
            Button("Cancel", role: .cancel) {}
            Button("Add") { addArea() }
                .disabled(newAreaName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Areas are stable, high-level parts of life such as Personal or Work.")
        }
        .alert("New topic", isPresented: $isAddingTopic) {
            TextField("Topic name", text: $newTopicName)
            Button("Cancel", role: .cancel) {}
            Button("Add") { addTopic() }
                .disabled(newTopicName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The topic will be added to \(selectedArea?.title ?? "the selected area").")
        }
        .alert("Unable to save taxonomy", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text("Areas & Topics")
                    .font(.system(size: 21, weight: .semibold))
                Text("Organize Main without changing where the underlying files live.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("YAML-backed")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background(Color.white.opacity(0.055), in: Capsule())
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var areaColumn: some View {
        VStack(spacing: 0) {
            columnHeader("Areas") {
                newAreaName = ""
                isAddingArea = true
            }

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(taxonomy.areas) { area in
                        Button {
                            selectedAreaID = area.id
                            selectedTopicID = nil
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "square.grid.2x2")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text(area.title)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(topics(in: area.id).count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 14, weight: selectedAreaID == area.id ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 11)
                            .frame(height: 38)
                            .background(
                                selectedAreaID == area.id ? Color.white.opacity(0.10) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
        }
        .background(Color.black.opacity(0.08))
    }

    private var topicColumn: some View {
        VStack(spacing: 0) {
            columnHeader("Topics") {
                newTopicName = ""
                isAddingTopic = true
            }
            .disabled(selectedAreaID == nil)

            if let selectedAreaID {
                let areaTopics = topics(in: selectedAreaID)
                if areaTopics.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No topics in this area")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Button("Add Topic") {
                            newTopicName = ""
                            isAddingTopic = true
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(areaTopics) { topic in
                                Button {
                                    selectedTopicID = topic.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(topic.title)
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                            let usage = topicUsageCounts[topic.id, default: 0]
                                            if usage > 0 {
                                                Text("\(usage)")
                                                    .font(.caption2.monospacedDigit())
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        Text(topic.id)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    .font(.system(size: 14, weight: selectedTopicID == topic.id ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        selectedTopicID == topic.id ? Color.white.opacity(0.10) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 9)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(10)
                    }
                }
            } else {
                Text("Select an area")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.opacity(0.035))
    }

    private var inspector: some View {
        Group {
            if let selectedTopicIndex {
                topicInspector(index: selectedTopicIndex)
            } else if let selectedAreaIndex {
                areaInspector(index: selectedAreaIndex)
            } else {
                Text("Select an area or topic to edit it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
    }

    private func areaInspector(index: Int) -> some View {
        let area = taxonomy.areas[index]
        let areaTopicCount = topics(in: area.id).count
        return VStack(alignment: .leading, spacing: 20) {
            inspectorHeading("Area", systemImage: "square.grid.2x2")

            editorField("Name") {
                TextField("Area name", text: areaTitleBinding(index))
                    .textFieldStyle(.roundedBorder)
            }

            identifierField(area.id)

            editorField("Description") {
                TextEditor(text: areaDescriptionBinding(index))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(height: 118)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("\(areaTopicCount) \(areaTopicCount == 1 ? "topic" : "topics")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Delete Area", role: .destructive) {
                deleteArea(index)
            }
            .disabled(areaTopicCount > 0 || taxonomy.areas.count == 1)
            .help(areaTopicCount > 0 ? "Move or delete this area's topics first" : "Delete this area")
        }
    }

    private func topicInspector(index: Int) -> some View {
        let topic = taxonomy.topics[index]
        let usage = topicUsageCounts[topic.id, default: 0]
        return VStack(alignment: .leading, spacing: 20) {
            inspectorHeading("Topic", systemImage: "folder")

            editorField("Name") {
                TextField("Topic name", text: topicTitleBinding(index))
                    .textFieldStyle(.roundedBorder)
            }

            identifierField(topic.id)

            editorField("Area") {
                Picker("", selection: topicAreaBinding(index)) {
                    ForEach(taxonomy.areas) { area in
                        Text(area.title).tag(area.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            editorField("Description") {
                TextEditor(text: topicDescriptionBinding(index))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(height: 132)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            }

            if usage > 0 {
                Label("Used by \(usage) \(usage == 1 ? "item" : "items")", systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Delete Topic", role: .destructive) {
                deleteTopic(index)
            }
            .disabled(usage > 0)
            .help(usage > 0 ? "Remove this topic from its items before deleting it" : "Delete this topic")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Reveal YAML") {
                NSWorkspace.shared.activateFileViewerSelecting([yamlURL])
            }

            Spacer()

            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Button("Save") {
                do {
                    try onSave(taxonomy)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!hasValidTitles)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
    }

    private func columnHeader(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private func inspectorHeading(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 19, weight: .semibold))
    }

    private func editorField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func identifierField(_ id: String) -> some View {
        editorField("Stable identifier") {
            Text(id)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var selectedArea: AreaDefinition? {
        guard let selectedAreaID else { return nil }
        return taxonomy.areas.first { $0.id == selectedAreaID }
    }

    private var selectedAreaIndex: Int? {
        guard let selectedAreaID else { return nil }
        return taxonomy.areas.firstIndex { $0.id == selectedAreaID }
    }

    private var selectedTopicIndex: Int? {
        guard let selectedTopicID else { return nil }
        return taxonomy.topics.firstIndex { $0.id == selectedTopicID }
    }

    private var hasValidTitles: Bool {
        !taxonomy.areas.isEmpty &&
        taxonomy.areas.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
        taxonomy.topics.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func topics(in areaID: String) -> [TopicDefinition] {
        taxonomy.topics.filter { $0.areaID == areaID }
    }

    private func areaTitleBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { taxonomy.areas[index].title },
            set: { taxonomy.areas[index].title = $0 }
        )
    }

    private func areaDescriptionBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { taxonomy.areas[index].description },
            set: { taxonomy.areas[index].description = $0 }
        )
    }

    private func topicTitleBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { taxonomy.topics[index].title },
            set: { taxonomy.topics[index].title = $0 }
        )
    }

    private func topicDescriptionBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { taxonomy.topics[index].description },
            set: { taxonomy.topics[index].description = $0 }
        )
    }

    private func topicAreaBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { taxonomy.topics[index].areaID },
            set: { newAreaID in
                taxonomy.topics[index].areaID = newAreaID
                selectedAreaID = newAreaID
            }
        )
    }

    private func addArea() {
        let title = newAreaName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let id = uniqueID(
            base: TaxonomyStore.slug(title, fallback: "area"),
            existing: Set(taxonomy.areas.map(\.id))
        )
        taxonomy.areas.append(AreaDefinition(id: id, title: title, description: ""))
        selectedAreaID = id
        selectedTopicID = nil
    }

    private func addTopic() {
        guard let selectedAreaID else { return }
        let title = newTopicName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let id = uniqueID(
            base: TaxonomyStore.slug(title, fallback: "topic"),
            existing: Set(taxonomy.topics.map(\.id))
        )
        taxonomy.topics.append(TopicDefinition(
            id: id,
            areaID: selectedAreaID,
            title: title,
            description: ""
        ))
        selectedTopicID = id
    }

    private func deleteArea(_ index: Int) {
        let areaID = taxonomy.areas[index].id
        guard topics(in: areaID).isEmpty, taxonomy.areas.count > 1 else { return }
        taxonomy.areas.remove(at: index)
        selectedAreaID = taxonomy.areas.first?.id
        selectedTopicID = nil
    }

    private func deleteTopic(_ index: Int) {
        let topic = taxonomy.topics[index]
        guard topicUsageCounts[topic.id, default: 0] == 0 else { return }
        taxonomy.topics.remove(at: index)
        selectedTopicID = nil
    }

    private func uniqueID(base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var sequence = 2
        while existing.contains("\(base)-\(sequence)") {
            sequence += 1
        }
        return "\(base)-\(sequence)"
    }
}
