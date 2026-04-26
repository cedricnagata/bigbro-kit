# BigBroKit

An iOS Swift Package for connecting to a [BigBro](https://github.com/nagata-inc/bigbro) Mac and running LLM inference over the local network. BigBroKit discovers the Mac via Bonjour, establishes a persistent TCP connection, and proxies requests to the Mac's local [Ollama](https://ollama.ai) instance — covering both `/api/chat` (with full tool-calling support) and `/api/generate`.

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

#### Inference — `/api/chat`

```swift
func chat(
    _ messages: [Message],
    model: String? = nil,         // overrides the Mac's default model
    streaming: Bool = true,       // false → single yield of the full response
    tools: [BigBroTool] = [],     // triggers the agentic tool-call loop
    format: OllamaFormat? = nil,
    options: OllamaOptions? = nil,
    think: Bool? = nil,           // chain-of-thought (supported models only)
    keepAlive: String? = nil      // how long Ollama keeps the model loaded
) -> AsyncThrowingStream<String, Error>
```

#### Inference — `/api/generate`

```swift
func generate(
    prompt: String,
    images: [Data] = [],          // multimodal models only; base64 is handled internally
    suffix: String? = nil,
    system: String? = nil,
    template: String? = nil,
    model: String? = nil,
    format: OllamaFormat? = nil,
    options: OllamaOptions? = nil,
    raw: Bool? = nil,
    think: Bool? = nil,
    keepAlive: String? = nil,
    streaming: Bool = true
) -> AsyncThrowingStream<String, Error>
```

`generate()` does not support tools — `/api/generate` is a raw completion endpoint.

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

### `OllamaOptions`

Maps directly to Ollama's `options` request field. All fields are optional.

```swift
let opts = OllamaOptions(temperature: 0.7, topK: 40, seed: 42)
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

### `OllamaFormat`

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
    case notPaired      // chat() or generate() called before a successful pair()
    case networkError   // TCP failure
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
│   ├── OllamaOptions.swift     — generation options + OllamaFormat enum
│   ├── PeerConnection.swift    — TCP actor (4-byte framed JSON)
│   └── Tool.swift              — BigBroTool definition + handler
└── Package.swift
```

## Protocol overview

BigBroKit communicates with the Mac over TCP on port 8765. Each message is a 4-byte big-endian length prefix followed by a UTF-8 JSON body.

| iOS → Mac | Fields | Purpose |
|---|---|---|
| `hello` | `deviceId`, `deviceName`, `appName`, `requiredModels?` | Initiate pairing |
| `request` | `requestId`, `messages`, `streaming`, `tools?`, `model?`, … | Chat inference |
| `generateRequest` | `requestId`, `prompt`, `streaming`, `images?`, … | Generate inference |
| `bye` | — | Clean disconnect |

| Mac → iOS | Fields | Purpose |
|---|---|---|
| `helloAck` | `status`, `missingModels?` | Pairing result |
| `chunk` | `requestId`, `delta` | Streamed text token |
| `toolCall` | `requestId`, `calls` | Tool calls array from Ollama |
| `done` | `requestId` | Request complete |
| `error` | `requestId`, `message` | Inference error |
| `modelsUpdate` | `missingModels` | Live push when Ollama model list changes |
| `bye` | — | Clean disconnect |
