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

#if os(iOS)
struct ReadingDepthStrip: View {
    @Bindable var model: LibraryModel
    let entry: LibraryEntry

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(entry.texts.map(\.variant), id: \.self) { variant in
                    Button {
                        Task { await model.workflows.selectVariant(variant) }
                    } label: {
                        ReadingDepthIcon(variant: variant)
                            .frame(width: 44, height: 32)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(
                        model.selection.selectedVariant == variant
                            ? Color.accentColor
                            : Color.primary.opacity(0.055)
                    )
                    .foregroundStyle(
                        model.selection.selectedVariant == variant ? Color.white : Color.primary
                    )
                    .clipShape(Capsule())
                    .accessibilityLabel(
                        variant == .source ? "Original" : variant.title
                    )
                    .accessibilityAddTraits(
                        model.selection.selectedVariant == variant ? .isSelected : []
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .mobileGlass(in: Capsule())
    }
}
#endif
