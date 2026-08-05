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
struct MobileXDetail: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: LibraryModel
    @Binding var showsChannelBrowser: Bool
    @Bindable var audioPlayer: NativeAudioPlayer
    @Binding var audioEntry: LibraryEntry?

    var body: some View {
        LibraryDetail(
            model: model,
            showsChannelBrowser: $showsChannelBrowser,
            audioPlayer: audioPlayer,
            audioEntry: $audioEntry
        )
        .background(readerBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(
            model.navigation.showingVoiceBriefSettings ? .hidden : .visible,
            for: .navigationBar
        )
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.navigation.navigateBack()
                    dismiss()
                } label: {
                    Image(systemName: "arrow.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Back")
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}

#endif
