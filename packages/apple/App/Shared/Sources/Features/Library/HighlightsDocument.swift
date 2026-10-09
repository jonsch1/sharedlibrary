import SwiftUI

struct HighlightsDocument: View {
    @Bindable var model: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Highlights")
                        .font(.title2.weight(.bold))
                    Text("Passages saved from your library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            GeometryReader { geometry in
                if model.selection.highlightsText.isEmpty {
                    XEmptyState(
                        icon: "highlighter",
                        title: "No highlights yet",
                        message: "Select a passage in any item, then choose Highlight."
                    )
                } else {
                    ScrollView {
                        MarkdownArticle(model.selection.highlightsText)
                            .frame(maxWidth: 620, alignment: .leading)
                            .padding(.horizontal, 28)
                            .padding(.top, 34)
                            .padding(.bottom, 80)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height, alignment: .top)
                    }
                }
            }
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
