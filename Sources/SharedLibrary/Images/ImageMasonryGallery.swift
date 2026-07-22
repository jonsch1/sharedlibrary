import AppKit
import SwiftUI

struct ImageMasonryGallery: View {
    let items: [LibraryItem]
    let selectedImageID: String?
    let imageURL: (LibraryItem) -> URL?
    let onSelect: (LibraryItem) -> Void
    let onOpen: (LibraryItem) -> Void
    let onCopyPath: (LibraryItem) -> Void
    let onReveal: (LibraryItem) -> Void
    let onDelete: (LibraryItem) -> Void

    private let spacing: CGFloat = 16
    private let minimumColumnWidth: CGFloat = 220

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    let columns = masonryColumns(for: geometry.size.width)
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            LazyVStack(spacing: spacing) {
                                ForEach(column) { item in
                                    imageCard(item)
                                        .id(item.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: selectedImageID) { _, imageID in
                    guard let imageID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(imageID, anchor: .center)
                    }
                }
            }
        }
    }

    private func imageCard(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = imageURL(item), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.18))
            } else {
                ZStack {
                    Color.white.opacity(0.04)
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                }
                .aspectRatio(4 / 3, contentMode: .fit)
            }

            Text(item.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(item.createdAtDate, format: .dateTime.year().month().day().hour().minute())
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.white.opacity(selectedImageID == item.id ? 0.11 : 0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    Color.white.opacity(selectedImageID == item.id ? 0.28 : 0.09),
                    lineWidth: selectedImageID == item.id ? 1.5 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onTapGesture(count: 2) {
            onSelect(item)
            onOpen(item)
        }
        .onTapGesture {
            onSelect(item)
        }
        .contextMenu {
            Button("Copy Path") {
                onCopyPath(item)
            }
            Button("Reveal in Finder") {
                onReveal(item)
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                onDelete(item)
            }
        }
        .help("Double-click to open \(item.title)")
    }

    private func masonryColumns(for availableWidth: CGFloat) -> [[LibraryItem]] {
        let usableWidth = max(availableWidth - 40, minimumColumnWidth)
        let columnCount = max(
            1,
            min(5, Int((usableWidth + spacing) / (minimumColumnWidth + spacing)))
        )
        let columnWidth = (usableWidth - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount)
        var columns = Array(repeating: [LibraryItem](), count: columnCount)
        var heights = Array(repeating: CGFloat.zero, count: columnCount)

        for item in items {
            let targetColumn = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[targetColumn].append(item)
            heights[targetColumn] += estimatedCardHeight(for: item, width: columnWidth) + spacing
        }
        return columns
    }

    private func estimatedCardHeight(for item: LibraryItem, width: CGFloat) -> CGFloat {
        guard let url = imageURL(item),
              let image = NSImage(contentsOf: url),
              image.size.width > 0,
              image.size.height > 0 else {
            return width * 0.75 + 74
        }
        return width * image.size.height / image.size.width + 74
    }
}
