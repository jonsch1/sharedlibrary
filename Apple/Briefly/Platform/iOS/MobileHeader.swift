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
struct MobileXHeaderAction {
    let icon: String
    let label: String
    var identifier: String? = nil
    let action: () -> Void
}

struct MobileXHeader: View {
    let title: String
    var showsLogo = false
    @Binding var showsSettings: Bool
    var showsSettingsButton = false
    var search: MobileXHeaderAction? = nil
    var primary: MobileXHeaderAction? = nil
    var trailing: MobileXHeaderAction? = nil

    var body: some View {
        ZStack {
            if showsLogo {
                BrieflyLogo()
            } else {
                Text(title)
                    .font(.headline.weight(.bold))
            }

            HStack {
                if showsSettingsButton {
                    Button { showsSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(Color.primary.opacity(0.06), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settings.open")
                }

                if let search {
                    headerButton(search)
                }

                Spacer()

                if let trailing {
                    headerButton(trailing)
                }

                if let primary {
                    headerButton(primary)
                } else if trailing == nil {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    private func headerButton(_ action: MobileXHeaderAction) -> some View {
        Button(action: action.action) {
            Image(systemName: action.icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.label)
        .accessibilityIdentifier(
            action.identifier ?? "header.\(action.label.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
    }
}

struct MobileXSearchField: View {
    @Binding var text: String
    let prompt: String
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.search)
                    .accessibilityIdentifier("library.search")
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: 40)
            .background(Color.primary.opacity(0.07), in: Capsule())

            Button("Cancel", action: cancel)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .task { focused = true }
    }
}

#endif
