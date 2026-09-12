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
    static let processingDefaultCommand = BrieflyCore.defaultProcessingCommand
    static let processingCommandKey = "BrieflyProcessingCommand"
    static let processingPromptKey = "BrieflyProcessingPrompt"
    static let processingVerificationKey = "BrieflyProcessingVerification"

    let session: LibrarySession
    var topicsText = ""
    var isTestingAI = false
    var processingCommand: String
    var processingPrompt: String
    var openRouterAPIKey: String
    var processingVerificationFingerprint: String
    var processingTestMessage: String?
    var processingTestSucceeded = false

    init(session: LibrarySession) {
        self.session = session
        let savedCommand = UserDefaults.standard.string(forKey: Self.processingCommandKey)
        processingCommand = switch savedCommand {
        case "briefly://openrouter/openai/gpt-5.6-luna",
             "codex exec --ephemeral --ignore-user-config --sandbox read-only --skip-git-repo-check --color never -":
            Self.processingDefaultCommand
        default:
            savedCommand ?? Self.processingDefaultCommand
        }
        processingPrompt = UserDefaults.standard.string(forKey: Self.processingPromptKey)
            ?? defaultProcessingPrompt
        openRouterAPIKey = OpenRouterCredentialStore.load() ?? ""
        processingVerificationFingerprint = UserDefaults.standard.string(
            forKey: Self.processingVerificationKey
        ) ?? ""
    }

    var processingConfiguration: LibraryProcessingConfiguration {
        #if os(macOS)
        let codexHome = CodexAccessStore.resolve()
        #else
        let codexHome: URL? = nil
        #endif
        return LibraryProcessingConfiguration(
            command: processingCommand,
            prompt: processingPrompt,
            openRouterAPIKey: openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            codexHome: codexHome
        )
    }

    #if os(macOS)
    var hasCodexAccess: Bool { CodexAccessStore.resolve() != nil }

    var codexAccessDescription: String {
        guard let url = CodexAccessStore.resolve() else {
            return "Briefly will use the Codex login from /Users/\(NSUserName())/.codex."
        }
        return "Codex access granted for \(url.path)"
    }

    func grantCodexAccess() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Codex folder"
        panel.message = "Choose ~/.codex so Briefly can use your existing Codex login."
        panel.prompt = "Allow Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let home = CodexAccessStore.userHome
        panel.directoryURL = home
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.lastPathComponent == ".codex" else {
            session.errorMessage = "Choose the .codex folder in your home folder."
            return
        }
        do {
            try CodexAccessStore.save(url)
            processingTestMessage = "Codex access granted. Test the connection to verify it."
            session.status = "Codex access granted"
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }
    #endif

    var defaultProcessingCommand: String { BrieflyCore.defaultProcessingCommand }

    #if os(macOS)
    var usesCodexCommand: Bool {
        processingCommand
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map { URL(fileURLWithPath: String($0)).lastPathComponent == "codex" } ?? false
    }

    var requiresCodexAccess: Bool {
        usesCodexCommand && processingConfiguration.openRouterAPIKey == nil
    }
    #endif

    var isProcessingConfigured: Bool {
        let verified =
            !processingCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            processingVerificationFingerprint == processingFingerprint
        #if os(macOS)
        return verified && (!requiresCodexAccess || hasCodexAccess)
        #else
        return verified
        #endif
    }

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
        #if os(macOS)
        guard !requiresCodexAccess || hasCodexAccess else {
            processingTestMessage = "Grant Briefly access to ~/.codex before testing Codex."
            session.errorMessage = processingTestMessage
            return
        }
        #endif
        isTestingAI = true
        processingTestMessage = nil
        processingTestSucceeded = false
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
                let codexHome = processingConfiguration.codexHome
                let hasAccess = codexHome?.startAccessingSecurityScopedResource() ?? false
                defer {
                    if hasAccess { codexHome?.stopAccessingSecurityScopedResource() }
                }
                output = try await runProcessingCommand(
                    processingCommand,
                    prompt: prompt,
                    timeout: 60,
                    environmentOverrides: codexHome.map {
                        ["CODEX_HOME": $0.path]
                    } ?? [:]
                )
            }
            #else
            throw LibraryError.processingUnavailable
            #endif
            guard processingTestResponseIsValid(output) else {
                throw NativeLibraryError.unexpectedAIResponse
            }
            processingVerificationFingerprint = processingFingerprint
            UserDefaults.standard.set(
                processingVerificationFingerprint,
                forKey: Self.processingVerificationKey
            )
            processingTestSucceeded = true
            processingTestMessage = "AI setup verified. Briefly is ready to process captures."
            session.status = "Processing command works"
        } catch {
            processingVerificationFingerprint = ""
            UserDefaults.standard.removeObject(forKey: Self.processingVerificationKey)
            processingTestMessage = error.localizedDescription
            session.errorMessage = error.localizedDescription
        }
    }

    private var processingFingerprint: String {
        let configuration = [
            processingCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(configuration.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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

#if os(macOS)
private enum CodexAccessStore {
    private static let bookmarkKey = "BrieflyCodexHomeBookmark"

    static let userHome = URL(fileURLWithPath: "/Users/\(NSUserName())", isDirectory: true)

    private static var expectedURL: URL {
        userHome.appendingPathComponent(".codex", isDirectory: true)
    }

    private static func isExpectedURL(_ url: URL) -> Bool {
        url.standardizedFileURL.path == expectedURL.standardizedFileURL.path
    }

    static func resolve() -> URL? {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), isExpectedURL(url) {
                if isStale, let refreshed = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
                }
                return url
            }
        }
        if FileManager.default.fileExists(atPath: expectedURL.path) {
            return expectedURL
        }
        return nil
    }

    static func save(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }
}
#endif

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
