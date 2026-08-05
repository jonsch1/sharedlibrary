import BrieflyCore
import Foundation
import Observation

@MainActor
@Observable
final class LibrarySettingsModel {
    static let managedAICommand = "briefly://openrouter/openai/gpt-5.6-luna"
    static let processingDefaultCommand = managedAICommand
    static let processingCommandKey = "BrieflyProcessingCommand"
    static let processingPromptKey = "BrieflyProcessingPrompt"
    static let aboutYouKey = "BrieflyAboutYou"

    let session: LibrarySession
    var topicsText = ""
    var isTestingAI = false
    var processingCommand: String
    var processingPrompt: String
    var aboutYou: String

    init(session: LibrarySession) {
        self.session = session
        processingCommand = UserDefaults.standard.string(forKey: Self.processingCommandKey)
            ?? Self.processingDefaultCommand
        processingPrompt = UserDefaults.standard.string(forKey: Self.processingPromptKey)
            ?? defaultProcessingPrompt
        aboutYou = UserDefaults.standard.string(forKey: Self.aboutYouKey) ?? ""
    }

    var usesManagedAI: Bool {
        processingCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            == Self.managedAICommand
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
        UserDefaults.standard.set(command, forKey: Self.processingCommandKey)
        UserDefaults.standard.set(prompt, forKey: Self.processingPromptKey)
        session.status = "AI processing settings saved"
    }

    func testProcessingCommand() async {
        guard !isTestingAI else { return }
        isTestingAI = true
        defer { isTestingAI = false }
        do {
            let prompt = "Reply with exactly: Briefly is ready."
            let output: String
            if usesManagedAI {
                output = try await session.backend.runManagedAI(prompt: prompt, format: "text")
            } else {
                #if os(macOS)
                output = try await runProcessingCommand(
                    processingCommand,
                    prompt: prompt,
                    timeout: 60
                )
                #else
                throw LibraryError.processingUnavailable
                #endif
            }
            guard output.localizedCaseInsensitiveContains("Briefly is ready") else {
                throw NativeLibraryError.unexpectedAIResponse
            }
            session.status = "Processing command works"
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }

    func useManagedAI(_ enabled: Bool) {
        processingCommand = enabled ? Self.managedAICommand : BrieflyCore.defaultProcessingCommand
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
