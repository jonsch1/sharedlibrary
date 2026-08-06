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

struct ChannelReviewDeck: View {
    private enum Decision: Equatable {
        case accept
        case reject
    }

    @Bindable var model: LibraryChannelModel
    let channelID: String
    let fallbackChannel: LibraryChannel
    let requestSummary: ChannelReviewSummaryRequester?
    @Environment(\.openURL) private var openURL
    @State private var dragOffset: CGFloat = 0
    @State private var isDeciding = false

    private var currentChannel: LibraryChannel {
        model.selectedChannel(for: channelID) ?? fallbackChannel
    }

    private var candidates: [LibraryChannelReviewItem] {
        model.reviewCandidates(for: currentChannel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("REVIEW QUEUE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.1)
                    Text("Choose what belongs in your library")
                        .font(.title3.weight(.bold))
                    Text("Swipe right to accept, left to reject, or use the buttons.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Text("\(candidates.count)/\(model.reviewWindow(for: currentChannel))")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(candidates.count) candidates waiting")
            }

            if let current = candidates.first {
                ZStack {
                    if let next = candidates.dropFirst().first {
                        reviewCard(next)
                            .scaleEffect(0.96)
                            .offset(y: 12)
                            .opacity(0.72)
                            .allowsHitTesting(false)
                    }
                    reviewCard(current)
                        .offset(x: dragOffset)
                        .rotationEffect(.degrees(Double(dragOffset / 28)))
                        .overlay(alignment: .topLeading) {
                            decisionBadge("REJECT", color: .orange, visible: dragOffset < -24)
                        }
                        .overlay(alignment: .topTrailing) {
                            decisionBadge("ACCEPT", color: .green, visible: dragOffset > 24)
                        }
                        .gesture(
                            DragGesture(minimumDistance: 12)
                                .onChanged { value in
                                    guard !isDeciding else { return }
                                    dragOffset = value.translation.width
                                }
                                .onEnded { value in
                                    guard !isDeciding else { return }
                                    let threshold: CGFloat = 96
                                    guard abs(value.translation.width) >= threshold else {
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                                            dragOffset = 0
                                        }
                                        return
                                    }
                                    decide(
                                        value.translation.width > 0 ? .accept : .reject,
                                        current
                                    )
                                }
                        )
                }
                .frame(maxWidth: .infinity, minHeight: 330, maxHeight: 430)

                HStack(spacing: 12) {
                    Button {
                        decide(.reject, current)
                    } label: {
                        Label("Reject", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .disabled(isDeciding || model.isAcceptingReviewCandidate)

                    Button {
                        decide(.accept, current)
                    } label: {
                        Label("Accept", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isDeciding || model.isAcceptingReviewCandidate)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.green)
                    Text("Nothing waiting for review")
                        .font(.headline)
                    Text("Fetch fresh candidates when you are ready. Accepted documents stay in your library.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 170)
                .padding(.horizontal, 24)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.primary.opacity(0.11))
        }
        .animation(.easeOut(duration: 0.2), value: candidates.map(\.id))
    }

    private func reviewCard(_ item: LibraryChannelReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: currentChannel.kind == .podcast ? "waveform" : "doc.text")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.host)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let publishedAt = item.item.publishedAt, !publishedAt.isEmpty {
                        Text(publishedAt)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let url = item.url {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.up.right")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Open source")
                }
            }

            Text(item.item.title)
                .font(.title2.weight(.bold))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("PREVIEW")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Text(item.previewText.isEmpty ? "Open the source to preview this candidate." : item.previewText)
                    .font(.callout)
                    .foregroundStyle(item.previewText.isEmpty ? .secondary : .primary)
                    .lineLimit(7)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Label(
                "Accepting saves this document and queues its summaries.",
                systemImage: "sparkles"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 310, alignment: .topLeading)
        .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.primary.opacity(0.11))
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
    }

    @ViewBuilder
    private func decisionBadge(_ title: String, color: Color, visible: Bool) -> some View {
        if visible {
            Text(title)
                .font(.caption.weight(.heavy))
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.background.opacity(0.9), in: Capsule())
                .overlay { Capsule().stroke(color, lineWidth: 2) }
                .padding(18)
        }
    }

    private func decide(_ decision: Decision, _ item: LibraryChannelReviewItem) {
        guard !isDeciding else { return }
        isDeciding = true
        withAnimation(.easeIn(duration: 0.18)) {
            dragOffset = decision == .accept ? 520 : -520
        }
        Task {
            switch decision {
            case .accept:
                _ = await model.acceptCandidate(item, requestSummary: requestSummary)
            case .reject:
                _ = await model.rejectCandidate(item)
            }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                dragOffset = 0
            }
            isDeciding = false
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
