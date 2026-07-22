import AppKit
import SwiftUI

private enum WorkspaceTheme {
    static let frameEdge = adaptive(
        light: color(0.62, 0.63, 0.61),
        dark: color(0.105, 0.11, 0.105)
    )
    static let frameGray = adaptive(
        light: color(0.69, 0.70, 0.68),
        dark: color(0.15, 0.155, 0.145)
    )
    static let frameHighlight = adaptive(
        light: color(0.74, 0.74, 0.71),
        dark: color(0.19, 0.195, 0.18)
    )
    static let sidebarPaper = adaptive(
        light: color(0.82, 0.82, 0.79),
        dark: color(0.185, 0.19, 0.18)
    )
    static let sidebarHighlight = adaptive(
        light: color(0.85, 0.85, 0.82),
        dark: color(0.22, 0.225, 0.21)
    )
    static let documentPaper = adaptive(
        light: color(0.91, 0.90, 0.86),
        dark: color(0.125, 0.13, 0.12)
    )
    static let documentHighlight = adaptive(
        light: color(0.93, 0.92, 0.88),
        dark: color(0.16, 0.165, 0.15)
    )
    static let footerGray = adaptive(
        light: color(0.72, 0.73, 0.70),
        dark: color(0.205, 0.21, 0.195)
    )
    static let activeGray = adaptive(
        light: color(0.47, 0.48, 0.46),
        dark: color(0.43, 0.44, 0.41)
    )
    static let controlFill = adaptive(
        light: color(0.87, 0.87, 0.83),
        dark: color(0.29, 0.30, 0.275)
    )
    static let selectionFill = adaptive(
        light: color(0.74, 0.74, 0.70, alpha: 0.68),
        dark: color(0.37, 0.38, 0.35, alpha: 0.66)
    )
    static let hairline = adaptive(
        light: color(0.18, 0.18, 0.17, alpha: 0.58),
        dark: color(0.82, 0.81, 0.76, alpha: 0.31)
    )
    static let primaryText = adaptive(
        light: color(0.12, 0.12, 0.115),
        dark: color(0.91, 0.90, 0.86)
    )
    static let secondaryText = adaptive(
        light: color(0.27, 0.27, 0.25),
        dark: color(0.73, 0.72, 0.68)
    )
    static let tertiaryText = adaptive(
        light: color(0.43, 0.43, 0.40),
        dark: color(0.58, 0.58, 0.54)
    )
    static let grain = adaptive(
        light: color(0, 0, 0),
        dark: color(1, 1, 1)
    )

    private static func color(
        _ red: CGFloat,
        _ green: CGFloat,
        _ blue: CGFloat,
        alpha: CGFloat = 1
    ) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private enum LibraryViewMode: String, CaseIterable, Identifiable {
    case recent
    case topics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return "Recent"
        case .topics: return "Topics"
        }
    }
}

private struct DocumentVariant: Identifiable {
    var title: String
    var target: URL

    var id: URL { target }
}

struct SharedLibraryWorkspaceView: View {
    @EnvironmentObject var env: AppEnvironment

    @AppStorage("libraryMarkdownMode") private var libraryMarkdownMode = "markdown"
    @AppStorage("libraryDarkMode") private var libraryDarkMode = false
    @State private var libraryViewModeRaw = LibraryViewMode.recent.rawValue
    @State private var knowledgeSnapshot = KnowledgeSnapshot.empty
    @State private var expandedItems: Set<String> = []
    @State private var selectedURL: URL?
    @State private var editorText = ""
    @State private var selectedMarkdownDocument = MarkdownDocument.parse("")
    @State private var selectedWordCount = 0
    @State private var searchText = ""
    @State private var isLoadingSelection = false
    @State private var isEditingMarkdown = false
    @State private var editorFocusRequest = 0
    @State private var errorMessage: String?
    @State private var copyFeedbackVisible = false
    @State private var copyFeedbackGeneration = 0
    @State private var knowledgeRefreshTask: Task<Void, Never>?
    @State private var documentSyncTask: Task<Void, Never>?

    private let sidebarWidth: CGFloat = 305
    private let outerInset: CGFloat = 12

    var body: some View {
        ZStack {
            workspaceBackdrop

            HStack(alignment: .top, spacing: 10) {
                leftPane
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, outerInset)
                    .padding(.vertical, outerInset)

                contentPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, outerInset)
                    .padding(.vertical, outerInset)
            }

        }
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .preferredColorScheme(libraryDarkMode ? .dark : .light)
        .alert("Workspace error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: loadWorkspace)
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            reloadTreePreservingSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .processingDidFail)) { notification in
            errorMessage = notification.userInfo?["message"] as? String
                ?? "The capture could not be processed."
        }
        .onDisappear {
            knowledgeRefreshTask?.cancel()
            documentSyncTask?.cancel()
        }
    }

    private var workspaceBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    WorkspaceTheme.frameEdge,
                    WorkspaceTheme.frameGray,
                    WorkspaceTheme.frameHighlight
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            PaperGrain(color: WorkspaceTheme.grain, opacity: 0.045)
        }
        .ignoresSafeArea()
    }

    private var sidebarPanelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        return ZStack {
            shape.fill(
                LinearGradient(
                    colors: [
                        WorkspaceTheme.sidebarHighlight,
                        WorkspaceTheme.sidebarPaper
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            PaperGrain(color: WorkspaceTheme.grain, opacity: 0.040)
                .clipShape(shape)

            shape.stroke(WorkspaceTheme.hairline, lineWidth: 0.85)
        }
    }

    private var documentPanelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        return ZStack {
            shape.fill(
                LinearGradient(
                    colors: [
                        WorkspaceTheme.documentHighlight,
                        WorkspaceTheme.documentPaper
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            PaperGrain(color: WorkspaceTheme.grain, opacity: 0.032)
                .clipShape(shape)

            shape.stroke(WorkspaceTheme.hairline, lineWidth: 0.85)
        }
    }

    private var leftPane: some View {
        sidebar
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchControls
                .padding(.horizontal, 22)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleTreeItems) { item in
                            fileTreeRows(item)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if libraryViewMode == .recent {
                            proxy.scrollTo(WorkspaceItem.virtualID("main"), anchor: .top)
                        }
                    }
                }
            }

            sidebarFloatingCommands
                .padding(.horizontal, 16)
        }
        .padding(.top, 66)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(sidebarPanelBackground)
        .overlay(alignment: .topLeading) {
            WorkspaceWindowControls()
                .padding(.top, 26)
                .padding(.leading, 26)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .contextMenu {
            Button("Refresh") {
                reloadTreePreservingSelection()
            }
            Button("Reveal Workspace in Finder") {
                reveal(env.settings.workspaceRootURL)
            }
        }
    }

    private var sidebarFloatingCommands: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sidebarFloatingCommand(
                    title: "Agent",
                    systemImage: "sparkles",
                    isSelected: false,
                    action: launchAgent
                )
                GitSyncSidebarButton(coordinator: env.gitSyncCoordinator)
            }
            GitSyncSidebarStatus(coordinator: env.gitSyncCoordinator)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchControls: some View {
        VStack(spacing: 13) {
            searchInput
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    Capsule(style: .continuous)
                        .fill(WorkspaceTheme.controlFill.opacity(0.66))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(WorkspaceTheme.hairline, lineWidth: 0.9)
                )

            libraryModePicker
        }
    }

    private var libraryModePicker: some View {
        HStack(spacing: 0) {
            ForEach(LibraryViewMode.allCases) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        libraryViewModeRaw = mode.rawValue
                    }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 13, weight: libraryViewMode == mode ? .semibold : .regular))
                        .foregroundStyle(libraryViewMode == mode ? Color.white.opacity(0.96) : WorkspaceTheme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if libraryViewMode == mode {
                                Capsule(style: .continuous)
                                    .fill(WorkspaceTheme.activeGray)
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(WorkspaceTheme.hairline, lineWidth: 0.65)
                                    )
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(height: 35)
        .background(WorkspaceTheme.controlFill.opacity(0.48), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(WorkspaceTheme.hairline, lineWidth: 1)
        )
    }

    private var searchInput: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(WorkspaceTheme.secondaryText)

            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(WorkspaceTheme.primaryText)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(WorkspaceTheme.tertiaryText)
                .help("Clear search")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 11)
        .frame(height: 48)
    }

    private func sidebarFloatingCommand(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .foregroundStyle(WorkspaceTheme.primaryText)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                Capsule(style: .continuous)
                    .fill(WorkspaceTheme.controlFill.opacity(isSelected ? 0.92 : 0.56))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(WorkspaceTheme.hairline, lineWidth: 0.9)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func fileTreeRows(_ item: WorkspaceItem) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 2) {
                FileTreeRow(
                    item: item,
                    isExpanded: expandedItems.contains(item.id),
                    isSelected: isWorkspaceItemSelected(item),
                    onToggle: { toggle(item) },
                    onSelect: { select(item.url) }
                )
                .contextMenu {
                    fileContextMenu(for: item)
                }

                if item.isDirectory, expandedItems.contains(item.id) {
                    ForEach(item.children) { child in
                        fileTreeRows(child)
                    }
                }
            }
            .id(item.id)
        )
    }

    private func isWorkspaceItemSelected(_ item: WorkspaceItem) -> Bool {
        guard let selectedURL else { return false }
        if selectedURL.standardizedFileURL == item.url.standardizedFileURL {
            return true
        }
        guard item.isRecordAlias, let selectedCaptureSourceURL else { return false }
        return selectedCaptureSourceURL.standardizedFileURL == item.url.standardizedFileURL
    }

    @ViewBuilder
    private func fileContextMenu(for item: WorkspaceItem) -> some View {
        if item.isVirtualFolder {
            EmptyView()
        } else {
            Button("Copy Path") {
                copyPath(item.url)
            }
            Button("Reveal in Finder") {
                reveal(item.url)
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                moveCaptureToTrash(item.url)
            }
        }
    }

    private var contentPane: some View {
        editorPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            if currentSelectedIsMarkdown && !isEditingMarkdown {
                markdownBodyEditor
            } else {
                rawEditor
            }

            editorFooter
        }
        .background(documentPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .onChange(of: editorText) { _, value in
            guard !isLoadingSelection else { return }
            updateDerivedDocumentState(for: value)
            saveSelectedText(value)
        }
        .contextMenu {
            if currentSelectedIsMarkdown {
                Button(isEditingMarkdown ? "Markdown Mode" : "Source Mode") {
                    setMarkdownSourceMode(!isEditingMarkdown)
                }
            }
            if let selectedURL, !selectedIsDirectory {
                Button("Copy Path") {
                    copyPath(selectedURL)
                }
                Button("Reveal in Finder") {
                    reveal(selectedURL)
                }
            }
        }
    }

    private var markdownBodyEditor: some View {
        EditableMarkdownWebView(
            markdown: Binding(
                get: { markdownBodyText },
                set: { updateMarkdownBody($0) }
            ),
            baseURL: selectedURL?.deletingLastPathComponent(),
            focusRequest: editorFocusRequest,
            isDarkMode: libraryDarkMode
        )
    }

    private var editorFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(WorkspaceTheme.hairline.opacity(0.72))
                .frame(height: 1)

            HStack(spacing: 14) {
                Text("\(wordCount) \(wordCount == 1 ? "word" : "words")")
                    .foregroundStyle(WorkspaceTheme.primaryText)
                    .frame(minWidth: 92, alignment: .leading)

                Spacer()

                if !documentVariants.isEmpty {
                    documentVariantSlider
                }

                if currentSelectedIsMarkdown {
                    markdownModeToggle
                } else {
                    Text(fileKindLabel)
                        .foregroundStyle(WorkspaceTheme.secondaryText)
                }

                copyPathButton

                if let processableRecord {
                    processButton(for: processableRecord)
                }
            }
            .font(.system(size: 14))
            .frame(height: 61)
            .padding(.horizontal, 36)
        }
        .background(WorkspaceTheme.footerGray)
    }

    private var documentVariantSlider: some View {
        HStack(spacing: 8) {
            Text("Concise")
                .foregroundStyle(WorkspaceTheme.primaryText)

            Slider(
                value: documentVariantBinding,
                in: 0...Double(max(documentVariants.count - 1, 1)),
                step: 1
            )
            .tint(WorkspaceTheme.activeGray)
            .frame(width: 180)
            .accessibilityLabel("Summary detail")
            .accessibilityValue(selectedDocumentVariantTitle)

            Text("Original")
                .foregroundStyle(WorkspaceTheme.primaryText)
        }
        .font(.system(size: 12, weight: .medium))
        .help("Current version: \(selectedDocumentVariantTitle)")
    }

    private func processButton(for record: KnowledgeRecord) -> some View {
        let isProcessing = env.processingCoordinator.isProcessing(record)
        let title = record.topicIDs.isEmpty ? "Organize capture" : "Reorganize capture"

        return Button {
            env.processingCoordinator.process(
                record: record,
                workspaceRootURL: env.settings.workspaceRootURL
            )
        } label: {
            Image(systemName: isProcessing ? "hourglass" : "arrow.clockwise")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(WorkspaceTheme.primaryText.opacity(0.90))
                .frame(width: 36, height: 36)
                .background(footerButtonBackground)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        .accessibilityLabel(isProcessing ? "Organizing capture" : title)
        .help(isProcessing
            ? "This capture is being organized in the background"
            : "\(title): regenerate all four summaries and assign its topic")
    }

    private var markdownModeToggle: some View {
        Button {
            setMarkdownSourceMode(!isEditingMarkdown)
        } label: {
            Text(isEditingMarkdown ? "Source" : "Markdown")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(WorkspaceTheme.primaryText.opacity(0.92))
            .padding(.horizontal, 14)
            .frame(minWidth: 112, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(WorkspaceTheme.controlFill.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(WorkspaceTheme.hairline, lineWidth: 0.9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isEditingMarkdown ? "Switch to Markdown" : "Switch to Source")
    }

    private func setMarkdownSourceMode(_ sourceMode: Bool) {
        isEditingMarkdown = sourceMode
        libraryMarkdownMode = sourceMode ? "source" : "markdown"
        editorFocusRequest += 1
    }

    private var copyPathButton: some View {
        Button {
            copySelectedPath()
        } label: {
            Image(systemName: copyFeedbackVisible ? "checkmark" : "doc.on.doc")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(WorkspaceTheme.primaryText.opacity(0.92))
                .frame(width: 36, height: 36)
                .background(footerButtonBackground)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(selectedURL == nil)
        .animation(.easeInOut(duration: 0.14), value: copyFeedbackVisible)
        .help("Copy path")
    }

    private var rawEditor: some View {
        PlainTextEditor(
            text: $editorText,
            font: contentEditorFont,
            isEditable: selectedURL != nil && !selectedIsDirectory,
            focusRequest: editorFocusRequest,
            textColor: rawEditorTextColor,
            insertionPointColor: rawEditorTextColor
        )
            .padding(.horizontal, 40)
            .padding(.vertical, 46)
    }

    private var contentEditorFont: NSFont {
        NSFont(name: "New York", size: 19) ?? NSFont.systemFont(ofSize: 19)
    }

    private var rawEditorTextColor: NSColor {
        libraryDarkMode
            ? NSColor(srgbRed: 0.91, green: 0.90, blue: 0.86, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.12, blue: 0.115, alpha: 1)
    }

    private var footerButtonBackground: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(WorkspaceTheme.controlFill.opacity(0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(WorkspaceTheme.hairline, lineWidth: 0.85)
            )
    }

    private var workspaceName: String {
        let name = env.settings.workspaceRootURL.lastPathComponent
        return name.isEmpty ? "workspace" : name
    }

    private var selectedTitle: String {
        guard let selectedURL else { return workspaceName }
        return selectedURL.lastPathComponent.isEmpty ? workspaceName : selectedURL.lastPathComponent
    }

    private var fileKindLabel: String {
        guard let selectedURL, !selectedIsDirectory else { return "Folder" }
        let ext = selectedURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.isEmpty ? "Text" : ext.uppercased()
    }

    private var visibleTreeItems: [WorkspaceItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return collectionTreeItems }
        return collectionTreeItems.compactMap { $0.filtered(matching: query) }
    }

    private var collectionTreeItems: [WorkspaceItem] {
        if libraryViewMode == .topics {
            return topicLibraryChildren
        }

        let library = WorkspaceItem.virtualFolder(
            id: "main",
            displayName: "Library",
            systemImage: "clock",
            badgeCount: libraryRecords.count,
            children: recentLibraryChildren
        )
        return [library]
    }

    private var libraryRecords: [KnowledgeRecord] {
        knowledgeSnapshot.records
    }

    private var recentLibraryChildren: [WorkspaceItem] {
        libraryRecords.map(WorkspaceItem.recordAlias)
    }

    private var topicLibraryChildren: [WorkspaceItem] {
        let sourceRecords = libraryRecords.filter { $0.typeID == "source" }
        let topicNames = Dictionary(uniqueKeysWithValues: knowledgeSnapshot.topics.map { ($0.id, $0.title) })
        let grouped = Dictionary(grouping: sourceRecords) { $0.topicIDs.first ?? "uncategorized" }
        let folders = grouped.compactMap { topicID, records -> WorkspaceItem? in
            guard topicID != "uncategorized" else { return nil }
            let name = topicNames[topicID] ?? TaxonomyStore.titleized(topicID)
            return WorkspaceItem.virtualFolder(
                id: "topic:\(topicID)",
                displayName: name,
                systemImage: "folder",
                badgeCount: records.count,
                children: records.map(WorkspaceItem.recordAlias)
            )
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        return folders
    }

    private var libraryViewMode: LibraryViewMode {
        LibraryViewMode(rawValue: libraryViewModeRaw) ?? .recent
    }

    private var currentSelectedIsMarkdown: Bool {
        guard let selectedURL, !selectedIsDirectory else { return false }
        return selectedURL.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame
    }

    private var selectedIsDirectory: Bool {
        guard let selectedURL else { return false }
        return isDirectory(selectedURL)
    }

    private var selectedFileURL: URL? {
        guard let selectedURL, !isDirectory(selectedURL) else { return nil }
        return selectedURL
    }

    private var documentVariants: [DocumentVariant] {
        guard let sourceURL = selectedCaptureSourceURL else { return [] }

        var variants: [DocumentVariant] = []
        let summariesFolder = env.settings.gatherFolderURL
            .appendingPathComponent("summaries", isDirectory: true)
        for level in SummaryDetailLevel.allCases {
            let url = summariesFolder
                .appendingPathComponent(level.storageDirectoryName, isDirectory: true)
                .appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: url.path) {
                variants.append(DocumentVariant(
                    title: documentVariantTitle(for: level),
                    target: url
                ))
            }
        }

        if variants.isEmpty {
            let legacyURL = summariesFolder.appendingPathComponent(sourceURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                variants.append(DocumentVariant(
                    title: "Concise",
                    target: legacyURL
                ))
            }
        }
        variants.append(DocumentVariant(title: "Original", target: sourceURL))
        return variants.count > 1 ? variants : []
    }

    private var documentVariantBinding: Binding<Double> {
        Binding(
            get: {
                guard let selectedURL,
                      let index = documentVariants.firstIndex(where: {
                          $0.target.standardizedFileURL == selectedURL.standardizedFileURL
                      }) else {
                    return 0
                }
                return Double(index)
            },
            set: { value in
                let index = min(max(Int(value.rounded()), 0), documentVariants.count - 1)
                selectDocumentVariant(documentVariants[index].target)
            }
        )
    }

    private func documentVariantTitle(for level: SummaryDetailLevel) -> String {
        switch level {
        case .brief:
            return "Concise"
        case .concise:
            return "Standard"
        case .detailed:
            return "Detailed"
        case .comprehensive:
            return "Comprehensive"
        }
    }

    private var selectedDocumentVariantTitle: String {
        guard let selectedURL else { return "Summary" }
        return documentVariants.first {
            $0.target.standardizedFileURL == selectedURL.standardizedFileURL
        }?.title ?? "Summary"
    }

    private var selectedCaptureSourceURL: URL? {
        guard let selectedFileURL,
              selectedFileURL.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame else {
            return nil
        }

        let fileURL = selectedFileURL.standardizedFileURL
        let parentURL = fileURL.deletingLastPathComponent().standardizedFileURL
        let gatherFolder = env.settings.gatherFolderURL.standardizedFileURL
        if parentURL.path == gatherFolder.path {
            return isPrimaryRecordURL(fileURL) ? fileURL : nil
        }

        if parentURL.lastPathComponent == "summaries",
           parentURL.deletingLastPathComponent().standardizedFileURL.path == gatherFolder.path {
            return gatherFolder.appendingPathComponent(fileURL.lastPathComponent)
        }

        let summariesFolder = parentURL.deletingLastPathComponent().standardizedFileURL
        if summariesFolder.lastPathComponent == "summaries",
           summariesFolder.deletingLastPathComponent().standardizedFileURL.path == gatherFolder.path,
           SummaryDetailLevel.allCases.contains(where: {
               $0.storageDirectoryName == parentURL.lastPathComponent
           }) {
            return gatherFolder.appendingPathComponent(fileURL.lastPathComponent)
        }
        return nil
    }

    private var processableRecord: KnowledgeRecord? {
        guard let sourceURL = selectedCaptureSourceURL else { return nil }
        let selectedPath = sourceURL.standardizedFileURL.path
        return knowledgeSnapshot.records.first {
            $0.typeID == "source" && $0.fileURL.standardizedFileURL.path == selectedPath
        }
    }

    private func isPrimaryRecordURL(_ url: URL) -> Bool {
        let parentURL = url.deletingLastPathComponent().standardizedFileURL
        if parentURL.path == env.settings.gatherFolderURL.standardizedFileURL.path {
            return !["TAGS.md", "AGENTS.md"].contains { excluded in
                url.lastPathComponent.localizedCaseInsensitiveCompare(excluded) == .orderedSame
            }
        }

        return false
    }

    private var wordCount: Int {
        selectedWordCount
    }

    private var markdownBodyText: String {
        selectedMarkdownDocument.body
    }

    private func updateMarkdownBody(_ body: String) {
        var document = selectedMarkdownDocument
        document.body = body
        selectedMarkdownDocument = document
        selectedWordCount = Self.countWords(in: body)
        editorText = document.serialized()
    }

    private func updateDerivedDocumentState(for text: String, isMarkdown: Bool? = nil) {
        if isMarkdown ?? currentSelectedIsMarkdown {
            let document = MarkdownDocument.parse(text)
            selectedMarkdownDocument = document
            selectedWordCount = Self.countWords(in: document.body)
        } else {
            selectedMarkdownDocument = MarkdownDocument(properties: [], body: text, hasFrontmatter: false)
            selectedWordCount = Self.countWords(in: text)
        }
    }

    private static func countWords(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private func loadWorkspace() {
        do {
            try env.settings.ensureWorkspace()
            reloadTreePreservingSelection()
            expandedItems.insert(WorkspaceItem.virtualID("main"))
            if selectedURL == nil {
                selectInitialFile()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadTreePreservingSelection() {
        do {
            try refreshKnowledgeSnapshot()
            if let selectedURL, !FileManager.default.fileExists(atPath: selectedURL.path) {
                self.selectedURL = nil
                editorText = ""
                updateDerivedDocumentState(for: "", isMarkdown: false)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshKnowledgeSnapshot() throws {
        knowledgeSnapshot = try env.knowledgeStore.snapshot(workspaceRootURL: env.settings.workspaceRootURL)
    }

    private func scheduleKnowledgeRefresh() {
        knowledgeRefreshTask?.cancel()
        knowledgeRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                do {
                    try refreshKnowledgeSnapshot()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func toggle(_ item: WorkspaceItem) {
        if expandedItems.contains(item.id) {
            expandedItems.remove(item.id)
        } else {
            expandedItems.insert(item.id)
        }
        if !item.isDirectory {
            select(item.url)
        }
    }

    private func select(
        _ url: URL,
        focusEditor: Bool = false,
        prefersShortestSummary: Bool = true
    ) {
        if !focusEditor {
            clearEditorFocus()
        }

        let targetURL = prefersShortestSummary ? shortestSummaryURL(for: url) ?? url : url
        selectedURL = targetURL
        let isMarkdown = targetURL.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame
        isEditingMarkdown = isMarkdown && libraryMarkdownMode == "source"
        guard !isDirectory(targetURL) else {
            editorText = ""
            updateDerivedDocumentState(for: "", isMarkdown: false)
            isEditingMarkdown = false
            return
        }

        do {
            isLoadingSelection = true
            let text = try String(contentsOf: targetURL, encoding: .utf8)
            editorText = text
            updateDerivedDocumentState(for: text, isMarkdown: isMarkdown)
            isLoadingSelection = false
            if focusEditor {
                DispatchQueue.main.async {
                    editorFocusRequest += 1
                }
            }
        } catch {
            isLoadingSelection = false
            editorText = ""
            updateDerivedDocumentState(for: "", isMarkdown: false)
            errorMessage = error.localizedDescription
        }
    }

    private func shortestSummaryURL(for url: URL) -> URL? {
        let sourceURL = url.standardizedFileURL
        guard sourceURL.deletingLastPathComponent().path ==
                env.settings.gatherFolderURL.standardizedFileURL.path else {
            return nil
        }

        let summariesFolder = env.settings.gatherFolderURL
            .appendingPathComponent("summaries", isDirectory: true)
        let briefURL = summariesFolder
            .appendingPathComponent(SummaryDetailLevel.brief.storageDirectoryName, isDirectory: true)
            .appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: briefURL.path) {
            return briefURL
        }

        let legacyURL = summariesFolder.appendingPathComponent(sourceURL.lastPathComponent)
        return FileManager.default.fileExists(atPath: legacyURL.path) ? legacyURL : nil
    }

    private func clearEditorFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func launchAgent() {
        do {
            try AgentLauncher.launch(
                commandTemplate: env.settings.agentCommand,
                workspaceURL: env.settings.workspaceRootURL
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveSelectedText(_ text: String) {
        guard let selectedURL, !isDirectory(selectedURL) else { return }
        do {
            try text.write(to: selectedURL, atomically: true, encoding: .utf8)
            if selectedURL.pathExtension.localizedCaseInsensitiveCompare("md") == .orderedSame {
                scheduleKnowledgeRefresh()
            }
            documentSyncTask?.cancel()
            documentSyncTask = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    env.gitSyncCoordinator.requestAutomaticSync(reason: "document edited")
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectDocumentVariant(_ url: URL) {
        select(url, prefersShortestSummary: false)
    }

    private func selectInitialFile() {
        guard let record = libraryRecords.first else { return }
        select(record.fileURL)
    }

    private func reveal(_ url: URL) {
        if isDirectory(url) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    private func copySelectedPath() {
        guard let selectedURL else { return }
        copyPath(selectedURL)
        showCopyFeedback()
    }

    private func showCopyFeedback() {
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        copyFeedbackVisible = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard copyFeedbackGeneration == generation else { return }
            copyFeedbackVisible = false
        }
    }

    private func relativePath(for url: URL) -> String? {
        let root = env.settings.workspaceRootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    private func moveCaptureToTrash(_ url: URL) {
        do {
            try env.libraryStore.deleteCapture(
                at: url,
                workspaceRootURL: env.settings.workspaceRootURL
            )
            reloadTreePreservingSelection()
            if selectedURL == url {
                selectedURL = nil
                editorText = ""
                updateDerivedDocumentState(for: "", isMarkdown: false)
            }
            env.gitSyncCoordinator.requestAutomaticSync(reason: "capture deleted")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private struct MarkdownDocument {
    var properties: [MarkdownProperty]
    var body: String
    var hasFrontmatter: Bool

    static func parse(_ text: String) -> MarkdownDocument {
        guard text.hasPrefix("---\n"),
              let endRange = text.dropFirst(4).range(of: "\n---\n") else {
            return MarkdownDocument(properties: [], body: text, hasFrontmatter: false)
        }

        let metadataStart = text.index(text.startIndex, offsetBy: 4)
        let metadata = String(text[metadataStart..<endRange.lowerBound])
        var body = String(text[endRange.upperBound...])
        if body.hasPrefix("\r\n") {
            body.removeFirst(2)
        } else if body.hasPrefix("\n") {
            body.removeFirst()
        }
        return MarkdownDocument(properties: parseProperties(metadata), body: body, hasFrontmatter: true)
    }

    func serialized() -> String {
        guard hasFrontmatter || !properties.isEmpty else {
            return body
        }

        var lines = ["---"]
        for property in properties where !property.key.isEmpty {
            lines.append(contentsOf: frontmatterLines(for: property))
        }
        lines.append("---")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    private static func parseProperties(_ metadata: String) -> [MarkdownProperty] {
        var properties: [MarkdownProperty] = []
        var currentKey: String?
        var currentValue: String = ""
        var listValues: [String] = []

        func finish() {
            guard let currentKey else { return }
            let values = listValues.isEmpty ? parseValues(currentValue) : listValues.map(parseScalar)
            properties.append(MarkdownProperty(key: currentKey, values: values))
        }

        for line in metadata.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("- ") {
                listValues.append(String(trimmed.dropFirst(2)))
                continue
            }

            guard let separator = line.firstIndex(of: ":") else { continue }
            finish()
            currentKey = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            currentValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            listValues = []
        }

        finish()
        return properties
    }

    private func frontmatterLines(for property: MarkdownProperty) -> [String] {
        if property.values.isEmpty {
            return ["\(property.key): []"]
        }

        if property.values.count == 1 {
            return ["\(property.key): \(Self.yamlString(property.values[0]))"]
        }

        return ["\(property.key):"]
            + property.values.map { "  - \(Self.yamlString($0))" }
    }

    private static func parseValues(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[]" else { return [] }

        if trimmed.hasPrefix("["),
           trimmed.hasSuffix("]"),
           let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return decoded
        }

        return [parseScalar(trimmed)]
    }

    private static func parseScalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\""),
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return trimmed
        }

        return decoded
    }

    private static func yamlString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

private struct MarkdownProperty: Identifiable, Hashable {
    var key: String
    var values: [String]

    var id: String { "\(key):\(values.joined(separator: "\u{1f}"))" }

    var displayKey: String {
        key.replacingOccurrences(of: "_", with: " ")
    }

    var displayValue: String {
        values.joined(separator: ", ")
    }
}

private struct GitSyncSidebarButton: View {
    @ObservedObject var coordinator: GitSyncCoordinator

    var body: some View {
        Button {
            coordinator.syncNow()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: coordinator.state.isBusy ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                Text("Sync Now")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .foregroundStyle(WorkspaceTheme.primaryText)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                Capsule(style: .continuous)
                    .fill(WorkspaceTheme.controlFill.opacity(0.56))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(WorkspaceTheme.hairline, lineWidth: 0.9)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(coordinator.state.isBusy)
        .help("Commit, fetch, rebase, and push workspace changes")
    }
}

private struct GitSyncSidebarStatus: View {
    @ObservedObject var coordinator: GitSyncCoordinator

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: statusSymbol)
                .font(.system(size: 11, weight: .semibold))
            Text(coordinator.state.message)
                .font(.system(size: 11))
                .lineLimit(2)
        }
        .foregroundStyle(WorkspaceTheme.secondaryText)
        .padding(.horizontal, 5)
        .help(coordinator.state.message)
    }

    private var statusSymbol: String {
        switch coordinator.state {
        case .checking, .syncing:
            return "arrow.triangle.2.circlepath"
        case .ready, .succeeded:
            return "checkmark.circle"
        case .needsSetup:
            return "wrench.and.screwdriver"
        case .unavailable, .failed:
            return "exclamationmark.triangle"
        }
    }
}

private struct WorkspaceWindowControls: View {
    private enum Control: Hashable {
        case close
        case minimize
        case zoom

        var color: Color {
            switch self {
            case .close: return Color(red: 1.00, green: 0.37, blue: 0.34)
            case .minimize: return Color(red: 1.00, green: 0.74, blue: 0.18)
            case .zoom: return Color(red: 0.16, green: 0.78, blue: 0.25)
            }
        }

        var symbol: String {
            switch self {
            case .close: return "xmark"
            case .minimize: return "minus"
            case .zoom: return "plus"
            }
        }

        var label: String {
            switch self {
            case .close: return "Close"
            case .minimize: return "Minimize"
            case .zoom: return "Zoom"
            }
        }
    }

    @State private var hoveredControl: Control?

    var body: some View {
        HStack(spacing: 9) {
            controlButton(.close)
            controlButton(.minimize)
            controlButton(.zoom)
        }
    }

    private func controlButton(_ control: Control) -> some View {
        Button {
            perform(control)
        } label: {
            ZStack {
                Circle()
                    .fill(control.color)

                if hoveredControl == control {
                    Image(systemName: control.symbol)
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.58))
                }
            }
            .frame(width: 13, height: 13)
            .overlay(
                Circle()
                    .stroke(Color.black.opacity(0.13), lineWidth: 0.5)
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredControl = isHovering ? control : nil
        }
        .accessibilityLabel(control.label)
        .help(control.label)
    }

    private func perform(_ control: Control) {
        guard let window = NSApp.keyWindow else { return }
        switch control {
        case .close:
            window.performClose(nil)
        case .minimize:
            window.miniaturize(nil)
        case .zoom:
            window.zoom(nil)
        }
    }
}

private struct PaperGrain: View {
    let color: Color
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            var state: UInt64 = 0x6A09E667F3BCC909

            func nextUnit() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state % 10_000) / 10_000
            }

            let pointCount = min(1_100, max(220, Int(size.width * size.height / 1_900)))
            for _ in 0..<pointCount {
                let x = nextUnit() * size.width
                let y = nextUnit() * size.height
                let diameter = 0.35 + (nextUnit() * 0.75)
                let alpha = opacity * (0.35 + (nextUnit() * 0.65))
                let rect = CGRect(x: x, y: y, width: diameter, height: diameter)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FileTreeRow: View {
    let item: WorkspaceItem
    let isExpanded: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void

    var body: some View {
        Button {
            item.isDirectory ? onToggle() : onSelect()
        } label: {
            Group {
                if item.isLibrarySection {
                    librarySectionRow
                } else {
                    standardRow
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var librarySectionRow: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 12)
                .foregroundStyle(WorkspaceTheme.secondaryText)

            Text(item.displayName.uppercased())
                .font(.system(size: 11, weight: .medium))
                .kerning(3.5)
                .foregroundStyle(WorkspaceTheme.secondaryText)

            Spacer(minLength: 8)

            badge
        }
        .frame(height: 38)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    private var standardRow: some View {
        HStack(spacing: 8) {
            if item.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 12)
                    .foregroundStyle(WorkspaceTheme.secondaryText)
            } else {
                Spacer()
                    .frame(width: 12)
            }

            if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(item.isVirtualFolder ? WorkspaceTheme.secondaryText : WorkspaceTheme.secondaryText.opacity(0.78))
            }

            Text(item.displayName)
                .font(.system(size: item.isRecordAlias ? 15 : 16, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(item.isRecordAlias ? .tail : .middle)

            Spacer(minLength: 0)

            badge
        }
        .foregroundStyle(isSelected ? WorkspaceTheme.primaryText : WorkspaceTheme.primaryText.opacity(0.82))
        .frame(height: 37)
        .padding(.horizontal, 12)
        .background(selectionBackground)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var badge: some View {
        if let badgeCount = item.badgeCount {
            Text("\(badgeCount)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WorkspaceTheme.secondaryText)
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
                .background(WorkspaceTheme.controlFill.opacity(0.78), in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(WorkspaceTheme.hairline.opacity(0.55), lineWidth: 0.65)
                )
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WorkspaceTheme.selectionFill)
        }
    }
}

private struct WorkspaceItem: Identifiable, Hashable {
    private enum Kind: Hashable {
        case virtualFolder
        case recordAlias
    }

    let url: URL
    let displayName: String
    let isDirectory: Bool
    let children: [WorkspaceItem]
    private let kind: Kind
    private let identity: String?
    let systemImage: String?
    let badgeCount: Int?

    var id: String { identity ?? url.path }
    var isVirtualFolder: Bool { kind == .virtualFolder }
    var isRecordAlias: Bool { kind == .recordAlias }
    var isLibrarySection: Bool { id == Self.virtualID("main") }

    private init(
        url: URL,
        displayName: String,
        isDirectory: Bool,
        children: [WorkspaceItem],
        kind: Kind,
        identity: String? = nil,
        systemImage: String? = nil,
        badgeCount: Int? = nil
    ) {
        self.url = url
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.children = children
        self.kind = kind
        self.identity = identity
        self.systemImage = systemImage
        self.badgeCount = badgeCount
    }

    static func virtualID(_ value: String) -> String {
        "virtual:\(value)"
    }

    static func virtualFolder(
        id: String,
        displayName: String,
        systemImage: String,
        badgeCount: Int,
        children: [WorkspaceItem]
    ) -> WorkspaceItem {
        WorkspaceItem(
            url: URL(fileURLWithPath: "/__sharedlibrary_virtual__/\(id)"),
            displayName: displayName,
            isDirectory: true,
            children: children,
            kind: .virtualFolder,
            identity: virtualID(id),
            systemImage: systemImage,
            badgeCount: badgeCount
        )
    }

    static func recordAlias(_ record: KnowledgeRecord) -> WorkspaceItem {
        WorkspaceItem(
            url: record.fileURL,
            displayName: record.title,
            isDirectory: false,
            children: [],
            kind: .recordAlias,
            identity: "virtual:record:\(record.id)",
            systemImage: "doc.text",
            badgeCount: nil
        )
    }

    func filtered(matching query: String, including allowedFilePaths: Set<String>? = nil) -> WorkspaceItem? {
        let queryIsEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let matchesQuery = queryIsEmpty || displayName.localizedCaseInsensitiveContains(query)

        if !isDirectory {
            let matchesTopic = allowedFilePaths?.contains(url.standardizedFileURL.path) ?? true
            return matchesQuery && matchesTopic ? self : nil
        }

        let matchingChildren = children.compactMap {
            $0.filtered(matching: query, including: allowedFilePaths)
        }

        if allowedFilePaths != nil {
            guard !matchingChildren.isEmpty else { return nil }
            return replacingChildren(matchingChildren)
        }

        guard matchesQuery || !matchingChildren.isEmpty else { return nil }
        return replacingChildren(matchesQuery ? children : matchingChildren)
    }

    private func replacingChildren(_ children: [WorkspaceItem]) -> WorkspaceItem {
        WorkspaceItem(
            url: url,
            displayName: displayName,
            isDirectory: isDirectory,
            children: children,
            kind: kind,
            identity: identity,
            systemImage: systemImage,
            badgeCount: badgeCount
        )
    }

}
