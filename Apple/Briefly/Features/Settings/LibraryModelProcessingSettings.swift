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
    func processSelected() async {
        guard !selectedID.isEmpty else { return }
        await enqueueProcessing(selectedID)
    }

    func saveProcessingSettings() {
        let command = processingCommand.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let prompt = processingPrompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !command.isEmpty, command.count <= 4_000 else {
            errorMessage = "The AI command must contain 1–4,000 characters."
            return
        }
        guard
            !prompt.isEmpty,
            prompt.count <= 50_000,
            prompt.contains("{{topics}}"),
            prompt.contains("{{source}}")
        else {
            errorMessage =
                "The processing prompt must contain {{topics}} and {{source}}."
            return
        }
        processingCommand = command
        processingPrompt = prompt
        UserDefaults.standard.set(command, forKey: Self.processingCommandKey)
        UserDefaults.standard.set(prompt, forKey: Self.processingPromptKey)
        status = "AI processing settings saved"
    }

    func testProcessingCommand() async {
        guard !isTestingAI else { return }
        isTestingAI = true
        defer { isTestingAI = false }
        do {
            let prompt = "Reply with exactly: Briefly is ready."
            let output: String
            if usesManagedAI {
                output = try await backend.runManagedAI(prompt: prompt, format: "text")
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
            status = "Processing command works"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func useManagedAI(_ enabled: Bool) {
        processingCommand = enabled
            ? Self.managedAICommand
            : defaultProcessingCommand
    }

    func savePersonalizationSettings() {
        let context = aboutYou.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.count <= 10_000 else {
            errorMessage = "Personal context must be 10,000 characters or fewer."
            return
        }
        aboutYou = context
        UserDefaults.standard.set(context, forKey: Self.aboutYouKey)
        status = "Personalization settings saved"
    }

    func saveTopics() async {
        guard let library else { return }
        do {
            let definitions = try topicsText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { line -> LibraryTopicDefinition in
                    guard let separator = line.firstIndex(of: ":") else {
                        throw BrieflyBackendError.message(
                            "Write each topic as “id: Title”."
                        )
                    }
                    return LibraryTopicDefinition(
                        id: String(line[..<separator])
                            .trimmingCharacters(in: .whitespaces),
                        title: String(line[line.index(after: separator)...])
                            .trimmingCharacters(in: .whitespaces)
                    )
                }
            let saved = try await library.replaceTopicDefinitions(definitions)
            topicsText = saved.map { "\($0.id): \($0.title)" }
                .joined(separator: "\n")
            projection = try await library.loadLibraryIndex()
            status = "Topics saved"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameTopic(_ currentTitle: String, to newTitle: String) async {
        guard let library else { return }
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
            await refreshLibrary()
            if selectedTopic == currentTitle { selectedTopic = savedTitle }
            status = "Collection renamed"
            requestSync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
