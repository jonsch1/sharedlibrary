import Foundation
import SwiftUI
import BrieflyCore

struct FeedEntryRow: View {
    let entry: LibraryEntry
    let action: () -> Void

    private var sourceURL: URL? {
        entry.sourceURL.flatMap(URL.init(string:))
    }

    private var sourceName: String {
        if let sharedBy = entry.sharedByDisplayName, !sharedBy.isEmpty {
            return sharedBy
        }
        if let host = sourceURL?.host {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return "Briefly"
    }

    private var relativeDate: String? {
        guard
            let rawDate = entry.createdAt ?? entry.updatedAt,
            let date = try? Date(rawDate, strategy: .iso8601)
        else { return nil }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private var displayExcerpt: String {
        let excerpt = entry.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
            excerpt.lowercased().hasPrefix(title.lowercased())
        else { return excerpt }
        return String(excerpt.dropFirst(title.count))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(sourceName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let username = entry.sharedByUsername, !username.isEmpty {
                    Text("@\(username)")
                        .lineLimit(1)
                }
                if let relativeDate {
                    Text("·")
                    Text(relativeDate)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.trailing, sourceURL == nil ? 0 : 40)
            .font(.callout)
            .foregroundStyle(.secondary)

            Text(entry.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !displayExcerpt.isEmpty {
                Text(displayExcerpt)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.entry.\(entry.id)")
        .overlay(alignment: .topTrailing) {
            if let sourceURL {
                Link(destination: sourceURL) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open original")
                .padding(.trailing, 6)
                .padding(.top, 2)
            }
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

#if os(macOS)
struct FeedRailCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        }
    }
}

struct BrowserCard<Content: View>: View {
    let palette: GrainyGradientPalette
    let variationKey: String
    let action: () -> Void
    let settingsAction: (() -> Void)?
    let settingsLabel: String
    let content: Content

    init(
        action: @escaping () -> Void,
        settingsAction: (() -> Void)? = nil,
        settingsLabel: String = "Settings",
        palette: GrainyGradientPalette = .item,
        variationKey: String = "",
        @ViewBuilder content: () -> Content
    ) {
        self.palette = palette
        self.variationKey = variationKey
        self.action = action
        self.settingsAction = settingsAction
        self.settingsLabel = settingsLabel
        self.content = content()
    }

    var body: some View {
        GrainyCard(palette: palette, variationKey: variationKey) {
            ZStack(alignment: .topTrailing) {
                Button(action: action) {
                    VStack(alignment: .leading, spacing: 10) {
                        content
                    }
                    .padding(.leading, 18)
                    .padding(.vertical, 18)
                    .padding(.trailing, settingsAction == nil ? 18 : 50)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)

                if let settingsAction {
                    Button(action: settingsAction) {
                        Image(systemName: "gearshape")
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .macLiquidGlass(in: Circle(), interactive: true)
                    .padding(10)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(settingsLabel)
                    .help(settingsLabel)
                }
            }
        }
    }
}

struct CardEyebrow: View {
    let icon: String
    let title: String
    var date: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title.uppercased())
                .lineLimit(1)
            Spacer(minLength: 6)
            if let date, let value = try? Date(date, strategy: .iso8601) {
                Text(
                    value.formatted(
                        .relative(presentation: .named, unitsStyle: .abbreviated)
                    )
                )
                .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10, weight: .bold))
        .tracking(0.4)
        .foregroundStyle(.secondary)
    }
}
#endif

struct XEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.bold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct XLoadingState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
