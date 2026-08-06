import SwiftUI
import BrieflyCore

struct ReadingDepthStrip: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry

    private var variants: [LibraryVariant] {
        let availableVariants = Set(entry.texts.map(\.variant))
        return LibraryVariant.allCases.filter(availableVariants.contains)
    }

    var body: some View {
        Group {
            #if os(iOS)
            buttons
                .padding(4)
                .mobileGlass(in: Capsule())
            #else
            buttons
            #endif
        }
        .animation(.snappy(duration: 0.2), value: model.selection.selectedVariant)
        .accessibilityIdentifier("reader.depth.selector")
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            ForEach(variants, id: \.self) { variant in
                depthButton(for: variant)
            }
        }
    }

    @ViewBuilder
    private func depthButton(for variant: LibraryVariant) -> some View {
        let selected = model.selection.selectedVariant == variant

        Button {
            Task { await model.workflows.selectVariant(variant) }
        } label: {
            ReadingDepthIcon(variant: variant)
        }
        .buttonStyle(.plain)
        .frame(
            width: ReaderActionBarMetrics.buttonSize,
            height: ReaderActionBarMetrics.buttonSize
        )
        .contentShape(Circle())
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .accessibilityLabel(variant == .source ? "Original" : variant.title)
        .accessibilityIdentifier("reader.depth.\(variant.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(variant == .source ? "Original" : variant.title)
    }
}
