import Testing
@testable import MuesliNativeApp

@Suite("Transcript chat message parsing")
struct TranscriptChatMessageTests {
    @Test("timestamped speaker lines become chat messages")
    func timestampedSpeakerLinesBecomeChatMessages() {
        let messages = TranscriptChatMessage.messages(from: """
        [10:00:00] You: Hello there.
        [10:00:04] Speaker 1: Hi back.
        """)

        #expect(messages.count == 2)
        #expect(messages[0].timestamp == "10:00:00")
        #expect(messages[0].speaker == "You")
        #expect(messages[0].text == "Hello there.")
        #expect(messages[0].isUser)
        #expect(messages[1].speaker == "Speaker 1")
        #expect(messages[1].text == "Hi back.")
        #expect(!messages[1].isUser)
    }

    @Test("plain transcript lines are preserved")
    func plainTranscriptLinesArePreserved() {
        let messages = TranscriptChatMessage.messages(from: """
        Product: launch timeline changed.

        This line has no speaker.
        """)

        #expect(messages.count == 2)
        #expect(messages[0].speaker == nil)
        #expect(messages[0].text == "Product: launch timeline changed.")
        #expect(messages[1].text == "This line has no speaker.")
    }
}

@Suite("Live transcript merge decision")
struct LiveTranscriptMergeDecisionTests {
    @Test("appends only unread suffix")
    func appendsOnlyUnreadSuffix() {
        let parsedTranscript = "[10:00:00] You: Hello.\n"
        let decision = LiveTranscriptView.transcriptMergeDecision(
            newTranscript: parsedTranscript + "[10:00:02] Others: Hi.\n",
            parsedTranscript: parsedTranscript,
            parsedLength: parsedTranscript.count
        )

        #expect(decision == .append("[10:00:02] Others: Hi.\n"))
    }

    @Test("returns unchanged for already parsed transcript")
    func returnsUnchangedForAlreadyParsedTranscript() {
        let parsedTranscript = "[10:00:00] You: Hello.\n"
        let decision = LiveTranscriptView.transcriptMergeDecision(
            newTranscript: parsedTranscript,
            parsedTranscript: parsedTranscript,
            parsedLength: parsedTranscript.count
        )

        #expect(decision == .unchanged)
    }

    @Test("resets when transcript shrinks")
    func resetsWhenTranscriptShrinks() {
        let parsedTranscript = "[10:00:00] You: Hello.\n"
        let decision = LiveTranscriptView.transcriptMergeDecision(
            newTranscript: "",
            parsedTranscript: parsedTranscript,
            parsedLength: parsedTranscript.count
        )

        #expect(decision == .resetAndAppend(""))
    }

    @Test("resets when parsed prefix diverges")
    func resetsWhenParsedPrefixDiverges() {
        let parsedTranscript = "[10:00:00] You: Hello.\n"
        let decision = LiveTranscriptView.transcriptMergeDecision(
            newTranscript: "[10:00:01] You: Corrected.\n",
            parsedTranscript: parsedTranscript,
            parsedLength: parsedTranscript.count
        )

        #expect(decision == .resetAndAppend("[10:00:01] You: Corrected.\n"))
    }
}
