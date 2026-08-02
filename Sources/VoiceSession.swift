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
        /// Wake-word mode only: hearing everything, answering nothing, waiting for its name.
        ///
        /// Distinct from ``listening`` because to the user they are different states — one is
        /// its turn to talk, the other is not — even though the microphone is open in both.
        case armed
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
    /// The level ``level`` has to clear before the loop treats it as speech, same scale.
    ///
    /// Worth drawing on the meter. A microphone that hears nothing and a threshold sitting
    /// above a microphone that hears plenty produce the same silence, and only this tells
    /// them apart.
    @Published public private(set) var threshold: Float = 0
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

    /// Whether replies are spoken aloud.
    ///
    /// `false` keeps the hands-free loop — talk to it, watch the answer stream in — without
    /// synthesizing anything. The turn ends at `.listening` rather than `.speaking`, and
    /// barge-in becomes moot because there is nothing to interrupt.
    public var speaksReplies: Bool

    /// When set, only utterances that open with this phrase are answered.
    ///
    /// `nil` is always-on hands-free: everything heard is a request. Setting it turns the
    /// same loop into an assistant that can sit in a room where other conversations are
    /// happening — the microphone stays open either way, but what counts as being spoken to
    /// narrows to what was addressed by name.
    ///
    /// The phrase is your app's to choose, and a string literal is enough for a fixed one:
    ///
    /// ```swift
    /// session.wakeWord = "hey jarvis"
    /// session.wakeWord = WakeWord(fromSettings)   // anything not a literal
    /// session.wakeWord = nil                      // back to answering everything
    /// ```
    ///
    /// See ``WakeWord`` for aliases, tolerance, and what makes a phrase match reliably.
    ///
    /// Changing this mid-session takes effect on the next utterance, and moves the resting
    /// phase between ``Phase/armed`` and ``Phase/listening`` at the end of the current turn.
    public var wakeWord: WakeWord?

    /// How long after answering the session keeps taking requests without the wake phrase.
    ///
    /// A follow-up is the common case — "and what about tomorrow?" — and needing to say the
    /// name again every time is most of what makes a wake-word assistant tiring to talk to.
    /// 0 re-arms the moment an answer finishes. Ignored when ``wakeWord`` is nil, where the
    /// session is always taking requests.
    public var followUpWindow: TimeInterval

    private let client: BigBroClient
    /// One engine for both directions. See the note where the two are constructed.
    private let engine = AVAudioEngine()
    private let microphone: BigBroMicrophone
    private let player: BigBroAudioPlayer
    private let systemPrompt: String?

    private var loopTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var rearmTask: Task<Void, Never>?
    /// True while a follow-up may be spoken without the wake phrase.
    private var followUpOpen = false
    private var cancellables: Set<AnyCancellable> = []

    public init(
        client: BigBroClient,
        model: String,
        tools: [BigBroTool] = [],
        voice: String? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        systemPrompt: String? = nil,
        allowsBargeIn: Bool = true,
        speaksReplies: Bool = true,
        wakeWord: WakeWord? = nil,
        followUpWindow: TimeInterval = 8,
        tuning: BigBroMicrophone.Tuning = BigBroMicrophone.Tuning()
    ) {
        self.client = client
        self.tools = tools
        self.voice = voice
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.systemPrompt = systemPrompt
        self.allowsBargeIn = allowsBargeIn
        self.speaksReplies = speaksReplies
        self.wakeWord = wakeWord
        self.followUpWindow = followUpWindow
        // Both are told not to touch the audio session: capture needs `.playAndRecord` and
        // playback would set `.playback`, and whichever ran last would win — silencing the
        // microphone or routing the answer to the earpiece. This type owns the session for both.
        //
        // They also share one engine, which is what makes voice processing work at all. The
        // processing lives in a single I/O unit and sees only the streams inside its own
        // engine: with capture in one and playback in another it has no reference signal to
        // cancel the echo against, and reports of that arrangement are that it silences
        // playback almost completely.
        self.microphone = BigBroMicrophone(
            tuning: tuning, configuresAudioSession: false, engine: engine
        )
        self.player = BigBroAudioPlayer(configuresAudioSession: false, engine: engine)

        if let systemPrompt, !systemPrompt.isEmpty {
            history = [.system(systemPrompt)]
        }

        microphone.$level
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.level = $0 }
            .store(in: &cancellables)

        microphone.$threshold
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.threshold = $0 }
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

        // Before the audio session is touched. Configuring a `.playAndRecord` session and
        // enabling voice processing both reach for an input this app may not yet be allowed
        // to open, and the failure that produces is a silent microphone rather than an error.
        // Asking here also means a refusal is reported straight away, instead of after the
        // wait for speech models below.
        guard await AVAudioApplication.requestRecordPermission() else {
            self.error = BigBroMicrophone.CaptureError.permissionDenied.localizedDescription
            return
        }

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
        closeFollowUp()
        microphone.stop()
        player.stop()
        phase = .idle
        level = 0
        didBargeIn = false
    }

    /// Stops the current spoken reply without ending the turn or the session.
    ///
    /// For a caller that turns speech off mid-answer: the answer keeps streaming to the
    /// screen, and the loop returns to listening as it would have anyway.
    public func stopSpeaking() {
        player.stop()
        if phase == .speaking { phase = .listening }
    }

    /// Where the loop sits between turns: waiting for its name, or for anything at all.
    private var restingPhase: Phase { wakeWord == nil ? .listening : .armed }

    /// Endpointing thresholds, adjustable while the loop runs.
    ///
    /// The defaults suit a phone held at conversational distance. A room, a headset, or a
    /// quiet talker can all want something else, and having to stop and rebuild the session
    /// to try a number makes tuning by ear impractical.
    public var tuning: BigBroMicrophone.Tuning {
        get { microphone.tuning }
        set { microphone.tuning = newValue }
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
        guard phase == .idle || phase == .listening || phase == .armed else { return }
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
        // reporting the resting phase from inside the loop left the session showing
        // "Getting ready…" for as long as the room stayed quiet — which reads as a
        // session that never started rather than one waiting to be spoken to.
        phase = restingPhase
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
                // The resting phase is left to the turn: only it knows whether the utterance
                // was answered, ignored, or opened a follow-up window.
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

    /// Transcribes one utterance, decides whether it was meant for us, and answers it if so.
    ///
    /// Transcription is a separate step rather than `converse(audio:)` doing it inline,
    /// because a wake word can only be checked against text: the gate has to run between
    /// hearing and generating, and folding both into one call leaves nowhere to put it.
    private func performTurn(_ audio: Data) async {
        // Read before the first await. The window can expire during transcription, and an
        // utterance that began inside it was addressed to us whatever the timer does next.
        let followingUp = followUpOpen
        closeFollowUp()

        error = nil
        didBargeIn = false
        phase = .transcribing

        let heard: String
        do {
            heard = try await client.transcribe(audio, format: "wav")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            self.error = error.localizedDescription
            settle(followingUp: followingUp)
            return
        }
        guard !Task.isCancelled else { return }

        // A cough, a door, a passing car. Transcribing to nothing is the common case in a
        // room, not an error.
        guard !heard.isEmpty else {
            settle(followingUp: followingUp)
            return
        }

        switch address(heard, followingUp: followingUp) {
        case .notForUs:
            // Deliberately silent. Armed in an occupied room, most of what the session hears
            // is somebody else's conversation, and reporting each one would be the noise.
            phase = .armed

        case .summoned:
            // Called by name with nothing after it. Answering the name itself would be a
            // non-sequitur; take the next thing said as the request instead.
            //
            // `transcript` deliberately not set. It means "what the user asked", and callers
            // mirror it into a conversation as the user's turn — publishing the wake phrase
            // there posts "hey big bro" as a message and leaves an answer bubble waiting for
            // a reply that was never requested. Waking is reported by the phase, which is
            // where a caller looks for it.
            openFollowUp()

        case .request(let request):
            transcript = request
            reply = ""
            await answer(request)
            openFollowUp()
        }
    }

    /// Generates and speaks an answer to one request.
    private func answer(_ request: String) async {
        phase = .thinking

        // Audio is fed to the player as it arrives rather than collected first, so playback
        // starts on the first synthesized sentence instead of after the last one.
        let (audioStream, audioIn) = AsyncThrowingStream<Data, Error>.makeStream()
        let playback = Task {
            do { try await self.player.play(audioStream) } catch { /* stopped or interrupted */ }
        }

        var spoken = ""
        do {
            for try await event in client.converse(
                history + [.user(request)],
                model: model,
                voice: voice,
                tools: tools,
                reasoningEffort: reasoningEffort,
                speaks: speaksReplies
            ) {
                if Task.isCancelled { break }
                switch event {
                case .transcript:
                    break   // only the audio-in overload produces one
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
        history.append(.user(request))
        if !spoken.isEmpty { history.append(.assistant(spoken)) }
    }

    // MARK: - Addressing

    private enum Address {
        /// Answer this.
        case request(String)
        /// Named, but nothing asked yet.
        case summoned
        /// Somebody else's conversation.
        case notForUs
    }

    private func address(_ heard: String, followingUp: Bool) -> Address {
        guard let wakeWord, !wakeWord.isEmpty else { return .request(heard) }
        if let match = wakeWord.match(heard) {
            return match.request.isEmpty ? .summoned : .request(match.request)
        }
        // No name in it. Inside the follow-up window that is fine — the conversation is
        // already open and saying the name again would be strange. Outside it, not ours.
        return followingUp ? .request(heard) : .notForUs
    }

    // MARK: - Follow-up window

    /// Takes requests without the wake phrase for a while, then re-arms.
    private func openFollowUp() {
        rearmTask?.cancel()
        rearmTask = nil

        guard wakeWord != nil else {
            // No gate at all: the session is always taking requests.
            followUpOpen = false
            phase = .listening
            return
        }
        guard followUpWindow > 0 else {
            followUpOpen = false
            phase = .armed
            return
        }

        followUpOpen = true
        phase = .listening
        let window = followUpWindow
        rearmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled, let self else { return }
            self.followUpOpen = false
            // Only if nothing has moved on since. A turn that started inside the window owns
            // the phase, and stamping `.armed` over `.thinking` would misreport it.
            if self.phase == .listening { self.phase = .armed }
        }
    }

    private func closeFollowUp() {
        rearmTask?.cancel()
        rearmTask = nil
        followUpOpen = false
    }

    /// Returns to rest after an utterance that produced no turn, keeping an open window open.
    private func settle(followingUp: Bool) {
        if followingUp { openFollowUp() } else { phase = restingPhase }
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
        // `.videoChat`, not `.voiceChat`. Both ask for the same voice processing, but
        // `.voiceChat` tells iOS this is a phone call: playback is then governed by the call
        // volume and follows the ring/silent switch, so a muted ringer makes the assistant
        // almost inaudible.
        try session.setCategory(.playAndRecord, mode: .videoChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        enableVoiceProcessing()
        BigBroAudioRoute.preferLoudestBuiltIn()

        // The route can change under a running session — AirPods connect, a headset is
        // unplugged — and the choice above has to be made again each time it does.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { BigBroAudioRoute.preferLoudestBuiltIn() }
        }
    }

    /// Turns on the processing a chat mode only *asks* for.
    ///
    /// Setting `.videoChat` is half of the bargain, and the half that costs rather than pays.
    /// Apple's terms are explicit: for apps that use a chat mode but do not use Audio Unit
    /// Voice I/O or `AVAudioEngine.setVoiceProcessingEnabled(_:)`, the system "doesn't apply
    /// voice-specific processing, like echo cancellation and automatic gain correction, and
    /// disables dynamic processing on input and output, which results in a lower playback
    /// level."
    ///
    /// So the mode alone bought none of the echo cancellation this loop is built on, no gain
    /// correction on a microphone that was reported as barely hearing anything, and a
    /// deliberately quieter output. All three complaints, one missing call.
    ///
    /// Enabling it on the input node enables it on the output node too — they are one I/O
    /// unit — which is also why the microphone and the player have to share this engine.
    private func enableVoiceProcessing() {
        do {
            // Before anything is connected or started. Reconfiguring the unit makes the
            // engine stop itself and post a configuration change; doing it here means there
            // is nothing running to interrupt, and the microphone starts it afterwards. The
            // observer matters for the changes that come later, mid-session.
            try engine.inputNode.setVoiceProcessingEnabled(true)
        } catch {
            // Not fatal. Without it the loop still runs, quieter and liable to interrupt
            // itself on its own voice — which is how it behaved before this call existed.
            print("[BigBroVoiceSession] voice processing unavailable: \(error.localizedDescription)")
        }
    }
}
