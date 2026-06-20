import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dictionary correction detector")
struct DictionaryCorrectionDetectorTests {
    @Test("detects a corrected misspelling inside pasted text")
    func detectsCorrectedMisspelling() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "I love museli",
            baselineText: "I love museli",
            currentText: "I love muesli",
            appContext: "Notes|com.apple.Notes"
        )

        #expect(suggestion?.observed == "museli")
        #expect(suggestion?.replacement == "muesli")
        #expect(suggestion?.appContext == "Notes|com.apple.Notes")
    }

    @Test("detects less similar uncommon product-name corrections")
    func detectsLessSimilarProductNameCorrection() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "the word newsly is hard to transcribe",
            baselineText: "the word newsly is hard to transcribe",
            currentText: "the word muesli is hard to transcribe"
        )

        #expect(suggestion?.observed == "newsly")
        #expect(suggestion?.replacement == "muesli")
    }

    @Test("detects proper noun split merge corrections")
    func detectsProperNounSplitMergeCorrection() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "often I try to say Alvar Pet in dictation",
            editedText: "often I try to say Alwarpet in dictation"
        )

        #expect(suggestion?.observed == "Alvar Pet")
        #expect(suggestion?.replacement == "Alwarpet")
    }

    @Test("detects muesli corrections from latest failure shape")
    func detectsMuesliCorrectionFromLatestFailureShape() {
        let original = "No, typically I think the word muzzle is the worst toughest one for it to transcribe because it usually transcribes to the one starting with the w letter N instead of just muzzli."
        let edited = "No, typically I think the word muesli is the worst toughest one for it to transcribe because it usually transcribes to the one starting with the w letter N instead of just muesli."

        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: original,
            editedText: edited
        )

        #expect(suggestion?.observed == "muzzle")
        #expect(suggestion?.replacement == "muesli")
    }

    @Test("detects muesli corrections from latest musley failure")
    func detectsMuesliCorrectionFromLatestMusleyFailure() {
        let original = "Okay, it is able to transcribe the word musley if I say it very explicitly and enunciate the words, but I think as such if I say musley fast it's not able to."
        let edited = "Okay, it is able to transcribe the word muesli if I say it very explicitly and enunciate the words, but I think as such if I say muesli fast it's not able to."

        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: original,
            editedText: edited
        )

        #expect(suggestion?.observed == "musley")
        #expect(suggestion?.replacement == "muesli")
    }

    @Test("detects muesli corrections from latest muwsly failure")
    func detectsMuesliCorrectionFromLatestMuwslyFailure() {
        let original = "See, I typically find the word muesli to be wrongly transcribed almost every time, so I'm just repeating muwsly twice."
        let edited = "See, I typically find the word muesli to be wrongly transcribed almost every time, so I'm just repeating muesli twice."

        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: original,
            editedText: edited
        )

        #expect(suggestion?.observed == "muwsly")
        #expect(suggestion?.replacement == "muesli")
    }

    @Test("detects word correction when extra text is appended afterwards")
    func detectsCorrectionWithAdditionalTyping() {
        let original = "So this time if I say Newsly has not transcribed Newsly properly, would you be able to add it to dictionary immediately?"
        let edited = "So this time if I say muesli has not transcribed muesli properly, would you be able to add it to dictionary immediately? (still did not trigger the prompt unfortunately)"

        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: original,
            editedText: edited,
            appContext: "Codex|com.openai.chat"
        )

        #expect(suggestion?.observed == "Newsly")
        #expect(suggestion?.replacement == "muesli")
        #expect(suggestion?.appContext == "Codex|com.openai.chat")
    }

    @Test("requires shared dictation context before diffing AX snapshots")
    func requiresSharedDictationContext() {
        #expect(DictionaryCorrectionDetector.hasSufficientSharedContext(
            originalText: "So this time if I say Newsly has not transcribed Newsly properly",
            editedText: "So this time if I say muesli has not transcribed muesli properly and then I kept typing"
        ))

        #expect(!DictionaryCorrectionDetector.hasSufficientSharedContext(
            originalText: "please look up spelling correction",
            editedText: "please look file_00000000f4ac61f4841155122554864c-sanitized spelling correction"
        ))
    }

    @Test("detects corrections from a final edited transcript snapshot")
    func detectsFinalEditedTranscriptSnapshot() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "Hey Musley, can you see if you're transcribing the word correctly?",
            editedText: "Hey Muesli, can you see if you're transcribing the word correctly?"
        )

        #expect(suggestion?.observed == "Musley")
        #expect(suggestion?.replacement == "Muesli")
    }

    @Test("detects capitalization corrections for names")
    func detectsCapitalizationCorrection() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "talk to pranav today",
            baselineText: "talk to pranav today",
            currentText: "talk to Pranav today"
        )

        #expect(suggestion?.observed == "pranav")
        #expect(suggestion?.replacement == "Pranav")
    }

    @Test("does not suggest common everyday typo corrections")
    func skipsCommonWords() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "ship teh update",
            baselineText: "ship teh update",
            currentText: "ship the update"
        )

        #expect(suggestion == nil)
    }

    @Test("does not suggest common word truncations")
    func skipsCommonWordTruncations() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "I usually use this prompt",
            baselineText: "I usually use this prompt",
            currentText: "I usual use this prompt"
        )

        #expect(suggestion == nil)
    }

    @Test("does not suggest common word to generated artifact corrections")
    func skipsCommonWordToGeneratedArtifact() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "please look up spelling correction",
            editedText: "please look file_00000000f4ac61f4841155122554864c-sanitized spelling correction"
        )

        #expect(suggestion == nil)
    }

    @Test("ignores edits outside the pasted dictation")
    func ignoresOutsideEdits() {
        let suggestion = DictionaryCorrectionDetector.suggestion(
            originalText: "hello muesli",
            baselineText: "before hello muesli",
            currentText: "before hello muesli!"
        )

        #expect(suggestion == nil)
    }
}

@Suite("Dictionary correction snapshot stabilizer")
struct DictionaryCorrectionSnapshotStabilizerTests {
    @Test("waits for a quiet window before evaluating a changed snapshot")
    func waitsForQuietWindow() {
        var stabilizer = DictationCorrectionSnapshotStabilizer()
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = "I usually use this prompt"

        #expect(stabilizer.observe(snapshots: [snapshot], now: start, quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: [snapshot], now: start.addingTimeInterval(1.0), quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: [snapshot], now: start.addingTimeInterval(1.6), quietWindow: 1.5) == [snapshot])
    }

    @Test("resets the quiet window when the snapshot changes")
    func resetsQuietWindowOnChange() {
        var stabilizer = DictationCorrectionSnapshotStabilizer()
        let start = Date(timeIntervalSince1970: 2_000)

        #expect(stabilizer.observe(snapshots: ["I usually"], now: start, quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: ["I usual"], now: start.addingTimeInterval(1.0), quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: ["I usual"], now: start.addingTimeInterval(2.4), quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: ["I usual"], now: start.addingTimeInterval(2.6), quietWindow: 1.5) == ["I usual"])
    }

    @Test("does not evaluate the same stable snapshot repeatedly")
    func evaluatesStableSnapshotOnce() {
        var stabilizer = DictationCorrectionSnapshotStabilizer()
        let start = Date(timeIntervalSince1970: 3_000)
        let snapshot = "muwsly"

        #expect(stabilizer.observe(snapshots: [snapshot], now: start, quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: [snapshot], now: start.addingTimeInterval(2.0), quietWindow: 1.5) == [snapshot])
        #expect(stabilizer.observe(snapshots: [snapshot], now: start.addingTimeInterval(3.0), quietWindow: 1.5).isEmpty)
    }

    @Test("evaluates later stable snapshots after an earlier snapshot was already evaluated")
    func evaluatesLaterStableSnapshotAfterEarlierCandidate() {
        var stabilizer = DictationCorrectionSnapshotStabilizer()
        let start = Date(timeIntervalSince1970: 4_000)
        let earlier = "I changed punctuation only."
        let later = "I changed museli to muesli."

        #expect(stabilizer.observe(snapshots: [earlier], now: start, quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: [earlier], now: start.addingTimeInterval(1.6), quietWindow: 1.5) == [earlier])
        #expect(stabilizer.observe(snapshots: [earlier, later], now: start.addingTimeInterval(1.7), quietWindow: 1.5).isEmpty)
        #expect(stabilizer.observe(snapshots: [earlier, later], now: start.addingTimeInterval(3.3), quietWindow: 1.5) == [later])
    }
}

@Suite("Dictionary suggestion config")
struct DictionarySuggestionConfigTests {
    @Test("old configs decode with correction prompts disabled")
    func oldConfigDefaults() throws {
        let data = Data(#"{"custom_words":[]}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(!config.enableDictionaryCorrectionPrompts)
        #expect(config.dictionarySuggestions.isEmpty)
        #expect(config.dismissedDictionarySuggestionKeys.isEmpty)
    }

    @Test("suggestion key is stable across whitespace and case")
    func stableSuggestionKey() {
        #expect(
            DictionarySuggestion.key(observed: " Museli ", replacement: "Muesli")
                == DictionarySuggestion.key(observed: "museli", replacement: " muesli ")
        )
    }

    @Test("suggestion app display name hides bundle identifier")
    func suggestionAppDisplayName() {
        let suggestion = DictionarySuggestion(
            observed: "museli",
            replacement: "muesli",
            appContext: "Codex|com.openai.codex"
        )

        #expect(suggestion.appDisplayName == "Codex")
    }
}
