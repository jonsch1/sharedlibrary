import Foundation

enum SummaryDetailLevel: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case brief
    case concise
    case detailed
    case comprehensive

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .brief:
            return "Brief"
        case .concise:
            return "Concise"
        case .detailed:
            return "Detailed"
        case .comprehensive:
            return "Comprehensive"
        }
    }

    var description: String {
        switch self {
        case .brief:
            return "The central idea and essential takeaways only."
        case .concise:
            return "Key points, decisions, and important caveats."
        case .detailed:
            return "Supporting reasoning, facts, and representative examples."
        case .comprehensive:
            return "Every substantive detail, compressed without omissions."
        }
    }

    var storageDirectoryName: String {
        title.lowercased()
    }

    static let generationOrder: [SummaryDetailLevel] = [
        .comprehensive,
        .detailed,
        .concise,
        .brief
    ]

    var promptRequirement: String {
        switch self {
        case .brief:
            return "Write a brief overview that captures only the central thesis, essential takeaways, and any critical decision or conclusion. Omit supporting examples, secondary arguments, and implementation details unless they are necessary to avoid a misleading summary. Prefer one to three short paragraphs or a compact bullet list."
        case .concise:
            return "Write a concise summary that captures the central thesis, key supporting points, important facts, decisions, conclusions, and material caveats. Omit most examples, repetition, and minor implementation details. Keep the result compact while preserving what a reader needs to understand and act on the source."
        case .detailed:
            return "Write a detailed condensation that preserves the main claims, supporting reasoning, important names, numbers, dates, technical details, instructions, decisions, caveats, conclusions, and representative examples. Omit only repetition, filler, and minor details that do not change the reader's understanding. Use clear Markdown structure when it improves readability."
        case .comprehensive:
            return "Produce a faithful, content-complete condensation of the source. Preserve every distinct substantive claim, fact, argument, example, instruction, decision, caveat, and conclusion needed to understand the source fully. Preserve important names, numbers, dates, technical details, and chronology. Remove only repetition, filler, greetings, verbal tics, irrelevant banter, promotional interruptions, and other noise. Do not impose a target length; the result should scale with the source and become shorter through compression, not by discarding meaningful content. Use clear Markdown headings and lists when they improve readability."
        }
    }
}

struct ProcessingSuggestion: Codable, Equatable {
    var shortFilename: String
    var summaries: CaptureSummaries
    var topicName: String

    private enum CodingKeys: String, CodingKey {
        case shortFilename = "short_filename"
        case summaries
        case topicName = "topic_name"
    }
}

enum ProcessingServiceError: LocalizedError {
    case codexNotFound
    case invalidSource
    case failed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex could not be found. Install the Codex CLI or make it available on PATH."
        case .invalidSource:
            return "The selected capture could not be read."
        case .failed(let detail):
            return detail.isEmpty ? "Codex could not process this capture." : detail
        case .invalidResponse:
            return "Codex returned an invalid processing suggestion."
        }
    }
}

struct ProcessingService {
    static let summaryModel = "gpt-5.6-terra"
    static let summaryReasoningEffort = "medium"

    func suggest(
        for record: KnowledgeRecord,
        availableTopics: [TopicDefinition],
        promptTemplate: String
    ) async throws -> ProcessingSuggestion {
        try await Task.detached(priority: .userInitiated) {
            try runSuggestion(
                for: record,
                availableTopics: availableTopics,
                promptTemplate: promptTemplate
            )
        }.value
    }

    private func runSuggestion(
        for record: KnowledgeRecord,
        availableTopics: [TopicDefinition],
        promptTemplate: String
    ) throws -> ProcessingSuggestion {
        guard let sourceText = try? String(contentsOf: record.fileURL, encoding: .utf8) else {
            throw ProcessingServiceError.invalidSource
        }
        let prompt = try Self.renderPrompt(
            template: promptTemplate,
            sourceText: sourceText,
            record: record,
            availableTopics: availableTopics
        )
        let responseData = try CodexStructuredOutputRunner().run(
            prompt: prompt,
            schemaJSON: Self.schemaJSON,
            operationName: "Process"
        )
        guard var suggestion = try? JSONDecoder().decode(ProcessingSuggestion.self, from: responseData) else {
            throw ProcessingServiceError.invalidResponse
        }

        suggestion.shortFilename = LibraryStore.processedFilenameBase(
            suggestion.shortFilename,
            fallback: record.fileURL.deletingPathExtension().lastPathComponent
        )
        suggestion.summaries = CaptureSummaries(
            brief: suggestion.summaries.brief.trimmingCharacters(in: .whitespacesAndNewlines),
            concise: suggestion.summaries.concise.trimmingCharacters(in: .whitespacesAndNewlines),
            detailed: suggestion.summaries.detailed.trimmingCharacters(in: .whitespacesAndNewlines),
            comprehensive: suggestion.summaries.comprehensive.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        suggestion.topicName = Self.normalizedTopicName(suggestion.topicName)
        guard suggestion.summaries.allAreNonempty,
              !suggestion.topicName.isEmpty else {
            throw ProcessingServiceError.invalidResponse
        }
        return suggestion
    }

    static func renderPrompt(
        template: String,
        sourceText: String,
        record: KnowledgeRecord,
        availableTopics: [TopicDefinition]
    ) throws -> String {
        let sourcePayload = ProcessingPromptPayload(
            currentFilename: record.fileURL.lastPathComponent,
            title: record.title,
            sourceURL: record.sourceURL,
            sourceText: sourceText
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let topicPayloads = availableTopics.map {
            ProcessingPromptTopic(
                id: $0.id,
                title: $0.title,
                description: $0.description
            )
        }
        let sourceData = try encoder.encode(sourcePayload)
        let topicsData = try encoder.encode(topicPayloads)
        let sourceJSON = String(data: sourceData, encoding: .utf8) ?? "{}"
        let topicsJSON = String(data: topicsData, encoding: .utf8) ?? "[]"

        return template
            .replacingOccurrences(of: AppSettings.existingTopicsPromptPlaceholder, with: topicsJSON)
            .replacingOccurrences(of: AppSettings.sourcePromptPlaceholder, with: sourceJSON)
    }

    private static func normalizedTopicName(_ value: String) -> String {
        let lines = value
            .replacingOccurrences(of: "#", with: "")
            .components(separatedBy: .newlines)
        let collapsed = lines
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' .,-"))
        return String(collapsed.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let schemaJSON = """
    {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "short_filename": { "type": "string" },
        "summaries": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "comprehensive": { "type": "string" },
            "detailed": { "type": "string" },
            "concise": { "type": "string" },
            "brief": { "type": "string" }
          },
          "required": ["comprehensive", "detailed", "concise", "brief"]
        },
        "topic_name": { "type": "string" }
      },
      "required": ["short_filename", "summaries", "topic_name"]
    }
    """
}

private struct ProcessingPromptPayload: Encodable {
    var currentFilename: String
    var title: String
    var sourceURL: String?
    var sourceText: String
}

private struct ProcessingPromptTopic: Encodable {
    var id: String
    var title: String
    var description: String
}
