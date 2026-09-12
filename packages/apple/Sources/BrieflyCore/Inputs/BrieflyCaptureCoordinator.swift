import Foundation

public struct BrieflyAdapterRunnerRequest: Codable, Equatable, Sendable {
    public let action: String
    public let id: String?
    public let port: Int?
    public let token: String?
    public let adapterIDs: [String]?

    public init(action: String, id: String? = nil, port: Int? = nil, token: String? = nil, adapterIDs: [String]? = nil) {
        self.action = action
        self.id = id
        self.port = port
        self.token = token
        self.adapterIDs = adapterIDs
    }
}

public struct BrieflyAdapterRunnerStatus: Codable, Equatable, Sendable {
    public let connected: Bool
    public let adapterCount: Int
}

public struct BrieflyCustomCaptureFailure: Error, LocalizedError, Sendable {
    public let url: URL
    public let adapterID: String?
    public var errorDescription: String? {
        if let adapterID {
            return "Custom handler “\(adapterID)” could not capture this link. Retry or use native capture."
        }
        return "Custom source handling could not check this link. Retry or use native capture."
    }
}

/// The app owns routing and persistence. The optional local runner only returns source data.
@MainActor
public final class BrieflyCaptureCoordinator {
    private struct Runner {
        let id: String
        let port: Int
        let token: String
        let adapterIDs: [String]
        let expires: Date
    }
    private var runner: Runner?

    public init() {}

    public func runnerStatus() -> BrieflyAdapterRunnerStatus {
        let current = activeRunner
        return .init(connected: current != nil, adapterCount: current?.adapterIDs.count ?? 0)
    }

    /// Registration is a short lease renewed by the SDK. A second live runner cannot take over.
    public func configureRunner(_ request: BrieflyAdapterRunnerRequest) throws -> BrieflyAdapterRunnerStatus {
        if request.action == "status" { return runnerStatus() }
        guard let id = request.id, UUID(uuidString: id) != nil else {
            throw BrieflyAgentFailure.invalid("Runner id must be a UUID.")
        }
        if request.action == "disconnect" {
            if runner?.id == id { runner = nil }
            return runnerStatus()
        }
        guard request.action == "connect", let port = request.port, (1...65_535).contains(port),
              let token = request.token, token.count == 64,
              token.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let ids = request.adapterIDs, !ids.isEmpty, ids.count <= 100,
              Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 100 }) else {
            throw BrieflyAgentFailure.invalid("Runner registration requires a local port, token, and 1–100 unique adapter IDs.")
        }
        if let current = activeRunner, current.id != id {
            throw BrieflyAgentFailure(code: "runner_conflict", message: "Another adapter runner is connected. Stop it before connecting this one.")
        }
        runner = Runner(id: id, port: port, token: token, adapterIDs: ids, expires: Date().addingTimeInterval(45))
        return runnerStatus()
    }

    public func capture(
        _ request: ItemInputRequest,
        in library: SQLiteLibraryStore,
        context: ItemInputContext = .init(),
        useNative: Bool = false,
        nativeDraft: ItemDraft? = nil
    ) async throws -> BrieflyAgentWriteResult {
        if case .url(let url) = request.source {
            guard isNativeHTTPURL(url), url.user == nil, url.password == nil, url.absoluteString.count <= 2_048 else {
                throw BrieflyAgentFailure.invalid("Capture requires an HTTP(S) URL without embedded credentials.")
            }
            if !useNative, let document = try await customDocument(for: url) {
                do {
                    return try await BrieflyAgentLibrary(store: library).save(document)
                } catch let failure as BrieflyAgentFailure where failure.code == "invalid_input" {
                    throw BrieflyCustomCaptureFailure(url: url, adapterID: nil)
                }
            }
        }
        let draft: ItemDraft
        if let nativeDraft { draft = nativeDraft }
        else { draft = try await NativeItemInputRouter().ingest(request, context: context) }
        let id = try await library.captureItem(draft)
        let result = try await BrieflyAgentLibrary(store: library).writeResult(id: id)
        if result.status == "processing" {
            try await library.enqueueProcessingJob(entryID: id, selectWhenFinished: false)
        }
        return result
    }

    private var activeRunner: Runner? {
        guard let runner, runner.expires > Date() else { return nil }
        return runner
    }

    private func customDocument(for url: URL) async throws -> BrieflyAgentSaveRequest? {
        guard let current = activeRunner else { return nil }
        struct Resolution: Decodable { let matched: Bool; let adapterId: String? }
        let resolution: Resolution
        do {
            resolution = try await callRunner(current, operation: "resolve", body: ["url": url.absoluteString], timeout: 3)
        } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost].contains(error.code) {
            // No runner answered the resolution request: ordinary native capture remains available.
            if runner?.id == current.id { runner = nil }
            return nil
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw BrieflyCustomCaptureFailure(url: url, adapterID: nil)
        }
        if !resolution.matched && resolution.adapterId == nil { return nil }
        guard resolution.matched, let adapterID = resolution.adapterId,
              current.adapterIDs.contains(adapterID) else {
            throw BrieflyCustomCaptureFailure(url: url, adapterID: nil)
        }
        struct Extraction: Decodable { let document: BrieflyAgentSaveRequest }
        do {
            let result: Extraction = try await callRunner(
                current, operation: "extract",
                body: ["url": url.absoluteString, "adapterId": adapterID], timeout: 120
            )
            let document = result.document
            return .init(title: document.title, content: document.content,
                         url: document.url ?? url.absoluteString,
                         concise: document.concise, detailed: document.detailed)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw BrieflyCustomCaptureFailure(url: url, adapterID: adapterID)
        }
    }

    private func callRunner<Result: Decodable>(
        _ runner: Runner, operation: String, body: [String: String], timeout: TimeInterval
    ) async throws -> Result {
        // The registered port is the only variable part of the address. Never forward credentials
        // to a redirect, a website, a system proxy, or the app's signed-in browser session.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: RunnerRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(runner.port)/\(operation)")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(runner.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw BrieflyAgentFailure(code: "adapter_failed", message: "The adapter runner could not complete this request.")
        }
        let maximum = operation == "resolve" ? 16_000 : 2_000_000
        guard response.expectedContentLength <= maximum else { throw NativeInputError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximum else { throw NativeInputError.responseTooLarge }
            data.append(byte)
        }
        return try JSONDecoder().decode(Result.self, from: data)
    }
}

private final class RunnerRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
