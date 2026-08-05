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
struct MobileHome: View {
    @Bindable var model: LibraryModel
    @Binding var showsSettings: Bool
    let onOpenDetail: () -> Void

    private var entries: [LibraryEntry] {
        model.navigation.homeEntries
            .filter { $0.matches(model.navigation.query) }
            .sorted {
                ($0.createdAt ?? $0.updatedAt ?? "") <
                    ($1.createdAt ?? $1.updatedAt ?? "")
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .mobileGlass(in: Circle())
                    .accessibilityLabel("Settings")

                    Spacer()
                }

                BrieflyLogo()
            }
            .padding(.horizontal, 18)
            .frame(height: 64)

            if entries.isEmpty {
                ContentUnavailableView(
                    model.navigation.query.isEmpty ? "Nothing here yet" : "No recent matches",
                    systemImage: model.navigation.query.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(
                        model.navigation.query.isEmpty
                            ? "New items and voice briefs will appear here."
                            : "Try another search."
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            MobileHomeEntryCard(
                                entry: entry
                            ) {
                                Task {
                                    model.navigation.activeSection = entry.voiceBriefID == nil
                                        ? .items
                                        : .briefs
                                    model.navigation.selectedVoiceBriefID = entry.voiceBriefID ?? ""
                                    await model.workflows.select(entry.id)
                                    onOpenDetail()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 150)
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
            }
        }
        .background(sidebarBackground.ignoresSafeArea())
    }
}

#endif
