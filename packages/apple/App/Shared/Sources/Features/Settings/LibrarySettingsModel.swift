import BrieflyCore
import CryptoKit
import Foundation
import Observation
import Security
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class LibrarySettingsModel {
    #if os(macOS)
    static let processingPromptKey = "BrieflyProcessingPrompt"
    static let processingVerificationKey = "BrieflyProcessingVerification"
    static let openRouterModelIDKey = "BrieflyOpenRouterModelID"
    static let openRouterEffortKey = "BrieflyOpenRouterReasoningEffort"
    static let openRouterModelSelectionKey = "BrieflyOpenRouterModelSelection"

    #endif
    let session: LibrarySession
    var topicsText = ""
    var isTestingAI = false
    #if os(macOS)
    var processingPrompt: String
    private(set) var openRouterAPIKey: String
    var isConnectingOpenRouter = false
    var openRouterConnectionMessage: String?
    var openRouterConnectionFailed = false
    @ObservationIgnored private var openRouterSignInTask: Task<Void, Never>?
    var processingVerificationFingerprint: String
    private(set) var openRouterModelID: String
    private(set) var openRouterReasoningEffort: String?
    private(set) var openRouterModelSelection: OpenRouterModelSelection?
    var isLoadingOpenRouterModel = false
    var openRouterModelMessage: String?
    var openRouterModelFailed = false

    #endif

    init(session: LibrarySession) {
        self.session = session
        #if os(macOS)
        processingPrompt = UserDefaults.standard.string(forKey: Self.processingPromptKey)
            ?? defaultProcessingPrompt
        openRouterAPIKey = OpenRouterCredentialStore.load() ?? ""
        processingVerificationFingerprint = UserDefaults.standard.string(
            forKey: Self.processingVerificationKey
        ) ?? ""
        let modelID = UserDefaults.standard.string(forKey: Self.openRouterModelIDKey) ?? defaultOpenRouterModelID
        let selection = UserDefaults.standard.data(forKey: Self.openRouterModelSelectionKey)
            .flatMap { try? JSONDecoder().decode(OpenRouterModelSelection.self, from: $0) }
        let savedEffort = UserDefaults.standard.string(forKey: Self.openRouterEffortKey)
        openRouterModelID = modelID
        openRouterModelSelection = selection?.modelID == modelID ? selection : nil
        openRouterReasoningEffort = selection?.modelID == modelID &&
            selection?.model.availableEfforts.contains(savedEffort ?? "") == true ? savedEffort : nil
        #endif
    }

    #if os(macOS)
    var processingConfiguration: LibraryProcessingConfiguration {
        LibraryProcessingConfiguration(
            prompt: processingPrompt,
            openRouterAPIKey: openRouterAPIKey.nilIfEmpty,
            modelID: openRouterModelID,
            reasoningEffort: openRouterReasoningEffort,
            model: openRouterModelSelection?.model
        )
    }

    var isOpenRouterConnected: Bool { !openRouterAPIKey.isEmpty }

    var isProcessingConfigured: Bool {
        isOpenRouterConnected && processingVerificationFingerprint == processingFingerprint
    }

    @discardableResult
    func updateOpenRouterModel(_ value: String, force: Bool = true) async -> Bool {
        guard !isLoadingOpenRouterModel, !isTestingAI else { return false }
        let modelID = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, let selection = openRouterModelSelection,
           selection.modelID == modelID, Date().timeIntervalSince(selection.fetchedAt) < 6 * 60 * 60 {
            return true
        }
        isLoadingOpenRouterModel = true
        openRouterModelMessage = nil
        openRouterModelFailed = false
        defer { isLoadingOpenRouterModel = false }
        do {
            let model = try await fetchOpenRouterModel(modelID)
            try Task.checkCancellation()
            guard model.supportsSummaries else {
                throw BrieflyBackendError.message("This model cannot create Briefly’s structured summaries. Choose a text model that supports structured outputs.")
            }
            let changedModel = modelID != openRouterModelID
            let resetEffort = changedModel || !model.availableEfforts.contains(openRouterReasoningEffort ?? "")
            let selection = OpenRouterModelSelection(modelID: modelID, model: model)
            let data = try JSONEncoder().encode(selection)
            openRouterModelID = modelID
            openRouterModelSelection = selection
            if resetEffort {
                openRouterReasoningEffort = nil
                UserDefaults.standard.removeObject(forKey: Self.openRouterEffortKey)
            }
            UserDefaults.standard.set(modelID, forKey: Self.openRouterModelIDKey)
            UserDefaults.standard.set(data, forKey: Self.openRouterModelSelectionKey)
            if changedModel { openRouterModelMessage = "Model saved. Changes apply to future summaries." }
            return true
        } catch is CancellationError {
            return false
        } catch {
            openRouterModelFailed = true
            openRouterModelMessage = error.localizedDescription
            return false
        }
    }

    func setOpenRouterReasoningEffort(_ value: String?) {
        guard !isTestingAI, !isLoadingOpenRouterModel else { return }
        if let value, openRouterModelSelection?.model.availableEfforts.contains(value) != true { return }
        openRouterReasoningEffort = value
        if let value { UserDefaults.standard.set(value, forKey: Self.openRouterEffortKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.openRouterEffortKey) }
    }
    #endif

    func refreshTopics(from library: SQLiteLibraryStore) async throws {
        topicsText = try await library.topicDefinitions()
            .map { "\($0.id): \($0.title)" }
            .joined(separator: "\n")
    }

    #if os(macOS)
    func connectOpenRouter() {
        guard !isConnectingOpenRouter, !isTestingAI else { return }
        isConnectingOpenRouter = true
        openRouterConnectionFailed = false
        openRouterConnectionMessage = "Finish signing in in your browser, then return to Briefly."
        session.errorMessage = nil
        openRouterSignInTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isConnectingOpenRouter = false
                openRouterSignInTask = nil
            }
            do {
                let key = try await OpenRouterOAuth().signIn { NSWorkspace.shared.open($0) }
                try Task.checkCancellation()
                try storeOpenRouterConnection(key, verified: true)
                openRouterConnectionMessage = nil
                NSApp.activate(ignoringOtherApps: true)
            } catch is CancellationError {
                openRouterConnectionMessage = "Sign-in canceled. You can try again whenever you’re ready."
            } catch {
                openRouterConnectionFailed = true
                openRouterConnectionMessage = error.localizedDescription
            }
        }
    }

    func cancelOpenRouterSignIn() {
        openRouterSignInTask?.cancel()
    }

    func disconnectOpenRouter() {
        guard !isConnectingOpenRouter, !isTestingAI else { return }
        do {
            try OpenRouterCredentialStore.save("")
            openRouterAPIKey = ""
            processingVerificationFingerprint = ""
            UserDefaults.standard.removeObject(forKey: Self.processingVerificationKey)
            openRouterConnectionFailed = false
            openRouterConnectionMessage = "Disconnected. You can revoke Briefly’s key in OpenRouter settings."
            session.status = "OpenRouter disconnected"
        } catch {
            openRouterConnectionFailed = true
            openRouterConnectionMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveOpenRouterAPIKey(_ value: String) -> Bool {
        guard !isConnectingOpenRouter, !isTestingAI else { return false }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 4_000 else {
            openRouterConnectionFailed = true
            openRouterConnectionMessage = "Enter a valid OpenRouter API key."
            return false
        }
        do {
            try storeOpenRouterConnection(key, verified: false)
            openRouterConnectionMessage = "API key saved. Test the connection to check access."
            return true
        } catch {
            openRouterConnectionFailed = true
            openRouterConnectionMessage = error.localizedDescription
            return false
        }
    }

    private func storeOpenRouterConnection(_ key: String, verified: Bool) throws {
        try OpenRouterCredentialStore.save(key)
        openRouterAPIKey = key
        processingVerificationFingerprint = verified ? processingFingerprint : ""
        UserDefaults.standard.set(processingVerificationFingerprint, forKey: Self.processingVerificationKey)
        openRouterConnectionFailed = false
        session.status = "OpenRouter connected"
    }

    @discardableResult
    func saveProcessingPrompt() -> Bool {
        let prompt = processingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= 50_000,
              prompt.contains("{{topics}}"), prompt.contains("{{source}}") else {
            session.errorMessage = "Summary instructions must contain {{topics}} and {{source}}, and be at most 50,000 characters."
            return false
        }
        processingPrompt = prompt
        UserDefaults.standard.set(prompt, forKey: Self.processingPromptKey)
        session.status = "Summary instructions saved"
        return true
    }

    var hasUnsavedProcessingPrompt: Bool {
        processingPrompt != (UserDefaults.standard.string(forKey: Self.processingPromptKey) ?? defaultProcessingPrompt)
    }

    func testOpenRouterConnection() async {
        guard !isTestingAI, !isConnectingOpenRouter, !isLoadingOpenRouterModel, isOpenRouterConnected else { return }
        isTestingAI = true
        openRouterConnectionMessage = nil
        openRouterConnectionFailed = false
        defer { isTestingAI = false }
        do {
            let output = try await runOpenRouterProcessing(
                prompt: "Reply with exactly: Briefly is ready.", format: "text", apiKey: openRouterAPIKey,
                modelID: openRouterModelID, reasoningEffort: openRouterReasoningEffort,
                model: openRouterModelSelection?.model
            )
            guard processingTestResponseIsValid(output) else {
                throw NativeLibraryError.unexpectedAIResponse
            }
            processingVerificationFingerprint = processingFingerprint
            UserDefaults.standard.set(processingVerificationFingerprint, forKey: Self.processingVerificationKey)
            openRouterConnectionMessage = "Connection verified. Briefly is ready to create summaries."
            session.status = "OpenRouter connection verified"
        } catch {
            processingVerificationFingerprint = ""
            UserDefaults.standard.removeObject(forKey: Self.processingVerificationKey)
            openRouterConnectionFailed = true
            openRouterConnectionMessage = error.localizedDescription
        }
    }

    private var processingFingerprint: String {
        SHA256.hash(data: Data(("openrouter\n" + openRouterAPIKey).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    #endif

    @discardableResult
    func saveTopics() async -> Bool {
        guard let library = session.library else { return false }
        do {
            let definitions = try topicsText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { line -> LibraryTopicDefinition in
                    guard let separator = line.firstIndex(of: ":") else {
                        throw BrieflyBackendError.message("Write each topic as “id: Title”.")
                    }
                    return LibraryTopicDefinition(
                        id: String(line[..<separator]).trimmingCharacters(in: .whitespaces),
                        title: String(line[line.index(after: separator)...])
                            .trimmingCharacters(in: .whitespaces)
                    )
                }
            let saved = try await library.replaceTopicDefinitions(definitions)
            topicsText = saved.map { "\($0.id): \($0.title)" }.joined(separator: "\n")
            session.projection = try await library.loadLibraryIndex()
            session.status = "Topics saved"
            return true
        } catch {
            session.errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func renameTopic(_ currentTitle: String, to newTitle: String) async -> String? {
        guard let library = session.library else { return nil }
        do {
            let definitions = try await library.topicDefinitions()
            guard let topic = definitions.first(where: { $0.title == currentTitle }) else {
                throw BrieflyBackendError.message("That topic no longer exists.")
            }
            let renamed = definitions.map {
                $0.id == topic.id
                    ? LibraryTopicDefinition(id: $0.id, title: newTitle)
                    : $0
            }
            let saved = try await library.replaceTopicDefinitions(renamed)
            let savedTitle = saved.first(where: { $0.id == topic.id })?.title ?? newTitle
            session.status = "Topic renamed"
            return savedTitle
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func deleteTopic(_ title: String) async -> Bool {
        guard let library = session.library else { return false }
        do {
            let definitions = try await library.topicDefinitions()
            guard let topic = definitions.first(where: { $0.title == title }) else {
                throw BrieflyBackendError.message("That topic no longer exists.")
            }
            try await library.deleteTopicDefinition(id: topic.id)
            session.status = "Topic deleted. Its items are still in your library."
            return true
        } catch {
            session.errorMessage = error.localizedDescription
            return false
        }
    }
}

#if os(macOS)
private enum OpenRouterCredentialStore {
    private static let service = "fyi.readbriefly.BrieflyNative.openrouter"
    private static let account = "openrouter_api_key"

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let key = String(data: data, encoding: .utf8),
            !key.isEmpty
        else {
            return nil
        }
        return key
    }

    static func save(_ key: String) throws {
        if key.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw BrieflyBackendError.message("Briefly could not remove the OpenRouter connection.")
            }
            return
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecItemNotFound else {
            guard status == errSecSuccess else {
                throw BrieflyBackendError.message("Briefly could not save the OpenRouter API key.")
            }
            return
        }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw BrieflyBackendError.message("Briefly could not save the OpenRouter API key.")
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

#endif
