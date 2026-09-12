import Foundation

#if os(macOS)
import Darwin
#endif

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

public let defaultProcessingCommand =
    "codex exec --ephemeral --sandbox read-only " +
    "--skip-git-repo-check --color never -"
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

public func runProcessingCommand(
    _ command: String,
    prompt: String,
    timeout: TimeInterval = 300,
    environmentOverrides: [String: String] = [:]
) async throws -> String {
    #if os(macOS)
    let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= 4_000 else {
        throw LibraryError.invalidProcessingCommand
    }
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appending(
        path: "briefly-process-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }
    let outputURL = directory.appending(path: "stdout")
    let errorURL = directory.appending(path: "stderr")
    guard
        fileManager.createFile(atPath: outputURL.path, contents: nil),
        fileManager.createFile(atPath: errorURL.path, contents: nil)
    else {
        throw LibraryError.processingFailed("Briefly could not prepare AI output files.")
    }
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer {
        try? outputHandle.close()
        try? errorHandle.close()
    }
    let input = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", normalized]
    process.currentDirectoryURL = directory
    process.standardInput = input
    process.standardOutput = outputHandle
    process.standardError = errorHandle
    var environment = ProcessInfo.processInfo.environment
    let userHomePath = environment["HOME"] ?? environment["USERPROFILE"] ?? ""
    let additions = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        userHomePath.isEmpty ? "" : "\(userHomePath)/.local/bin",
        userHomePath.isEmpty ? "" : "\(userHomePath)/.npm-global/bin"
    ].filter { !$0.isEmpty }
    let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    environment["PATH"] = NSOrderedSet(array: existing + additions).array
        .compactMap { $0 as? String }
        .joined(separator: ":")
    for (key, value) in environmentOverrides {
        environment[key] = value
    }
    process.environment = environment

    let stop = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<ProcessingStop, Error>) in
        let state = ProcessingProcessState()
        let monitor = DispatchSource.makeTimerSource(queue: .global())
        process.terminationHandler = { _ in
            monitor.cancel()
            if let reason = state.finish() {
                continuation.resume(returning: reason)
            }
        }
        do {
            try process.run()
        } catch {
            monitor.cancel()
            _ = state.finish()
            continuation.resume(throwing: error)
            return
        }
        monitor.schedule(deadline: .now() + 0.25, repeating: 0.25)
        monitor.setEventHandler {
            let size = (try? fileSize(outputURL)) ?? 0
            if size > 10_000_000, state.request(.outputTooLarge) {
                process.terminate()
            }
        }
        monitor.resume()
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            if state.request(.inputFailed(error.localizedDescription)) {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning, state.request(.timedOut) {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }
    try? outputHandle.close()
    try? errorHandle.close()
    switch stop {
    case .finished:
        break
    case .timedOut:
        throw LibraryError.processingTimedOut
    case .outputTooLarge:
        throw LibraryError.processingOutputTooLarge
    case .inputFailed(let message):
        throw LibraryError.processingFailed(message)
    }
    let outputSize = try fileSize(outputURL)
    guard outputSize <= 10_000_000 else {
        throw LibraryError.processingOutputTooLarge
    }
    let output = try String(contentsOf: outputURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
        throw LibraryError.processingFailed(
            try conciseProcessError(errorURL)
        )
    }
    guard !output.isEmpty else {
        throw LibraryError.processingFailed(
            "The AI command returned no output."
        )
    }
    return output
    #else
    throw LibraryError.processingUnavailable
    #endif
}

#if os(macOS)
private enum ProcessingStop {
    case finished
    case timedOut
    case outputTooLarge
    case inputFailed(String)
}

private final class ProcessingProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var reason = ProcessingStop.finished
    private var didFinish = false

    func request(_ value: ProcessingStop) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        reason = value
        return true
    }

    func finish() -> ProcessingStop? {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return nil }
        didFinish = true
        return reason
    }
}

private func fileSize(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.intValue ?? 0
}

private func conciseProcessError(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try fileSize(url)
    if size > 100_000 {
        try handle.seek(toOffset: UInt64(size - 100_000))
    }
    let data = try handle.readToEnd() ?? Data()
    let lines = String(decoding: data, as: UTF8.self)
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let message = lines.last?
        .replacingOccurrences(of: #"^ERROR:\s*"#, with: "", options: .regularExpression) ??
        "The AI command could not process this capture."
    return message.count > 320
        ? "\(message.prefix(319).trimmingCharacters(in: .whitespaces))…"
        : message
}
#endif
