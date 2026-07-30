# BigBroKit

An iOS Swift Package for connecting to a [BigBro](https://github.com/nagata-inc/bigbro) Mac and running inference over the local network. BigBroKit discovers the Mac via Bonjour, establishes a persistent TCP connection, and proxies requests to the Mac's local backend.

The Mac talks to an OpenAI-compatible server — [Ollama](https://ollama.ai) by default for chat, [LocalAI](https://localai.io) for speech — so this package covers chat with full tool calling, single-turn generation, text-to-speech and transcription.

## Requirements

- iOS 17.0+
- Xcode 15+
- A Mac running the BigBro app on the same local network

## Installation

### Swift Package Manager

**Xcode:** File → Add Package Dependencies, enter the repository URL.

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/nagata-inc/bigbro-kit", from: "1.0.0")
]
```

## Setup

Add the following to your app's `Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Used to discover and connect to BigBro on your local network.</string>
<key>NSBonjourServices</key>
<array>
    <string>_bigbro._tcp</string>
</array>
```

## Quick start

```swift
import BigBroKit

let client = BigBroClient(appName: "My App")

// 1. Discover BigBro Macs on the local network (5-second scan)
let devices = await client.discover()
guard !devices.isEmpty else { return }

// 2. Pair — shows an approval dialog on the Mac the first time; silent thereafter
let approved = try await client.pair(with: devices[0])
guard approved else { return }

// 3. Check for missing models
if !client.missingModels.isEmpty {
    print("Missing: \(client.missingModels.joined(separator: ", "))")
}

// 4. Stream a chat response one token at a time
for try await delta in client.chat([.user("Explain Swift concurrency in one paragraph.")]) {
    print(delta, terminator: "")
}
```

## Connection lifecycle

`BigBroClient` keeps **no persistent state** — every launch starts disconnected. The Mac remembers every device it has approved, so re-pairing after a fresh app launch is instant and silent (no dialog, no delay).

```
.disconnected → pair() → .connected → (network degrades) → .reconnecting → (recovers) → .connected
                                                                          → (timeout)   → .disconnected
```

The client tears down automatically — returning `connectionState` to `.disconnected` — when any of these happens:

- The Mac user clicks **Disconnect** or **Remove** for that device
- The underlying TCP connection fails or is reset

Observe state changes in SwiftUI with `@ObservedObject`:

```swift
struct ContentView: View {
    @ObservedObject var client: BigBroClient

    var body: some View {
        switch client.connectionState {
        case .disconnected:  Text("Not connected")
        case .reconnecting:  ProgressView("Reconnecting…")
        case .connected:     Text("Connected to \(client.connectedDevice?.name ?? "")")
        }
    }
}
```

## Required models

Declare the Ollama models your app needs when creating the client. BigBro checks whether they are installed when the device connects and reports any that are missing:

```swift
let client = BigBroClient(
    appName: "My App",
    requiredModels: ["llama3.2", "llava:13b"]
)

// After pair():
if !client.missingModels.isEmpty {
    // Show a warning — these models need to be downloaded in Ollama on the Mac
}
```

`missingModels` is a `@Published` property. If Ollama's model list changes while the device is connected (e.g. a model is downloaded), the Mac automatically pushes an update and `missingModels` updates in real time — no reconnect needed.

## API reference

### `BigBroClient`

`@MainActor ObservableObject`. Create one instance per session.

#### State

```swift
@Published var connectedDevice: BigBroDevice?
@Published var connectionState: ConnectionState   // .disconnected | .reconnecting | .connected
@Published var missingModels: [String]            // models not yet installed in Ollama on the Mac
var isConnected: Bool                             // true only when fully .connected
```

#### Initializer

```swift
public init(appName: String, requiredModels: [String] = [])
```

`appName` is displayed on the Mac's device list alongside the device name (e.g. "iPhone • My App"), making it easy to distinguish multiple apps from the same device.

#### Discovery and pairing

```swift
// Scans the local network for BigBro Macs. Times out after ~5 seconds.
// Multiple concurrent calls join the same in-flight scan.
func discover() async -> [BigBroDevice]

// Connects and performs the hello/helloAck handshake.
// Returns true if the Mac approved, false if denied.
// Throws on network failure.
func pair(with device: BigBroDevice) async throws -> Bool

// Sends bye and tears down the connection.
func disconnect()
```

#### Inference — chat

```swift
func chat(
    _ messages: [Message],
    model: String? = nil,         // overrides the Mac's default model
    streaming: Bool = true,       // false → single yield of the full response
    tools: [BigBroTool] = [],     // triggers the agentic tool-call loop
    format: ResponseFormat? = nil,
    options: GenerationOptions? = nil,
    think: Bool? = nil,                        // forward the reasoning trace to this device
    reasoningEffort: ReasoningEffort? = nil,   // how hard the model actually thinks
    keepAlive: String? = nil      // how long Ollama keeps the model loaded
) -> AsyncThrowingStream<String, Error>
```

#### Inference — generate

```swift
func generate(
    prompt: String,
    images: [Data] = [],          // multimodal models only; base64 is handled internally
    suffix: String? = nil,
    system: String? = nil,
    template: String? = nil,
    model: String? = nil,
    format: ResponseFormat? = nil,
    options: GenerationOptions? = nil,
    raw: Bool? = nil,
    think: Bool? = nil,
    reasoningEffort: ReasoningEffort? = nil,
    keepAlive: String? = nil,
    streaming: Bool = true
) -> AsyncThrowingStream<String, Error>
```

`generate()` does not support tools — it is a single-turn completion.

> `template`, `raw` and `suffix` have no equivalent on the Mac's backend and return an error
> rather than being silently ignored. Reasoning arrives as a separate `thinking` message so it
> is never mixed into the answer — or spoken.

#### Reasoning: `think` vs `reasoningEffort`

Two different knobs, easy to confuse:

```swift
public enum ReasoningEffort: String, Sendable, CaseIterable, Codable {
    case low, medium, high        // .default == .medium
}
```

| | What it changes | Effect on latency |
|---|---|---|
| `think` | Whether the reasoning trace is **forwarded** to this device (via `onThinking`) or dropped on the Mac | None on its own — the model reasons either way |
| `reasoningEffort` | How long the model actually **spends reasoning** before answering | Real: `.low` is typically tens of analysis tokens, `.high` hundreds |

There is deliberately no "off". gpt-oss is a Harmony model — it always writes an `analysis`
channel before its final one, and the only lever its prompt format carries is an effort level,
rendered into the system message as `Reasoning: <level>`. It was trained on exactly these three
words; a fourth value would be text the model has never seen, which degrades the answer instead
of skipping the analysis. `.low` is the closest thing to turning it off.

Passing `think: false` without an explicit effort is treated by the Mac as a request for speed
and lowers the budget to `low`. Set `reasoningEffort` when you want to say so outright — it
always wins over that inference, so `think: false` + `.high` means "think hard, just don't show
me the working".

#### Inference — run / stop

```swift
func runModel(vision: Bool = false) async throws
func runModel(_ model: String?) async throws     // name the model outright
func stopModel(_ model: String? = nil) async throws
```

Downloaded and running are different states on the Mac: weights on disk cost only disk, weights
in memory cost RAM — 12 GB of it for gpt-oss-20b. `runModel` moves a model from the first to the
second; `stopModel` moves it back, keeping the download.

Removing a download is deliberately not available here. It is destructive and irreversible over
a slow re-download, so it belongs to whoever owns the Mac, in BigBro's Settings. Note too that
models are shared across paired devices — stopping one takes it away from all of them, not just
this device.

Starts a model on the Mac ahead of time, without generating anything. The Mac materializes a
model's weights into memory the first time a request actually needs it — for a large model, a
real multi-second cost that otherwise lands on whichever message happens to be first. Call this
when a chat session is likely to start soon (e.g. when the chat screen appears) to pay that
cost earlier instead.

Purely an optimization: safe to skip, and safe to call more than once. Throws
`BigBroError.modelDownloading` if the model isn't downloaded yet (the download starts either
way — watch `modelDownloads` and retry once it completes, or just proceed to `chat()`/`generate()`,
which will wait on the same download).

A good place to call it is the moment a Mac connects, so the wait overlaps with the user
getting to the chat screen:

```swift
client.$connectionState
    .sink { state in
        guard state == .connected else { return }
        Task { try? await client.runModel(nil) }
    }
    .store(in: &cancellables)
```

The `vision:` form asks the Mac for whichever model it has configured for that capability. The
`String?` form names one outright — use it when the app lets the user pick a model, so the one
that gets started is the one the next message will actually use. Passing `nil` falls back to
the Mac's default.

A Mac running a build that doesn't know these messages ignores them and answers nothing, so the
call gives up after three minutes rather than hanging forever. That timeout returns normally —
it isn't surfaced as an error, since both are optional either way.

`preloadModel(vision:)` and `preloadSpeech()` remain as deprecated aliases. The old name
suggested a cache warm-up; a model that has been run stays running until stopped.

---

#### Speech — `speak()`, `transcribe()`, `converse()`

Requires a speech backend enabled on the Mac (LocalAI by default; Speaches works too).

```swift
func speak(
    _ text: String,
    voice: String? = nil,
    model: String? = nil,
    responseFormat: String? = nil,   // "pcm" (default), "wav", "mp3", "opus", "flac"
    speed: Double? = nil
) -> AsyncThrowingStream<Data, Error>

func transcribe(
    _ audio: Data,
    format: String = "wav",
    model: String? = nil,
    language: String? = nil
) async throws -> String

func converse(
    _ messages: [Message],
    voice: String? = nil,
    tools: [BigBroTool] = [],
    model: String? = nil,
    options: GenerationOptions? = nil,
    reasoningEffort: ReasoningEffort? = nil
) -> AsyncThrowingStream<ConverseEvent, Error>

// Speech in, speech out — one whole spoken turn.
func converse(
    audio: Data,
    format: String = "wav",
    history: [Message] = [],
    voice: String? = nil,
    tools: [BigBroTool] = [],
    model: String? = nil,
    options: GenerationOptions? = nil,
    reasoningEffort: ReasoningEffort? = nil
) -> AsyncThrowingStream<ConverseEvent, Error>

// Starts Kokoro and Parakeet on the Mac before a voice session begins. No matching stop:
// the speech models are shared by every paired device and reload slowly.
func runSpeech() async throws
```

`speak()` yields raw audio chunks. The default `pcm` is 24 kHz 16-bit signed little-endian mono
with no header, so it cannot be handed to `AVAudioPlayer` — use `BigBroAudioPlayer` below.
Speaking a canned string costs no LLM call.

#### `BigBroAudioPlayer`

```swift
let player = BigBroAudioPlayer()
try await player.play(client.speak("Dinner is ready."))
```

Converts each chunk to Float32 and schedules it on an `AVAudioPlayerNode` as it arrives, so
playback begins on the first chunk rather than after the whole utterance. `play()` returns once
the last buffer has finished; `stop()` ends playback immediately for barge-in and leaves the
engine running so the next utterance starts without restart latency.

Pass `configuresAudioSession: false` if your app already manages `AVAudioSession` itself —
otherwise the two fight over the category — and call `shutdown()` before deactivating the session.

`transcribe()` is batch, not streaming: record a complete turn, then send it. Uploads are
capped at 10 MB. Your app needs `NSMicrophoneUsageDescription` to record.

`converse()` runs a chat turn and speaks the answer as it arrives, one sentence at a time,
so time to first audio is a single sentence rather than a whole generation:

```swift
for try await event in client.converse([.user("What's the weather like?")], voice: "af_heart") {
    switch event {
    case .text(let delta):  transcript += delta
    case .audio(let chunk): audioIn.yield(chunk)
    case .transcript:       break   // only the audio-in overload produces this
    }
}
```

Sentences are segmented with `NLTokenizer` and stripped of markdown — code fences, link
targets and table pipes are noise read aloud. Speech requests are serialized, so audio can
never arrive out of order. The tool-calling loop still runs on the device, which is why
`converse()` is a composition over `chat()` and `speak()` rather than a Mac-side mode: only
the client knows which turn is a final answer and which is an intermediate tool step.

The `audio:` overload closes the loop — transcribe, answer, speak, in one call. It yields
`.transcript` first, then `.text` and `.audio` interleaved:

```swift
for try await event in client.converse(audio: wav, history: history, tools: myTools) {
    switch event {
    case .transcript(let heard): print("you said: \(heard)")
    case .text(let delta):       reply += delta
    case .audio(let chunk):      audioIn.yield(chunk)
    }
}
```

An utterance that transcribes to nothing finishes after `.transcript("")` without generating,
so a hands-free loop can ignore empty transcripts rather than treating a cough as a turn.

---

### `BigBroMicrophone` — capture with endpointing

`transcribe()` needs a complete recording, which leaves you to decide when a turn ended.
Push-to-talk answers that with a button; a hands-free loop has to answer it from the audio.
`BigBroMicrophone` watches signal energy and emits one 16 kHz WAV per utterance:

```swift
let mic = BigBroMicrophone()
for try await utterance in mic.utterances() {
    let text = try await client.transcribe(utterance, format: "wav")
}
```

Published state — `isCapturing`, `isSpeaking`, `level` — drives listening indicators and
meters. `Tuning` exposes the endpointing thresholds; `hangoverDuration` (default 0.7 s) is the
one that decides how responsive the loop feels against how badly it clips people who pause
mid-sentence. A 0.3 s preroll is kept so the opening consonant isn't lost, since by the time
energy crosses the threshold the word has already started.

Requires `NSMicrophoneUsageDescription`.

---

### `BigBroVoiceSession` — the whole loop

Listen, transcribe, answer (with tools), speak, repeat — continuously, hands-free.

```swift
let session = BigBroVoiceSession(client: client, tools: myTools)
await session.start()
// session.phase, .transcript, .reply, .level, .history are all @Published
session.stop()
```

It owns the pieces that only matter once the legs run continuously: conversation history
across turns, one `AVAudioSession` that capture and playback can share, and barge-in.

**Barge-in** is on by default. Talking over an answer cuts it off and starts a new turn — and
that cancellation propagates, so the Mac stops generating rather than finishing an answer
nobody will hear. The interrupted turn is still committed to history, partial answer included,
so a follow-up like "sorry, go on" has something to refer to.

The session sets `.playAndRecord` with mode `.voiceChat`, which is what enables the system
echo canceller. Without it the microphone hears the assistant's own voice, the endpointer
reads that as the user talking, and the loop interrupts itself in a cycle that never settles.
If echo cancellation is failing on some device, `allowsBargeIn = false` makes the loop
half-duplex instead of letting it argue with itself.

`setHistory(_:)` adopts an existing conversation, so switching from typing to voice continues
it rather than starting over.

---

### `Message`

```swift
public struct Message {
    public enum Role: String { case user, assistant, system, tool }

    public let role: Role
    public let content: String
    public let images: [Data]?              // raw Data; base64-encoded on the wire
    public let toolCalls: [[String: Any]]?  // assistant messages containing tool calls
    public let toolName: String?            // tool-role result messages
    public let thinking: String?            // chain-of-thought text (thinking models only)
}
```

**Convenience constructors:**

```swift
.user("Hello")
.user("Describe this image.", images: [imageData])
.assistant("Hello back!")
.system("You are a concise assistant.")
.tool(name: "get_weather", content: "72°F, sunny")
```

---

### `BigBroTool`

Tools are defined with a JSON-schema description and a Swift `async` handler that runs locally on the iOS device. Pass one or more to `chat()` and the SDK's agentic loop handles tool execution transparently — callers only see the final text stream.

```swift
// Tool with no parameters
let dateTool = BigBroTool(
    definition: BigBroTool.Definition(
        name: "get_current_date",
        description: "Returns the current date and time."
    ),
    handler: { _ in
        DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .medium)
    }
)

// Tool with parameters
let weatherTool = BigBroTool(
    definition: BigBroTool.Definition(
        name: "get_weather",
        description: "Returns current weather for a city.",
        parameters: BigBroTool.Definition.Parameters(
            properties: [
                "city": .init(type: "string", description: "City name")
            ],
            required: ["city"]
        )
    ),
    handler: { args in
        let city = args["city"] as? String ?? ""
        return await fetchWeather(for: city)
    }
)

for try await delta in client.chat(history, tools: [dateTool, weatherTool]) {
    print(delta, terminator: "")
}
```

**Agentic loop:** When Ollama returns tool calls, the SDK automatically:
1. Executes each tool handler locally on the device
2. Appends the results to the message history
3. Re-sends the updated history
4. Repeats until Ollama returns a final text response

The caller never sees intermediate tool calls — only the final streamed text.

---

### `GenerationOptions`

Maps directly to Ollama's `options` request field. All fields are optional.

```swift
let opts = GenerationOptions(temperature: 0.7, topK: 40, seed: 42)
for try await delta in client.chat(messages, options: opts) { ... }
```

| Swift property | Ollama key | Type |
|---|---|---|
| `temperature` | `temperature` | `Double` |
| `topK` | `top_k` | `Int` |
| `topP` | `top_p` | `Double` |
| `seed` | `seed` | `Int` |
| `numPredict` | `num_predict` | `Int` |
| `stop` | `stop` | `[String]` |
| `repeatPenalty` | `repeat_penalty` | `Double` |
| `presencePenalty` | `presence_penalty` | `Double` |
| `frequencyPenalty` | `frequency_penalty` | `Double` |
| `numCtx` | `num_ctx` | `Int` |
| `numThread` | `num_thread` | `Int` |

---

### `ResponseFormat`

```swift
// Plain JSON mode
client.chat(messages, format: .json)

// Structured output with a JSON schema
let schemaData = try JSONSerialization.data(withJSONObject: [
    "type": "object",
    "properties": ["name": ["type": "string"], "age": ["type": "integer"]],
    "required": ["name", "age"]
])
client.chat(messages, format: .jsonSchema(schemaData))
```

---

### `BigBroDevice`

```swift
public struct BigBroDevice: Identifiable, Hashable {
    public let id: String     // service name (Mac hostname)
    public let name: String   // e.g. "Cedric's MacBook Pro"
    public let host: String   // resolved mDNS hostname
    public let port: Int      // always 8765
}
```

---

### `BigBroError`

```swift
public enum BigBroError: LocalizedError {
    case notPaired            // a request was made before a successful pair()
    case networkError         // TCP failure
    case serverError(String)  // the Mac reported a failure; the message is actionable
    case modelDownloading(model: String, alreadyInProgress: Bool)
}
```

---

### `ConnectionState`

```swift
public enum ConnectionState: Equatable {
    case disconnected
    case reconnecting   // path degraded; recovering or timing out
    case connected
}
```

## Error handling

```swift
do {
    for try await delta in client.chat(messages) {
        output += delta
    }
} catch BigBroError.notPaired {
    // call pair() first
} catch BigBroError.networkError {
    // connection dropped; check client.connectionState
} catch {
    // unexpected error
}
```

## Non-streaming mode

When `streaming: false`, the stream yields exactly one value — the complete response — then finishes:

```swift
var fullResponse = ""
for try await chunk in client.chat(messages, streaming: false) {
    fullResponse = chunk
}
```

## Source layout

```
bigbro-kit/
├── Sources/
│   ├── BigBroClient.swift      — main client (ObservableObject, agentic loop)
│   ├── BigBroDevice.swift      — discovered device model
│   ├── BonjourBrowser.swift    — Bonjour/mDNS discovery (NetServiceBrowser, MainActor)
│   ├── Message.swift           — chat message model + wire serialization
│   ├── GenerationOptions.swift — generation options + ResponseFormat enum
│   ├── PeerConnection.swift    — TCP actor (4-byte framed JSON)
│   └── Tool.swift              — BigBroTool definition + handler
└── Package.swift
```

## Protocol overview

BigBroKit communicates with the Mac over TCP on port 8765. Each message is a 4-byte big-endian length prefix followed by a UTF-8 JSON body.

| iOS → Mac | Fields | Purpose |
|---|---|---|
| `hello` | `deviceId`, `deviceName`, `appName`, `requiredModels?` | Initiate pairing |
| `request` | `requestId`, `messages`, `streaming`, `tools?`, `model?`, `think?`, `reasoning_effort?`, … | Chat inference |
| `generateRequest` | `requestId`, `prompt`, `streaming`, `images?`, `think?`, `reasoning_effort?`, … | Generate inference |
| `speechRequest` | `requestId`, `input`, `voice?`, `model?`, `response_format?`, `speed?` | Text to speech |
| `transcribeRequest` | `requestId`, `audio` (base64), `audioFormat?`, `model?`, `language?` | Speech to text |
| `run` | `requestId`, `model?` (`"text"` / `"vision"` / `"speech"`, or a model id) | Start a model — put its weights in memory |
| `stop` | `requestId`, `model?` (`"text"` / `"vision"`, or a model id) | Stop a model, keeping its download |
| `bye` | — | Clean disconnect |

| Mac → iOS | Fields | Purpose |
|---|---|---|
| `helloAck` | `status`, `missingModels?` | Pairing result |
| `chunk` | `requestId`, `delta` | Streamed text token |
| `thinking` | `requestId`, `delta` | Reasoning token, never mixed into `chunk` |
| `toolCall` | `requestId`, `calls` | Tool calls array |
| `audioStart` | `requestId`, `format`, `sampleRate`, `channels`, `model`, `voice` | Precedes audio so playback can be configured |
| `audioChunk` | `requestId`, `audio` (base64), `seq` | Synthesized audio |
| `transcript` | `requestId`, `text`, `language?` | Transcription result |
| `done` | `requestId` | Request complete |
| `error` | `requestId`, `message` | Inference error |

Every response carries a `requestId` and the client routes on it, so chat, speech and
transcription can be in flight simultaneously — which `converse()` relies on.
| `modelsUpdate` | `missingModels` | Live push when Ollama model list changes |
| `bye` | — | Clean disconnect |
