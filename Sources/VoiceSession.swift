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
        /// Microphone open and whatever is said next taken as a request.
        ///
        /// The resting state without a wake word. With one it is reached only by being called
        /// by name and asked nothing — the session has been summoned and is waiting on the
        /// request that was promised — and it lapses back to ``armed`` shortly after.
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
    /// Whether the user can cut an answer short by talking over it.
    ///
    /// What counts as "talking over it" depends on ``wakeWord``. Without one, any speech
    /// interrupts, on the leading edge — the answer stops the moment the microphone hears a
    /// voice. With one, only the phrase does: the answer keeps playing while whatever was
    /// heard is transcribed, and is left alone unless the session was named. The wake word
    /// would be pointless otherwise, since the whole reason to set one is that the room
    /// contains speech not addressed here.
    ///
    /// The cost of that in wake-word mode is latency — an interruption cannot land until the
    /// speaker stops and the utterance transcribes, where the always-on case cuts off
    /// instantly. Worth turning off entirely only if echo cancellation is failing and the
    /// loop is interrupting itself.
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
    /// Setting one makes the phrase the *only* way in. Every request has to open with it,
    /// including the one after an answer — the session re-arms as soon as it stops speaking
    /// rather than staying open for a follow-up, and it interrupts itself for nothing else.
    /// The single exception is being called by name with no request attached, which opens the
    /// microphone briefly for the request that was promised; see ``Phase/listening``.
    ///
    /// Changing this mid-session takes effect on the next utterance, and moves the resting
    /// phase between ``Phase/armed`` and ``Phase/listening`` at the end of the current turn.
    public var wakeWord: WakeWord?

    /// How long a session called by name with nothing after it waits for the request.
    ///
    /// Deliberately not configurable, and short. This is the only state in wake-word mode
    /// where speech is taken without the phrase, so how long it lasts is exactly how long
    /// the wake word is not doing its job; a false wake nobody follows up costs this much
    /// open microphone and no more.
    private static let summonWindow: TimeInterval = 8

    private let client: BigBroClient
    /// One engine for both directions. See the note where the two are constructed.
    private let engine = AVAudioEngine()
    private let microphone: BigBroMicrophone
    private let player: BigBroAudioPlayer
    private let systemPrompt: String?

    private var loopTask: Task<Void, Never>?
    /// The answer in flight, if any.
    ///
    /// Deliberately not awaited by the loop: an answer plays for seconds, and the utterance
    /// that interrupts it has to be heard and transcribed while it does.
    private var answerTask: Task<Void, Never>?
    private var rearmTask: Task<Void, Never>?
    private var routeObserver: NSObjectProtocol?
    /// When an outstanding summons stops being honoured, or nil if there isn't one.
    private var summonedUntil: ContinuousClock.Instant?
    /// True once speech has begun inside the window, holding it open until that speech is
    /// dealt with. See ``summoned``.
    private var summonHeld = false
    private var cancellables: Set<AnyCancellable> = []

    /// Whether the next utterance may be taken as a request without the wake phrase.
    ///
    /// Deliberately measured against when speech *started*, not when its transcript came back.
    /// A request lands several seconds after the summons that invited it — the endpointer
    /// waits out `hangoverDuration` before closing the utterance and the Mac then has to
    /// transcribe it — so a deadline checked on arrival expires under exactly the request it
    /// was opened for, and does it more the longer the sentence.
    private var summoned: Bool {
        if summonHeld { return true }
        guard let summonedUntil else { return false }
        return .now < summonedUntil
    }

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

        // The leading edge of speech. An utterance is only emitted once the user stops
        // talking, which is too late for either thing that needs to know somebody has
        // started: barge-in, which has to land while there is still an answer to cut off,
        // and an open summons, which is about when the user began speaking rather than when
        // their sentence finally reached the Mac.
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
        answerTask?.cancel()
        answerTask = nil
        clearSummon()
        microphone.stop()
        player.stop()
        releaseAudio()
        phase = .idle
        level = 0
        threshold = 0
        didBargeIn = false
    }

    /// Stops the current spoken reply without ending the turn or the session.
    ///
    /// For a caller that turns speech off mid-answer: the answer keeps streaming to the
    /// screen, and the loop returns to listening as it would have anyway.
    public func stopSpeaking() {
        player.stop()
        // Still generating, just no longer aloud. Resting here would advertise a turn that
        // has not finished; `.armed` in particular would invite a request the loop is about
        // to talk over.
        if phase == .speaking { phase = answerTask != nil ? .thinking : restingPhase }
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
                await consider(utterance)
                if Task.isCancelled { return }
            }
        } catch {
            self.error = error.localizedDescription
        }
        if !Task.isCancelled { phase = .idle }
    }

    /// Decides what one utterance is: a request, an interruption, or somebody else talking.
    private func consider(_ audio: Data) async {
        guard answerTask != nil else {
            await takeTurn(audio)
            return
        }

        // Arrived while an answer was playing.
        guard allowsBargeIn else { return }

        if let wakeWord, !wakeWord.isEmpty {
            // Only its own name stops it. Read this without touching the answer — the phase
            // stays `.speaking`, the audio keeps playing — and let it run on unless the
            // session was actually addressed.
            guard let address = await interruption(audio, wakeWord: wakeWord) else { return }
            await cancelAnswer(bargedIn: true)
            act(on: address)
            return
        }

        // No wake word: any speech interrupts, and `userStartedSpeaking` cut this one off on
        // the leading edge already. All that is left is to let it unwind before replacing it.
        await cancelAnswer(bargedIn: true)
        await takeTurn(audio)
    }

    /// Transcribes one utterance and acts on it. The session is not answering anything.
    ///
    /// Transcription is a separate step rather than `converse(audio:)` doing it inline,
    /// because a wake word can only be checked against text: the gate has to run between
    /// hearing and generating, and folding both into one call leaves nowhere to put it.
    private func takeTurn(_ audio: Data) async {
        error = nil
        didBargeIn = false
        phase = .transcribing

        let heard: String
        do {
            heard = try await client.transcribe(audio, format: "wav")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            self.error = error.localizedDescription
            rest()
            return
        }
        guard !Task.isCancelled else { return }

        // A cough, a door, a passing car. Transcribing to nothing is the common case in a
        // room, not an error — and it does not spend a summons, since the request it was
        // waiting for has still not been spoken.
        guard !heard.isEmpty else {
            rest()
            return
        }

        act(on: address(heard))
    }

    /// Transcribes an utterance heard over an answer, returning how it addressed the session,
    /// or nil if it didn't.
    ///
    /// Failures are silent here. The answer is still playing and still correct; reporting a
    /// transcription error over the top of it would put the session's own reply and an error
    /// on screen at once, for a request nobody established had been made.
    private func interruption(_ audio: Data, wakeWord: WakeWord) async -> Address? {
        guard let heard = try? await client.transcribe(audio, format: "wav")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !heard.isEmpty,
              !Task.isCancelled,
              let match = wakeWord.match(heard)
        else { return nil }
        return match.request.isEmpty ? .summoned : .request(match.request)
    }

    private func act(on address: Address) {
        switch address {
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
            summon()

        case .request(let request):
            clearSummon()
            transcript = request
            reply = ""
            startAnswer(request)
        }
    }

    /// Starts answering, without waiting for it.
    ///
    /// The loop has to stay on the utterance stream while this runs. An answer occupies the
    /// session for seconds, and every way out of it — barge-in without a wake word, the phrase
    /// with one — arrives as an utterance that has to be heard before it can be obeyed.
    private func startAnswer(_ request: String) {
        answerTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.answer(request)
            guard !Task.isCancelled else { return }
            self.answerTask = nil
            self.rest()
        }
        answerTask = task
    }

    /// Stops the answer in flight and waits for it to unwind, so the next turn starts clean.
    private func cancelAnswer(bargedIn: Bool) async {
        guard let task = answerTask else { return }
        if bargedIn { didBargeIn = true }
        player.stop()
        task.cancel()
        await task.value
        answerTask = nil
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

    private func address(_ heard: String) -> Address {
        guard let wakeWord, !wakeWord.isEmpty else { return .request(heard) }
        if let match = wakeWord.match(heard) {
            return match.request.isEmpty ? .summoned : .request(match.request)
        }
        // No name in it. That is fine only if the session was just called by name and asked
        // nothing — this is the request that was promised, and repeating the phrase to
        // deliver it would be absurd. Any other time, somebody else is talking.
        return summoned ? .request(heard) : .notForUs
    }

    // MARK: - Summons

    /// Takes the next utterance as a request without the phrase, briefly.
    private func summon() {
        summonHeld = false
        summonedUntil = .now.advanced(by: .seconds(Self.summonWindow))
        phase = .listening

        // Drives the phase only — ``summoned`` is answered by the deadline itself, so this
        // firing late, or being cancelled, cannot leave the microphone open a moment longer
        // than the window says.
        rearmTask?.cancel()
        rearmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.summonWindow))
            guard !Task.isCancelled, let self, !self.summonHeld else { return }
            // Only if nothing has moved on since. A turn that started inside the window owns
            // the phase, and stamping `.armed` over `.thinking` would misreport it.
            if self.phase == .listening { self.phase = .armed }
        }
    }

    /// Holds an open summons until the speech now under way has been dealt with.
    ///
    /// The window governs when the user has to *start* answering, which is the only part of
    /// it they can judge. How long they then talk for, and how long the Mac takes to
    /// transcribe it, are not theirs to control and must not decide whether they were heard.
    private func holdSummon() {
        guard summonedUntil != nil, summoned else { return }
        summonHeld = true
    }

    private func clearSummon() {
        rearmTask?.cancel()
        rearmTask = nil
        summonedUntil = nil
        summonHeld = false
    }

    /// Returns to rest between turns.
    ///
    /// With a wake word that is `.armed` — including straight after an answer, which is the
    /// whole point of the phrase: the session stops speaking and immediately stops listening
    /// for anything but its name. The one exception is an outstanding summons, which survives
    /// an utterance that turned out to be nothing, because the request it is waiting for has
    /// still not been spoken.
    private func rest() {
        // The hold, though, is spent: it belonged to the utterance just dealt with. Dropping
        // it puts the original deadline back in charge, so a cough two seconds into the
        // window cannot extend it, and a cough after the window has passed ends it.
        summonHeld = false
        phase = summoned ? .listening : restingPhase
    }

    // MARK: - Barge-in

    /// Somebody has started talking. Stops the clock on a summons, and cuts off an answer if
    /// this session is the kind that lets it.
    ///
    /// Interruption from here is for sessions with no wake word only. This fires on energy
    /// alone, and energy cannot tell the phrase from the conversation happening next to the
    /// phone — acting on it would mean any voice in the room could cut the answer off, which
    /// is the arrangement a wake word is chosen to avoid. Those sessions interrupt from
    /// ``consider(_:)`` instead, once there is a transcript to check.
    private func userStartedSpeaking() {
        holdSummon()
        guard allowsBargeIn, wakeWord == nil || wakeWord?.isEmpty == true else { return }
        guard phase == .speaking || phase == .thinking else { return }
        print("[BigBroVoiceSession] barge-in")
        didBargeIn = true
        player.stop()
        answerTask?.cancel()
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
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { BigBroAudioRoute.preferLoudestBuiltIn() }
        }
    }

    /// Gives back the engine and the audio session.
    ///
    /// The microphone and the player were both handed this engine rather than making their
    /// own, and neither will stop something it does not own — so stopping it falls here.
    /// Left running it holds a `.playAndRecord` route and an open microphone for the rest of
    /// the app's life, and the next thing that wants the speaker gets an engine that starts
    /// but never renders: buffers scheduled, no I/O cycles, and a caller waiting forever on
    /// audio that cannot play.
    private func releaseAudio() {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        if engine.isRunning { engine.stop() }
        // Deactivated so whatever plays next picks its own category, rather than inheriting
        // a chat session tuned for a conversation that has ended.
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
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
