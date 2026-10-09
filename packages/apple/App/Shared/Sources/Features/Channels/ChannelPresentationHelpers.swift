import Foundation
import SwiftUI
import BrieflyCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

func extendsSidebarSelection() -> Bool {
    #if os(macOS)
    NSEvent.modifierFlags.contains(.command)
    #else
    false
    #endif
}

struct FaviconImage: View {
    let url: URL
    let fallback: String

    var body: some View {
        #if os(macOS)
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(Rectangle())
        } else {
            fallbackImage
        }
        #else
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(Rectangle())
        } else {
            fallbackImage
        }
        #endif
    }

    private var fallbackImage: some View {
        Image(systemName: fallback)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 17)
    }
}

struct SidebarEmpty: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
            Text(title)
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}

struct ChannelCandidateDocument: View {
    private enum Decision: Equatable {
        case accept
        case reject
        case loadMore
        case refresh
    }

    @Bindable var model: LibraryModel
    let channelID: String
    let fallbackChannel: LibraryChannel?
    let showsNavigationHeader: Bool
    @State private var deciding: Decision?
    @State private var skippedItemIDs = Set<String>()
    @State private var resolvedPreviewText = [String: String]()

    init(
        model: LibraryModel,
        channelID: String,
        fallbackChannel: LibraryChannel? = nil,
        showsNavigationHeader: Bool = true
    ) {
        self.model = model
        self.channelID = channelID
        self.fallbackChannel = fallbackChannel
        self.showsNavigationHeader = showsNavigationHeader
    }

    private var isAllChannels: Bool {
        channelID.isEmpty
    }

    private var currentChannel: LibraryChannel? {
        guard let current = candidates.first else {
            return model.channels.selectedChannel(for: channelID) ?? fallbackChannel
        }
        return model.channels.selectedChannel(for: current.channelID)
    }

    private var candidates: [LibraryChannelReviewItem] {
        let items: [LibraryChannelReviewItem]
        if isAllChannels {
            items = model.channels.reviewCandidatesAcrossChannels()
        } else if let channel = model.channels.selectedChannel(for: channelID) ?? fallbackChannel {
            items = model.channels.reviewCandidates(for: channel)
        } else {
            items = []
        }
        return items.filter { !skippedItemIDs.contains($0.reviewKey) }
    }

    private var canLoadMore: Bool {
        if isAllChannels {
            return model.channels.channels.contains(where: \.canLoadMore)
        }
        return currentChannel?.canLoadMore == true
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            if showsNavigationHeader {
                HStack(spacing: 12) {
                    Button {
                        model.workflows.navigateBack()
                    } label: {
                        Image(systemName: "arrow.left")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .accessibilityLabel("Back")
                    .help("Back")

                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 56)
                .fadingBarBackground()
                .readingColumn()
            }
            #endif

            VStack(spacing: 0) {
                ZStack {
                    if let current = candidates.first {
                        let previewText = resolvedPreviewText[current.reviewKey] ?? current.previewText
                        if previewText.isEmpty {
                            XEmptyState(
                                icon: "doc.text.magnifyingglass",
                                title: "Preview unavailable",
                                message: "This candidate did not include readable text."
                            )
                            #if os(macOS)
                            .readingColumn()
                            #endif
                        } else {
                            EditableDocumentTextView(
                                text: .constant(previewText),
                                isEditable: false,
                                highlightedPassages: [],
                                onHighlight: nil,
                                onRemoveHighlight: nil
                            )
                            .accessibilityIdentifier("channel.review.editor")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id(current.reviewKey)
                        }
                    } else {
                        XEmptyState(
                            icon: "checkmark.circle",
                            title: "Nothing to review",
                            message: skippedItemIDs.isEmpty
                                ? isAllChannels
                                    ? "New items from your channels appear here."
                                    : "New items from this channel appear here."
                                : "You've skipped every remaining item."
                        )
                        #if os(macOS)
                        .readingColumn()
                        #endif
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .scrollContentEdgeFade()

                actionBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // On macOS this spans the full content area so the preview's scroller sits at the
        // window edge; the text, bars, and states keep to the reading column.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: channelID) {
            skippedItemIDs = []
            resolvedPreviewText = [:]
        }
        .task(id: candidates.first?.reviewKey) {
            guard let current = candidates.first,
                  resolvedPreviewText[current.reviewKey] == nil,
                  let preview = await model.channels.resolvedPreview(for: current)
            else { return }
            resolvedPreviewText[current.reviewKey] = preview
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let current = candidates.first, let url = current.url {
                        Link(destination: url) {
                            Label("Open original source", systemImage: "arrow.up.right")
                        }
                    }
                    Button("Channel settings", systemImage: "gearshape") {
                        if let currentChannel {
                            model.workflows.showChannelSettings(currentChannel.source)
                        }
                    }
                    .disabled(currentChannel == nil)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Candidate settings")
            }
        }
        #endif
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            if let current = candidates.first {
                actionButton("Reject", systemImage: "xmark", progress: deciding == .reject) {
                    decide(.reject, current)
                }
                actionButton("Skip", systemImage: "forward", progress: false) {
                    skippedItemIDs.insert(current.reviewKey)
                }
                actionButton(
                    "Accept",
                    systemImage: "checkmark",
                    prominent: true,
                    progress: deciding == .accept
                ) {
                    decide(.accept, current)
                }
            } else if canLoadMore {
                actionButton(
                    "Load more",
                    systemImage: "arrow.down.circle",
                    prominent: true,
                    progress: deciding == .loadMore
                ) {
                    loadMore()
                }
            } else {
                actionButton(
                    "Check for new items",
                    systemImage: "arrow.clockwise",
                    prominent: true,
                    progress: deciding == .refresh
                ) {
                    refresh()
                }
            }
        }
        .disabled(
            deciding != nil || model.channels.isAcceptingReviewCandidate ||
                model.channels.isCheckingChannel
        )
        .padding(.horizontal, 16)
        .padding(.top, 20)
        #if os(iOS)
        .padding(.bottom, 10)
        #else
        .padding(.bottom, 14)
        .readingColumn()
        #endif
        .frame(maxWidth: .infinity)
        .fadingBarBackground(.bottom)
    }

    /// Square review action: the decision to make is solid, the alternatives are frosted
    /// like unselected chips.
    private func actionButton(
        _ title: String,
        systemImage: String,
        prominent: Bool = false,
        progress: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if progress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.bold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.headline)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(prominent ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .background {
                if prominent {
                    Rectangle().fill(Color.primary)
                } else {
                    Rectangle().fill(.thinMaterial).overlay(Color.primary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        #if os(macOS)
        .help(title)
        #endif
    }

    private func decide(_ decision: Decision, _ item: LibraryChannelReviewItem) {
        guard deciding == nil, !model.channels.isAcceptingReviewCandidate else { return }
        deciding = decision
        Task {
            switch decision {
            case .accept:
                #if os(macOS)
                _ = await model.channels.acceptCandidate(
                    item,
                    requestSummary: { entryIDs in
                        await model.workflows.finishAcceptedChannelItems(entryIDs)
                    }
                )
                #else
                _ = await model.channels.acceptCandidate(item)
                #endif
            case .reject:
                _ = await model.channels.rejectCandidate(item)
            case .loadMore, .refresh:
                break
            }
            deciding = nil
        }
    }

    private func loadMore() {
        guard deciding == nil else { return }
        deciding = .loadMore
        Task {
            if isAllChannels {
                await model.workflows.checkAllChannels(loadMore: true)
            } else {
                await model.workflows.checkSelectedChannel(loadMore: true)
            }
            deciding = nil
        }
    }

    private func refresh() {
        guard deciding == nil else { return }
        deciding = .refresh
        Task {
            if isAllChannels {
                await model.workflows.checkAllChannels()
            } else {
                await model.workflows.checkSelectedChannel()
            }
            deciding = nil
        }
    }
}

func channelTitle(_ source: String) -> String {
    guard let host = URL(string: source)?.host?.lowercased() else {
        return source
    }
    if host.contains("arxiv.org") { return "ArXiv" }
    if host.contains("ycombinator.com") { return "Hacker News" }
    if host.contains("reddit.com") { return "Reddit" }
    if host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter.com") {
        return "X"
    }
    return host
        .replacingOccurrences(of: "www.", with: "")
        .split(separator: ".")
        .first
        .map { String($0).capitalized } ?? source
}

func compactLabel(_ value: String, maxLength: Int = 28) -> String {
    guard value.count > maxLength else { return value }
    return String(value.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
}

func localFaviconURL(
    for entry: LibraryEntry
) -> URL? {
    guard let favicon = entry.favicon else { return nil }
    let url = URL(fileURLWithPath: favicon.path)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}
