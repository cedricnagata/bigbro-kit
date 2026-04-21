import SwiftUI

public struct BigBroChatView: View {
    public let client: BigBroClient

    @State private var conversationMessages: [Message] = []
    @State private var displayMessages: [(id: UUID, role: String, text: String)] = []
    @State private var inputText: String = ""
    @State private var isLoading = false

    public init(client: BigBroClient) {
        self.client = client
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(displayMessages, id: \.id) { message in
                            HStack(alignment: .bottom) {
                                if message.role == "user" { Spacer(minLength: 60) }
                                Text(message.text)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(message.role == "user" ? Color.blue : Color(.systemGray5))
                                    .foregroundStyle(message.role == "user" ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                if message.role != "user" { Spacer(minLength: 60) }
                            }
                        }
                        if isLoading {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .padding(10)
                                Spacer()
                            }
                        }
                    }
                    .padding()
                    .id("bottom")
                }
                .onChange(of: displayMessages.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: isLoading) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Message", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit { Task { await send() } }

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
            .padding(12)
        }
    }

    private func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        conversationMessages.append(.user(text))
        displayMessages.append((id: UUID(), role: "user", text: text))
        isLoading = true
        defer { isLoading = false }

        do {
            let reply = try await client.chat(conversationMessages)
            conversationMessages.append(.assistant(reply))
            displayMessages.append((id: UUID(), role: "assistant", text: reply))
        } catch {
            displayMessages.append((id: UUID(), role: "assistant", text: "Error: \(error.localizedDescription)"))
        }
    }
}
