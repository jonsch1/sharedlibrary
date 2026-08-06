import Foundation
import SwiftUI
import BrieflyCore

#if os(iOS)
struct MobileHomeEntryCard: View {
    let entry: LibraryEntry
    let action: () -> Void

    var body: some View {
        MobileEntryRow(entry: entry, kind: inferredKind, action: action)
    }

    private var inferredKind: MobileEntryKind {
        .item
    }
}

enum MobileEntryKind {
    case item
    case channel
}

struct MobileEntryCard: View {
    let entry: LibraryEntry
    let kind: MobileEntryKind
    var selected = false
    let action: () -> Void

    var body: some View {
        MobileEntryRow(
            entry: entry,
            kind: kind,
            selected: selected,
            action: action
        )
    }
}

struct MobileEntryRow: View {
    let entry: LibraryEntry
    let kind: MobileEntryKind
    var selected = false
    let action: () -> Void

    private var accent: Color {
        switch kind {
        case .item: Color(red: 0.60, green: 0.34, blue: 0.96)
        case .channel: Color(red: 0.93, green: 0.39, blue: 0.25)
        }
    }

    private var icon: String {
        switch kind {
        case .channel:
            return "dot.radiowaves.left.and.right"
        case .item:
            return switch entry.entryType {
            case "pdf": "doc.richtext"
            case "link": "link"
            default: "doc.text"
            }
        }
    }

    private var date: Date? {
        guard let value = entry.createdAt ?? entry.updatedAt else { return nil }
        return try? Date(value, strategy: .iso8601)
    }

    private var dateText: String? {
        guard let date else { return nil }
        let elapsed = max(0, Date().timeIntervalSince(date))
        switch elapsed {
        case ..<3_600: return "\(max(1, Int(elapsed / 60)))m"
        case ..<86_400: return "\(Int(elapsed / 3_600))h"
        case ..<604_800: return "\(Int(elapsed / 86_400))d"
        case ..<2_592_000: return "\(Int(elapsed / 604_800))w"
        case ..<31_536_000: return "\(Int(elapsed / 2_592_000))mo"
        default: return "\(Int(elapsed / 31_536_000))y"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let dateText {
                            Text(dateText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }

                    if !entry.excerpt.isEmpty {
                        Text(entry.excerpt)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(accent.opacity(0.9))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? accent.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.075))
                .frame(height: 0.5)
                .padding(.leading, 54)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.entry.\(entry.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(
            date.map {
                $0.formatted(.relative(presentation: .named, unitsStyle: .wide))
            } ?? ""
        )
    }
}

#endif
