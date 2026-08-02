import XCTest
@testable import BigBroKit

/// The matcher runs against transcriber output, so the cases that matter are the ones a
/// transcriber actually produces: casing it invented, punctuation it added, and the name
/// misheard as a word it already knew.
final class WakeWordTests: XCTestCase {

    private let wake = WakeWord("hey big bro")

    // MARK: - Waking

    func testMatchesThePhraseExactly() {
        XCTAssertEqual(wake.match("hey big bro")?.request, "")
    }

    func testStripsThePhraseAndReturnsTheRequest() {
        XCTAssertEqual(wake.match("hey big bro what's the weather")?.request,
                       "what's the weather")
    }

    func testIgnoresCasingAndPunctuation() {
        XCTAssertEqual(wake.match("Hey, Big Bro, what's the weather?")?.request,
                       "what's the weather?")
    }

    /// Whether a coined name comes back as one word or two is the transcriber's whim, and
    /// both spellings have to reach the same place.
    func testIgnoresHowTheNameWasSplit() {
        XCTAssertEqual(wake.match("hey bigbro what time is it")?.request, "what time is it")
        XCTAssertEqual(wake.match("heybigbro what time is it")?.request, "what time is it")
    }

    /// The whole reason tolerance exists: these are real transcriptions of the phrase.
    func testToleratesTheNameBeingMisheard() {
        XCTAssertEqual(wake.match("hey big brow what time is it")?.request, "what time is it")
        XCTAssertEqual(wake.match("hey pig bro what time is it")?.request, "what time is it")
    }

    func testTrimsPunctuationStrandedBeforeTheRequest() {
        XCTAssertEqual(wake.match("hey big bro — what's up")?.request, "what's up")
        XCTAssertEqual(wake.match("hey big bro: what's up")?.request, "what's up")
    }

    func testReportsHowManyWordsThePhraseConsumed() {
        XCTAssertEqual(wake.match("hey big bro hello")?.wordsConsumed, 3)
        XCTAssertEqual(wake.match("hey bigbro hello")?.wordsConsumed, 2)
    }

    // MARK: - Staying asleep

    func testIgnoresUnrelatedSpeech() {
        XCTAssertNil(wake.match("so anyway I told him no"))
        XCTAssertNil(wake.match("can you pass the salt"))
        XCTAssertNil(wake.match(""))
    }

    /// Anywhere-in-the-utterance matching would fire on every passing mention of the name,
    /// which in a room where the session is armed is most of them.
    func testRequiresThePhraseToOpenTheUtterance() {
        XCTAssertNil(wake.match("I was telling her hey big bro is what he calls it"))
    }

    func testDoesNotFireOnAPrefixOfTheName() {
        XCTAssertNil(wake.match("hey what's up"))
        XCTAssertNil(wake.match("hey there"))
    }

    /// Tolerance scaled to length rather than fixed, so a long phrase gets slack without a
    /// short one matching half the language.
    func testToleranceDoesNotStretchToADifferentPhrase() {
        XCTAssertNil(wake.match("hey little bro what time is it"))
    }

    func testZeroToleranceDemandsThePhraseVerbatim() {
        let strict = WakeWord("hey big bro", tolerance: 0)
        XCTAssertEqual(strict.match("hey big bro hello")?.request, "hello")
        XCTAssertNil(strict.match("hey big brow hello"))
    }

    // MARK: - Configuration

    func testAliasesAreMatchedToo() {
        let wake = WakeWord("computer", aliases: ["jarvis"])
        XCTAssertEqual(wake.match("jarvis lights on")?.request, "lights on")
        XCTAssertEqual(wake.match("computer lights on")?.request, "lights on")
    }

    /// The name belongs to the app using the kit, so writing one has to be as cheap as
    /// writing a string.
    func testAStringLiteralIsAWakeWord() {
        let wake: WakeWord = "hey jarvis"
        XCTAssertEqual(wake.match("hey jarvis lights on")?.request, "lights on")
        XCTAssertNil(wake.match("hey big bro lights on"))
    }

    func testOptionalTakesAStringLiteralToo() {
        let wake: WakeWord? = "computer"
        XCTAssertEqual(wake?.match("computer lights on")?.request, "lights on")
    }

    func testPhraseReportsTheCanonicalSpelling() {
        XCTAssertEqual(WakeWord("hey jarvis", aliases: ["jarvis"]).phrase, "hey jarvis")
        XCTAssertEqual(WakeWord("yo").phrase, "")
    }

    /// The floor is a default, not a rule: an app whose name really is that short should be
    /// able to take the false wakes rather than the wrong name.
    func testMinimumLengthIsTunable() {
        XCTAssertTrue(WakeWord("ava").isEmpty)
        let short = WakeWord("ava", minimumLength: 3)
        XCTAssertFalse(short.isEmpty)
        XCTAssertEqual(short.match("ava lights on")?.request, "lights on")
    }

    func testDefaultIsBigBrosOwnName() {
        XCTAssertEqual(WakeWord.default.phrase, "hey big bro")
    }

    /// Below a few characters the tolerance window overlaps too much ordinary speech for the
    /// gate to mean anything, so such a phrase is refused rather than silently useless.
    func testRejectsAPhraseTooShortToGateOn() {
        let wake = WakeWord("yo")
        XCTAssertTrue(wake.isEmpty)
        XCTAssertNil(wake.match("yo what's up"))
    }

    func testAnEmptyPhraseNeverMatches() {
        let wake = WakeWord("   ")
        XCTAssertTrue(wake.isEmpty)
        XCTAssertNil(wake.match("anything at all"))
    }

    // MARK: - Distance

    func testEditDistance() {
        XCTAssertEqual(WakeWord.editDistance("abc", "abc"), 0)
        XCTAssertEqual(WakeWord.editDistance("abc", "abd"), 1)
        XCTAssertEqual(WakeWord.editDistance("abc", ""), 3)
        XCTAssertEqual(WakeWord.editDistance("", "abc"), 3)
        XCTAssertEqual(WakeWord.editDistance("kitten", "sitting"), 3)
    }

    func testNormalizeKeepsOnlyLowercasedAlphanumerics() {
        XCTAssertEqual(WakeWord.normalize("Hey, Big Bro!"), "heybigbro")
        XCTAssertEqual(WakeWord.normalize("  spaced  out  "), "spacedout")
    }
}
