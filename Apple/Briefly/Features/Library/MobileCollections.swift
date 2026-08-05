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
struct MobileCollectionHeader: View {
    let title: String
    let count: Int
    let back: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .mobileGlass(in: Circle())
            .accessibilityLabel("Back to collections")

            Text(title)
                .font(.title3.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(count.formatted())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

struct MobileCollectionCard: View {
    let key: String
    var palette: GrainyGradientPalette = .item
    var minimumHeight: CGFloat? = nil
    let icon: String
    let eyebrow: String
    let title: String
    let subtitle: String
    var settingsLabel = "Settings"
    var settingsAction: (() -> Void)?
    let action: () -> Void

    var body: some View {
        GrainyCard(palette: palette, variationKey: key) {
            ZStack(alignment: .topTrailing) {
                Button(action: action) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(eyebrow, systemImage: icon)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.5)
                        Text(title)
                            .font(.title2.weight(.bold))
                            .lineLimit(2)
                        Text(subtitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(3)
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: minimumHeight ?? 132,
                        alignment: .topLeading
                    )
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let settingsAction {
                    Button(action: settingsAction) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .background(.primary.opacity(0.06), in: Circle())
                    .padding(12)
                    .accessibilityLabel(settingsLabel)
                }
            }
        }
    }
}
#endif
