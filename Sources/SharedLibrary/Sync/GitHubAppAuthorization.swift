import AppKit
import Combine
import Foundation

struct GitHubUserAccessToken: Codable, Equatable, Sendable {
    var clientID: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var refreshTokenExpiresAt: Date?
}

protocol GitHubCredentialProviding: Sendable {
    func configuredClientID() async -> String?
    func validAccessToken(forceRefresh: Bool) async throws -> String?
}

actor GitHubCredentialVault: GitHubCredentialProviding {
    static let shared = GitHubCredentialVault()

    private static let tokenAccount = "github_app_user_access_token"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func configuredClientID() -> String? {
        let value = AppSettings.shared.githubAppClientID
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    func storedToken() throws -> GitHubUserAccessToken? {
        guard let value = try KeychainStore.string(for: Self.tokenAccount),
              let data = value.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode(GitHubUserAccessToken.self, from: data)
    }

    func save(_ token: GitHubUserAccessToken) throws {
        let data = try JSONEncoder().encode(token)
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        try KeychainStore.setString(value, for: Self.tokenAccount)
    }

    func clear() throws {
        try KeychainStore.delete(account: Self.tokenAccount)
    }

    func validAccessToken(forceRefresh: Bool = false) async throws -> String? {
        guard var token = try storedToken() else { return nil }
        let shouldRefresh = forceRefresh
            || token.expiresAt.map { $0 <= Date().addingTimeInterval(90) } == true
        guard shouldRefresh else { return token.accessToken }
        guard let refreshToken = token.refreshToken,
              token.refreshTokenExpiresAt.map({ $0 > Date() }) != false else {
            if forceRefresh || token.expiresAt != nil {
                try clear()
                return nil
            }
            return token.accessToken
        }

        var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.data([
            "client_id": token.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            try clear()
            throw GitHubAppAuthenticationError.connectionExpired
        }
        let refreshed = try JSONDecoder.github.decode(GitHubTokenResponse.self, from: data)
        guard let accessToken = refreshed.accessToken, !accessToken.isEmpty else {
            try clear()
            throw GitHubAppAuthenticationError.connectionExpired
        }
        token.accessToken = accessToken
        token.refreshToken = refreshed.refreshToken ?? token.refreshToken
        token.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        token.refreshTokenExpiresAt = refreshed.refreshTokenExpiresIn.map {
            Date().addingTimeInterval(TimeInterval($0))
        } ?? token.refreshTokenExpiresAt
        try save(token)
        return token.accessToken
    }
}

enum GitHubAppAuthenticationError: LocalizedError, Equatable {
    case invalidClientID
    case deviceFlowDisabled
    case authorizationDenied
    case authorizationExpired
    case connectionExpired
    case invalidResponse
    case github(String)

    var errorDescription: String? {
        switch self {
        case .invalidClientID:
            return "This Shared Library build is not configured with a GitHub App Client ID."
        case .deviceFlowDisabled:
            return "Device Flow is disabled for this GitHub App. Enable it in the app settings and try again."
        case .authorizationDenied:
            return "GitHub authorization was cancelled."
        case .authorizationExpired:
            return "The GitHub device code expired. Start the connection again."
        case .connectionExpired:
            return "The GitHub connection expired. Connect the GitHub App again."
        case .invalidResponse:
            return "GitHub returned an invalid authentication response."
        case .github(let message):
            return message
        }
    }
}

struct GitHubDeviceAuthorization: Equatable, Sendable {
    var deviceCode: String
    var userCode: String
    var verificationURI: URL
    var expiresAt: Date
    var interval: Int
}

enum GitHubDevicePollResult: Sendable {
    case pending(interval: Int)
    case authorized(GitHubUserAccessToken)
}

struct GitHubDeviceFlowClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func begin(clientID: String) async throws -> GitHubDeviceAuthorization {
        let normalized = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidClientID(normalized) else {
            throw GitHubAppAuthenticationError.invalidClientID
        }

        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.data(["client_id": normalized])

        let (data, response) = try await session.data(for: request)
        try Self.requireSuccess(response: response, data: data)
        let value = try JSONDecoder.github.decode(GitHubDeviceCodeResponse.self, from: data)
        guard let verificationURI = URL(string: value.verificationURI),
              !value.deviceCode.isEmpty,
              !value.userCode.isEmpty else {
            throw GitHubAppAuthenticationError.invalidResponse
        }
        return GitHubDeviceAuthorization(
            deviceCode: value.deviceCode,
            userCode: value.userCode,
            verificationURI: verificationURI,
            expiresAt: Date().addingTimeInterval(TimeInterval(value.expiresIn)),
            interval: max(1, value.interval)
        )
    }

    func poll(
        clientID: String,
        authorization: GitHubDeviceAuthorization,
        interval: Int
    ) async throws -> GitHubDevicePollResult {
        guard authorization.expiresAt > Date() else {
            throw GitHubAppAuthenticationError.authorizationExpired
        }

        var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormEncoding.data([
            "client_id": clientID,
            "device_code": authorization.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAppAuthenticationError.invalidResponse
        }
        let value = try JSONDecoder.github.decode(GitHubTokenResponse.self, from: data)
        if let error = value.error {
            switch error {
            case "authorization_pending":
                return .pending(interval: interval)
            case "slow_down":
                return .pending(interval: max(interval + 5, value.interval ?? 0))
            case "expired_token":
                throw GitHubAppAuthenticationError.authorizationExpired
            case "access_denied":
                throw GitHubAppAuthenticationError.authorizationDenied
            case "device_flow_disabled":
                throw GitHubAppAuthenticationError.deviceFlowDisabled
            default:
                throw GitHubAppAuthenticationError.github(
                    value.errorDescription ?? "GitHub authorization failed (\(http.statusCode))."
                )
            }
        }
        guard (200..<300).contains(http.statusCode),
              let accessToken = value.accessToken,
              !accessToken.isEmpty else {
            throw GitHubAppAuthenticationError.invalidResponse
        }
        return .authorized(GitHubUserAccessToken(
            clientID: clientID,
            accessToken: accessToken,
            refreshToken: value.refreshToken,
            expiresAt: value.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            refreshTokenExpiresAt: value.refreshTokenExpiresIn.map {
                Date().addingTimeInterval(TimeInterval($0))
            }
        ))
    }

    static func isValidClientID(_ value: String) -> Bool {
        guard (8...128).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
        }
    }

    private static func requireSuccess(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAppAuthenticationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let value = try? JSONDecoder.github.decode(GitHubTokenResponse.self, from: data)
            if value?.error == "device_flow_disabled" {
                throw GitHubAppAuthenticationError.deviceFlowDisabled
            }
            throw GitHubAppAuthenticationError.github(
                value?.errorDescription ?? "GitHub authorization failed (\(http.statusCode))."
            )
        }
    }
}

enum GitHubAppAuthorizationState: Equatable {
    case disconnected
    case connecting(String)
    case waiting(code: String, verificationURI: URL)
    case connected(login: String)
    case failed(String)

    var message: String {
        switch self {
        case .disconnected:
            return "GitHub App is not connected."
        case .connecting(let message), .failed(let message):
            return message
        case .waiting(let code, _):
            return "Enter code \(code) on GitHub to finish connecting."
        case .connected(let login):
            return "Connected to GitHub as @\(login)."
        }
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .waiting:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class GitHubAppAuthorizationCoordinator: ObservableObject {
    @Published private(set) var state = GitHubAppAuthorizationState.disconnected

    private let vault: GitHubCredentialVault
    private let flowClient: GitHubDeviceFlowClient
    private let apiClient: GitHubAPIClient
    private var task: Task<Void, Never>?
    private var verificationURI: URL?

    init(
        vault: GitHubCredentialVault = .shared,
        flowClient: GitHubDeviceFlowClient = GitHubDeviceFlowClient(),
        apiClient: GitHubAPIClient = GitHubAPIClient()
    ) {
        self.vault = vault
        self.flowClient = flowClient
        self.apiClient = apiClient
    }

    func refreshStatus() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard try await vault.validAccessToken(forceRefresh: false) != nil else {
                    state = .disconnected
                    task = nil
                    return
                }
                let user = try await apiClient.currentUser()
                state = .connected(login: user.login)
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func connect() {
        guard task == nil else { return }
        let normalized = AppSettings.shared.githubAppClientID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitHubDeviceFlowClient.isValidClientID(normalized) else {
            state = .failed(GitHubAppAuthenticationError.invalidClientID.localizedDescription)
            return
        }
        state = .connecting("Requesting a GitHub device code...")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await flowClient.begin(clientID: normalized)
                verificationURI = authorization.verificationURI
                state = .waiting(
                    code: authorization.userCode,
                    verificationURI: authorization.verificationURI
                )
                NSWorkspace.shared.open(authorization.verificationURI)
                var interval = authorization.interval
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    switch try await flowClient.poll(
                        clientID: normalized,
                        authorization: authorization,
                        interval: interval
                    ) {
                    case .pending(let updatedInterval):
                        interval = updatedInterval
                    case .authorized(let token):
                        try await vault.save(token)
                        let user = try await apiClient.currentUser()
                        state = .connected(login: user.login)
                        task = nil
                        return
                    }
                }
            } catch is CancellationError {
                state = .disconnected
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func openVerificationPage() {
        if let verificationURI {
            NSWorkspace.shared.open(verificationURI)
        }
    }

    func disconnect() {
        task?.cancel()
        verificationURI = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await vault.clear()
                state = .disconnected
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }
}

struct GitHubUserProfile: Decodable, Equatable, Sendable {
    var login: String
}

protocol GitHubAPIRequesting: Sendable {
    func currentUser() async throws -> GitHubUserProfile
    func graphQL(query: String, variables: [String: String]) async throws -> Data
}

struct GitHubAPIClient: GitHubAPIRequesting, Sendable {
    private let credentials: any GitHubCredentialProviding
    private let session: URLSession

    init(
        credentials: any GitHubCredentialProviding = GitHubCredentialVault.shared,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.session = session
    }

    func currentUser() async throws -> GitHubUserProfile {
        try await decodedRequest(path: "/user", method: "GET", body: nil)
    }

    func graphQL(query: String, variables: [String: String]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": variables
        ])
        return try await dataRequest(path: "/graphql", method: "POST", body: body)
    }

    private func decodedRequest<Value: Decodable>(
        path: String,
        method: String,
        body: Data?
    ) async throws -> Value {
        let data = try await dataRequest(path: path, method: method, body: body)
        return try JSONDecoder.github.decode(Value.self, from: data)
    }

    private func dataRequest(path: String, method: String, body: Data?) async throws -> Data {
        for forceRefresh in [false, true] {
            guard let token = try await credentials.validAccessToken(forceRefresh: forceRefresh) else {
                throw GitHubAppAuthenticationError.connectionExpired
            }
            var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Shared-Library", forHTTPHeaderField: "User-Agent")
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GitHubAppAuthenticationError.invalidResponse
            }
            if http.statusCode == 401, !forceRefresh {
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                let error = try? JSONDecoder.github.decode(GitHubAPIErrorResponse.self, from: data)
                throw GitHubAppAuthenticationError.github(
                    error?.message ?? "GitHub request failed (\(http.statusCode))."
                )
            }
            return data
        }
        throw GitHubAppAuthenticationError.connectionExpired
    }
}

private struct GitHubDeviceCodeResponse: Decodable {
    var deviceCode: String
    var userCode: String
    var verificationURI: String
    var expiresIn: Int
    var interval: Int
}

private struct GitHubTokenResponse: Decodable {
    var accessToken: String?
    var expiresIn: Int?
    var refreshToken: String?
    var refreshTokenExpiresIn: Int?
    var error: String?
    var errorDescription: String?
    var interval: Int?
}

private struct GitHubAPIErrorResponse: Decodable {
    var message: String
}

private enum FormEncoding {
    static func data(_ values: [String: String]) -> Data {
        values
            .map { key, value in
                "\(escape(key))=\(escape(value))"
            }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var value = CharacterSet.urlQueryAllowed
        value.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value
    }()
}

private extension JSONDecoder {
    static var github: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
