import BrieflyCore
import Foundation
import Observation

/// Saving is available on every device. Only the Mac owns extraction services.
@MainActor
@Observable
final class LibraryCaptureModel {
    let session: LibrarySession
    var isIngesting = false
    #if os(macOS)
    let inputService: LibraryInputService
    #endif

    init(session: LibrarySession) {
        self.session = session
        #if os(macOS)
        self.inputService = LibraryInputService(session: session)
        #endif
    }

    @discardableResult
    func capture(_ text: String, useNative: Bool = false) async -> String? {
        guard let library = session.library else {
            session.errorMessage = "Open a Briefly library before capturing."
            return nil
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
            session.status = "Saving…"
            let request = ItemInputRequest(source: url.map(ItemInputSource.url) ?? .text(trimmed))
            #if os(macOS)
            let result = try await inputService.captureCoordinator.capture(
                request, in: library, context: inputService.itemInputContext(), useNative: useNative
            )
            session.status = "Captured"
            return result.id
            #else
            let id = try await library.queueCapture(request)
            session.status = "Saved to inbox"
            return id
            #endif
        } catch let failure as BrieflyCustomCaptureFailure {
            session.customCaptureFailure = failure
            return nil
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func captureFile(_ url: URL) async -> String? {
        guard let library = session.library else {
            session.errorMessage = "Open a Briefly library before importing a file."
            return nil
        }
        isIngesting = true
        defer { isIngesting = false }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let request = try CaptureFileInput.read(url)
            #if os(macOS)
            let result = try await inputService.captureCoordinator.capture(
                request, in: library, context: inputService.itemInputContext()
            )
            let entryID = result.id
            #else
            let entryID = try await library.queueCapture(request)
            #endif
            session.status = "File saved"
            return entryID
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

}
