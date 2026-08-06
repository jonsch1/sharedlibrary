import SwiftUI
import BrieflyCore

#if os(iOS)
struct ReadingDepthStrip: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry

    private var variants: [LibraryVariant] {
        let availableVariants = Set(entry.texts.map(\.variant))
        return LibraryVariant.allCases.filter(availableVariants.contains)
    }

    private var selectedVariant: Binding<LibraryVariant> {
        Binding(
            get: { model.selection.selectedVariant },
            set: { variant in
                guard variant != model.selection.selectedVariant else { return }
                Task { await model.workflows.selectVariant(variant) }
            }
        )
    }

    var body: some View {
        Picker("Reading depth", selection: selectedVariant) {
            ForEach(variants, id: \.self) { variant in
                ReadingDepthIcon(variant: variant)
                    .accessibilityLabel(variant == .source ? "Original" : variant.title)
                    .tag(variant)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("reader.depth.selector")
    }
}
#endif
