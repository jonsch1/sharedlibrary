import AVFoundation
import AuthenticationServices
import BrieflyCore
import CloudKit
import CryptoKit
import Observation
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
import Carbon.HIToolbox
#elseif os(iOS)
import BackgroundTasks
import MediaPlayer
import UIKit
#endif

#if os(macOS)
struct MasonryLayout: Layout {
    let minimumColumnWidth: CGFloat
    let maximumColumnWidth: CGFloat
    let spacing: CGFloat

    struct Cache {
        var frames = [CGRect]()
        var size = CGSize.zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard !subviews.isEmpty else {
            cache = Cache()
            return .zero
        }

        let availableWidth = max(
            1,
            proposal.width ?? maximumColumnWidth
        )
        let columnCount = max(
            1,
            Int(
                floor(
                    (availableWidth + spacing) /
                        (minimumColumnWidth + spacing)
                )
            )
        )
        let columnWidth = min(
            maximumColumnWidth,
            (availableWidth - CGFloat(columnCount - 1) * spacing) /
                CGFloat(columnCount)
        )
        var columnHeights = Array(repeating: CGFloat.zero, count: columnCount)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(
                ProposedViewSize(width: columnWidth, height: nil)
            )
            let column = columnHeights.enumerated().min {
                if $0.element == $1.element {
                    return $0.offset < $1.offset
                }
                return $0.element < $1.element
            }?.offset ?? 0
            let origin = CGPoint(
                x: CGFloat(column) * (columnWidth + spacing),
                y: columnHeights[column]
            )
            frames[index] = CGRect(
                origin: origin,
                size: CGSize(width: columnWidth, height: size.height)
            )
            columnHeights[column] = origin.y + size.height + spacing
        }

        let height = max(0, (columnHeights.max() ?? 0) - spacing)
        cache.frames = frames
        cache.size = CGSize(width: availableWidth, height: height)
        return cache.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        if cache.frames.count != subviews.count ||
            abs(cache.size.width - bounds.width) > 0.5
        {
            _ = sizeThatFits(
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
                subviews: subviews,
                cache: &cache
            )
        }

        for index in subviews.indices {
            let frame = cache.frames[index]
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + frame.minX,
                    y: bounds.minY + frame.minY
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: frame.width,
                    height: nil
                )
            )
        }
    }
}

struct BalancedTilingLayout: Layout {
    let minimumTileWidth: CGFloat
    let maximumColumns: Int
    let spacing: CGFloat
    let featuredCount: Int

    struct Cache {
        var frames = [CGRect]()
        var size = CGSize.zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard !subviews.isEmpty else {
            cache = Cache()
            return .zero
        }

        let availableWidth = max(1, proposal.width ?? minimumTileWidth)
        let rows = rowCounts(itemCount: subviews.count, width: availableWidth)
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var itemIndex = 0
        var y = CGFloat.zero

        for (rowIndex, itemCount) in rows.enumerated() {
            let availableForTiles = availableWidth - CGFloat(itemCount - 1) * spacing
            let weights = rowWeights(count: itemCount, rowIndex: rowIndex)
            let totalWeight = weights.reduce(0, +)
            let widths = weights.map { availableForTiles * $0 / totalWeight }
            var measuredHeights = [CGFloat]()

            for offset in 0..<itemCount {
                let size = subviews[itemIndex + offset].sizeThatFits(
                    ProposedViewSize(width: widths[offset], height: nil)
                )
                measuredHeights.append(size.height)
            }

            let isFeaturedRow = rowIndex == 0 && featuredCount > 0 &&
                subviews.count >= 6
            let rowHeight = max(
                isFeaturedRow ? 262 : 164,
                measuredHeights.max() ?? 0
            )
            var x = CGFloat.zero

            for offset in 0..<itemCount {
                frames[itemIndex + offset] = CGRect(
                    x: x,
                    y: y,
                    width: widths[offset],
                    height: rowHeight
                )
                x += widths[offset] + spacing
            }

            itemIndex += itemCount
            y += rowHeight + spacing
        }

        cache.frames = frames
        cache.size = CGSize(width: availableWidth, height: max(0, y - spacing))
        return cache.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        if cache.frames.count != subviews.count ||
            abs(cache.size.width - bounds.width) > 0.5
        {
            _ = sizeThatFits(
                proposal: ProposedViewSize(width: bounds.width, height: nil),
                subviews: subviews,
                cache: &cache
            )
        }

        for index in subviews.indices {
            let frame = cache.frames[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func rowCounts(itemCount: Int, width: CGFloat) -> [Int] {
        let preferred = max(
            2,
            min(
                maximumColumns,
                Int((width + spacing) / (minimumTileWidth + spacing))
            )
        )
        var remaining = itemCount
        var rows = [Int]()

        if featuredCount > 0 && itemCount >= 6 {
            let count = min(featuredCount, remaining)
            rows.append(count)
            remaining -= count
        }

        while remaining > 0 {
            if remaining <= preferred {
                rows.append(remaining)
                break
            }
            if remaining < preferred * 2 {
                let leading = Int(ceil(Double(remaining) / 2.0))
                rows.append(leading)
                rows.append(remaining - leading)
                break
            }
            rows.append(preferred)
            remaining -= preferred
        }
        return rows
    }

    private func rowWeights(count: Int, rowIndex: Int) -> [CGFloat] {
        let weights: [CGFloat] = switch count {
        case 2: [1.08, 0.92]
        case 3: rowIndex == 0 && featuredCount > 0
            ? [1.24, 1.0, 0.86]
            : [1.08, 0.92, 1.0]
        case 4: [1.08, 0.92, 1.04, 0.96]
        case 5: [1.06, 0.94, 1.02, 0.90, 1.08]
        case 6: [1.05, 0.95, 1.0, 1.04, 0.92, 1.04]
        default: Array(repeating: 1, count: count)
        }
        return rowIndex.isMultiple(of: 2) ? weights : Array(weights.reversed())
    }
}

#endif
