import Foundation
import BrieflyCore
import Security
import WebKit

@MainActor
final class BrieflyBackend {
    static let shared = BrieflyBackend()
    static let origin = URL(string: "https://www.readbriefly.fyi")!
    private static let sessionCookieName = "shared_library_session"

    private let urlSession: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        urlSession = URLSession(configuration: configuration)
    }

    func accountStatus() async throws -> BrieflyAccountStatus {
        let (data, response) = try await request("api/auth/status")
        if response.statusCode == 401 {
            await clearSession()
            return .signedOut
        }
        try requireSuccess(
            response,
            data: data,
            fallback: "Could not check the Briefly account."
        )
        let account = try JSONDecoder().decode(BrieflyAccountStatus.self, from: data)
        if !account.authenticated { await clearSession() }
        return account
    }

    func signOut() async throws {
        let (data, response) = try await request("api/auth/logout", method: "POST")
        try requireSuccess(response, data: data, fallback: "Could not sign out.")
        await clearSession()
    }

    func deleteAccount() async throws {
        let (data, response) = try await request("api/auth/account", method: "DELETE")
        try requireSuccess(response, data: data, fallback: "Could not delete the account.")
        await clearSession()
    }

    func signInWithApple(
        identityToken: Data,
        authorizationCode: Data,
        nonce: String
    ) async throws
        -> BrieflyAccountStatus
    {
        struct Payload: Encodable {
            let identityToken: String
            let authorizationCode: String
            let nonce: String
        }
        guard
            let token = String(data: identityToken, encoding: .utf8),
            let code = String(data: authorizationCode, encoding: .utf8)
        else {
            throw BrieflyBackendError.message("Apple returned an invalid identity token.")
        }
        let body = try JSONEncoder().encode(
            Payload(identityToken: token, authorizationCode: code, nonce: nonce)
        )
        let (data, response) = try await request(
            "api/auth/apple/native",
            method: "POST",
            body: body
        )
        try requireSuccess(response, data: data, fallback: "Could not sign in with Apple.")
        await storeCookies(from: response)
        return try JSONDecoder().decode(BrieflyAccountStatus.self, from: data)
    }

    func signInForAppReview(username: String, password: String) async throws
        -> BrieflyAccountStatus
    {
        struct Payload: Encodable {
            let username: String
            let password: String
        }
        let body = try JSONEncoder().encode(
            Payload(username: username, password: password)
        )
        let (data, response) = try await request(
            "api/auth/review",
            method: "POST",
            body: body
        )
        try requireSuccess(
            response,
            data: data,
            fallback: "Could not sign in for App Review."
        )
        await storeCookies(from: response)
        return try JSONDecoder().decode(BrieflyAccountStatus.self, from: data)
    }

    #if os(macOS)
    func firecrawl(_ url: URL) async throws -> ItemDraft {
        let body = try JSONSerialization.data(withJSONObject: ["url": url.absoluteString])
        let (data, response) = try await request(
            "api/extraction/firecrawl",
            method: "POST",
            body: body
        )
        try requireSuccess(response, data: data, fallback: "Briefly could not extract this page.")
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["success"] as? Bool == true,
              let result = payload["data"] as? [String: Any],
              let markdown = (result["markdown"] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ), !markdown.isEmpty else {
            throw BrieflyBackendError.message("Briefly web extraction returned no readable content.")
        }
        let metadata = result["metadata"] as? [String: Any]
        let source = [metadata?["sourceURL"], metadata?["url"]]
            .compactMap { $0 as? String }.compactMap(URL.init(string:)).first ?? url
        return ItemDraft(
            inputID: .webPage,
            title: (metadata?["title"] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).nilIfEmpty ?? source.host ?? "Web page",
            content: markdown,
            sourceURL: url,
            canonicalURL: source,
            faviconURL: URL(string: "/favicon.ico", relativeTo: source)?.absoluteURL
        )
    }

    func transcribe(_ url: URL) async throws -> InputTranscript {
        let endpoint = URL(string: "https://jonsch1--briefly-whisper-transcribe.modal.run")!
        let token = await cookies(for: Self.origin)
            .first(where: { $0.name == "shared_library_session" })?.value
        guard let token, !token.isEmpty else {
            throw BrieflyBackendError.message("Sign in to generate a transcript.")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 1_800)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": url.absoluteString,
            "include_timestamps": false
        ])
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var (data, rawResponse) = try await URLSession.shared.data(for: request)
        if let response = rawResponse as? HTTPURLResponse,
           response.statusCode == 422,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["detail"] as? String == "Upload podcast media directly for transcription." {
            let (audio, _) = try await downloadAudio(url)
            request.httpBody = audio
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("0", forHTTPHeaderField: "X-Briefly-Include-Timestamps")
            (data, rawResponse) = try await URLSession.shared.data(for: request)
        }
        guard let response = rawResponse as? HTTPURLResponse else {
            throw BrieflyBackendError.message("The transcription service returned an invalid response.")
        }
        try requireSuccess(response, data: data, fallback: "The transcription service failed.")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = (object["text"] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ), !text.isEmpty else {
            throw BrieflyBackendError.message("The transcription service returned no transcript.")
        }
        return InputTranscript(text: text, language: object["language"] as? String)
    }

    func downloadAudio(_ url: URL) async throws -> (Data, String) {
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.setValue("audio/*,*/*;q=0.1", forHTTPHeaderField: "Accept")
        let (data, rawResponse) = try await URLSession.shared.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), !data.isEmpty,
              data.count <= 250_000_000 else {
            throw BrieflyBackendError.message("Briefly could not download this audio.")
        }
        let mime = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first.map(String.init) ?? "audio/mpeg"
        return (data, mime.hasPrefix("audio/") ? mime : "audio/mpeg")
    }

    #endif

    func shareStatus(captureID: String) async throws -> BrieflyShareLinkStatus {
        let encoded = captureID.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? captureID
        let path = "api/share-links?captureID=\(encoded)"
        let (data, response) = try await request(path)
        try requireSuccess(response, data: data, fallback: "Could not read the share link.")
        return try JSONDecoder().decode(BrieflyShareLinkStatus.self, from: data)
    }

    func publishShare(
        captureID: String,
        source: BrieflyShareSource
    ) async throws -> BrieflyShareLinkStatus {
        struct Payload: Encodable {
            let captureID: String
            let source: BrieflyShareSource
        }
        let body = try JSONEncoder().encode(Payload(captureID: captureID, source: source))
        let (data, response) = try await request(
            "api/share-links",
            method: "POST",
            body: body
        )
        try requireSuccess(response, data: data, fallback: "Could not create the share link.")
        return try JSONDecoder().decode(BrieflyShareLinkStatus.self, from: data)
    }

    func revokeShare(token: String) async throws {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_-")
        )
        guard
            token.count == 32,
            token.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw BrieflyBackendError.message("Invalid share link.")
        }
        let (data, response) = try await request(
            "api/share-links/\(token)",
            method: "DELETE"
        )
        try requireSuccess(response, data: data, fallback: "Could not revoke the share link.")
    }

    private func request(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        timeoutInterval: TimeInterval = 60
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: Self.origin)?.absoluteURL else {
            throw BrieflyBackendError.message("The Briefly service URL is invalid.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if method != "GET" {
            request.setValue(Self.origin.absoluteString, forHTTPHeaderField: "Origin")
        }
        let cookies = await cookies(for: url)
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw BrieflyBackendError.message("Briefly returned an invalid response.")
        }
        return (data, response)
    }

    private func storeCookies(from response: HTTPURLResponse) async {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) {
            guard let key = $1.key as? String, let value = $1.value as? String else { return }
            $0[key] = value
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: Self.origin) {
            if cookie.name == Self.sessionCookieName, !cookie.value.isEmpty {
                BrieflySessionTokenStore.save(cookie.value)
            }
            await withCheckedContinuation { continuation in
                BrieflyWebSession.dataStore.httpCookieStore.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    private func cookies(for url: URL) async -> [HTTPCookie] {
        let cookies = await withCheckedContinuation {
            (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            BrieflyWebSession.dataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        guard let host = url.host?.lowercased() else { return [] }
        var matching = cookies.filter {
            let domain = $0.domain
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            return host == domain || host.hasSuffix(".\(domain)")
        }
        if let token = BrieflySessionTokenStore.load() {
            matching.removeAll { $0.name == Self.sessionCookieName }
            if let cookie = HTTPCookie(properties: [
                .name: Self.sessionCookieName,
                .value: token,
                .domain: host,
                .path: "/",
                .secure: "TRUE"
            ]) {
                matching.append(cookie)
            }
        } else if let cookie = matching.first(where: {
            $0.name == Self.sessionCookieName && !$0.value.isEmpty
        }) {
            // Adopt sessions created by earlier builds before Keychain persistence existed.
            BrieflySessionTokenStore.save(cookie.value)
        }
        return matching
    }

    private func clearSession() async {
        BrieflySessionTokenStore.remove()
        let cookies = await withCheckedContinuation {
            (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            BrieflyWebSession.dataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        for cookie in cookies where cookie.name == Self.sessionCookieName {
            await withCheckedContinuation { continuation in
                BrieflyWebSession.dataStore.httpCookieStore.delete(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    private func requireSuccess(
        _ response: HTTPURLResponse,
        data: Data?,
        fallback: String
    ) throws {
        guard (200..<300).contains(response.statusCode) else {
            let value = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            throw BrieflyBackendError.message(
                value?["error"] as? String ??
                    value?["message"] as? String ??
                    value?["detail"] as? String ??
                    fallback
            )
        }
    }
}

private enum BrieflySessionTokenStore {
    private static let service = "fyi.readbriefly.BrieflyNative.session"
    private static let account = "shared_library_session"

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else {
            return nil
        }
        return token
    }

    static func save(_ token: String) {
        guard !token.isEmpty else {
            remove()
            return
        }
        let data = Data(token.utf8)
        let updates: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, updates as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func remove() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum BrieflyBackendError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): value
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
enum BrieflyWebSession {
    static let dataStore: WKWebsiteDataStore = ProcessInfo.processInfo.arguments.contains("--app-review-testing")
        ? .nonPersistent()
        : WKWebsiteDataStore(forIdentifier: UUID(uuidString: "F5D5198E-24BC-4E08-AAC0-D275EE8620D1")!)
}
