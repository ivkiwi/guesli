import FluidAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting live chunking")
struct MeetingLiveChunkingTests {
    @Test("GigaAM uses longer live chunks with overlap")
    func gigaAMUsesLongerLiveChunksWithOverlap() {
        let chunking = MeetingSession.liveChunkingConfiguration(for: .gigaAMV3Russian)

        #expect(chunking.minChunkDuration == 3)
        #expect(chunking.maxChunkDuration == 20)
        #expect(chunking.overlapSampleCount == 32_000)
        #expect(chunking.deduplicatesText)
    }

    @Test("non-GigaAM backends keep default live chunking")
    func nonGigaAMBackendsKeepDefaultLiveChunking() {
        for backend in BackendOption.all where backend != .gigaAMV3Russian {
            let chunking = MeetingSession.liveChunkingConfiguration(for: backend)

            #expect(chunking.minChunkDuration == 3)
            #expect(chunking.maxChunkDuration == 5)
            #expect(chunking.overlapSampleCount == 0)
            #expect(!chunking.deduplicatesText)
        }
    }

    @Test("GigaAM config reaches VAD controller")
    func gigaAMConfigReachesVadController() {
        let chunking = MeetingSession.liveChunkingConfiguration(for: .gigaAMV3Russian)
        let controller = StreamingVadController(
            minChunkDuration: chunking.minChunkDuration,
            maxChunkDuration: chunking.maxChunkDuration,
            makeInitialState: { VadStreamState.initial() },
            processStreamChunk: { _, state in
                VadStreamResult(state: state, event: nil, probability: 0)
            }
        )

        #expect(controller.configuredMinChunkDurationForTesting == 3)
        #expect(controller.configuredMaxChunkDurationForTesting == 20)
    }

    @Test("overlapped live text deduplicates per track only when enabled")
    func overlappedLiveTextDeduplicatesPerTrackOnlyWhenEnabled() {
        var micPrevious = ""
        var systemPrevious = ""

        let firstMic = MeetingSession.deduplicateLiveSegments(
            [SpeechSegment(start: 0, end: 10, text: "alpha beta gamma delta epsilon")],
            enabled: true,
            previousText: &micPrevious
        )
        let secondMic = MeetingSession.deduplicateLiveSegments(
            [SpeechSegment(start: 8, end: 18, text: "gamma delta epsilon zeta eta")],
            enabled: true,
            previousText: &micPrevious
        )
        let firstSystem = MeetingSession.deduplicateLiveSegments(
            [SpeechSegment(start: 8, end: 18, text: "gamma delta epsilon system words")],
            enabled: true,
            previousText: &systemPrevious
        )

        var disabledPrevious = ""
        _ = MeetingSession.deduplicateLiveSegments(
            [SpeechSegment(start: 0, end: 10, text: "alpha beta gamma delta epsilon")],
            enabled: false,
            previousText: &disabledPrevious
        )
        let disabledDuplicate = MeetingSession.deduplicateLiveSegments(
            [SpeechSegment(start: 8, end: 18, text: "gamma delta epsilon zeta eta")],
            enabled: false,
            previousText: &disabledPrevious
        )

        #expect(firstMic.map(\.text) == ["alpha beta gamma delta epsilon"])
        #expect(secondMic.map(\.text) == ["zeta eta"])
        #expect(firstSystem.map(\.text) == ["gamma delta epsilon system words"])
        #expect(disabledDuplicate.map(\.text) == ["gamma delta epsilon zeta eta"])
        #expect(disabledPrevious.isEmpty)
    }

    @Test("chunk collector releases live chunks in registration order")
    func chunkCollectorReleasesLiveChunksInRegistrationOrder() async {
        let collector = MeetingChunkCollector()
        let firstTask = Task { [SpeechSegment(start: 0, end: 1, text: "first")] }
        let secondTask = Task { [SpeechSegment(start: 1, end: 2, text: "second")] }

        let first = collector.add(firstTask)
        let second = collector.add(secondTask)

        #expect(first.registered)
        #expect(second.registered)
        #expect(collector.retire(id: second.retireID, segments: await secondTask.value)?.isEmpty == true)

        let ready = collector.retire(id: first.retireID, segments: await firstTask.value)

        #expect(ready?.map { $0.map(\.text) } == [["first"], ["second"]])
    }
}
