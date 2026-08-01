import Foundation
import AVFoundation
import Combine

/// A hands-free spoken conversation: listen, transcribe, answer, speak, repeat.
///
/// The individual legs already exist — `BigBroMicrophone` endpoints utterances,
/// `BigBroClient.converse(audio:)` turns one into a spoken answer, `BigBroAudioPlayer` plays
/// it. What this adds is the part that only makes sense once they run continuously: keeping
/// conversation history across turns, holding one audio session that both capture and playback
/// can live in, and handling the user talking over the answer.
///
/// ```swift
/// let session = BigBroVoiceSession(client: client, tools: myTools)
/// await session.start()
/// // session.phase, .transcript, .reply drive the UI
/// ```
///
/// Everything is published, so a SwiftUI view can observe it directly.
@MainActor
public final class BigBroVoiceSession: ObservableObject {

    public enum Phase: Equatable {
        case idle
        /// Waiting on the Mac's speech models before the first listen.
        case preparing
        /// Microphone open, waiting for the user to say something.
        case listening
        /// An utterance has been captured and is being transcribed on the Mac.
        case transcribing
        /// The model is generating — including any tool calls.
        case thinking
        /// Speaking the answer. The microphone stays open for barge-in.
        case speaking
    }

    @Published public private(set) var phase: Phase = .idle
    /// The most recent thing the user was heard to say.
    @Published public private(set) var transcript = ""
    /// The current answer, accumulating as it generates.
    @Published public private(set) var reply = ""
    /// Full conversation, including the system prompt if one was given. Survives across turns
    /// and is what gets sent as context; clear it with ``resetConversation()``.
    @Published public private(set) var history: [Message] = []
    /// Set when a turn fails. Cleared at the start of the next one.
    @Published public private(set) var error: String?
    /// Smoothed 0...1 input level, mirrored from the microphone for meters.
    @Published public private(set) var level: Float = 0
    /// True once the user has interrupted and before the next turn starts.
    @Published public private(set) var didBargeIn = false

    /// Tools the model may call. The loop runs inside `converse`, so a tool call costs no
    /// extra round trip to this device.
    public var tools: [BigBroTool]
    /// Kokoro voice for the answer. `nil` uses `BigBroClient.defaultVoice`.
    public var voice: String?
    /// Model to answer with. Required — the Mac keeps no default. A model that can't call
    /// tools still answers; the Mac drops them and says so.
    public var model: String
    public var reasoningEffort: ReasoningEffort?
    /// When false, anything the user says while the answer plays is discarded instead of
    /// cutting it off. Worth turning off only if echo cancellation is failing and the loop is
    /// interrupting itself.
    public var allowsBargeIn: Bool

    private let client: BigBroClient
    private let microphone: BigBroMicrophone
    private let player: BigBroAudioPlayer
    private let systemPrompt: String?

    private var loopTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    public init(
        client: BigBroClient,
        model: String,
        tools: [BigBroTool] = [],
        voice: String? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        systemPrompt: String? = nil,
        allowsBargeIn: Bool = true,
        tuning: BigBroMicrophone.Tuning = BigBroMicrophone.Tuning()
    ) {
        self.client = client
        self.tools = tools
        self.voice = voice
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.systemPrompt = systemPrompt
        self.allowsBargeIn = allowsBargeIn
        // Both are told not to touch the audio session: capture needs `.playAndRecord` and
        // playback would set `.playback`, and whichever ran last would win — silencing the
        // microphone or routing the answer to the earpiece. This type owns the session for both.
        self.microphone = BigBroMicrophone(tuning: tuning, configuresAudioSession: false)
        self.player = BigBroAudioPlayer(configuresAudioSession: false)

        if let systemPrompt, !systemPrompt.isEmpty {
            history = [.system(systemPrompt)]
        }

        microphone.$level
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.level = $0 }
            .store(in: &cancellables)

        // Barge-in has to come from the level detector, not from the utterance stream: an
        // utterance is only emitted once the user stops talking, which is far too late to
        // interrupt with. This fires on the leading edge instead.
        microphone.$isSpeaking
            .receive(on: DispatchQueue.main)
            .filter { $0 }
            .sink { [weak self] _ in self?.userStartedSpeaking() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Opens the microphone and starts the loop. Returns as soon as it is running.
    ///
    /// Waits for the Mac's speech models first — they are usually already warm, but starting
    /// a hands-free loop only to have the first sentence swallowed by a cold model load is
    /// the worst version of that wait.
    public func start() async {
        guard phase == .idle else { return }
        error = nil
        didBargeIn = false

        do {
            try configureAudioSession()
        } catch {
            self.error = error.localizedDescription
            return
        }

        phase = .preparing
        do {
            try await client.runSpeech()
        } catch {
            // Not fatal on its own — the first turn will simply be slower, or will fail with
            // a clearer error of its own.
            print("[BigBroVoiceSession] speech preload skipped: \(error.localizedDescription)")
        }

        guard phase != .idle else { return }   // stopped while we were waiting
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    /// Ends the session. Safe to call at any time, including mid-turn.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        turnTask?.cancel()
        turnTask = nil
        microphone.stop()
        player.stop()
        phase = .idle
        level = 0
        didBargeIn = false
    }

    /// Forgets the conversation, keeping the system prompt. The session can keep running.
    public func resetConversation() {
        history = systemPrompt.map { [.system($0)] } ?? []
        transcript = ""
        reply = ""
    }

    /// Adopts an existing conversation, so a session can pick up where typing left off.
    ///
    /// The system prompt is re-applied at the front unless `messages` already opens with one.
    /// Ignored mid-turn, where swapping context under a request in flight would mean the
    /// answer and the history no longer describe the same conversation.
    public func setHistory(_ messages: [Message]) {
        guard phase == .idle || phase == .listening else { return }
        if let systemPrompt, !systemPrompt.isEmpty, messages.first?.role != .system {
            history = [.system(systemPrompt)] + messages
        } else {
            history = messages
        }
    }

    /// Releases the audio route. Call before deactivating your own audio session.
    public func shutdown() {
        stop()
        player.shutdown()
    }

    // MARK: - Loop

    private func runLoop() async {
        // Announced before the first utterance, not after the first completed turn.
        // `utterances()` only yields once the user has actually said something, so
        // reporting `.listening` from inside the loop left the session showing
        // "Getting ready…" for as long as the room stayed quiet — which reads as a
        // session that never started rather than one waiting to be spoken to.
        phase = .listening
        do {
            for try await utterance in microphone.utterances() {
                if Task.isCancelled { return }
                if phase == .speaking || phase == .thinking {
                    // Arrived mid-answer. With barge-in on, `userStartedSpeaking` has already
                    // cut the previous turn short and this is the replacement; with it off,
                    // the user talked over the answer and asked for nothing.
                    guard allowsBargeIn else { continue }
                }
                await runTurn(utterance)
                if Task.isCancelled { return }
                phase = .listening
            }
        } catch {
            self.error = error.localizedDescription
        }
        if !Task.isCancelled { phase = .idle }
    }

    private func runTurn(_ audio: Data) async {
        let turn = Task { [weak self] in
            guard let self else { return }
            await self.performTurn(audio)
        }
        turnTask = turn
        await turn.value
        turnTask = nil
    }

    private func performTurn(_ audio: Data) async {
        error = nil
        didBargeIn = false
        reply = ""
        phase = .transcribing

        // Audio is fed to the player as it arrives rather than collected first, so playback
        // starts on the first synthesized sentence instead of after the last one.
        let (audioStream, audioIn) = AsyncThrowingStream<Data, Error>.makeStream()
        let playback = Task {
            do { try await self.player.play(audioStream) } catch { /* stopped or interrupted */ }
        }

        var heard = ""
        var spoken = ""
        do {
            for try await event in client.converse(
                audio: audio,
                model: model,
                history: history,
                voice: voice,
                tools: tools,
                reasoningEffort: reasoningEffort
            ) {
                if Task.isCancelled { break }
                switch event {
                case .transcript(let text):
                    heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    transcript = heard
                    if !heard.isEmpty { phase = .thinking }
                case .text(let delta):
                    spoken += delta
                    reply = spoken
                case .audio(let chunk):
                    if phase != .speaking { phase = .speaking }
                    audioIn.yield(chunk)
                case .speechFailed(let message):
                    // The turn still happened and the answer still stands; only the
                    // voice failed. Surfaced without ending the session.
                    self.error = message
                }
            }
        } catch {
            self.error = error.localizedDescription
        }

        audioIn.finish()
        await playback.value

        // Commit even a turn that was cut off. The user did say something and the assistant
        // did say part of an answer; dropping either would leave the model unable to make
        // sense of "sorry, go on" or "what did you just say".
        if !heard.isEmpty {
            history.append(.user(heard))
            if !spoken.isEmpty { history.append(.assistant(spoken)) }
        }
    }

    // MARK: - Barge-in

    private func userStartedSpeaking() {
        guard allowsBargeIn, phase == .speaking || phase == .thinking else { return }
        print("[BigBroVoiceSession] barge-in")
        didBargeIn = true
        player.stop()
        turnTask?.cancel()
    }

    // MARK: - Audio session

    /// One session for both directions, configured once here.
    ///
    /// A chat mode is the load-bearing part: it enables the system echo canceller, without
    /// which the microphone hears the assistant's own answer, the endpointer reads it as the
    /// user talking, and the loop interrupts itself in a cycle that never settles.
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // `.videoChat`, not `.voiceChat`. Both give the echo cancellation barge-in needs,
        // but `.voiceChat` tells iOS this is a phone call: playback is then governed by the
        // call volume and follows the ring/silent switch, so a muted ringer makes the
        // assistant almost inaudible. `.videoChat` keeps the cancellation and plays through
        // the main speaker at media levels.
        try session.setCategory(.playAndRecord, mode: .videoChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
    }
}
