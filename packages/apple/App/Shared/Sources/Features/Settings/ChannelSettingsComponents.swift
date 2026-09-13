import Foundation
import SwiftUI

struct ChannelSourceCard: View {
    let source: String
    let remove: () -> Void

    private var displaySource: String {
        guard let url = URL(string: source) else { return source }
        let host = url.host?.replacingOccurrences(of: "www.", with: "") ?? source
        let path = url.path == "/" ? "" : url.path
        return host + path
    }

    private var symbol: String {
        guard let host = URL(string: source)?.host?.lowercased() else { return "globe" }
        if host.contains("youtube") { return "play.fill" }
        if host.contains("podcast") || host.contains("spotify") { return "waveform" }
        if host == "x.com" || host.hasSuffix("twitter.com") { return "at" }
        if host.contains("reddit") { return "bubble.left.and.bubble.right.fill" }
        return "globe"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: Rectangle())
            Text(displaySource)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)

            Button(action: remove) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(displaySource)")
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(.primary.opacity(0.035), in: Rectangle())
        .overlay {
            Rectangle()
                .stroke(.primary.opacity(0.12), lineWidth: 1)
        }
    }
}
struct ConfigurationCard<Content: View>: View {
    let eyebrow: String
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(eyebrow)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 28, weight: .bold))
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            content
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(24)
        #if os(macOS)
        .background(.ultraThinMaterial.opacity(0.64))
        .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }
        #endif
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
