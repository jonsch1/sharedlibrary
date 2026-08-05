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

struct SyncActivityView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "icloud")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text("Syncing with iCloud")
                    .font(.subheadline.weight(.semibold))

                if model.lifecycle.syncTotal > 0 {
                    HStack {
                        Text("\(model.lifecycle.syncCompleted) of \(model.lifecycle.syncTotal) changes")
                        Spacer(minLength: 16)
                        Text(
                            Double(model.lifecycle.syncCompleted) / Double(model.lifecycle.syncTotal),
                            format: .percent.precision(.fractionLength(0))
                        )
                        .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ProgressView(
                        value: Double(model.lifecycle.syncCompleted),
                        total: Double(model.lifecycle.syncTotal)
                    )
                    .tint(.accentColor)
                } else {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.session.status)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 210, alignment: .leading)
        }
        .padding(14)
        #if os(macOS)
        .macLiquidGlass(
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        #else
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        #endif
        .shadow(color: .black.opacity(0.13), radius: 16, y: 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Syncing with iCloud")
        .accessibilityValue(
            model.lifecycle.syncTotal > 0
                ? "\(model.lifecycle.syncCompleted) of \(model.lifecycle.syncTotal) changes"
                : model.session.status
        )
    }
}
