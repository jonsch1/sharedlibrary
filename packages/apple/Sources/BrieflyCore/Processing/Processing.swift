import Foundation

public func spokenText(_ markdown: String) -> String {
    var text = markdown
    for (pattern, replacement) in [
        (#"!\[[^\]]*\]\([^)]+\)"#, ""),
        (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
        (#"(?m)^#{1,6}\s+"#, ""),
        (#"[>*_~`]"#, ""),
        (#"(?m)^\s*[-+]\s+"#, ""),
        (#"\s+"#, " ")
    ] {
        text = text.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .regularExpression
        )
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

#if os(macOS)
public let defaultProcessingPrompt = """
Summarize one captured source for a private knowledge library.
Always write both summaries in English, regardless of the language of the source.
Return only valid JSON matching the required schema.
summaries.detailed: Provide a clear, thorough summary that preserves the source’s most important information and nuance. Include names, dates, and figures only when they are important for understanding.
summaries.concise: Condense the detailed summary into its essential ideas without introducing new information.
Write for both reading and listening. Use natural language, short paragraphs, clear headings, and smooth transitions. Avoid tables, footnotes, citation markers, raw URLs, and unexplained abbreviations.
short_filename: Use 2–6 lowercase words in kebab case, without a file extension.
topic_name: Reuse the most suitable existing topic or create a reusable topic name of 2–4 words.
Existing topics:
{{topics}}
Source:
{{source}}
"""

public func processingTestResponseIsValid(_ output: String) -> Bool {
    output.localizedCaseInsensitiveContains("Briefly is ready")
}

public struct ProcessingSuggestion: Codable, Equatable, Sendable {
    public struct Summaries: Codable, Equatable, Sendable {
        public var concise: String
        public var detailed: String

        public init(
            concise: String,
            detailed: String
        ) {
            self.concise = concise
            self.detailed = detailed
        }

        func text(for variant: LibraryVariant) -> String? {
            switch variant {
            case .concise: concise
            case .detailed: detailed
            case .source: nil
            }
        }
    }

    public var shortFilename: String
    public var topicName: String
    public var summaries: Summaries

    public init(
        shortFilename: String,
        topicName: String,
        summaries: Summaries
    ) {
        self.shortFilename = shortFilename
        self.topicName = topicName
        self.summaries = summaries
    }

    public static func decode(_ output: String) throws -> Self {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = regexCapture(
            trimmed,
            pattern: #"^```(?:json)?\s*([\s\S]*?)\s*```$"#
        ) ?? trimmed
        guard let data = payload.data(using: .utf8) else {
            throw LibraryError.invalidProcessingOutput
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let value = try? decoder.decode(Self.self, from: data) else {
            throw LibraryError.invalidProcessingOutput
        }
        let summaries = [
            value.summaries.concise,
            value.summaries.detailed
        ]
        guard
            !value.shortFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !value.topicName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            summaries.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        else {
            throw LibraryError.invalidProcessingOutput
        }
        return value
    }
}

#endif
