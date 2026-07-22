import Foundation

struct CodexStructuredOutputRunner {
    func run(
        prompt: String,
        schemaJSON: String,
        operationName: String
    ) throws -> Data {
        let temporaryFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedLibrary-\(operationName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryFolder) }

        let schemaURL = temporaryFolder.appendingPathComponent("schema.json")
        let outputURL = temporaryFolder.appendingPathComponent("output.json")
        try schemaJSON.write(to: schemaURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = try codexExecutableURL()
        process.currentDirectoryURL = temporaryFolder
        var arguments = [
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--model", ProcessingService.summaryModel,
            "--config", "model_reasoning_effort=\"\(ProcessingService.summaryReasoningEffort)\"",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--color", "never",
            "--output-schema", schemaURL.path,
            "--output-last-message", outputURL.path,
            "-C", temporaryFolder.path
        ]
        arguments.append("-")
        process.arguments = arguments
        process.environment = processEnvironment()

        let input = Pipe()
        let error = Pipe()
        let errorBuffer = CodexOutputBuffer()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errorBuffer.append(data) }
        }

        try process.run()
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        error.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            let detail = String(data: errorBuffer.data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ProcessingServiceError.failed(Self.conciseError(detail))
        }
        guard let responseData = try? Data(contentsOf: outputURL) else {
            throw ProcessingServiceError.invalidResponse
        }
        return responseData
    }

    private func codexExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let configured = [environment["CODEX_BINARY"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = configured + pathDirectories.map { "\($0)/codex" } + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex"
        ]

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw ProcessingServiceError.codexNotFound
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaults = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(home)/.local/bin", "\(home)/.npm-global/bin"
        ]
        var seen = Set<String>()
        let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (existing + defaults).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }.joined(separator: ":")
        return environment
    }

    private static func conciseError(_ detail: String) -> String {
        let messagePattern = #"\"message\":\"((?:\\.|[^\"])*)\""#
        if let regex = try? NSRegularExpression(pattern: messagePattern),
           let match = regex.matches(
                in: detail,
                range: NSRange(detail.startIndex..<detail.endIndex, in: detail)
           ).last,
           let messageRange = Range(match.range(at: 1), in: detail) {
            let encodedMessage = "\"\(detail[messageRange])\""
            if let data = encodedMessage.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                return truncatedError(decoded)
            }
        }

        let fallback = detail
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .last?
            .replacingOccurrences(of: "ERROR: ", with: "")
            ?? "Codex could not process this capture."
        return truncatedError(fallback)
    }

    private static func truncatedError(_ value: String) -> String {
        guard value.count > 320 else { return value }
        return String(value.prefix(319)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

private final class CodexOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.withLock { storage.append(data) }
    }

    func data() -> Data {
        lock.withLock { storage }
    }
}
