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
        buttons
        .animation(.snappy(duration: 0.2), value: model.selection.selectedVariant)
        .accessibilityIdentifier("reader.depth.selector")
    }

    private var buttons: some View {
        HStack(spacing: 0) {
            ForEach(variants, id: \.self) { variant in
                ReadingDepthButton(model: model, variant: variant)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

#if os(iOS)
struct ReadingDepthPicker: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry

    private var variants: [LibraryVariant] {
        let availableVariants = Set(entry.texts.map(\.variant))
        return LibraryVariant.allCases.filter(availableVariants.contains)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(variants, id: \.self) { variant in
                ChoiceChip(
                    title: variant.title,
                    isSelected: model.selection.selectedVariant == variant
                ) {
                    guard model.selection.selectedVariant != variant else { return }
                    model.selection.selectedVariant = variant
                    Task { await model.workflows.selectVariant(variant) }
                }
                .accessibilityIdentifier("reader.depth.\(variant.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.depth.selector")
    }
}
#endif

struct ReadingDepthButton: View {
    @Bindable var model: LibraryModel
    let variant: LibraryVariant

    var body: some View {
        let selected = model.selection.selectedVariant == variant

        Button {
            Task { await model.workflows.selectVariant(variant) }
        } label: {
            HStack(spacing: 7) {
                ReadingDepthIcon(variant: variant)
                Text(variant.title)
            }
            .font(ReaderActionBarMetrics.iconFont)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        #if os(iOS)
        .frame(height: 64)
        #else
        .frame(height: 52)
        #endif
        .contentShape(Rectangle())
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .accessibilityLabel(variant == .source ? "Original" : variant.title)
        .accessibilityIdentifier("reader.depth.\(variant.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(variant == .source ? "Original" : variant.title)
    }
}
