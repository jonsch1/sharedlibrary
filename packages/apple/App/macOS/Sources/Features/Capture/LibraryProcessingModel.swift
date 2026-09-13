#if os(macOS)
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

    var isProcessing = false
    var onStateChanged: (@MainActor @Sendable () async -> Void)?

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
                let document = try await library.getDocument(entryID)
                if var request = document.captureRequest {
                    guard request.hasExtractedSource else { continue }
                    request.state = .summarizing
                    request.error = nil
                    _ = try await library.batch([.init(
                        id: entryID, baseRevision: document.revision, captureRequest: request
                    )])
                }
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
        guard let library = session.library, !isProcessing else { return [] }
        isProcessing = true
        session.status = "Preparing summaries…"
        defer { isProcessing = false }

        do {
            for id in try await library.pendingCaptureIDs() {
                do {
                    try await library.extractQueuedCapture(
                        id, context: inputService.itemInputContext(),
                        extract: { [inputService] request in
                            try await inputService.captureCoordinator.extractSource(
                                request, context: inputService.itemInputContext()
                            )
                        },
                        onStateChanged: onStateChanged ?? {}
                    )
                } catch {
                    session.errorMessage = error.localizedDescription
                }
            }
        } catch { session.errorMessage = error.localizedDescription }

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
            if try await library.getDocument(entryID).captureRequest?.state == .ready {
                try await library.completeProcessingJob(entryID: entryID)
                return ProcessingJobResult(entryID: entryID, selectedID: nil, succeeded: true)
            }
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
            try? await library.failCapture(entryID, error: error.localizedDescription)
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

#endif
