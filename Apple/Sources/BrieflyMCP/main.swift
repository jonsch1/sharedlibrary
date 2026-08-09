import BrieflyCore
import Foundation
import MCP

@main
struct BrieflyMCPCommand {
    static func main() async throws {
        let api: any BrieflyAgentAPI
        if let databaseURL = developmentDatabaseURL() {
            api = DirectBrieflyAgentAPI(databaseURL: databaseURL)
        } else {
            api = SocketBrieflyAgentAPI()
        }

        let server = Server(
            name: "briefly",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: brieflyTools)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            do {
                switch parameters.name {
                case "ingest":
                    let request = try decode(
                        BrieflyAgentIngestRequest.self,
                        arguments: parameters.arguments
                    )
                    return try success(try await api.ingest(request))
                case "save":
                    let request = try decode(
                        BrieflyAgentSaveRequest.self,
                        arguments: parameters.arguments
                    )
                    return try success(try await api.save(request))
                case "search":
                    let request = try decode(
                        BrieflyAgentSearchRequest.self,
                        arguments: parameters.arguments
                    )
                    return try success(try await api.search(request))
                case "read":
                    let request = try decode(
                        BrieflyAgentReadRequest.self,
                        arguments: parameters.arguments
                    )
                    return try success(try await api.read(request))
                default:
                    return try failure(.invalid("Unknown Briefly tool."))
                }
            } catch let error as BrieflyAgentFailure {
                return try failure(error)
            } catch {
                return try failure(BrieflyAgentFailure(
                    code: "failed",
                    message: "Briefly could not complete the request."
                ))
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        do {
            try await Task.sleep(for: .seconds(60 * 60 * 24 * 365 * 100))
        } catch {}
        await server.stop()
    }
}

private let brieflyTools = [
    Tool(
        name: "ingest",
        description: "Capture one HTTP(S) URL using Briefly extraction and summarization. Changes the library; use only when asked.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object(["type": .string("string"), "maxLength": .int(2048)])
            ]),
            "required": .array([.string("url")]),
            "additionalProperties": .bool(false)
        ])
    ),
    Tool(
        name: "save",
        description: "Store agent-supplied document content and optional summaries without fetching its URL. Changes the library; use only when asked.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string"), "maxLength": .int(200)]),
                "content": .object(["type": .string("string"), "maxLength": .int(500000)]),
                "url": .object(["type": .string("string"), "maxLength": .int(2048)]),
                "concise": .object(["type": .string("string"), "maxLength": .int(100000)]),
                "detailed": .object(["type": .string("string"), "maxLength": .int(500000)])
            ]),
            "required": .array([.string("title"), .string("content")]),
            "additionalProperties": .bool(false)
        ])
    ),
    Tool(
        name: "search",
        description: "Search Briefly summaries, or omit q for recent items. Returns at most 10 compact matches.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "q": .object(["type": .string("string"), "maxLength": .int(500)]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .int(1),
                    "maximum": .int(10)
                ])
            ]),
            "additionalProperties": .bool(false)
        ])
    ),
    Tool(
        name: "read",
        description: "Read a saved Briefly summary by search-result id. detail=true selects the detailed summary; pass next as cursor.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "detail": .object(["type": .string("boolean")]),
                "cursor": .object(["type": .string("integer"), "minimum": .int(0)])
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false)
        ])
    )
]

private struct SocketBrieflyAgentAPI: BrieflyAgentAPI {
    let client = BrieflyAgentSocketClient()

    func ingest(_ request: BrieflyAgentIngestRequest) async throws -> BrieflyAgentWriteResult {
        let reply = try await client.call(BrieflyAgentCall(op: "ingest", ingest: request))
        if let error = reply.error { throw error }
        guard let result = reply.ingest else { throw invalidReply() }
        return result
    }

    func save(_ request: BrieflyAgentSaveRequest) async throws -> BrieflyAgentWriteResult {
        let reply = try await client.call(BrieflyAgentCall(op: "save", save: request))
        if let error = reply.error { throw error }
        guard let result = reply.save else { throw invalidReply() }
        return result
    }

    func search(_ request: BrieflyAgentSearchRequest) async throws -> BrieflyAgentSearchResult {
        let reply = try await client.call(BrieflyAgentCall(op: "search", search: request))
        if let error = reply.error { throw error }
        guard let result = reply.search else { throw invalidReply() }
        return result
    }

    func read(_ request: BrieflyAgentReadRequest) async throws -> BrieflyAgentReadResult {
        let reply = try await client.call(BrieflyAgentCall(op: "read", read: request))
        if let error = reply.error { throw error }
        guard let result = reply.read else { throw invalidReply() }
        return result
    }

    private func invalidReply() -> BrieflyAgentFailure {
        BrieflyAgentFailure(
            code: "invalid_response",
            message: "Briefly returned an invalid local response."
        )
    }
}

private struct DirectBrieflyAgentAPI: BrieflyAgentAPI {
    let store: SQLiteLibraryStore

    init(databaseURL: URL) {
        store = SQLiteLibraryStore(databaseURL: databaseURL)
    }

    func ingest(_ request: BrieflyAgentIngestRequest) async throws -> BrieflyAgentWriteResult {
        let value = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            value.count <= 2_048,
            !value.contains(where: \.isWhitespace),
            let url = URL(string: value),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil,
            url.user == nil,
            url.password == nil
        else {
            throw BrieflyAgentFailure.invalid("url must be an absolute HTTP(S) URL.")
        }
        let draft = try await NativeItemInputRouter().ingest(
            ItemInputRequest(source: .url(url))
        )
        let id = try await store.captureItem(draft)
        let result = try await BrieflyAgentLibrary(store: store).writeResult(id: id)
        if result.status == "processing" {
            try await store.enqueueProcessingJob(entryID: id, selectWhenFinished: false)
        }
        return result
    }

    func save(_ request: BrieflyAgentSaveRequest) async throws -> BrieflyAgentWriteResult {
        try await BrieflyAgentLibrary(store: store).save(request)
    }

    func search(_ request: BrieflyAgentSearchRequest) async throws -> BrieflyAgentSearchResult {
        try await BrieflyAgentLibrary(store: store).search(request)
    }

    func read(_ request: BrieflyAgentReadRequest) async throws -> BrieflyAgentReadResult {
        try await BrieflyAgentLibrary(store: store).read(request)
    }
}

private struct BrieflyAgentErrorOutput: Encodable {
    let error: BrieflyAgentFailure
}

private func decode<T: Decodable>(
    _ type: T.Type,
    arguments: [String: Value]?
) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(arguments ?? [:]))
    } catch {
        throw BrieflyAgentFailure.invalid("The tool arguments are invalid.")
    }
}

private func success<T: Encodable>(_ value: T) throws -> CallTool.Result {
    let encoded = try compactJSON(value)
    return .init(content: [.text(text: encoded, annotations: nil, _meta: nil)], isError: false)
}

private func failure(_ value: BrieflyAgentFailure) throws -> CallTool.Result {
    .init(
        content: [.text(
            text: try compactJSON(BrieflyAgentErrorOutput(error: value)),
            annotations: nil,
            _meta: nil
        )],
        isError: true
    )
}

private func compactJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
        throw BrieflyAgentFailure(
            code: "invalid_response",
            message: "Briefly could not encode the response."
        )
    }
    return string
}

private func developmentDatabaseURL() -> URL? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--library"),
          arguments.indices.contains(index + 1) else { return nil }
    return URL(filePath: arguments[index + 1]).standardizedFileURL
}
