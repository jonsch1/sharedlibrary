#if os(macOS)
import CryptoKit
import Foundation
import Network
import Security

/// A browser authorization session. Its callback listener exists only for this
/// attempt and binds to IPv4 loopback, never to the network interfaces.
@MainActor
public final class OpenRouterOAuth {
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var callbackURL: URL?
    private var callbackPath = ""
    private var finished = false
    private var callbackReceived = false

    public init() {}

    public func signIn(
        openBrowser: (URL) -> Bool,
        http: InputHTTPClient = .openRouter,
        timeout: TimeInterval = 600
    ) async throws -> String {
        guard listener == nil, !finished else { throw OpenRouterOAuthError.unavailable }
        let verifier = try randomToken()
        callbackPath = "/openrouter/" + (try randomToken())
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        defer { stop() }
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self?.fail(OpenRouterOAuthError.timedOut)
        }
        defer { deadline.cancel() }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let callback = try await withCheckedThrowingContinuation { continuation in
                readyContinuation = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in self?.listenerChanged(state) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.receive(connection) }
                }
                listener.start(queue: .main)
            }
            var authorization = URLComponents(string: "https://openrouter.ai/auth")!
            authorization.queryItems = [
                URLQueryItem(name: "callback_url", value: callback.absoluteString),
                URLQueryItem(name: "code_challenge", value: base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "key_label", value: "Briefly")
            ]
            let code: String = try await withCheckedThrowingContinuation { continuation in
                codeContinuation = continuation
                if !openBrowser(authorization.url!) { fail(OpenRouterOAuthError.unavailable) }
            }
            // Nothing else needs to reach the callback once a code was accepted.
            listener.cancel()
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://www.readbriefly.fyi", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Briefly", forHTTPHeaderField: "X-OpenRouter-Title")
            request.httpBody = try JSONEncoder().encode([
                "code": code, "code_verifier": verifier, "code_challenge_method": "S256"
            ])
            let response = try await http.send(request, 16_000)
            try Task.checkCancellation()
            guard !finished, response.finalURL == request.url,
                  (200..<300).contains(response.statusCode), response.data.count <= 16_000 else {
                throw OpenRouterOAuthError.exchangeFailed
            }
            struct Credential: Decodable { let key: String }
            guard let credential = try? JSONDecoder().decode(Credential.self, from: response.data),
                  !credential.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenRouterOAuthError.exchangeFailed
            }
            return credential.key
        } onCancel: {
            Task { @MainActor in self.fail(CancellationError()) }
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port, let continuation = readyContinuation else { return }
            let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(callbackPath)")!
            callbackURL = url
            readyContinuation = nil
            continuation.resume(returning: url)
        case .failed:
            fail(OpenRouterOAuthError.unavailable)
        default:
            break
        }
    }

    private func receive(_ connection: NWConnection) {
        guard !finished, codeContinuation != nil, connections.count < 8 else {
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .main)
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.close(connection)
        }
        connection.stateUpdateHandler = { state in
            if case .cancelled = state { deadline.cancel() }
            if case .failed = state { deadline.cancel() }
        }
        read(connection, data: Data())
    }

    private func read(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] bytes, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[ObjectIdentifier(connection)] != nil else { return }
                var data = data
                data.append(bytes ?? Data())
                guard data.count <= 8_192, error == nil else {
                    self.close(connection)
                    return
                }
                if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handle(data, from: connection)
                } else if complete {
                    self.close(connection)
                } else {
                    self.read(connection, data: data)
                }
            }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection) {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ").map(String.init) ?? []
        let hosts = lines.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "host" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1",
              let callbackURL, let port = callbackURL.port,
              hosts == ["127.0.0.1:\(port)"],
              request[1].hasPrefix("/"), !request[1].hasPrefix("//"),
              let url = URL(string: "http://127.0.0.1:\(port)" + request[1]),
              url.path == callbackPath, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            respond(connection, status: "400 Bad Request", message: "This is not the current Briefly sign-in callback.")
            return
        }
        let items = components.queryItems ?? []
        if items.contains(where: { $0.name == "error" }) {
            callbackReceived = true
            respond(connection, status: "200 OK", message: "Authorization was declined. Return to Briefly to try again.") { [weak self] in
                self?.fail(OpenRouterOAuthError.declined)
            }
            return
        }
        let codes = items.filter { $0.name == "code" }
        guard !callbackReceived, codes.count == 1, let code = codes[0].value,
              !code.isEmpty, code.count <= 4_000, codeContinuation != nil else {
            respond(connection, status: "400 Bad Request", message: "Briefly did not receive an authorization code.")
            return
        }
        callbackReceived = true
        respond(connection, status: "200 OK", message: "Authorization received. You can return to Briefly.") { [weak self] in
            guard let self, let continuation = self.codeContinuation else { return }
            self.codeContinuation = nil
            continuation.resume(returning: code)
        }
    }

    private func respond(_ connection: NWConnection, status: String, message: String, afterSend: (() -> Void)? = nil) {
        let body = "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>Briefly</title><body><h1>Briefly</h1><p>\(message)</p></body></html>"
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((headers + body).utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.close(connection)
                afterSend?()
            }
        })
    }

    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func fail(_ error: Error) {
        finished = true
        let ready = readyContinuation
        let code = codeContinuation
        readyContinuation = nil
        codeContinuation = nil
        ready?.resume(throwing: error)
        code?.resume(throwing: error)
        stop()
    }

    private func stop() {
        finished = true
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }
}

private func randomToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw OpenRouterOAuthError.unavailable
    }
    return base64URL(Data(bytes))
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private enum OpenRouterOAuthError: LocalizedError {
    case unavailable, timedOut, declined, exchangeFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Briefly could not start OpenRouter sign-in. Try again."
        case .timedOut: "OpenRouter sign-in expired. Sign in again to continue."
        case .declined: "OpenRouter authorization was declined."
        case .exchangeFailed: "OpenRouter could not finish authorization. Sign in again to continue."
        }
    }
}

public extension InputHTTPClient {
    static let openRouter = Self { request, maximumBytes in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: OpenRouterRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              response.expectedContentLength <= maximumBytes else {
            throw NativeInputError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw NativeInputError.responseTooLarge }
            data.append(byte)
        }
        return InputHTTPResponse(data: data, finalURL: response.url ?? request.url!, statusCode: response.statusCode)
    }
}

private final class OpenRouterRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
