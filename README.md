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

`BigBroClient` is an `ObservableObject`, so you can observe its state directly from SwiftUI:

```swift
import SwiftUI
import BigBroKit

struct ContentView: View {
    @StateObject private var client = BigBroClient()

    var body: some View {
        VStack {
            if client.isConnected {
                Text("Connected to \(client.connectedDevice?.name ?? "")")
            } else {
                Button("Find BigBro") {
                    Task {
                        let devices = await client.discover()
                        if let mac = devices.first {
                            _ = try? await client.pair(with: mac)
                        }
                    }
                }
            }
        }
    }
}
```

Sending messages:

```swift
let messages: [Message] = [.user("Explain Swift concurrency in one paragraph.")]

// Streaming (default) — deltas arrive one token at a time
for try await delta in client.send(messages) {
    print(delta, terminator: "")
}

// Non-streaming — full response arrives as a single chunk
for try await reply in client.send(messages, streaming: false) {
    print(reply)
}
```

## Session model

BigBroKit keeps **no persistent state** — no stored device, no stored token, no known-devices history. Every launch starts disconnected; the user has to Find BigBro again.

The Mac, however, remembers every device it has approved. When an iOS device re-pairs after a fresh launch, the Mac auto-approves silently (no dialog, no user tap), so the re-connect flow feels instant.

A presence stream (`/presence` SSE) keeps `isConnected` in sync. The stream ends — and the client fully tears down (device + token forgotten) — when any of these happens:

- The Mac user clicks **Disconnect** or **Remove** on that device
- The iOS device doesn't receive a heartbeat for 15 seconds
- The network drops

## API

### `BigBroClient`

```swift
public final class BigBroClient: ObservableObject {
    @Published public private(set) var connectedDevice: BigBroDevice?
    @Published public private(set) var isConnected: Bool

    // Discover BigBro Macs on the local network (5s Bonjour timeout)
    public func discover() async -> [BigBroDevice]

    // Send a pair request and poll for approval (60s timeout).
    // Returns true if approved, false if denied.
    // On approval, opens the presence stream and sets isConnected=true.
    public func pair(with device: BigBroDevice) async throws -> Bool

    // Send messages. `streaming: true` yields token deltas as they arrive;
    // `streaming: false` yields the full response as a single element.
    public func send(_ messages: [Message],
                     streaming: Bool = true) -> AsyncThrowingStream<String, Error>

    // Close the presence stream and forget device + token.
    public func disconnect()
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
public struct BigBroDevice: Identifiable, Hashable {
    public let id: String
    public let name: String   // e.g. "Cedric's MacBook Pro"
    public let host: String
    public let port: Int
}
```

### Errors

```swift
public enum BigBroError: LocalizedError {
    case notPaired       // send() called before pairing
    case timeout         // pair() timed out waiting for approval
    case missingToken    // approved but no token returned
    case networkError    // network-level failure
}
```
