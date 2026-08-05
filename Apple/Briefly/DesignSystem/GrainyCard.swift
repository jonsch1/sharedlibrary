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

enum GrainyGradientPalette {
    case item
    case channel
    case brief
}

struct GrainyCard<Content: View>: View {
    let content: Content

    init(
        palette: GrainyGradientPalette,
        variationKey: String,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .background {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.78)
                    Color.primary.opacity(0.018)
                }
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: cardCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .stroke(.primary.opacity(0.11))
            }
            #if os(macOS)
            .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
            #else
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            #endif
    }

    private var cardCornerRadius: CGFloat {
        #if os(macOS)
        11
        #else
        20
        #endif
    }
}
