import Foundation
import AVFoundation

/// Plays the audio stream produced by `BigBroClient.speak(_:)`.
///
/// The default wire format is headerless 24 kHz 16-bit signed little-endian mono PCM. Carrying
/// no container, it cannot be handed to `AVAudioPlayer`; this converts each chunk to Float32 and
/// schedules it on an `AVAudioPlayerNode` as it arrives, so playback starts on the first chunk
/// rather than after the whole utterance is synthesized.
///
/// ```swift
/// let player = BigBroAudioPlayer()
/// try await player.play(client.speak("Hello"))
/// ```
@MainActor
public final class BigBroAudioPlayer {

    public enum PlaybackError: Error, LocalizedError {
        case engineFailed(String)
        case formatUnavailable

        public var errorDescription: String? {
            switch self {
            case .engineFailed(let reason): return "Could not start audio playback: \(reason)"
            case .formatUnavailable:        return "Unsupported audio format."
            }
        }
    }

    private let engine: AVAudioEngine
    /// False when the engine was handed in, in which case stopping is somebody else's call.
    private let ownsEngine: Bool
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let configuresAudioSession: Bool

    private var isAttached = false

    /// A chunk boundary can land mid-sample; the odd trailing byte waits here for the next chunk.
    private var pendingByte: UInt8?

    private var scheduledBuffers = 0
    private var completedBuffers = 0
    private var drainContinuation: CheckedContinuation<Void, Never>?

    /// - Parameters:
    ///   - sampleRate: Must match the backend. 24 kHz is what `response_format: "pcm"` produces.
    ///   - configuresAudioSession: Leave `true` for apps with no audio session handling of their
    ///     own. Set `false` when the host app already manages `AVAudioSession` itself — otherwise
    ///     the two fight over the category and playback can be routed to the wrong output.
    ///   - engine: An engine to play through, instead of a private one.
    ///
    ///     Pass the same engine here and to `BigBroMicrophone` when recording at the same time.
    ///     Voice processing lives in one I/O unit and sees only the streams inside its own
    ///     engine, so split across two it can neither cancel the echo nor apply the dynamic
    ///     processing that brings playback up to a normal level.
    public init(
        sampleRate: Double = 24_000,
        channels: AVAudioChannelCount = 1,
        configuresAudioSession: Bool = true,
        engine: AVAudioEngine? = nil
    ) {
        // Float32 deinterleaved is AVAudioEngine's native currency, so converting on the way in
        // avoids an AVAudioConverter for the interleaved-Int16 wire format.
        self.format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
            ?? AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        self.configuresAudioSession = configuresAudioSession
        self.engine = engine ?? AVAudioEngine()
        self.ownsEngine = engine == nil
    }

    // MARK: - Playback

    /// Plays an audio stream, returning once the final buffer has finished playing.
    ///
    /// Cancelling the surrounding task, or calling ``stop()``, ends playback early and returns.
    public func play(_ stream: AsyncThrowingStream<Data, Error>) async throws {
        try start()

        pendingByte = nil
        scheduledBuffers = 0
        completedBuffers = 0

        do {
            for try await chunk in stream {
                guard let buffer = makeBuffer(from: chunk) else { continue }
                scheduledBuffers += 1
                node.scheduleBuffer(buffer) { [weak self] in
                    // Fires on an engine-internal thread, not the main actor.
                    Task { @MainActor in self?.bufferCompleted() }
                }
            }
        } catch {
            stop()
            throw error
        }

        await waitForDrain()
    }

    /// Stops playback immediately and discards anything still queued — use for barge-in.
    ///
    /// The engine stays running so the next utterance starts without restart latency. Call
    /// ``shutdown()`` to release it entirely.
    public func stop() {
        node.stop()
        node.reset()
        pendingByte = nil
        scheduledBuffers = 0
        completedBuffers = 0
        resumeDrain()
    }

    /// Stops playback and tears the engine down, releasing the audio route.
    ///
    /// Apps that manage their own `AVAudioSession` should call this before deactivating it.
    public func shutdown() {
        stop()
        // A borrowed engine may still be capturing. Stopping it would take the microphone
        // down with the speaker.
        if ownsEngine, engine.isRunning { engine.stop() }
    }

    public var isPlaying: Bool { node.isPlaying }

    // MARK: - Engine

    private func start() throws {
        if configuresAudioSession {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
            } catch {
                throw PlaybackError.engineFailed(error.localizedDescription)
            }
        }

        // Whether the audio is loud enough is decided entirely by the route and the
        // volume that goes with it, and neither is visible from the code that scheduled
        // the buffers. Logged once per playback so a "it's too quiet" report carries the
        // two facts that identify the cause: `Receiver` means it is playing out of the
        // earpiece, and a low `volume` on `.playAndRecord` means it is being governed by
        // the call volume rather than the media one.
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        print("[BigBroAudioPlayer] route=\(outputs.isEmpty ? "none" : outputs) "
              + "category=\(session.category.rawValue) mode=\(session.mode.rawValue) "
              + "volume=\(String(format: "%.2f", session.outputVolume))")

        if !isAttached {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            isAttached = true
        }

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                throw PlaybackError.engineFailed(error.localizedDescription)
            }
        }

        if !node.isPlaying { node.play() }
    }

    // MARK: - Buffering

    /// Converts one chunk of 16-bit little-endian PCM into a Float32 buffer.
    ///
    /// Chunks are byte-aligned, not sample-aligned, so a single sample can straddle two of them.
    /// The leftover byte is carried into the next call — dropping it would shift every following
    /// sample by one byte and turn the rest of the utterance into noise.
    private func makeBuffer(from chunk: Data) -> AVAudioPCMBuffer? {
        var bytes = Data()
        if let pendingByte {
            bytes.append(pendingByte)
            self.pendingByte = nil
        }
        bytes.append(chunk)

        if bytes.count % 2 == 1 {
            pendingByte = bytes.removeLast()
        }
        guard !bytes.isEmpty else { return nil }

        let frames = bytes.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)

        bytes.withUnsafeBytes { raw in
            for frame in 0..<frames {
                // Assembled byte by byte rather than loaded as Int16: Data gives no alignment
                // guarantee, and an unaligned load is undefined behaviour.
                let low = UInt16(raw[frame * 2])
                let high = UInt16(raw[frame * 2 + 1])
                let sample = Int16(bitPattern: low | (high << 8))
                channel[frame] = Float(sample) / 32_768.0
            }
        }
        return buffer
    }

    // MARK: - Drain

    private func waitForDrain() async {
        guard completedBuffers < scheduledBuffers else { return }
        // Safe against interleaving: both this check and bufferCompleted() run on the main actor,
        // and withCheckedContinuation's body runs synchronously.
        await withCheckedContinuation { continuation in
            drainContinuation = continuation
        }
    }

    private func bufferCompleted() {
        completedBuffers += 1
        if completedBuffers >= scheduledBuffers { resumeDrain() }
    }

    private func resumeDrain() {
        guard let continuation = drainContinuation else { return }
        drainContinuation = nil
        continuation.resume()
    }
}
