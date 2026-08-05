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
struct MacXLoadingWorkspace: View {
    let status: String

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Color.clear
                    .frame(height: 42)
                    .accessibilityHidden(true)
                ForEach([
                    ("house", "Home"),
                    ("dot.radiowaves.left.and.right", "Channels"),
                    ("headphones", "Briefs"),
                    ("highlighter", "Highlights"),
                    ("trash", "Trash")
                ], id: \.1) { icon, title in
                    Label(title, systemImage: icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .frame(width: 220)

            VStack(spacing: 0) {
                HStack {
                    Text("Home").font(.title2.weight(.bold))
                    Spacer()
                }
                .padding(18)
                Divider()
                XLoadingState(
                    title: "Opening your library",
                    message: status
                )
            }
            .frame(width: 680)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial.opacity(0.64))
            .overlay { Rectangle().stroke(Color.primary.opacity(0.10)) }

            VStack(alignment: .leading, spacing: 14) {
                Capsule()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 44)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .frame(height: 230)
            }
            .frame(width: 310)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: 1_298, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { BrieflyAtmosphere().ignoresSafeArea() }
        .ignoresSafeArea(.container, edges: .top)
    }
}

#endif
