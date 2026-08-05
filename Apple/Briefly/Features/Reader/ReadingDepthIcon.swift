import Foundation
import SwiftUI
import BrieflyCore

struct ReadingDepthIcon: View {
    let variant: LibraryVariant

    private var lineWidths: [CGFloat] {
        switch variant {
        case .concise: [18, 12]
        case .detailed: [18, 18, 12]
        case .source: []
        }
    }

    var body: some View {
        if variant == .source {
            Image(systemName: "doc.text")
                .font(.system(size: 17, weight: .medium))
        } else {
            VStack(alignment: .leading, spacing: 2.5) {
                ForEach(Array(lineWidths.enumerated()), id: \.offset) { _, width in
                    Capsule()
                        .frame(width: width, height: 2)
                }
            }
            .frame(width: 18, height: 21, alignment: .center)
        }
    }
}
