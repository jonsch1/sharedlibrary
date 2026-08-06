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
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            fallbackImage
        }
        #else
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
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

struct ChannelReviewReader: View {
    private enum Decision: Equatable {
        case accept
        case reject
    }

    @Bindable var model: LibraryChannelModel
    let channelID: String
    let fallbackChannel: LibraryChannel
    let requestSummary: ChannelReviewSummaryRequester?
    @Environment(\.openURL) private var openURL
    @State private var deciding: Decision?

    private var currentChannel: LibraryChannel {
        model.selectedChannel(for: channelID) ?? fallbackChannel
    }

    private var candidates: [LibraryChannelReviewItem] {
        model.reviewCandidates(for: currentChannel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            reviewHeader

            if let current = candidates.first {
                candidateDocument(current)
            } else {
                emptyReviewState
            }
        }
        .background(readerBackground)
        .animation(.easeOut(duration: 0.2), value: candidates.map(\.id))
    }

    private var reviewHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("REVIEW QUEUE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.1)
                    Text("Read before you save")
                        .font(.title3.weight(.bold))
                }
                Spacer(minLength: 16)
                Text("\(candidates.count) pending")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(candidates.count) candidates waiting")
            }
            Text("Review each source in full, then choose what belongs in your library.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    private func candidateDocument(_ item: LibraryChannelReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: currentChannel.kind == .podcast ? "waveform" : "doc.text")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentChannel.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(item.host)
                            if let date = formattedPublishedDate(item.item.publishedAt) {
                                Text("·")
                                Text(date)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if let url = item.url {
                        Button {
                            openURL(url)
                        } label: {
                            Image(systemName: "arrow.up.right")
                                .frame(width: 36, height: 36)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .background(.primary.opacity(0.06), in: Circle())
                        .accessibilityLabel("Open source")
                    }
                }

                Text(item.item.title.isEmpty ? "Untitled candidate" : item.item.title)
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(currentChannel.kind?.rawValue.capitalized ?? "Candidate")
                    Text("·")
                    Text("Pending review")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)

            Divider()
                .padding(.horizontal, 24)

            if item.previewText.isEmpty {
                Text("This source did not provide a preview. Open the original source above to read it before deciding.")
                    .font(.system(size: 19, weight: .regular, design: .serif))
                    .lineSpacing(7)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
            } else {
                MarkdownArticle(item.previewText)
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
            }

            decisionActions(for: item)
        }
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func decisionActions(for item: LibraryChannelReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()

            Label(
                "Accepting saves one ordinary library document and queues its summaries.",
                systemImage: "sparkles"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                decide(.accept, item)
            } label: {
                HStack {
                    if deciding == .accept {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label("Accept", systemImage: "checkmark")
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(deciding != nil || model.isAcceptingReviewCandidate)

            Button {
                decide(.reject, item)
            } label: {
                HStack {
                    if deciding == .reject {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label("Reject", systemImage: "xmark")
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(deciding != nil || model.isAcceptingReviewCandidate)
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 34)
    }

    private var emptyReviewState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 30))
                .foregroundStyle(.green)
            Text("Nothing waiting for review")
                .font(.headline)
            Text("Fetch fresh candidates when you are ready. Accepted documents stay in your library.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(.horizontal, 24)
    }

    private func formattedPublishedDate(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard let date = try? Date(value, strategy: .iso8601) else { return value }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func decide(_ decision: Decision, _ item: LibraryChannelReviewItem) {
        guard deciding == nil, !model.isAcceptingReviewCandidate else { return }
        deciding = decision
        Task {
            switch decision {
            case .accept:
                _ = await model.acceptCandidate(item, requestSummary: requestSummary)
            case .reject:
                _ = await model.rejectCandidate(item)
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
