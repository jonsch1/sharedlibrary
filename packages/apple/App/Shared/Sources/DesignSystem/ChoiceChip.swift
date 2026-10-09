import SwiftUI

/// Square selection control shared by topic, channel, and reading-depth choices.
/// The visible chip is 36pt tall; vertical padding extends the hit area to 44pt.
struct ChoiceChip: View {
    let title: String
    let isSelected: Bool
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil)
                .frame(height: 36)
                .foregroundStyle(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                .background {
                    // Unselected chips are frosted so content scrolling under a header stays out of the label.
                    if isSelected {
                        Rectangle().fill(Color.primary)
                    } else {
                        Rectangle().fill(.thinMaterial).overlay(Color.primary.opacity(0.05))
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
