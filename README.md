# BigBroKit

An iOS Swift framework for connecting to a [BigBro](https://github.com/nagata-inc/bigbro) Mac and offloading LLM inference over the local network.

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

## Usage

```swift
import BigBroKit

let client = BigBroClient()

// 1. Discover BigBro Macs on the local network
let devices = await client.discover()

// 2. Pair with a device (shows an approval dialog on the Mac)
let approved = try await client.pair(with: devices[0])

// 3. Stream a chat response token by token
if approved {
    let messages: [Message] = [.user("Explain Swift concurrency in one paragraph.")]
    for try await delta in client.chatStream(messages) {
        print(delta, terminator: "")
    }
}
```

## API

### `BigBroClient`

```swift
public final class BigBroClient {
    // Discovers BigBro Macs on the local network (5s timeout)
    public func discover() async -> [BigBroDevice]

    // Sends a pairing request and polls for approval (60s timeout)
    // Returns true if approved, false if denied
    public func pair(with device: BigBroDevice) async throws -> Bool

    // Streams a chat response as individual token deltas
    public func chatStream(_ messages: [Message]) -> AsyncThrowingStream<String, Error>

    // Returns the full response as a single string
    public func chat(_ messages: [Message]) async throws -> String
}
```

### `Message`

```swift
public struct Message {
    public static func user(_ content: String) -> Message
    public static func assistant(_ content: String) -> Message
    public static func system(_ content: String) -> Message
}
```

### `BigBroDevice`

```swift
public struct BigBroDevice: Identifiable {
    public let id: String
    public let name: String   // e.g. "Cedric's MacBook Pro"
    public let host: String
    public let port: Int
}
```

## Error handling

```swift
public enum BigBroError: LocalizedError {
    case notPaired       // chat called before pairing
    case timeout         // pairing request timed out after 60s
    case missingToken    // approved but no token returned
    case networkError    // network-level failure
}
```
