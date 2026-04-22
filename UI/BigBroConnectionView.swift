import SwiftUI

/// A ready-to-use SwiftUI view that shows the current BigBro connection status.
/// Drop it anywhere in your UI and pass your `BigBroClient` instance.
///
/// ```swift
/// @StateObject var client = BigBroClient()
///
/// BigBroConnectionView(client: client) {
///     // Called when user taps "Connect" while disconnected
///     await viewModel.startPairing()
/// }
/// ```
public struct BigBroConnectionView: View {
    @ObservedObject public var client: BigBroClient

    /// Optional action invoked when the user taps "Connect" while disconnected.
    /// Wire this up to your own discovery/pairing flow.
    public var onConnect: (() async -> Void)?

    public init(client: BigBroClient, onConnect: (() async -> Void)? = nil) {
        self.client = client
        self.onConnect = onConnect
    }

    public var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 10)

            if client.isConnected, let device = client.connectedDevice {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Disconnect") {
                    client.disconnect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.red)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not connected")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("No BigBro device paired")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let onConnect {
                    Button("Connect") {
                        Task { await onConnect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
