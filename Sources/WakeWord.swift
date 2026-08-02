import Foundation

/// A phrase that has to be said before the assistant will answer.
///
/// Matching runs against the transcript rather than the audio, so it costs no new model and
/// no new dependency: the microphone already endpoints utterances and the Mac already
/// transcribes them. What this adds is the decision about which transcripts were meant for us.
///
/// ```swift
/// let wake = WakeWord("hey big bro")
/// wake.match("Hey, Big Bro, what's the weather?")?.request   // "what's the weather?"
/// wake.match("so anyway I told him no")                      // nil
/// ```
///
/// The phrase must open the utterance. Allowing it anywhere would fire on any passing mention
/// of the name, which in a room where the session is armed is most of them.
public struct WakeWord: Sendable, Equatable {

    /// What the assistant answers to. The first is the canonical spelling; the rest are
    /// alternates for a name that might be transcribed as a genuinely different word.
    ///
    /// Spacing needs no alternate — matching ignores it, so "bigbro" and "big bro" are the
    /// same phrase and only one of them has to be listed.
    public var phrases: [String]

    /// How much of the phrase may be misheard and still count, as a fraction of its length.
    ///
    /// Transcription of a coined name is unreliable in a way ordinary words are not: "hey big
    /// bro" comes back as "hey big brow", "hey pig bro", "a big bro". Exact matching fails
    /// often enough to make the mode feel broken, so this trades a small false-wake risk
    /// against it. 0 demands the phrase verbatim.
    ///
    /// Scaled to length rather than fixed because the same slack that is generous on a long
    /// phrase is reckless on a short one — one edit on "bro" matches most three-letter words.
    public var tolerance: Double

    /// A phrase shorter than this is rejected at init. Below roughly this length the tolerance
    /// window overlaps too much ordinary speech to be usable as a gate.
    public static let minimumPhraseLength = 4

    public static let `default` = WakeWord("hey big bro")

    /// - Parameters:
    ///   - phrase: What to listen for. Case, spacing and punctuation are all ignored.
    ///   - aliases: Alternate spellings, tried in order after `phrase`.
    ///   - tolerance: Fraction of the phrase that may be misheard. See ``tolerance``.
    public init(_ phrase: String, aliases: [String] = [], tolerance: Double = 0.25) {
        self.phrases = ([phrase] + aliases)
            .filter { Self.normalize($0).count >= Self.minimumPhraseLength }
        self.tolerance = max(0, tolerance)
    }

    /// True when no usable phrase survived initialization, in which case ``match(_:)`` never
    /// fires. A caller offering a wake phrase as a text field should check this before
    /// starting a session that would otherwise answer nothing.
    public var isEmpty: Bool { phrases.isEmpty }

    public struct Match: Sendable, Equatable {
        /// What was said after the phrase. Empty when the phrase was the whole utterance —
        /// the user called the assistant by name and has not yet asked anything.
        public let request: String
        /// How many leading words the phrase consumed.
        public let wordsConsumed: Int
    }

    /// Returns what was asked, or nil if the utterance was not addressed to us.
    public func match(_ transcript: String) -> Match? {
        let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let normalized = words.map(Self.normalize)

        for phrase in phrases {
            let target = Self.normalize(phrase)
            let budget = tolerance <= 0
                ? 0
                : max(1, Int((Double(target.count) * tolerance).rounded()))

            // The phrase can be split into words any number of ways — "bigbro" and "big bro"
            // are one name said one way, and which one comes back is the transcriber's whim.
            // Rather than guess, every prefix length is tried and the closest wins.
            let spoken = phrase.split(whereSeparator: \.isWhitespace).count
            var best: (distance: Int, count: Int)?
            for count in 1...min(words.count, spoken + 2) {
                let candidate = normalized[0..<count].joined()
                guard !candidate.isEmpty else { continue }
                let distance = Self.editDistance(candidate, target)
                guard distance <= budget else { continue }
                // Strictly closer, so a tie keeps the shorter prefix and leaves as much of
                // the utterance as possible in the request.
                if best == nil || distance < best!.distance { best = (distance, count) }
            }

            if let best {
                let rest = Self.trimmingLeadingJunk(words[best.count...].joined(separator: " "))
                return Match(request: rest, wordsConsumed: best.count)
            }
        }
        return nil
    }

    // MARK: - Text

    /// Lowercased letters and digits only.
    ///
    /// Spaces go too, so how the transcriber chose to break the name up stops mattering.
    static func normalize(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// Drops punctuation left stranded at the front of a request once the name is stripped
    /// off, as in "hey big bro — what's up".
    ///
    /// Leading only: `trimmingCharacters(in:)` would take the same set off the end and eat
    /// the question mark that makes "what's the weather?" a question.
    static func trimmingLeadingJunk(_ text: String) -> String {
        let junk = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        let kept = text.drop { character in
            character.unicodeScalars.allSatisfy(junk.contains)
        }
        return String(kept)
    }

    /// Levenshtein distance, two rows rather than a full matrix.
    ///
    /// Both inputs are a handful of characters, so the cost is irrelevant and clarity wins.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
