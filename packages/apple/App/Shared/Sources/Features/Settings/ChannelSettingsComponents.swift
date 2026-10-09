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
                .frame(width: 24)
            Text(displaySource)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)

            Button(action: remove) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(displaySource)")
        }
        .frame(height: 44)
    }
}
