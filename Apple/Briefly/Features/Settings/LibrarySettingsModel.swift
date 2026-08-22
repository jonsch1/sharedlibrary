import BrieflyCore
import Foundation
import Observation
import Security

@MainActor
@Observable
final class LibrarySettingsModel {
    static let processingDefaultCommand = BrieflyCore.defaultProcessingCommand
    static let processingCommandKey = "BrieflyProcessingCommand"
    static let processingPromptKey = "BrieflyProcessingPrompt"
    static let aboutYouKey = "BrieflyAboutYou"

    let session: LibrarySession
    var topicsText = ""
    var isTestingAI = false
    var processingCommand: String
    var processingPrompt: String
    var openRouterAPIKey: String
    var aboutYou: String

    init(session: LibrarySession) {
        self.session = session
        let savedCommand = UserDefaults.standard.string(forKey: Self.processingCommandKey)
        processingCommand = savedCommand == "briefly://openrouter/openai/gpt-5.6-luna"
            ? Self.processingDefaultCommand
            : savedCommand ?? Self.processingDefaultCommand
        processingPrompt = UserDefaults.standard.string(forKey: Self.processingPromptKey)
            ?? defaultProcessingPrompt
        openRouterAPIKey = OpenRouterCredentialStore.load() ?? ""
        aboutYou = UserDefaults.standard.string(forKey: Self.aboutYouKey) ?? ""
    }

    var processingConfiguration: LibraryProcessingConfiguration {
        LibraryProcessingConfiguration(
            command: processingCommand,
            prompt: processingPrompt,
            openRouterAPIKey: openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        )
    }

    var defaultProcessingCommand: String { BrieflyCore.defaultProcessingCommand }

    func refreshTopics(from library: SQLiteLibraryStore) async throws {
        topicsText = try await library.topicDefinitions()
            .map { "\($0.id): \($0.title)" }
            .joined(separator: "\n")
    }

    func saveProcessingSettings() {
        let command = processingCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = processingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command.count <= 4_000 else {
            session.errorMessage = "The AI command must contain 1–4,000 characters."
            return
        }
        guard
            !prompt.isEmpty,
            prompt.count <= 50_000,
            prompt.contains("{{topics}}"),
            prompt.contains("{{source}}")
        else {
            session.errorMessage =
                "The processing prompt must contain {{topics}} and {{source}}."
            return
        }
        processingCommand = command
        processingPrompt = prompt
        let apiKey = openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try OpenRouterCredentialStore.save(apiKey)
        } catch {
            session.errorMessage = error.localizedDescription
            return
        }
        openRouterAPIKey = apiKey
        UserDefaults.standard.set(command, forKey: Self.processingCommandKey)
        UserDefaults.standard.set(prompt, forKey: Self.processingPromptKey)
        session.status = apiKey.isEmpty
            ? "AI command settings saved"
            : "OpenRouter settings saved"
    }

    func testProcessingCommand() async {
        guard !isTestingAI else { return }
        isTestingAI = true
        defer { isTestingAI = false }
        do {
            let prompt = "Reply with exactly: Briefly is ready."
            let output: String
            #if os(macOS)
            if let apiKey = processingConfiguration.openRouterAPIKey {
                output = try await runOpenRouterProcessing(
                    prompt: prompt,
                    format: "text",
                    apiKey: apiKey
                )
            } else {
                output = try await runProcessingCommand(
                    processingCommand,
                    prompt: prompt,
                    timeout: 60
                )
            }
            #else
            throw LibraryError.processingUnavailable
            #endif
            guard output.localizedCaseInsensitiveContains("Briefly is ready") else {
                throw NativeLibraryError.unexpectedAIResponse
            }
            session.status = "Processing command works"
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func savePersonalizationSettings() {
        let context = aboutYou.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.count <= 10_000 else {
            session.errorMessage = "Personal context must be 10,000 characters or fewer."
            return
        }
        aboutYou = context
        UserDefaults.standard.set(context, forKey: Self.aboutYouKey)
        session.status = "Personalization settings saved"
    }

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
                throw BrieflyBackendError.message("That collection no longer exists.")
            }
            let renamed = definitions.map {
                $0.id == topic.id
                    ? LibraryTopicDefinition(id: $0.id, title: newTitle)
                    : $0
            }
            let saved = try await library.replaceTopicDefinitions(renamed)
            let savedTitle = saved.first(where: { $0.id == topic.id })?.title ?? newTitle
            session.status = "Collection renamed"
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
                throw BrieflyBackendError.message("That collection no longer exists.")
            }
            try await library.deleteTopicDefinition(id: topic.id)
            session.status = "Collection deleted. Its notes are still in your library."
            return true
        } catch {
            session.errorMessage = error.localizedDescription
            return false
        }
    }
}

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
            SecItemDelete(baseQuery as CFDictionary)
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
