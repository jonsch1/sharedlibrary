import Foundation

public struct InputHTTPResponse: Sendable {
    public let data: Data
    public let finalURL: URL
    public let contentType: String
    public let statusCode: Int

    public init(
        data: Data,
        finalURL: URL,
        contentType: String = "text/html",
        statusCode: Int = 200
    ) {
        self.data = data
        self.finalURL = finalURL
        self.contentType = contentType
        self.statusCode = statusCode
    }

    public var text: String { String(decoding: data, as: UTF8.self) }
}

public struct InputHTTPClient: Sendable {
    public let send: @Sendable (URLRequest, Int) async throws -> InputHTTPResponse

    public init(
        send: @escaping @Sendable (URLRequest, Int) async throws -> InputHTTPResponse
    ) {
        self.send = send
    }

    public static let live = Self { request, maximumBytes in
        let (data, rawResponse) = try await URLSession.shared.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw NativeInputError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw NativeInputError.requestFailed(response.statusCode)
        }
        guard data.count <= maximumBytes else { throw NativeInputError.responseTooLarge }
        return InputHTTPResponse(
            data: data,
            finalURL: response.url ?? request.url!,
            contentType: response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased() ?? "",
            statusCode: response.statusCode
        )
    }

    public func get(
        _ url: URL,
        headers: [String: String] = [:],
        maximumBytes: Int = 20_000_000
    ) async throws -> InputHTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await send(request, maximumBytes)
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
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await send(request, maximumBytes)
    }
}
