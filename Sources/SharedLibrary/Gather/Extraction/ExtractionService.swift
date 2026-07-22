import Foundation
import PDFKit

enum ExtractionError: LocalizedError {
    case noURLInClipboard
    case helperNotFound
    case nodeNotFound([String])
    case helperFailed(String)
    case invalidOutput
    case invalidPDF
    case pdfDownloadFailed(Int)
    case pdfHasNoText
    case timedOut(Int)

    var errorDescription: String? {
        switch self {
        case .noURLInClipboard:
            return "Clipboard does not contain a URL."
        case .helperNotFound:
            return "Extractor helper not found. Run npm install in Tools/extractor."
        case .nodeNotFound(let paths):
            return "Node.js was not found. Install Node.js, or set SHARED_LIBRARY_NODE_PATH in Shared Library's .env file. Searched: \(paths.joined(separator: ", "))"
        case .helperFailed(let message):
            return message
        case .invalidOutput:
            return "Extractor returned invalid JSON."
        case .invalidPDF:
            return "The downloaded file is not a valid PDF."
        case .pdfDownloadFailed(let statusCode):
            return "PDF download failed with HTTP status \(statusCode)."
        case .pdfHasNoText:
            return "The PDF does not contain extractable text."
        case .timedOut(let seconds):
            return "Extraction timed out after \(seconds) seconds."
        }
    }
}

struct ExtractedContent: Decodable {
    let url: String
    let title: String?
    let description: String?
    let siteName: String?
    let content: String
    let wordCount: Int?
    let totalCharacters: Int?
    let transcriptSource: String?
    let mediaDurationSeconds: Double?
    let rawJSON: String

    private enum CodingKeys: String, CodingKey {
        case url, title, description, siteName, content, wordCount, totalCharacters
        case transcriptSource, mediaDurationSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        siteName = try container.decodeIfPresent(String.self, forKey: .siteName)
        content = try container.decode(String.self, forKey: .content)
        wordCount = try container.decodeIfPresent(Int.self, forKey: .wordCount)
        totalCharacters = try container.decodeIfPresent(Int.self, forKey: .totalCharacters)
        transcriptSource = try container.decodeIfPresent(String.self, forKey: .transcriptSource)
        mediaDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .mediaDurationSeconds)
        rawJSON = ""
    }

    init(decoded: ExtractedContent, rawJSON: String) {
        url = decoded.url
        title = decoded.title
        description = decoded.description
        siteName = decoded.siteName
        content = decoded.content
        wordCount = decoded.wordCount
        totalCharacters = decoded.totalCharacters
        transcriptSource = decoded.transcriptSource
        mediaDurationSeconds = decoded.mediaDurationSeconds
        self.rawJSON = rawJSON
    }

    init(
        url: String,
        title: String?,
        description: String?,
        siteName: String?,
        content: String,
        wordCount: Int?,
        totalCharacters: Int?,
        transcriptSource: String? = nil,
        mediaDurationSeconds: Double? = nil,
        rawJSON: String = ""
    ) {
        self.url = url
        self.title = title
        self.description = description
        self.siteName = siteName
        self.content = content
        self.wordCount = wordCount
        self.totalCharacters = totalCharacters
        self.transcriptSource = transcriptSource
        self.mediaDurationSeconds = mediaDurationSeconds
        self.rawJSON = rawJSON
    }
}

struct ExtractionService {
    private let processTimeoutSeconds = 150

    func extract(url: String) async throws -> ExtractedContent {
        if let sourceURL = URL(string: url) {
            if let bioRxivPDFURL = Self.bioRxivPDFURL(forArticleURL: sourceURL) {
                return try await extractPDF(at: bioRxivPDFURL, sourceURL: sourceURL)
            }

            if let markxivURL = Self.markxivURL(forArxivPDFURL: sourceURL) {
                do {
                    return try await extractMarkxiv(at: markxivURL, sourceURL: sourceURL)
                } catch {
                    return try await extractPDF(at: sourceURL)
                }
            }

            if Self.isLikelyPDFURL(sourceURL) {
                return try await extractPDF(at: sourceURL)
            }
        }

        let helper = try helperURL()
        var env = processEnvironment(helper: helper)
        let node = try nodeExecutableURL(env: env)
        env["PATH"] = mergedPath(existingPath: env["PATH"])

        let process = Process()
        process.executableURL = node
        process.arguments = [helper.path, url]
        process.currentDirectoryURL = helper.deletingLastPathComponent()
        process.environment = env

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        let outputBuffer = LockedData()
        let errorBuffer = LockedData()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { outputBuffer.append(data) }
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errorBuffer.append(data) }
        }

        try process.run()

        let timedOut = LockedFlag()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(processTimeoutSeconds)) {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }

        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil

        let outputData = outputBuffer.data()
        let errorData = errorBuffer.data()
        let stderr = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if timedOut.value {
            throw ExtractionError.timedOut(processTimeoutSeconds)
        }

        guard process.terminationStatus == 0 else {
            throw ExtractionError.helperFailed(stderr?.isEmpty == false ? stderr! : "Extraction helper failed.")
        }

        guard let raw = String(data: outputData, encoding: .utf8), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractionError.invalidOutput
        }
        let decoded = try JSONDecoder().decode(ExtractedContent.self, from: outputData)
        return ExtractedContent(decoded: decoded, rawJSON: raw)
    }

    static func isLikelyPDFURL(_ url: URL) -> Bool {
        if url.pathExtension.localizedCaseInsensitiveCompare("pdf") == .orderedSame {
            return true
        }

        let host = url.host(percentEncoded: false)?.lowercased()
        return (host == "arxiv.org" || host == "www.arxiv.org")
            && url.path.lowercased().hasPrefix("/pdf/")
    }

    static func markxivURL(forArxivPDFURL url: URL) -> URL? {
        let host = url.host(percentEncoded: false)?.lowercased()
        guard host == "arxiv.org" || host == "www.arxiv.org" else { return nil }

        let path = url.path(percentEncoded: false)
        guard path.lowercased().hasPrefix("/pdf/") else { return nil }

        var identifier = String(path.dropFirst("/pdf/".count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if identifier.lowercased().hasSuffix(".pdf") {
            identifier.removeLast(".pdf".count)
        }
        guard !identifier.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.markxiv.org"
        components.path = "/abs/\(identifier)"
        return components.url
    }

    static func bioRxivPDFURL(forArticleURL url: URL) -> URL? {
        let host = url.host(percentEncoded: false)?.lowercased()
        guard host == "biorxiv.org" || host == "www.biorxiv.org" else { return nil }

        let path = url.path(percentEncoded: false)
        guard path.lowercased().hasPrefix("/content/") else { return nil }

        var identifier = String(path.dropFirst("/content/".count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if identifier.lowercased().hasSuffix(".full.pdf") {
            identifier.removeLast(".full.pdf".count)
        }

        let identifierParts = identifier.split(separator: "/", omittingEmptySubsequences: false)
        guard identifierParts.count == 2,
              identifierParts[0].hasPrefix("10."),
              identifierParts[1].range(of: #"v\d+$"#, options: .regularExpression) != nil else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.biorxiv.org"
        components.path = "/content/\(identifier).full.pdf"
        return components.url
    }

    static func markdownTitle(in content: String) -> String? {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }

            let title = String(trimmed.dropFirst(2))
                .trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                return title
            }
        }
        return nil
    }

    static func extractedPDFContent(from data: Data, sourceURL: URL) throws -> ExtractedContent {
        guard let document = PDFDocument(data: data) else {
            throw ExtractionError.invalidPDF
        }

        let content = document.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else {
            throw ExtractionError.pdfHasNoText
        }

        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableTitle = title?.isEmpty == false ? title : nil

        return ExtractedContent(
            url: sourceURL.absoluteString,
            title: usableTitle,
            description: nil,
            siteName: sourceURL.host(percentEncoded: false),
            content: content,
            wordCount: content.split(whereSeparator: { $0.isWhitespace }).count,
            totalCharacters: content.count
        )
    }

    private func extractPDF(at downloadURL: URL, sourceURL: URL? = nil) async throws -> ExtractedContent {
        var request = URLRequest(url: downloadURL, timeoutInterval: TimeInterval(processTimeoutSeconds))
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        request.setValue("SharedLibrary/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw ExtractionError.pdfDownloadFailed(httpResponse.statusCode)
        }

        return try Self.extractedPDFContent(from: data, sourceURL: sourceURL ?? downloadURL)
    }

    private func extractMarkxiv(at markxivURL: URL, sourceURL: URL) async throws -> ExtractedContent {
        var request = URLRequest(url: markxivURL, timeoutInterval: TimeInterval(processTimeoutSeconds))
        request.setValue("text/markdown", forHTTPHeaderField: "Accept")
        request.setValue("SharedLibrary/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw ExtractionError.helperFailed("Markxiv returned HTTP status \(httpResponse.statusCode).")
        }

        guard let markdown = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !markdown.isEmpty else {
            throw ExtractionError.invalidOutput
        }
        guard let title = Self.markdownTitle(in: markdown) else {
            throw ExtractionError.invalidOutput
        }

        return ExtractedContent(
            url: sourceURL.absoluteString,
            title: title,
            description: nil,
            siteName: sourceURL.host(percentEncoded: false),
            content: markdown,
            wordCount: markdown.split(whereSeparator: { $0.isWhitespace }).count,
            totalCharacters: markdown.count
        )
    }

    private func nodeExecutableURL(env: [String: String]) throws -> URL {
        let fileManager = FileManager.default
        let configuredPaths = [
            env["SHARED_LIBRARY_NODE_PATH"],
            env["NODE_BINARY"]
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for path in configuredPaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let searchPaths = executableSearchPaths(existingPath: mergedPath(existingPath: env["PATH"]))
        for directory in searchPaths {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("node").path
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        throw ExtractionError.nodeNotFound(searchPaths)
    }

    private func helperURL() throws -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var candidates = [URL]()
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Tools/extractor/extract.mjs"))
        }
        candidates.append(contentsOf: [
            cwd.appendingPathComponent("Tools/extractor/extract.mjs"),
            URL(fileURLWithPath: "/Users/jschaul/Code/sharedlibrary/Tools/extractor/extract.mjs")
        ])
        guard let helper = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw ExtractionError.helperNotFound
        }
        return helper
    }

    private func processEnvironment(helper: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for envFile in envFileCandidates(helper: helper) {
            mergeEnvFile(envFile, into: &env)
        }
        if let keychainFirecrawlKey = try? KeychainStore.string(for: KeychainStore.firecrawlAPIKeyAccount),
           !keychainFirecrawlKey.isEmpty {
            env["FIRECRAWL_API_KEY"] = keychainFirecrawlKey
        }
        env["SHARED_LIBRARY_TRANSCRIPT_TIMESTAMPS"] = AppSettings.includeTranscriptTimestamps ? "true" : "false"
        env["PATH"] = mergedPath(existingPath: env["PATH"])
        return env
    }

    private func mergedPath(existingPath: String?) -> String {
        executableSearchPaths(existingPath: existingPath).joined(separator: ":")
    }

    private func executableSearchPaths(existingPath: String?) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaults = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/opt/local/bin",
            "\(home)/.local/bin"
        ]
        let existing = existingPath?
            .split(separator: ":")
            .map(String.init) ?? []

        var seen = Set<String>()
        return (existing + defaults).filter { path in
            guard !path.isEmpty, !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private func envFileCandidates(helper: URL) -> [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Shared Library", isDirectory: true)
            .appendingPathComponent(".env")

        return [
            cwd.appendingPathComponent(".env"),
            helper.deletingLastPathComponent().appendingPathComponent(".env"),
            appSupport
        ]
    }

    private func mergeEnvFile(_ url: URL, into env: inout [String: String]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }

            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
            guard !key.isEmpty, env[key]?.isEmpty ?? true else { continue }
            env[key] = value
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.withLock {
            storage.append(data)
        }
    }

    func data() -> Data {
        lock.withLock {
            storage
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock {
            storage
        }
    }

    func set() {
        lock.withLock {
            storage = true
        }
    }
}
