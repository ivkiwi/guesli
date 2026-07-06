import CoreAudio
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

    @Test("live overlap context stays bounded")
    func liveOverlapContextStaysBounded() {
        var previous = (0..<100).map { "p\($0)" }.joined(separator: " ")

        let segments = MeetingSession.deduplicateLiveSegments(
            [SpeechSegment(start: 8, end: 18, text: "p97 p98 p99 fresh words")],
            enabled: true,
            previousText: &previous
        )

        #expect(segments.map(\.text) == ["fresh words"])
        #expect(previous.split(separator: " ").count <= 80)
        #expect(previous.hasSuffix("fresh words"))
    }

    @Test("late repeated trigram does not drop new words")
    func lateRepeatedTrigramDoesNotDropNewWords() {
        let filler = (0..<16).map { "fresh\($0)" }.joined(separator: " ")
        let next = "\(filler) alpha beta gamma still new"

        let addition = TranscriptOverlapMerger.uniqueAddition(
            previous: "alpha beta gamma",
            next: next
        )

        #expect(addition == next)
    }

#if DEBUG
    @Test("backend update is rejected while recording")
    func backendUpdateIsRejectedWhileRecording() {
        let session = MeetingSession(
            title: "Test",
            calendarEventID: nil,
            backend: .whisper,
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            config: AppConfig(),
            templateSnapshot: MeetingTemplates.auto.snapshot,
            transcriptionCoordinator: TranscriptionCoordinator(),
            meetingMicRecorder: FakeMeetingMicRecorder()
        )

        #expect(session.updateBackend(.gigaAMV3Russian))
        #expect(session.currentBackendForTesting() == .gigaAMV3Russian)

        session.setRecordingForTesting(true)

        #expect(!session.updateBackend(.whisper))
        #expect(session.currentBackendForTesting() == .gigaAMV3Russian)
    }
#endif

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

    @Test("chunk collector releases tail after failed earlier chunk retires empty")
    func chunkCollectorFailureRetiresSlotAndReleasesTail() async {
        let collector = MeetingChunkCollector()
        let failedChunk = Task { [SpeechSegment]() }
        let tailChunk = Task { [SpeechSegment(start: 3, end: 4, text: "tail")] }

        let failed = collector.add(failedChunk)
        let tail = collector.add(tailChunk)

        #expect(failed.registered)
        #expect(tail.registered)
        #expect(collector.retire(id: tail.retireID, segments: await tailChunk.value)?.isEmpty == true)

        let ready = collector.retire(id: failed.retireID, segments: await failedChunk.value)

        #expect(ready?.map { $0.map(\.text) } == [[], ["tail"]])
    }

    @Test("chunk collector final drain flushes buffered tail past stalled slot")
    func chunkCollectorFinalDrainFlushesBufferedTailPastStalledSlot() async {
        let collector = MeetingChunkCollector()
        let stalled = Task<[SpeechSegment], Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return []
        }
        let tailChunk = Task { [SpeechSegment(start: 3, end: 4, text: "tail")] }

        let stalledRegistration = collector.add(stalled)
        let tailRegistration = collector.add(tailChunk)

        #expect(stalledRegistration.registered)
        #expect(tailRegistration.registered)
        #expect(collector.retire(id: tailRegistration.retireID, segments: await tailChunk.value)?.isEmpty == true)

        var logs: [String] = []
        let drained = await collector.closeAndDrainSortedSegments(inactivityTimeout: 0.05) { logs.append($0) }

        #expect(drained.map(\.text) == ["tail"])
        #expect(logs.contains { $0.contains("[live-collector] dropped pending chunk sequence=0 reason=drain_timeout") })
    }

    @Test("chunk collector final drain does not race progress timeout")
    func chunkCollectorFinalDrainDoesNotRaceProgressTimeout() async {
        for _ in 0..<50 {
            let collector = MeetingChunkCollector()
            let chunks = ControlledSpeechChunks()
            for index in 0..<4 {
                _ = collector.add(
                    Task {
                        await chunks.wait(for: index)
                    }
                )
            }

            while await chunks.readyCount() < 4 {
                await Task.yield()
            }

            var logs: [String] = []
            let drainTask = Task {
                await collector.closeAndDrainSortedSegments(inactivityTimeout: 0.25) { logs.append($0) }
            }

            for index in 0..<4 {
                await chunks.resume(
                    index: index,
                    with: [SpeechSegment(start: Double(index), end: Double(index + 1), text: "chunk \(index)")]
                )
                try? await Task.sleep(for: .milliseconds(5))
            }

            let drained = await drainTask.value

            #expect(drained.map(\.text) == (0..<4).map { "chunk \($0)" })
            #expect(logs.isEmpty)
        }
    }
}

private actor ControlledSpeechChunks {
    private var continuations: [Int: CheckedContinuation<[SpeechSegment], Never>] = [:]

    func wait(for index: Int) async -> [SpeechSegment] {
        await withCheckedContinuation { continuation in
            continuations[index] = continuation
        }
    }

    func readyCount() -> Int {
        continuations.count
    }

    func resume(index: Int, with segments: [SpeechSegment]) {
        continuations.removeValue(forKey: index)?.resume(returning: segments)
    }
}

#if DEBUG
private final class FakeMeetingMicRecorder: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?

    func prepare() throws {}
    func start() throws {}
    func pause() {}
    func resume() {}
    func stop() -> URL? { nil }
    func cancel() {}
    func currentPower() -> Float { -80 }

    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: .systemDefaultStreaming,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
    }
}
#endif
