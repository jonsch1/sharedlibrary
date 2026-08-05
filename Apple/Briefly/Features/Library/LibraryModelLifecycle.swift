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

extension LibraryModel {
    func start() async {
        guard !started else { return }
        started = true
        if environment.isUITesting {
            do {
                await openLibrary(databaseURL: try environment.prepareUITestLibrary())
                await loadSelectedText()
                status = "Ready for application tour"
            } catch {
                isReady = true
                errorMessage = error.localizedDescription
            }
            return
        }
        localSpeechPreparation = Task { await prepareLocalSpeech() }
        let usesDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        if usesDemo {
            projection = .demo
            status = "Showing the sample library"
            selectInitialContent()
            isReady = true
        } else {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Briefly", directoryHint: .isDirectory)
            let current = directory.appending(path: "library.sqlite3")
            let legacy = directory
                .appending(path: ".briefly", directoryHint: .isDirectory)
                .appending(path: "library.sqlite3")
            let databaseURL = FileManager.default.fileExists(atPath: current.path)
                ? current
                : FileManager.default.fileExists(atPath: legacy.path) ? legacy : current
            await openLibrary(databaseURL: databaseURL)
        }

        async let selectedText: Void = loadSelectedText()
        async let accountRefresh: Void = refreshAccount()
        if library != nil {
            async let cloudSync: Void = sync()
            _ = await (selectedText, accountRefresh, cloudSync)
            await drainProcessingQueue()
            await resumePendingVoiceBriefs()
            await runDueChannelChecks()
            await runDueVoiceBriefs()
        } else {
            _ = await (selectedText, accountRefresh)
        }
    }

    func prepareLocalSpeech() async {
        guard !isPreparingSpeech, !isLocalSpeechReady else { return }
        isPreparingSpeech = true
        speechPreparationStatus = "Preparing local voice…"
        defer {
            isPreparingSpeech = false
            localSpeechPreparation = nil
        }
        do {
            try await LocalVoiceBriefSynthesizer.shared.prepare { [weak self] stage in
                Task { @MainActor in
                    guard let self else { return }
                    switch stage {
                    case .downloading(let fraction):
                        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
                        self.speechPreparationStatus =
                            "Downloading local voice… \(percent)%"
                    case .loading:
                        self.speechPreparationStatus = "Loading local voice…"
                    case .ready:
                        self.speechPreparationStatus = "Local voice ready"
                    }
                }
            }
            isLocalSpeechReady = true
            speechPreparationStatus = "Local voice ready"
        } catch {
            isLocalSpeechReady = false
            speechPreparationStatus = "System voice will be used"
        }
    }

    func openLibrary(databaseURL: URL) async {
        do {
            let next = SQLiteLibraryStore(databaseURL: databaseURL)
            projection = try await next.loadLibraryIndex()
            topicsText = try await next.topicDefinitions()
                .map { "\($0.id): \($0.title)" }
                .joined(separator: "\n")
            library = next
            status = "Opened local SQLite library"
            selectInitialContent()
            isReady = true
            let database = try await next.documentDatabase()
            cloud = !environment.isUITesting && Self.cloudKitAvailable
                ? CloudDocumentSync(
                    store: database,
                    containerIdentifier: "iCloud.fyi.readbriefly"
                )
                : nil
        } catch {
            library = nil
            libraryChannels = []
            trashEntries = []
            isReady = true
            errorMessage = error.localizedDescription
        }
    }

    func refreshLibrary(selecting entryID: String? = nil) async {
        guard let library else { return }
        do {
            projection = try await library.loadLibraryIndex()
            if hasLoadedTrash { try await refreshTrash(from: library) }
            if hasLoadedChannels { try await refreshChannels(from: library) }
            if hasLoadedHighlights { try await refreshHighlights(from: library) }
            topicsText = try await library.topicDefinitions()
                .map { "\($0.id): \($0.title)" }
                .joined(separator: "\n")
            status = "Refreshed the local database"
            await restoreSelection(preferredEntryID: entryID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func capture(_ text: String) async {
        guard let library else {
            errorMessage = "Open a Briefly library before capturing."
            return
        }
        isIngesting = true
        defer { isIngesting = false }
        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(string: trimmed).flatMap {
                ["http", "https"].contains($0.scheme?.lowercased() ?? "") &&
                    $0.host != nil &&
                    !trimmed.contains(where: \.isWhitespace)
                    ? $0
                    : nil
            }
            status = url == nil ? "Capturing text…" : "Extracting the item…"
            let router = NativeItemInputRouter()
            var request = ItemInputRequest(source: url.map(ItemInputSource.url) ?? .text(trimmed))
            request.retainAudio = UserDefaults.standard.bool(forKey: "BrieflySaveCapturedAudio") &&
                router.inputID(for: request) == .youtube
            let draft = try await router.ingest(
                request,
                context: itemInputContext()
            )
            let id = try await library.captureItem(draft)
            await refreshLibrary(selecting: id)
            activeSection = .items
            if environment.isUITesting {
                status = "Captured"
                return
            }
            status = "Captured. Preparing summaries…"
            isIngesting = false
            await enqueueProcessing(id)
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setBrowserIngesting(_ ingesting: Bool) {
        isIngesting = ingesting
        if ingesting {
            status = "Extracting the signed-in page…"
        }
    }

    func captureWebPage(url: URL, page: SignedInChannelPage) async {
        guard let library else {
            errorMessage = "Open a Briefly library before saving web pages."
            return
        }
        isIngesting = true
        defer { isIngesting = false }
        do {
            let id = try await library.captureItem(ItemDraft(
                inputID: .webPage,
                title: page.title,
                content: page.text,
                sourceURL: url,
                canonicalURL: url,
                faviconData: page.faviconData,
                faviconFileExtension: page.faviconFileExtension
            ))
            await refreshLibrary(selecting: id)
            status = "Saved the signed-in page. Preparing summaries…"
            isIngesting = false
            await enqueueProcessing(id)
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func capturePDF(_ url: URL) async {
        guard let library else {
            errorMessage = "Choose a local Briefly library before importing a PDF."
            return
        }
        isIngesting = true
        defer { isIngesting = false }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let draft = try await NativeItemInputRouter().ingest(
                ItemInputRequest(source: .file(url)),
                context: itemInputContext()
            )
            let entryID = try await library.captureItem(draft)
            await refreshLibrary(selecting: entryID)
            status = "PDF captured. Preparing summaries…"
            isIngesting = false
            await enqueueProcessing(entryID)
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveText(
        _ text: String,
        entryID: String,
        variant: LibraryVariant
    ) async {
        guard let library, !entryID.isEmpty else { return }
        do {
            try await library.writeText(
                entryID: entryID,
                variant: variant,
                text: text
            )
            projection = try await library.loadLibraryIndex()
            if selectedID == entryID, selectedVariant == variant {
                selectedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            status = "Document saved"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addHighlight(_ text: String) async {
        guard let library, !selectedID.isEmpty else { return }
        do {
            try await library.addHighlight(
                entryID: selectedID,
                variant: selectedVariant,
                text: text
            )
            try await refreshHighlights(from: library)
            status = "Added to Highlights"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeHighlight(_ text: String) async {
        guard let library else { return }
        do {
            guard try await library.removeHighlight(text) else { return }
            try await refreshHighlights(from: library)
            status = "Removed from Highlights"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
