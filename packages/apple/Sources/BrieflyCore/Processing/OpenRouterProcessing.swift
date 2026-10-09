#if os(macOS)
import Foundation

public let defaultOpenRouterModelID = "openai/gpt-5.6-luna"

public struct OpenRouterModel: Codable, Sendable {
    public struct Architecture: Codable, Sendable {
        public let inputModalities: [String]
        public let outputModalities: [String]
    }
    public struct Pricing: Codable, Sendable {
        public let prompt: String?
        public let completion: String?
    }
    public struct TopProvider: Codable, Sendable {
        public let maxCompletionTokens: Int?
    }
    public struct Reasoning: Codable, Sendable {
        public let supportedEfforts: [String]?
        public let exposesEffort: Bool
        public let defaultEffort: String?
        public let defaultEnabled: Bool?
        public let mandatory: Bool

        private enum CodingKeys: String, CodingKey {
            case supportedEfforts, defaultEffort, defaultEnabled, mandatory
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            exposesEffort = values.contains(.supportedEfforts)
            supportedEfforts = try values.decodeIfPresent([String].self, forKey: .supportedEfforts)
            defaultEffort = try values.decodeIfPresent(String.self, forKey: .defaultEffort)
            defaultEnabled = try values.decodeIfPresent(Bool.self, forKey: .defaultEnabled)
            mandatory = try values.decodeIfPresent(Bool.self, forKey: .mandatory) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            if exposesEffort {
                if let supportedEfforts { try values.encode(supportedEfforts, forKey: .supportedEfforts) }
                else { try values.encodeNil(forKey: .supportedEfforts) }
            }
            try values.encodeIfPresent(defaultEffort, forKey: .defaultEffort)
            try values.encodeIfPresent(defaultEnabled, forKey: .defaultEnabled)
            try values.encode(mandatory, forKey: .mandatory)
        }
    }

    public let id: String
    public let name: String
    public let architecture: Architecture
    public let supportedParameters: [String]
    public let pricing: Pricing?
    public let topProvider: TopProvider?
    public let reasoning: Reasoning?

    public var supportsSummaries: Bool {
        architecture.inputModalities.contains("text") &&
        architecture.outputModalities.contains("text") &&
        supportedParameters.contains("structured_outputs") &&
        supportedParameters.contains("response_format") &&
        (topProvider?.maxCompletionTokens ?? 1) > 0
    }

    public var availableEfforts: [String] {
        guard let reasoning, reasoning.exposesEffort else { return [] }
        // A null supported_efforts accepts all gateway values; an absent field
        // means no effort control. Mandatory reasoning must never offer "none".
        let values = reasoning.supportedEfforts ?? ["max", "xhigh", "high", "medium", "low", "minimal", "none"]
        return values.reversed().filter { !(reasoning.mandatory && $0 == "none") }
    }
}

public struct OpenRouterModelSelection: Codable, Sendable {
    public let modelID: String
    public let model: OpenRouterModel
    public let fetchedAt: Date

    public init(modelID: String, model: OpenRouterModel, fetchedAt: Date = Date()) {
        self.modelID = modelID
        self.model = model
        self.fetchedAt = fetchedAt
    }
}

public func fetchOpenRouterModel(
    _ modelID: String,
    http: InputHTTPClient = .openRouter
) async throws -> OpenRouterModel {
    try validateOpenRouterModelID(modelID)
    var components = URLComponents()
    components.scheme = "https"
    components.host = "openrouter.ai"
    components.path = "/api/v1/model/" + modelID
    var request = URLRequest(url: components.url!, timeoutInterval: 20)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let response = try await http.send(request, 1_000_000)
    guard response.finalURL == request.url, response.data.count <= 1_000_000 else {
        throw OpenRouterProcessingError(message: "OpenRouter returned invalid model options.")
    }
    if response.statusCode == 404 {
        throw OpenRouterProcessingError(message: "Model not found. Copy its model ID from OpenRouter, including the provider name.")
    }
    guard (200..<300).contains(response.statusCode) else {
        throw OpenRouterProcessingError(message: "Could not load this model’s options from OpenRouter. Try again.")
    }
    struct Response: Decodable { let data: OpenRouterModel }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let model = try? decoder.decode(Response.self, from: response.data).data else {
        throw OpenRouterProcessingError(message: "OpenRouter returned invalid model options.")
    }
    return model
}

private func validateOpenRouterModelID(_ modelID: String) throws {
    guard modelID.count <= 200,
          modelID.range(of: #"^~?[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil else {
        throw OpenRouterProcessingError(message: "Use a model ID such as openai/gpt-5.6-luna. You can copy one from OpenRouter’s model page.")
    }
    guard !modelID.hasSuffix(":batch") else {
        throw OpenRouterProcessingError(message: "Choose the regular model ID instead of its batch variant.")
    }
}

private struct OpenRouterProcessingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct OpenRouterResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
    }

    let choices: [Choice]
}

private struct OpenRouterFailure: Decodable {
    struct Detail: Decodable {
        let message: String?
    }

    let error: Detail?
}

public func runOpenRouterProcessing(
    prompt: String,
    format: String,
    apiKey: String,
    modelID: String,
    reasoningEffort: String? = nil,
    model: OpenRouterModel? = nil,
    http: InputHTTPClient = .openRouter
) async throws -> String {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw OpenRouterProcessingError(message: "Enter an OpenRouter API key first.")
    }
    try validateOpenRouterModelID(modelID)
    if let reasoningEffort, !(model?.availableEfforts.contains(reasoningEffort) ?? false) {
        throw OpenRouterProcessingError(message: "Choose a reasoning effort supported by this model.")
    }
    if format == "json", let model, !model.supportsSummaries {
        throw OpenRouterProcessingError(message: "This model does not support Briefly’s structured summaries.")
    }
    guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
        throw OpenRouterProcessingError(message: "The OpenRouter service URL is invalid.")
    }

    var request = URLRequest(url: url, timeoutInterval: 15 * 60)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("https://www.readbriefly.fyi", forHTTPHeaderField: "HTTP-Referer")
    request.setValue("Briefly", forHTTPHeaderField: "X-Title")

    var payload: [String: Any] = [
        "model": modelID,
        "messages": [["role": "user", "content": prompt]],
        "max_tokens": min(format == "json" ? 32_000 : 16_000, model?.topProvider?.maxCompletionTokens ?? 32_000),
        "provider": [
            "require_parameters": true,
            "allow_fallbacks": true
        ]
    ]
    if model?.reasoning != nil || reasoningEffort != nil {
        var reasoning: [String: Any] = ["exclude": true]
        if let reasoningEffort { reasoning["effort"] = reasoningEffort }
        payload["reasoning"] = reasoning
    }
    if format == "json" {
        payload["response_format"] = [
            "type": "json_schema",
            "json_schema": [
                "name": "briefly_processing",
                "strict": true,
                "schema": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "short_filename": ["type": "string"],
                        "summaries": [
                            "type": "object",
                            "additionalProperties": false,
                            "properties": [
                                "detailed": ["type": "string"],
                                "concise": ["type": "string"]
                            ],
                            "required": ["detailed", "concise"]
                        ],
                        "topic_name": ["type": "string"]
                    ],
                    "required": ["short_filename", "summaries", "topic_name"]
                ]
            ]
        ]
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let response = try await http.send(request, 2_000_000)
    guard response.finalURL == request.url, response.data.count <= 2_000_000 else {
        throw OpenRouterProcessingError(message: "OpenRouter returned an invalid response.")
    }
    let data = response.data
    guard (200..<300).contains(response.statusCode) else {
        let failure = try? JSONDecoder().decode(OpenRouterFailure.self, from: data)
        throw OpenRouterProcessingError(message: 
            failure?.error?.message ?? "OpenRouter could not process this request."
        )
    }
    let result = try? JSONDecoder().decode(OpenRouterResponse.self, from: data)
    if result?.choices.first?.finishReason == "length" {
        throw OpenRouterProcessingError(message: "The model reached its output limit. Try a lower reasoning effort or a model with a larger output limit.")
    }
    guard let output = result?.choices.first?.message.content?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !output.isEmpty else {
        throw OpenRouterProcessingError(message: "OpenRouter returned no output.")
    }
    return output
}

#endif
