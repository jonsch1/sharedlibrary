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
            #if os(macOS)
            .readingColumn()
            #endif

            Divider()
                #if os(macOS)
                .readingColumn()
                #endif

            GeometryReader { geometry in
                if model.selection.highlightsText.isEmpty {
                    XEmptyState(
                        icon: "highlighter",
                        title: "No highlights yet",
                        message: "Select a passage in any item, then choose Highlight."
                    )
                    #if os(macOS)
                    .readingColumn()
                    #endif
                } else {
                    ScrollView {
                        MarkdownArticle(model.selection.highlightsText)
                            .frame(maxWidth: 620, alignment: .leading)
                            .padding(.horizontal, 28)
                            .padding(.top, 34)
                            .padding(.bottom, 80)
                            .frame(maxWidth: .infinity)
                            #if os(macOS)
                            .readingColumn()
                            #endif
                            .frame(minHeight: geometry.size.height, alignment: .top)
                    }
                }
            }
        }
        #if os(iOS)
        .frame(maxWidth: 680)
        #endif
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
