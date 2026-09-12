import Foundation

public struct InputHTTPResponse: Sendable {
    public let data: Data
    public let finalURL: URL
    public let contentType: String
    public let statusCode: Int
    public let headers: [String: String]

    public init(
        data: Data,
        finalURL: URL,
        contentType: String = "text/html",
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) {
        self.data = data
        self.finalURL = finalURL
        self.contentType = contentType.lowercased()
        self.statusCode = statusCode
        self.headers = headers
    }

    public var text: String {
        guard !inputIsBinaryContentType(contentType) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct InputHTTPClient: Sendable {
    public let send: @Sendable (URLRequest, Int) async throws -> InputHTTPResponse

    public init(
        send: @escaping @Sendable (URLRequest, Int) async throws -> InputHTTPResponse
    ) {
        self.send = send
    }

    public static let live = Self { request, maximumBytes in
        guard maximumBytes >= 0 else { throw NativeInputError.responseTooLarge }
        let (bytes, rawResponse) = try await URLSession.shared.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = rawResponse as? HTTPURLResponse else {
            throw NativeInputError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw NativeInputError.requestFailed(response.statusCode)
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw NativeInputError.responseTooLarge
        }
        let finalURL = response.url ?? request.url!
        guard isNativeHTTPURL(finalURL), finalURL.user == nil, finalURL.password == nil else {
            throw NativeInputError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw NativeInputError.responseTooLarge }
            data.append(byte)
        }
        return InputHTTPResponse(
            data: data,
            finalURL: finalURL,
            contentType: response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased() ?? "",
            statusCode: response.statusCode,
            headers: response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                guard let name = pair.key as? String else { return }
                result[name.lowercased()] = String(describing: pair.value)
            }
        )
    }

    public func get(
        _ url: URL,
        headers: [String: String] = [:],
        maximumBytes: Int = 20_000_000
    ) async throws -> InputHTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let response = try await send(request, maximumBytes)
        return try validatedResponse(response, maximumBytes: maximumBytes)
    }

    public func post(
        _ url: URL,
        body: Data,
        headers: [String: String] = [:],
        maximumBytes: Int = 20_000_000
    ) async throws -> InputHTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let response = try await send(request, maximumBytes)
        return try validatedResponse(response, maximumBytes: maximumBytes)
    }

    private func validatedResponse(
        _ response: InputHTTPResponse,
        maximumBytes: Int
    ) throws -> InputHTTPResponse {
        guard (200..<300).contains(response.statusCode) else {
            throw NativeInputError.requestFailed(response.statusCode)
        }
        guard response.data.count <= maximumBytes else { throw NativeInputError.responseTooLarge }
        guard isNativeHTTPURL(response.finalURL), response.finalURL.user == nil,
              response.finalURL.password == nil else {
            throw NativeInputError.invalidResponse
        }
        return response
    }
}

func isNativeHTTPURL(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
}
