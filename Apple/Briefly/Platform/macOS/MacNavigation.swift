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
struct MacXNavigation: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    @Binding var showsCaptureComposer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                BrieflyLogo()
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .padding(.bottom, 10)

            ForEach(LibrarySection.allCases) { section in
                Button {
                    showsSettings = false
                    Task { await model.show(section) }
                } label: {
                    navigationRow(
                        section.title,
                        icon: section.icon,
                        selected: model.activeSection == section &&
                            !model.showingHighlights && !model.showingTrash
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("navigation.\(section.rawValue)")
            }

            Button {
                showsSettings = false
                model.showHighlights()
            } label: {
                navigationRow(
                    "Highlights",
                    icon: "highlighter",
                    selected: model.showingHighlights
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("navigation.highlights")

            Button {
                showsSettings = false
                model.showTrash()
            } label: {
                navigationRow("Trash", icon: "trash", selected: model.showingTrash)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("navigation.trash")

            Button {
                switch model.activeSection {
                case .items:
                    showsCaptureComposer = true
                case .channels:
                    model.query = ""
                    model.showChannelSettings("new")
                case .briefs:
                    model.query = ""
                    model.showVoiceBriefSettings("new")
                }
            } label: {
                Label(primaryActionTitle, systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier(
                model.activeSection == .items ? "capture.open" : "navigation.primaryAction"
            )
            .padding(.top, 12)
            .padding(.horizontal, 4)

            Spacer(minLength: 18)

            Button {
                showsSettings = true
            } label: {
                navigationRow("Settings", icon: "gearshape", selected: showsSettings)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings.open")
        }
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity)
    }

    private var primaryActionTitle: String {
        switch model.activeSection {
        case .items: "Capture"
        case .channels: "New channel"
        case .briefs: "New brief"
        }
    }

    private func navigationRow(
        _ title: String,
        icon: String,
        selected: Bool
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: selected ? .semibold : .regular))
                .frame(width: 28)
            Text(title)
                .font(.system(size: 19, weight: selected ? .bold : .medium))
            Spacer()
        }
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.82))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

#endif
