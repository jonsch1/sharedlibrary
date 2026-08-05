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

enum BrieflySettingsSection: String, CaseIterable, Identifiable {
    case general
    case library
    case capture
    case account
    case personalization
    case topics
    case ai

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "Appearance"
        case .library: "Library & Sync"
        case .capture: "Capture"
        case .account: "Account"
        case .personalization: "Personalization"
        case .topics: "Topics"
        case .ai: "AI Processing"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .library: "folder"
        case .capture: "keyboard"
        case .account: "person.crop.circle"
        case .personalization: "person.text.rectangle"
        case .topics: "number"
        case .ai: "sparkles"
        }
    }
}
