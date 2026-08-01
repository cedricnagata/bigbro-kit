import Foundation
import AVFoundation
import Combine

/// Captures microphone audio and cuts it into utterances, so a voice loop can run hands-free.
///
/// `transcribe()` takes a complete recording, which leaves the caller to decide when a turn
/// ended. Push-to-talk answers that with a button. A realtime loop has to answer it from the
/// audio itself: this watches signal energy and closes an utterance once the talking stops.
///
/// Each utterance is emitted as a self-contained 16 kHz mono WAV. 16 kHz because that is what
/// the Mac's transcription model consumes — sending the hardware's native 48 kHz would triple
/// the bytes over a base64 TCP hop and be downsampled on arrival anyway.
///
/// ```swift
/// let mic = BigBroMicrophone()
/// for try await utterance in mic.utterances() {
///     let text = try await client.transcribe(utterance, format: "wav")
/// }
/// ```
@MainActor
public final class BigBroMicrophone: ObservableObject {

    public enum CaptureError: Error, LocalizedError {
        case permissionDenied
        case engineFailed(String)
        case formatUnavailable

        public var errorDescription: String? {
            switch self {
            case .permissionDenied:         return "Microphone access was denied."
            case .engineFailed(let reason): return "Could not start the microphone: \(reason)"
            case .formatUnavailable:        return "Unsupported microphone format."
            }
        }
    }

    /// Endpointing thresholds. Defaults are tuned for a phone held at conversational distance.
    public struct Tuning: Sendable {
        /// Speech must stay above the threshold this long before an utterance opens. Rejects
        /// coughs, door slams and the leading edge of the device's own speaker.
        public var onsetDuration: TimeInterval = 0.12
        /// Silence this long closes the utterance. The dominant control on how responsive the
        /// loop feels: too short clips people who pause mid-sentence, too long feels sluggish.
        public var hangoverDuration: TimeInterval = 0.7
        /// Audio kept from before onset, so the first consonant isn't clipped — by the time
        /// energy crosses the threshold, the word has already started.
        public var prerollDuration: TimeInterval = 0.3
        /// Hard cap on one utterance, so a noisy room can't buffer without bound.
        public var maxUtteranceDuration: TimeInterval = 30
        /// Utterances shorter than this are dropped unsent — too brief to be words, and
        /// transcribing them wastes a round trip to produce an empty string.
        public var minUtteranceDuration: TimeInterval = 0.25
        /// How far above the measured room tone speech has to sit. A multiplier rather than a
        /// fixed level so the same numbers work in a quiet room and a noisy one.
        public var speechThresholdMultiplier: Float = 3.0
        /// Floor under the adaptive threshold, so near-silence can't drive it to zero and make
        /// every faint rustle read as speech.
        public var minimumSpeechLevel: Float = 0.012

        public init() {}
    }

    @Published public private(set) var isCapturing = false
    /// True while the endpointer believes the user is mid-utterance. Drives "listening"
    /// affordances, and is the signal a caller uses for barge-in.
    @Published public private(set) var isSpeaking = false
    /// Smoothed 0...1 input level, for a meter. Updated at UI rate, not audio rate.
    @Published public private(set) var level: Float = 0

    public var tuning: Tuning {
        get { detector.tuning }
        set { detector.tuning = newValue }
    }

    private let engine = AVAudioEngine()
    private let detector: UtteranceDetector
    private let configuresAudioSession: Bool
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var stateTask: Task<Void, Never>?

    /// - Parameter configuresAudioSession: Leave `true` for apps with no audio session of
    ///   their own. `BigBroVoiceSession` sets it `false` and configures the session itself,
    ///   because capture and playback have to agree on one category to run at the same time.
    public init(tuning: Tuning = Tuning(), configuresAudioSession: Bool = true) {
        self.detector = UtteranceDetector(tuning: tuning)
        self.configuresAudioSession = configuresAudioSession
    }

    // MARK: - Capture

    /// Starts capturing and yields one WAV per detected utterance until ``stop()`` is called.
    ///
    /// Only one stream is active at a time; starting a second ends the first.
    public func utterances() -> AsyncThrowingStream<Data, Error> {
        stop()
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            Task { @MainActor in
                do {
                    try await self.startEngine()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        }
    }

    public func stop() {
        stateTask?.cancel()
        stateTask = nil

        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        detector.reset()

        continuation?.finish()
        continuation = nil

        isCapturing = false
        isSpeaking = false
        level = 0
    }

    private func startEngine() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw CaptureError.permissionDenied
        }

        if configuresAudioSession {
            do {
                let session = AVAudioSession.sharedInstance()
                // A chat mode is what turns on the system's echo canceller. Without it the
                // mic hears the assistant's own reply and the endpointer treats it as the
                // user talking, which makes the loop converse with itself. `.videoChat`
                // rather than `.voiceChat` — see VoiceSession: the latter binds playback to
                // call volume and the ring switch, leaving a muted ringer nearly silent.
                try session.setCategory(.playAndRecord, mode: .videoChat,
                                        options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true)
            } catch {
                throw CaptureError.engineFailed(error.localizedDescription)
            }
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw CaptureError.formatUnavailable
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(UtteranceDetector.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.formatUnavailable
        }

        let detector = self.detector
        detector.reset()
        detector.onUtterance = { [weak self] wav in
            // Hops off the audio thread — the continuation is thread-safe, but anything
            // touching actor state is not.
            Task { @MainActor in self?.continuation?.yield(wav) }
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            guard let converted = Self.convert(buffer, using: converter, to: targetFormat) else { return }
            detector.consume(converted)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineFailed(error.localizedDescription)
        }

        isCapturing = true
        startStatePolling()
    }

    /// Mirrors the detector's state onto published properties at UI rate.
    ///
    /// The tap runs hundreds of times a second on a realtime thread; publishing from there
    /// would both violate main-actor isolation and thrash SwiftUI. Sampling instead keeps the
    /// audio path free of any hop back to the main actor.
    private func startStatePolling() {
        stateTask?.cancel()
        stateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = self.detector.snapshot()
                if self.isSpeaking != snapshot.isSpeaking { self.isSpeaking = snapshot.isSpeaking }
                self.level = snapshot.level
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

// MARK: - Endpointing

/// Energy-based voice activity detection and utterance assembly.
///
/// Deliberately not an actor: every method runs on the realtime audio thread, where awaiting
/// anything is forbidden. A lock around plain state is the correct tool here.
private final class UtteranceDetector: @unchecked Sendable {
    static let sampleRate = 16_000

    var tuning: BigBroMicrophone.Tuning {
        get { lock.withLock { _tuning } }
        set { lock.withLock { _tuning = newValue } }
    }

    /// Called on the audio thread with a complete utterance as WAV.
    var onUtterance: (@Sendable (Data) -> Void)?

    private let lock = NSLock()
    private var _tuning: BigBroMicrophone.Tuning

    /// Room tone estimate, adapted only while nobody is talking.
    private var noiseFloor: Float = 0.005
    private var smoothedLevel: Float = 0
    private var inUtterance = false
    private var voicedRun: TimeInterval = 0
    private var silenceRun: TimeInterval = 0
    private var utterance: [Float] = []
    private var preroll: [Float] = []

    init(tuning: BigBroMicrophone.Tuning) {
        self._tuning = tuning
    }

    func reset() {
        lock.withLock {
            noiseFloor = 0.005
            smoothedLevel = 0
            inUtterance = false
            voicedRun = 0
            silenceRun = 0
            utterance.removeAll(keepingCapacity: true)
            preroll.removeAll(keepingCapacity: true)
        }
    }

    func snapshot() -> (isSpeaking: Bool, level: Float) {
        lock.withLock { (inUtterance, min(smoothedLevel * 8, 1)) }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channel, count: frames))
        let rms = Self.rms(samples)
        let duration = Double(frames) / Double(Self.sampleRate)

        let completed: Data? = lock.withLock {
            smoothedLevel += (rms - smoothedLevel) * 0.3

            let threshold = max(noiseFloor * _tuning.speechThresholdMultiplier, _tuning.minimumSpeechLevel)
            let voiced = rms > threshold

            if voiced {
                voicedRun += duration
                silenceRun = 0
            } else {
                silenceRun += duration
                voicedRun = 0
                // Adapt only on genuine silence. Adapting during speech would chase the
                // speaker's own energy upward until they were no longer audible to the
                // detector — the failure mode where the loop stops hearing you mid-sentence.
                if !inUtterance {
                    noiseFloor += (rms - noiseFloor) * 0.05
                }
            }

            if inUtterance {
                utterance.append(contentsOf: samples)

                let elapsed = Double(utterance.count) / Double(Self.sampleRate)
                let ended = silenceRun >= _tuning.hangoverDuration
                let overran = elapsed >= _tuning.maxUtteranceDuration
                if ended || overran {
                    return closeUtteranceLocked()
                }
            } else {
                appendPrerollLocked(samples)
                if voiced && voicedRun >= _tuning.onsetDuration {
                    inUtterance = true
                    // Start from the preroll so the opening consonant survives.
                    utterance = preroll
                    preroll.removeAll(keepingCapacity: true)
                }
            }
            return nil
        }

        if let completed { onUtterance?(completed) }
    }

    private func appendPrerollLocked(_ samples: [Float]) {
        preroll.append(contentsOf: samples)
        let cap = Int(Double(Self.sampleRate) * _tuning.prerollDuration)
        if preroll.count > cap {
            preroll.removeFirst(preroll.count - cap)
        }
    }

    /// Finishes the current utterance and returns it as WAV, or nil if it was too short to
    /// be worth sending. Caller must hold the lock.
    private func closeUtteranceLocked() -> Data? {
        let samples = utterance
        utterance.removeAll(keepingCapacity: true)
        preroll.removeAll(keepingCapacity: true)
        inUtterance = false
        voicedRun = 0
        silenceRun = 0

        let duration = Double(samples.count) / Double(Self.sampleRate)
        guard duration >= _tuning.minUtteranceDuration else { return nil }
        return WAVEncoder.encode(samples: samples, sampleRate: Self.sampleRate)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

// MARK: - WAV

/// Wraps raw samples in a canonical 44-byte PCM WAV header.
///
/// The Mac decodes uploads with `AVAudioFile`, which needs a real container — raw samples
/// would be rejected outright.
enum WAVEncoder {
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let byteCount = samples.count * 2
        var data = Data(capacity: 44 + byteCount)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                      // PCM chunk size
        append(UInt16(1))                       // format: PCM
        append(UInt16(1))                       // channels: mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))          // byte rate: rate * blockAlign
        append(UInt16(2))                       // block align: channels * bytesPerSample
        append(UInt16(16))                      // bits per sample

        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16(clamped * 32_767))
        }
        return data
    }
}
