# BigBroKit

An iOS Swift Package for connecting to a [BigBro](https://github.com/nagata-inc/bigbro) Mac and offloading LLM inference over the local network. BigBroKit discovers the Mac via Bonjour, establishes a persistent TCP connection, and proxies requests to the Mac's local [Ollama](https://ollama.ai) instance — covering both `/api/chat` (with full tool-calling support) and `/api/generate`.

## Requirements

- iOS 17.0+
- Xcode 15+
- A Mac running the BigBro app on the same local network

## Installation

### Swift Package Manager

Add BigBroKit as a dependency in Xcode: **File → Add Package Dependencies** and enter the repository URL.

Or add it to your `Package.swift`:

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

let client = BigBroClient()

// 1. Discover BigBro Macs on the local network
let devices = await client.discover()

// 2. Pair with one (shows an approval dialog on the Mac on first connect)
let approved = try await client.pair(with: devices[0])

// 3. Send a chat request — deltas stream back one token at a time
let messages: [Message] = [.user("Explain Swift concurrency in one paragraph.")]
for try await delta in client.send(messages) {
    print(delta, terminator: "")
}
```

## API reference

### `BigBroClient`

`@MainActor ObservableObject` — one instance per session.

```swift
// State
@Published var connectedDevice: BigBroDevice?
@Published var connectionState: ConnectionState   // .disconnected | .reconnecting | .connected
var isConnected: Bool

// Discovery & pairing
func discover() async -> [BigBroDevice]
func pair(with device: BigBroDevice) async throws -> Bool
func disconnect()

// Inference — /api/chat
func send(
    _ messages: [Message],
    model: String? = nil,
    streaming: Bool = true,
    tools: [BigBroTool] = [],
    format: OllamaFormat? = nil,
    options: OllamaOptions? = nil,
    think: Bool? = nil,
    keepAlive: String? = nil
) -> AsyncThrowingStream<String, Error>

// Inference — /api/generate
func generate(
    prompt: String,
    images: [Data] = [],
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

### `Message`

```swift
public struct Message {
    public enum Role: String { case user, assistant, system, tool }

    public let role: Role
    public let content: String
    public let images: [Data]?       // base64-encoded on the wire; pass raw Data here
    public let toolCalls: [[String: Any]]?  // for assistant messages containing tool calls
    public let toolName: String?     // for tool-role result messages
    public let thinking: String?     // chain-of-thought text (thinking models only)

    // Convenience constructors
    static func user(_ content: String, images: [Data] = []) -> Message
    static func assistant(_ content: String) -> Message
    static func system(_ content: String) -> Message
    static func tool(name: String, content: String) -> Message
}
```

### `BigBroTool`

Tools are defined with a JSON-schema-compatible description and a Swift async handler that runs locally on the iOS device. The SDK's agentic loop calls handlers transparently — callers just consume the final text stream.

```swift
let dateTool = BigBroTool(
    definition: BigBroTool.Definition(
        name: "get_current_date",
        description: "Returns the current date and time.",
        parameters: BigBroTool.Definition.Parameters()
    ),
    handler: { _ in
        DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .medium)
    }
)

// Tools with parameters:
let searchTool = BigBroTool(
    definition: BigBroTool.Definition(
        name: "web_search",
        description: "Search the web.",
        parameters: BigBroTool.Definition.Parameters(
            properties: ["query": .init(type: "string", description: "Search query")],
            required: ["query"]
        )
    ),
    handler: { args in
        let query = args["query"] as? String ?? ""
        // ... perform search ...
        return results
    }
)

// Pass tools to send():
for try await delta in client.send(history, tools: [dateTool, searchTool]) {
    print(delta, terminator: "")
}
```

### `OllamaOptions`

Maps directly to Ollama's `options` request field. All fields are optional.

```swift
let opts = OllamaOptions(temperature: 0.7, topK: 40, seed: 42)
for try await delta in client.send(messages, options: opts) { ... }
```

| Field | Ollama key | Type |
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

### `OllamaFormat`

```swift
// Plain JSON mode
client.send(messages, format: .json)

// Structured JSON schema (serialize the schema dict to Data first)
let schemaData = try JSONSerialization.data(withJSONObject: mySchema)
client.send(messages, format: .jsonSchema(schemaData))
```

### `BigBroDevice`

```swift
public struct BigBroDevice: Identifiable, Hashable {
    public let id: String
    public let name: String   // e.g. "Cedric's MacBook Pro"
    public let host: String
    public let port: Int
}
```

### `BigBroError`

```swift
public enum BigBroError: LocalizedError {
    case notPaired     // send()/generate() called before pairing
    case networkError  // network-level failure or heartbeat timeout
}
```

## Session model

BigBroKit keeps **no persistent state** — no stored device, no stored credentials. Every launch starts disconnected.

The Mac, however, remembers every device it has approved. When the same iOS device re-pairs after a fresh launch, the Mac auto-approves silently (no dialog, no delay), so reconnects feel instant.

The client tears down automatically — returning `connectionState` to `.disconnected` — when any of these happens:

- The Mac user clicks **Disconnect** or **Remove** for that device
- The iOS device misses heartbeat pongs for more than 25 seconds
- The network drops and does not recover

While the network path is degraded (but not yet timed out), `connectionState` is `.reconnecting`. The UI can show a spinner during this window; the client recovers automatically if the path comes back in time.

## Tool calling

When tools are passed to `send()`, the SDK runs a transparent agentic loop:

1. Sends the request to the Mac
2. Mac streams the response; if Ollama returns tool calls, the Mac forwards them to the iOS client
3. iOS executes each tool handler locally and appends the results to the message history
4. Re-sends the updated history to the Mac
5. Repeats until Ollama returns a final text response with no tool calls
6. Yields all text deltas to the caller's `AsyncThrowingStream`

Callers never see tool calls — only the final streamed text.

## Source layout

```
bigbro-kit/
├── Sources/
│   ├── BigBroClient.swift      — main client (ObservableObject)
│   ├── BigBroDevice.swift      — discovered device model
│   ├── BonjourBrowser.swift    — Bonjour/mDNS discovery
│   ├── Message.swift           — chat message model
│   ├── OllamaOptions.swift     — generation options + format enum
│   ├── PeerConnection.swift    — TCP actor (4-byte framed JSON)
│   └── Tool.swift              — BigBroTool definition + handler
└── Package.swift
```
