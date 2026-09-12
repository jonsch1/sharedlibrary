import BrieflyCore
import Foundation
import Observation

struct LibraryProcessingConfiguration: Sendable {
    let command: String
    let prompt: String
    let openRouterAPIKey: String?
    let codexHome: URL?
}

@MainActor
@Observable
final class LibraryProcessingModel {
    let session: LibrarySession
    let inputService: LibraryInputService

    var isIngesting = false
    var isProcessing = false

    init(session: LibrarySession, inputService: LibraryInputService) {
        self.session = session
        self.inputService = inputService
    }

    func enqueueProcessing(
        _ entryIDs: [String],
        selectWhenFinished: Bool = false,
        configuration: LibraryProcessingConfiguration
    ) async -> [ProcessingJobResult] {
        guard let library = session.library else { return [] }
        do {
            for entryID in entryIDs {
                try await library.enqueueProcessingJob(
                    entryID: entryID,
                    selectWhenFinished: selectWhenFinished
                )
            }
            return await drainProcessingQueue(
                configuration: configuration
            )
        } catch {
            session.errorMessage = error.localizedDescription
            return []
        }
    }

    func drainProcessingQueue(
        configuration: LibraryProcessingConfiguration
    ) async -> [ProcessingJobResult] {
        #if os(iOS)
        return []
        #else
        guard let library = session.library, !isProcessing else { return [] }
        isProcessing = true
        session.status = "Preparing summaries…"
        defer { isProcessing = false }

        var results = [ProcessingJobResult]()
        await withTaskGroup(of: ProcessingJobResult.self) { group in
            var activeTasks = 0

            for _ in 0..<3 {
                guard let job = try? await library.claimNextProcessingJob() else { break }
                activeTasks += 1
                group.addTask { await self.process(job, configuration: configuration) }
            }

            while activeTasks > 0 {
                if Task.isCancelled { group.cancelAll() }
                if let result = await group.next() {
                    results.append(result)
                }
                activeTasks -= 1
                if !Task.isCancelled,
                   let job = try? await library.claimNextProcessingJob()
                {
                    activeTasks += 1
                    group.addTask { await self.process(job, configuration: configuration) }
                }
            }
        }
        session.status = "Summaries ready"
        return results
        #endif
    }

    @discardableResult
    func capture(_ text: String) async -> String? {
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
            session.status = url == nil ? "Capturing text…" : "Extracting the item…"
            let router = NativeItemInputRouter()
            let request = ItemInputRequest(source: url.map(ItemInputSource.url) ?? .text(trimmed))
            let draft = try await router.ingest(request, context: inputService.itemInputContext())
            let id = try await library.captureItem(draft)
            session.status = "Captured"
            return id
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    func captureShared(
        _ request: ItemInputRequest,
        captureID: String
    ) async throws -> String {
        guard let library = session.library else { throw LibraryError.missingEntry }
        isIngesting = true
        defer { isIngesting = false }
        session.status = switch request.source {
        case .url: "Importing a shared link…"
        case .text: "Importing shared text…"
        case .file: "Importing a shared PDF…"
        }
        let draft = try await NativeItemInputRouter().ingest(
            request,
            context: inputService.itemInputContext()
        )
        return try await library.captureItem(draft, captureID: captureID)
    }

    func setBrowserIngesting(_ ingesting: Bool) {
        isIngesting = ingesting
        if ingesting {
            session.status = "Extracting the signed-in page…"
        }
    }

    @discardableResult
    func captureWebPage(url: URL, page: SignedInChannelPage) async -> String? {
        guard let library = session.library else {
            session.errorMessage = "Open a Briefly library before saving web pages."
            return nil
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
            session.status = "Saved the signed-in page"
            return id
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func capturePDF(_ url: URL) async -> String? {
        guard let library = session.library else {
            session.errorMessage = "Choose a local Briefly library before importing a PDF."
            return nil
        }
        isIngesting = true
        defer { isIngesting = false }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let draft = try await inputService.ingestPDF(url)
            let entryID = try await library.captureItem(draft)
            session.status = "PDF captured"
            return entryID
        } catch {
            session.errorMessage = error.localizedDescription
            return nil
        }
    }

    private func process(
        _ job: SQLiteProcessingJob,
        configuration: LibraryProcessingConfiguration
    ) async -> ProcessingJobResult {
        guard let library = session.library else {
            return ProcessingJobResult(
                entryID: job.documentID,
                selectedID: nil,
                succeeded: false
            )
        }
        let entryID = job.documentID
        do {
            let prompt = try await library.processingPrompt(
                entryID: entryID,
                template: configuration.prompt
            )
            let output: String
            if let apiKey = configuration.openRouterAPIKey,
               !apiKey.isEmpty {
                output = try await runOpenRouterProcessing(
                    prompt: prompt,
                    format: "json",
                    apiKey: apiKey
                )
            } else {
                #if os(macOS)
                let hasAccess = configuration.codexHome?.startAccessingSecurityScopedResource() ?? false
                defer {
                    if hasAccess { configuration.codexHome?.stopAccessingSecurityScopedResource() }
                }
                output = try await runProcessingCommand(
                    configuration.command,
                    prompt: prompt,
                    environmentOverrides: configuration.codexHome.map {
                        ["CODEX_HOME": $0.path]
                    } ?? [:]
                )
                #else
                throw LibraryError.processingUnavailable
                #endif
            }
            let suggestion = try ProcessingSuggestion.decode(output)
            let processedID = try await library.applyProcessingSuggestion(
                entryID: entryID,
                suggestion: suggestion
            )
            try await library.completeProcessingJob(entryID: entryID)
            return ProcessingJobResult(
                entryID: entryID,
                selectedID: job.selectWhenFinished ? processedID : nil,
                succeeded: true
            )
        } catch is CancellationError {
            try? await library.enqueueProcessingJob(
                entryID: entryID,
                selectWhenFinished: job.selectWhenFinished
            )
            return ProcessingJobResult(
                entryID: entryID,
                selectedID: nil,
                succeeded: false
            )
        } catch {
            try? await library.failProcessingJob(
                entryID: entryID,
                error: error.localizedDescription
            )
            session.errorMessage = error.localizedDescription
            session.status = "The capture is saved without summaries"
            return ProcessingJobResult(
                entryID: entryID,
                selectedID: nil,
                succeeded: false
            )
        }
    }
}

private struct OpenRouterResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct OpenRouterFailure: Decodable {
    struct Detail: Decodable {
        let message: String?
    }

    let error: Detail?
}

func runOpenRouterProcessing(
    prompt: String,
    format: String,
    apiKey: String
) async throws -> String {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BrieflyBackendError.message("Enter an OpenRouter API key first.")
    }
    guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
        throw BrieflyBackendError.message("The OpenRouter service URL is invalid.")
    }

    var request = URLRequest(url: url, timeoutInterval: 15 * 60)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("https://www.readbriefly.fyi", forHTTPHeaderField: "HTTP-Referer")
    request.setValue("Briefly", forHTTPHeaderField: "X-Title")

    var payload: [String: Any] = [
        "model": "openai/gpt-5.6-luna",
        "messages": [["role": "user", "content": prompt]],
        "max_tokens": format == "json" ? 32_000 : 16_000,
        "provider": [
            "order": ["fireworks"],
            "allow_fallbacks": true
        ]
    ]
    if format == "json" {
        payload["response_format"] = [
            "type": "json_schema",
            "json_schema": [
                "name": "briefly_processing",
                "strict": true,
                "schema": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "short_filename": ["type": "string"],
                        "summaries": [
                            "type": "object",
                            "additionalProperties": false,
                            "properties": [
                                "detailed": ["type": "string"],
                                "concise": ["type": "string"]
                            ],
                            "required": ["detailed", "concise"]
                        ],
                        "topic_name": ["type": "string"]
                    ],
                    "required": ["short_filename", "summaries", "topic_name"]
                ]
            ]
        ]
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (data, rawResponse) = try await URLSession.shared.data(for: request)
    guard let response = rawResponse as? HTTPURLResponse else {
        throw BrieflyBackendError.message("OpenRouter returned an invalid response.")
    }
    guard (200..<300).contains(response.statusCode) else {
        let failure = try? JSONDecoder().decode(OpenRouterFailure.self, from: data)
        throw BrieflyBackendError.message(
            failure?.error?.message ?? "OpenRouter could not process this request."
        )
    }
    let result = try? JSONDecoder().decode(OpenRouterResponse.self, from: data)
    guard let output = result?.choices.first?.message.content?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !output.isEmpty else {
        throw BrieflyBackendError.message("OpenRouter returned no output.")
    }
    return output
}
