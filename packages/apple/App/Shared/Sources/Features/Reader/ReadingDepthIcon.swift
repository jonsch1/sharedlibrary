import Foundation
import SwiftUI
import BrieflyCore

enum ReaderActionBarMetrics {
    static let iconSize: CGFloat = 18
    static let iconSlot: CGFloat = 22
    static let moreSlot: CGFloat = 58
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
