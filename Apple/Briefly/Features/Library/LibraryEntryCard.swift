import Foundation
import SwiftUI
import BrieflyCore

struct GrainyEntryCard: View {
    let entry: LibraryEntry
    let paletteOverride: GrainyGradientPalette?
    let selected: Bool
    let minimumHeight: CGFloat?
    let featured: Bool
    let action: () -> Void

    private var palette: GrainyGradientPalette {
        paletteOverride ?? (entry.voiceBriefID == nil ? .item : .brief)
    }

    init(
        entry: LibraryEntry,
        palette: GrainyGradientPalette? = nil,
        selected: Bool = false,
        minimumHeight: CGFloat? = nil,
        featured: Bool = false,
        action: @escaping () -> Void
    ) {
        self.entry = entry
        self.paletteOverride = palette
        self.selected = selected
        self.minimumHeight = minimumHeight
        self.featured = featured
        self.action = action
    }

    private var cardMinimumHeight: CGFloat? {
        if let minimumHeight { return minimumHeight }
        #if os(macOS)
        return nil
        #else
        return 132
        #endif
    }

    private var dateText: String? {
        guard
            let value = entry.createdAt ?? entry.updatedAt,
            let date = try? Date(value, strategy: .iso8601)
        else { return nil }
        return date.formatted(
            .relative(presentation: .named, unitsStyle: .abbreviated)
        )
    }

    var body: some View {
        GrainyCard(palette: palette, variationKey: entry.id) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.title)
                            .font(cardTitleFont)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let dateText {
                            Text(dateText)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .opacity(0.85)
                        }
                    }

                    if !entry.excerpt.isEmpty {
                        Text(entry.excerpt)
                            .font(.system(size: featured ? 13 : 12, weight: .regular))
                            .lineLimit(featured ? 5 : 4)
                            .multilineTextAlignment(.leading)
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(.primary)
                .frame(
                    maxWidth: .infinity,
                    minHeight: cardMinimumHeight,
                    alignment: .topLeading
                )
                .padding(featured ? 22 : 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay {
            RoundedRectangle(cornerRadius: selectionCornerRadius, style: .continuous)
                .stroke(
                    selected ? .white.opacity(0.7) : .clear,
                    lineWidth: selected ? 2 : 0
                )
        }
    }

    private var cardTitleFont: Font {
        #if os(macOS)
        .system(size: featured ? 21 : 16, weight: .semibold)
        #else
        .title2.weight(.bold)
        #endif
    }

    private var selectionCornerRadius: CGFloat {
        #if os(macOS)
        11
        #else
        20
        #endif
    }
}
