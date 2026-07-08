import CoreAudio
import FluidAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting live overlap pipeline", .muesliHermeticSupport)
struct MeetingLiveOverlapPipelineTests {
    @Test("meeting backend selection drives GigaAM chunking even when dictation backend differs")
    func meetingBackendSelectionDrivesChunking() throws {
        var config = AppConfig()
        config.sttBackend = BackendOption.whisperTinyEnglish.backend
        config.sttModel = BackendOption.whisperTinyEnglish.model
        config.meetingTranscriptionBackend = BackendOption.gigaAMV3Russian.backend
        config.meetingTranscriptionModel = BackendOption.gigaAMV3Russian.model

        let resolved = try #require(MuesliController.availableMeetingTranscriptionBackend(
            config: config,
            dictationBackend: .whisperTinyEnglish,
            downloadedOptions: [.whisperTinyEnglish, .gigaAMV3Russian]
        ))
        let chunking = MeetingSession.liveChunkingConfiguration(for: resolved)

        #expect(resolved == .gigaAMV3Russian)
        #expect(chunking.minChunkDuration == 3)
        #expect(chunking.maxChunkDuration == 20)
        #expect(chunking.overlapSampleCount == 32_000)
        #expect(chunking.deduplicatesText)
    }

    @Test("live checkpoint assembler deduplicates GigaAM overlap per speaker only")
    func liveCheckpointDeduplicatesPerSpeaker() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var overlapBySpeaker: [String: String] = [:]

        let firstMic = LiveTranscriptCheckpointAssembler.entries(
            segments: [SpeechSegment(start: 0, end: 10, text: "alpha beta gamma delta epsilon")],
            speaker: "You",
            meetingID: 42,
            liveTranscriptStart: start,
            shouldDeduplicate: true,
            overlapByMeetingSpeaker: &overlapBySpeaker
        )
        let secondMic = LiveTranscriptCheckpointAssembler.entries(
            segments: [SpeechSegment(start: 8, end: 18, text: "gamma delta epsilon zeta eta")],
            speaker: "You",
            meetingID: 42,
            liveTranscriptStart: start,
            shouldDeduplicate: true,
            overlapByMeetingSpeaker: &overlapBySpeaker
        )
        let firstSystem = LiveTranscriptCheckpointAssembler.entries(
            segments: [SpeechSegment(start: 8, end: 18, text: "gamma delta epsilon system words")],
            speaker: "Others",
            meetingID: 42,
            liveTranscriptStart: start,
            shouldDeduplicate: true,
            overlapByMeetingSpeaker: &overlapBySpeaker
        )

        #expect(firstMic.map(\.text) == ["alpha beta gamma delta epsilon"])
        #expect(secondMic.map(\.text) == ["zeta eta"])
        #expect(firstSystem.map(\.text) == ["gamma delta epsilon system words"])
    }

    @Test("live checkpoint assembler leaves duplicate text when overlap dedupe is disabled")
    func liveCheckpointDoesNotDeduplicateWithoutOverlap() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var overlapBySpeaker: [String: String] = [:]
        _ = LiveTranscriptCheckpointAssembler.entries(
            segments: [SpeechSegment(start: 0, end: 10, text: "alpha beta gamma delta epsilon")],
            speaker: "You",
            meetingID: 42,
            liveTranscriptStart: start,
            shouldDeduplicate: false,
            overlapByMeetingSpeaker: &overlapBySpeaker
        )
        let duplicate = LiveTranscriptCheckpointAssembler.entries(
            segments: [SpeechSegment(start: 8, end: 18, text: "gamma delta epsilon zeta eta")],
            speaker: "You",
            meetingID: 42,
            liveTranscriptStart: start,
            shouldDeduplicate: false,
            overlapByMeetingSpeaker: &overlapBySpeaker
        )

        #expect(duplicate.map(\.text) == ["gamma delta epsilon zeta eta"])
        #expect(overlapBySpeaker.isEmpty)
    }

    @Test("chunk collector releases live chunks in registration order under out-of-order completion")
    func chunkCollectorPreservesLiveOrder() async {
        let collector = MeetingChunkCollector()
        let slowFirst = Task { [SpeechSegment(start: 0, end: 1, text: "first")] }
        let fastSecond = Task { [SpeechSegment(start: 1, end: 2, text: "second")] }

        let first = collector.add(slowFirst)
        let second = collector.add(fastSecond)

        #expect(first.registered)
        #expect(second.registered)
        #expect(collector.retire(id: second.retireID, segments: await fastSecond.value)?.isEmpty == true)

        let ready = collector.retire(id: first.retireID, segments: await slowFirst.value)
        #expect(ready?.map { $0.map(\.text) } == [["first"], ["second"]])
    }

    @Test("chunk collector advances past empty earlier chunks")
    func chunkCollectorAdvancesPastEmptyChunks() async {
        let collector = MeetingChunkCollector()
        let emptyFirst = Task { [SpeechSegment]() }
        let second = Task { [SpeechSegment(start: 1, end: 2, text: "second")] }

        let firstRegistration = collector.add(emptyFirst)
        let secondRegistration = collector.add(second)

        #expect(collector.retire(id: secondRegistration.retireID, segments: await second.value)?.isEmpty == true)
        let ready = collector.retire(id: firstRegistration.retireID, segments: await emptyFirst.value)
        #expect(ready?.map { $0.map(\.text) } == [[], ["second"]])
    }

    @Test("GigaAM VAD controller config overrides the 5 second default")
    func gigaAMVadConfigOverridesDefault() {
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

    @Test("synthetic overlapped chunks merge without duplicate markers or gaps")
    func syntheticOverlapTranscriptMergesWithoutDuplicatesOrGaps() {
        let transcripts = [
            "zero one two three four",
            "two three four five six seven",
            "five six seven eight nine",
        ]

        let merged = TranscriptOverlapMerger.merge(transcripts)

        #expect(merged == "zero one two three four five six seven eight nine")
    }

    @Test("live overlap context stays bounded")
    func liveOverlapContextStaysBounded() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var overlapBySpeaker = [
            "42|You": (0..<100).map { "p\($0)" }.joined(separator: " "),
        ]

        let entries = LiveTranscriptCheckpointAssembler.entries(
            segments: [SpeechSegment(start: 8, end: 18, text: "p97 p98 p99 fresh words")],
            speaker: "You",
            meetingID: 42,
            liveTranscriptStart: start,
            shouldDeduplicate: true,
            overlapByMeetingSpeaker: &overlapBySpeaker
        )
        let retained = try #require(overlapBySpeaker["42|You"])

        #expect(entries.map(\.text) == ["fresh words"])
        #expect(retained.split(separator: " ").count <= 80)
        #expect(retained.hasSuffix("fresh words"))
    }

    @Test("retranscribe gates work on VAD speech regions")
    func retranscribeGatesWorkOnVADSpeechRegions() async throws {
        let samples = (0..<(16_000 * 4)).map { Float($0 % 100) / 100.0 }
        let vadSegments = [
            VadSegment(startTime: 0.5, endTime: 1.0),
            VadSegment(startTime: 2.0, endTime: 2.5),
        ]
        var calls: [MeetingRetranscriptionPipeline.AudioSegment] = []

        let result = try await MeetingRetranscriptionPipeline.transcribeSegmentedAudio(
            samples: samples,
            vadSegments: vadSegments
        ) { segment, audio in
            calls.append(segment)
            #expect(audio.count == segment.endSample - segment.startSample)
            return SpeechTranscriptionResult(text: "chunk \(calls.count)", segments: [])
        }

        #expect(calls.map(\.startSample) == [8_000, 32_000])
        #expect(calls.map(\.endSample) == [16_000, 40_000])
        #expect(result.text == "chunk 1 chunk 2")
        #expect(result.segments.map(\.text) == ["chunk 1", "chunk 2"])
        #expect(result.segments.map(\.start) == [0.5, 2.0])
        #expect(result.segments.map(\.end) == [1.0, 2.5])
    }

    @Test("retranscribe feeds VAD segments in timeline order")
    func retranscribeFeedsVADSegmentsInTimelineOrder() async throws {
        let samples = (0..<(16_000 * 5)).map { Float($0 % 100) / 100.0 }
        let vadSegments = [
            VadSegment(startTime: 3.0, endTime: 3.5),
            VadSegment(startTime: 0.5, endTime: 1.0),
            VadSegment(startTime: 2.0, endTime: 2.5),
        ]
        var calls: [MeetingRetranscriptionPipeline.AudioSegment] = []

        let result = try await MeetingRetranscriptionPipeline.transcribeSegmentedAudio(
            samples: samples,
            vadSegments: vadSegments
        ) { segment, audio in
            calls.append(segment)
            #expect(audio.count == segment.endSample - segment.startSample)
            let label: String
            if segment.startSample == 8_000 {
                label = "early"
            } else if segment.startSample == 32_000 {
                label = "middle"
            } else {
                label = "late"
            }
            return SpeechTranscriptionResult(text: label, segments: [])
        }

        #expect(calls.map(\.startSample) == [8_000, 32_000, 48_000])
        #expect(calls.map(\.endSample) == [16_000, 40_000, 56_000])
        #expect(result.text == "early middle late")
        #expect(result.segments.map(\.text) == ["early", "middle", "late"])
    }

    @Test("retranscribe batch maps results by VAD input order")
    func retranscribeBatchMapsResultsByVADInputOrder() async throws {
        let samples = (0..<(16_000 * 4)).map { Float($0 % 100) / 100.0 }
        let vadSegments = [
            VadSegment(startTime: 2.0, endTime: 2.5),
            VadSegment(startTime: 0.5, endTime: 1.0),
        ]
        var batchStarts: [Int] = []

        let result = try await MeetingRetranscriptionPipeline.transcribeSegmentedAudio(
            samples: samples,
            vadSegments: vadSegments
        ) { segmentAudio in
            batchStarts = segmentAudio.map(\.segment.startSample)
            return segmentAudio.map { item in
                let label = item.segment.startSample == 8_000 ? "early" : "late"
                return SpeechTranscriptionResult(text: label, segments: [])
            }
        }

        #expect(batchStarts == [8_000, 32_000])
        #expect(result.text == "early late")
        #expect(result.segments.map(\.text) == ["early", "late"])
    }

    @Test("retranscribe batch rejects missing results")
    func retranscribeBatchRejectsMissingResults() async throws {
        let samples = (0..<(16_000 * 2)).map { Float($0 % 100) / 100.0 }
        let vadSegments = [
            VadSegment(startTime: 0.0, endTime: 0.5),
            VadSegment(startTime: 1.0, endTime: 1.5),
        ]

        await #expect(throws: Error.self) {
            _ = try await MeetingRetranscriptionPipeline.transcribeSegmentedAudio(
                samples: samples,
                vadSegments: vadSegments
            ) { _ in
                [SpeechTranscriptionResult(text: "only one", segments: [])]
            }
        }
    }

    @Test("retranscribe skips transcription when VAD finds no speech")
    func retranscribeSkipsTranscriptionWhenVADFindsNoSpeech() async throws {
        var transcribeWasCalled = false
        let result = try await MeetingRetranscriptionPipeline.transcribeSegmentedAudio(
            samples: Array(repeating: Float(0), count: 16_000),
            vadSegments: []
        ) { _, _ in
            transcribeWasCalled = true
            return SpeechTranscriptionResult(text: "unexpected", segments: [])
        }

        #expect(!transcribeWasCalled)
        #expect(result.text.isEmpty)
        #expect(result.segments.isEmpty)
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
