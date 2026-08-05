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

enum NativeLibraryError: LocalizedError {
    case audioGenerationFailed
    case audioPlaybackFailed
    case emptySpeech
    case iCloudUnavailable
    case unexpectedAIResponse

    var errorDescription: String? {
        switch self {
        case .audioGenerationFailed:
            "The system voice could not create an audio file."
        case .audioPlaybackFailed:
            "Briefly could not start audio playback."
        case .emptySpeech:
            "The voice brief does not contain text to speak."
        case .iCloudUnavailable:
            "Sign in to iCloud and enable iCloud Drive for Briefly."
        case .unexpectedAIResponse:
            "The command ran, but returned an unexpected response."
        }
    }
}
