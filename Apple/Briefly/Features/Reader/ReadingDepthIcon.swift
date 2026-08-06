import Foundation
import SwiftUI
import BrieflyCore

enum ReaderActionBarMetrics {
    static let buttonSize: CGFloat = 36
    static let iconSize: CGFloat = 15
    static let iconSlot: CGFloat = 18
    static let iconFont = Font.system(size: iconSize, weight: .medium)
}

struct ReadingDepthIcon: View {
    let variant: LibraryVariant

    private var systemImage: String {
        switch variant {
        case .concise: "text.alignleft"
        case .detailed: "text.justify"
        case .source: "doc.text"
        }
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(ReaderActionBarMetrics.iconFont)
            .symbolRenderingMode(.monochrome)
            .frame(
                width: ReaderActionBarMetrics.iconSlot,
                height: ReaderActionBarMetrics.iconSlot
            )
    }
}
