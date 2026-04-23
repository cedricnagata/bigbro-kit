import Foundation

/// Model generation parameters forwarded verbatim to Ollama's `options` field.
/// All fields are optional — only non-nil values are included in the request.
public struct OllamaOptions: Sendable {
    public var temperature: Double?
    public var topK: Int?
    public var topP: Double?
    public var seed: Int?
    public var numPredict: Int?
    public var stop: [String]?
    public var repeatPenalty: Double?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    public var numCtx: Int?
    public var numThread: Int?

    public init(
        temperature: Double? = nil,
        topK: Int? = nil,
        topP: Double? = nil,
        seed: Int? = nil,
        numPredict: Int? = nil,
        stop: [String]? = nil,
        repeatPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        numCtx: Int? = nil,
        numThread: Int? = nil
    ) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.seed = seed
        self.numPredict = numPredict
        self.stop = stop
        self.repeatPenalty = repeatPenalty
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.numCtx = numCtx
        self.numThread = numThread
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = [:]
        if let v = temperature      { d["temperature"] = v }
        if let v = topK             { d["top_k"] = v }
        if let v = topP             { d["top_p"] = v }
        if let v = seed             { d["seed"] = v }
        if let v = numPredict       { d["num_predict"] = v }
        if let v = stop             { d["stop"] = v }
        if let v = repeatPenalty    { d["repeat_penalty"] = v }
        if let v = presencePenalty  { d["presence_penalty"] = v }
        if let v = frequencyPenalty { d["frequency_penalty"] = v }
        if let v = numCtx           { d["num_ctx"] = v }
        if let v = numThread        { d["num_thread"] = v }
        return d
    }
}

/// Ollama response format — either plain JSON mode or a structured JSON schema.
///
/// For `jsonSchema`, serialize your schema dict to `Data` before passing:
/// ```swift
/// let schemaData = try JSONSerialization.data(withJSONObject: mySchema)
/// let format = OllamaFormat.jsonSchema(schemaData)
/// ```
public enum OllamaFormat: Sendable {
    case json
    case jsonSchema(Data)

    func toJSONValue() -> Any {
        switch self {
        case .json:
            return "json"
        case .jsonSchema(let data):
            return (try? JSONSerialization.jsonObject(with: data)) ?? "json"
        }
    }
}
