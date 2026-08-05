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

enum LibrarySection: String, CaseIterable, Identifiable {
    case items
    case channels
    case briefs

    var id: Self { self }

    var title: String {
        switch self {
        case .items: "Home"
        case .channels: "Channels"
        case .briefs: "Briefs"
        }
    }

    var icon: String {
        switch self {
        case .items: "house"
        case .channels: "dot.radiowaves.left.and.right"
        case .briefs: "headphones"
        }
    }

    var searchPrompt: String {
        switch self {
        case .items: "Search items"
        case .channels: "Search channels"
        case .briefs: "Search voice briefs"
        }
    }
}
struct BrieflyActivity: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}
enum VoiceBriefGenerationPhase: Equatable {
    case retrieving
    case summarizing
    case assembling
}

struct VoiceBriefGenerationProgress {
    let voiceBriefID: String
    var phase = VoiceBriefGenerationPhase.retrieving
    var checkedChannelCount = 0
    var totalChannelCount = 0
    var retrievedItemCount = 0
    var summarizedItemCount = 0
    var failedItemCount = 0
}

struct ProcessingJobResult: Sendable {
    let entryID: String
    let selectedID: String?
    let succeeded: Bool
}

@MainActor
@Observable
final class LibraryModel {
    static let subscriptionProductID = "fyi.readbriefly.plus.monthly"
    static let managedAICommand =
        "briefly://openrouter/openai/gpt-5.6-luna"
    static let processingDefaultCommand = managedAICommand
    static let processingCommandKey = "BrieflyProcessingCommand"
    static let processingPromptKey = "BrieflyProcessingPrompt"
    static let aboutYouKey = "BrieflyAboutYou"
    let backend = BrieflyBackend.shared
    let environment: AppEnvironment
    var cloud: CloudDocumentSync?
    var started = false
    var library: SQLiteLibraryStore?
    var hasLoadedChannels = false
    var hasLoadedHighlights = false
    var hasLoadedTrash = false
    var pendingSync: Task<Void, Never>?
    var localSpeechPreparation: Task<Void, Never>?
    #if os(iOS)
    static let continuedVoiceBriefTaskPrefix =
        "fyi.readbriefly.BrieflyNative.voice-brief"
    @ObservationIgnored
    var continuedVoiceBriefTask: AnyObject?
    @ObservationIgnored
    var continuedVoiceBriefWork: Task<Void, Never>?
    #endif

    var isReady = false
    var projection = LibraryProjection.empty
    var trashEntries = [LibraryEntry]()
    var activeSection = LibrarySection.briefs
    var selectedID = ""
    var selectedIDs = Set<String>()
    var selectedVoiceBriefID = ""
    var selectedChannelSource = ""
    var newChannelSources = [String]()
    var channelBrowserAddress = ""
    var channelBrowserStagesSource = false
    var showingVoiceBriefSettings = false
    var showingChannelSettings = false
    var selectedVariant = LibraryVariant.concise
    var selectedText = ""
    var highlightsText = ""
    var showingHighlights = false
    var showingTrash = false
    var query = ""
    var selectedTopic = "All"
    var selectedChannelDomain = "All"
    var isLoadingText = false
    var isIngesting = false
    var isSyncing = false
    var syncCompleted = 0
    var syncTotal = 0
    var isProcessing = false
    var isCheckingChannel = false
    var isRunningVoiceBrief = false
    var voiceBriefGenerationProgress: VoiceBriefGenerationProgress?
    var isGeneratingSpeech = false
    var isPreparingSpeech = false
    var isLocalSpeechReady = false
    var speechPreparationStatus = "Preparing local voice…"
    var isCheckingAccount = false
    var isTestingAI = false
    var status = "Loading library…"
    var errorMessage: String?
    var libraryChannels = [LibraryChannel]()
    var topicsText = ""
    var account = BrieflyAccountStatus.signedOut
    var subscriptionProduct: Product?
    var isPurchasingSubscription = false
    var processingCommand =
        UserDefaults.standard.string(forKey: LibraryModel.processingCommandKey) ??
        LibraryModel.processingDefaultCommand
    var processingPrompt =
        UserDefaults.standard.string(forKey: LibraryModel.processingPromptKey) ??
        defaultProcessingPrompt
    var aboutYou =
        UserDefaults.standard.string(forKey: LibraryModel.aboutYouKey) ?? ""

    init(environment: AppEnvironment = .current()) {
        self.environment = environment
    }

    var runsScheduledWork: Bool { !environment.isUITesting }

    var canEdit: Bool {
        library != nil
    }

    static var cloudKitAvailable: Bool {
        #if os(macOS)
        let signature = Bundle.main.bundleURL
            .appending(path: "Contents/_CodeSignature/CodeResources")
        #else
        let signature = Bundle.main.bundleURL
            .appending(path: "_CodeSignature/CodeResources")
        #endif
        return FileManager.default.fileExists(
            atPath: signature.path
        )
    }

    var usesManagedAI: Bool {
        processingCommand == Self.managedAICommand
    }

    var isWorking: Bool {
        isIngesting || isCheckingChannel || isProcessing || isRunningVoiceBrief ||
            isGeneratingSpeech || isPreparingSpeech || isSyncing || isTestingAI
    }

    var menuBarActivity: String? {
        if isRunningVoiceBrief { return "Creating brief" }
        if isGeneratingSpeech { return "Creating audio" }
        if isPreparingSpeech { return "Preparing voice" }
        if isProcessing { return "Processing" }
        if isIngesting || isCheckingChannel { return "Ingesting" }
        if isSyncing {
            return syncTotal > 0 ? "Syncing \(syncCompleted)/\(syncTotal)" : "Syncing"
        }
        if isTestingAI { return "Testing" }
        return nil
    }

    var menuBarIcon: String {
        if isRunningVoiceBrief || isGeneratingSpeech || isPreparingSpeech {
            return "waveform"
        }
        if isProcessing || isTestingAI { return "sparkles" }
        if isIngesting || isCheckingChannel { return "square.and.arrow.down" }
        if isSyncing { return "arrow.triangle.2.circlepath" }
        return "doc.text"
    }

    var activityStatus: String {
        isPreparingSpeech ? speechPreparationStatus : status
    }

    var activeActivities: [BrieflyActivity] {
        var activities = [BrieflyActivity]()
        if isRunningVoiceBrief {
            activities.append(.init(icon: "sparkles", title: "Creating brief", detail: status))
        }
        if isGeneratingSpeech {
            activities.append(.init(icon: "waveform", title: "Creating audio", detail: status))
        }
        if isPreparingSpeech {
            activities.append(.init(icon: "waveform", title: "Preparing voice", detail: speechPreparationStatus))
        }
        if isProcessing {
            activities.append(.init(icon: "sparkles", title: "Preparing summaries", detail: status))
        }
        if isIngesting || isCheckingChannel {
            activities.append(.init(icon: "square.and.arrow.down", title: "Gathering items", detail: status))
        }
        if isSyncing {
            let detail = syncTotal > 0
                ? "Uploading \(syncCompleted) of \(syncTotal) changes"
                : status
            activities.append(.init(icon: "icloud", title: "Syncing", detail: detail))
        }
        if isTestingAI {
            activities.append(.init(icon: "checkmark.bubble", title: "Testing AI", detail: status))
        }
        return activities
    }

    var selectedEntry: LibraryEntry? {
        (projection.entries + trashEntries).first { $0.id == selectedID }
    }

    var highlightCount: Int {
        highlightsText.components(separatedBy: .newlines)
            .count { $0.hasPrefix("## ") }
    }

    var loadedHighlightCount: Int? {
        hasLoadedHighlights ? highlightCount : nil
    }

    var loadedTrashCount: Int? {
        hasLoadedTrash ? trashEntries.count : nil
    }

    var selectedVoiceBrief: LibraryVoiceBrief? {
        projection.voiceBriefDefinitions.first { $0.id == selectedVoiceBriefID }
    }

    var selectedChannel: LibraryChannel? {
        channels.first { $0.source == selectedChannelSource }
    }

    var homeEntries: [LibraryEntry] {
        projection.entries.filter(\.isMainLibraryEntry)
    }

    var filteredEntries: [LibraryEntry] {
        (showingTrash ? trashEntries : homeEntries).filter {
            (selectedTopic.isEmpty || selectedTopic == "All" ||
                    $0.topicNames.contains(selectedTopic)) &&
                $0.matches(query)
        }
    }

    var channels: [LibraryChannel] {
        if library != nil { return libraryChannels }
        return projection.channelSources.map {
            LibraryChannel(source: $0, title: channelTitle($0))
        }
    }

    var filteredChannels: [LibraryChannel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return channels }
        return channels.filter {
            $0.matches(needle) ||
                channelEntries(for: $0.source).contains { $0.matches(needle) }
        }
    }

    func channelEntries(for source: String) -> [LibraryEntry] {
        guard let channel = channels.first(where: { $0.source == source }) else {
            return projection.entries(forChannel: source)
        }
        let entryIDs = Set(channel.entryIDs)
        if entryIDs.isEmpty { return projection.entries(forChannel: source) }
        return projection.entries
            .filter { entryIDs.contains($0.id) }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

}
