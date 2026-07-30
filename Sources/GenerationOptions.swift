import Foundation

/// Model generation parameters. All fields are optional — only non-nil values are sent.
///
/// The Mac maps these onto the backend's OpenAI-compatible request: most translate directly,
/// `numPredict` becomes `max_tokens`, and `topK`, `repeatPenalty`, `numCtx` and `numThread`
/// have no OpenAI equivalent and are forwarded verbatim for backends that accept them as
/// extensions.
public struct GenerationOptions: Sendable {
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
        if let v = stop, !v.isEmpty { d["stop"] = v }
        if let v = repeatPenalty    { d["repeat_penalty"] = v }
        if let v = presencePenalty  { d["presence_penalty"] = v }
        if let v = frequencyPenalty { d["frequency_penalty"] = v }
        if let v = numCtx           { d["num_ctx"] = v }
        if let v = numThread        { d["num_thread"] = v }
        return d
    }
}

/// How much deliberation a reasoning model should spend before answering.
///
/// This is a *budget*, not a switch. gpt-oss is a Harmony model: it always writes to an
/// analysis channel before its final one, and the only lever its prompt format carries is an
/// effort level, rendered literally into the system message as `Reasoning: <level>`. It was
/// trained on exactly these three words — there is no fourth value meaning "off", and
/// inventing one puts text in the prompt the model has never seen, which degrades the answer
/// instead of skipping the analysis. `.low` is the closest thing to turning it off, typically
/// tens of analysis tokens rather than hundreds.
///
/// Distinct from `think:` on `chat()` and `generate()`, which decides whether the reasoning
/// the model produces is *forwarded* to this device or dropped on the Mac. Turning `think`
/// off hides the trace; it does not make the model skip it.
///
/// The two do interact at one point: when no effort is named, the Mac reads `think: false` as
/// a request for speed and drops the budget to `.low` on the caller's behalf. Setting this
/// explicitly overrides that, so `think: false` with `.high` means "think hard, just don't
/// show me the working".
public enum ReasoningEffort: String, Sendable, CaseIterable, Codable {
    case low
    case medium
    case high

    /// What gpt-oss assumes when nothing is specified.
    public static let `default`: ReasoningEffort = .medium
}

/// Constrains the response — either plain JSON mode or a structured JSON schema.
///
/// For `jsonSchema`, serialize your schema dict to `Data` before passing:
/// ```swift
/// let schemaData = try JSONSerialization.data(withJSONObject: mySchema)
/// let format = ResponseFormat.jsonSchema(schemaData)
/// ```
public enum ResponseFormat: Sendable {
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

// MARK: - Compatibility

/// The old names are kept as aliases so existing call sites keep compiling. They predate
/// BigBro proxying to any OpenAI-compatible backend, and are misleading now that the
/// backend may not be Ollama at all.
@available(*, deprecated, renamed: "GenerationOptions")
public typealias OllamaOptions = GenerationOptions

@available(*, deprecated, renamed: "ResponseFormat")
public typealias OllamaFormat = ResponseFormat
