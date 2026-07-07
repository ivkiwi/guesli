import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting stop ordering", .muesliHermeticSupport)
struct MeetingStopOrderingTests {
#if DEBUG
    @Test("stop requests intake shutdown before chunk queue finalization")
    func stopRequestsIntakeBeforeFinalization() async throws {
        let events = LockedStopEvents()
        let session = makeSession()
        session.onStopPhaseForTesting = { events.append($0) }
        let writer = try MeetingRecordingWriter()
        let retainedSamples = [Int16](repeating: 128, count: 512)
        writer.appendMic(retainedSamples)
        writer.appendSystem(retainedSamples)
        session.setRetainedRecordingWriterForTesting(writer)
        session.onRetainedRecordingReady = { request in
            events.append("retained_recording_callback")
            return request.tempURL
        }
        session.setRecordingForTesting(true)

        let samples = [Int16](repeating: 128, count: 512)
        for _ in 0..<20 {
            session.enqueueRealtimeMicSamplesForTesting(samples)
            session.enqueueRealtimeSystemSamplesForTesting(samples)
        }

        let result = try await session.stop()
        if let savedURL = result.retainedRecordingSavedURL {
            try? FileManager.default.removeItem(at: savedURL)
        }

        let phases = events.snapshot()
        #expect(phases.first == "stop_requested")
        #expect(index("mic_recorder_stop", in: phases) < index("chunk_queue_finalize", in: phases))
        #expect(index("system_recorder_stop", in: phases) < index("chunk_queue_finalize", in: phases))
        #expect(index("chunk_queue_finalize", in: phases) < index("retained_recording_finalize", in: phases))
        #expect(index("retained_recording_finalize", in: phases) < index("final_mic_chunk_transcription", in: phases))
        #expect(index("retained_recording_finalize", in: phases) < index("mic_collector_drain", in: phases))
        #expect(index("retained_recording_callback", in: phases) < index("final_mic_chunk_transcription", in: phases))
        #expect(result.retainedRecordingSavedURL != nil)
        #expect(session.stopIntakeRequestedForTesting)

        let diagnostics = try String(contentsOf: DiagnosticsLog.defaultURL, encoding: .utf8)
        #expect(diagnostics.contains("[live-collector] stop mic registered="))
    }
#endif

    @Test("collector drain terminates while producer keeps feeding")
    func collectorDrainTerminatesWhileProducerKeepsFeeding() async {
        let collector = MeetingChunkCollector()
        _ = collector.add(stalledTask())

        let feeder = Task {
            while !Task.isCancelled {
                let task = stalledTask()
                let registration = collector.add(task)
                if !registration.registered {
                    task.cancel()
                    return true
                }
                await Task.yield()
            }
            return false
        }

        await Task.yield()
        let drained = await collector.closeAndDrainSortedSegments(inactivityTimeout: 0.01)
        let rejectedAfterClose = await feeder.value

        #expect(drained.isEmpty)
        #expect(rejectedAfterClose)
    }

    @Test("controller runs meeting stop work detached from main actor")
    func controllerRunsMeetingStopDetachedFromMainActor() throws {
        let source = try sourceFile(named: "MuesliController.swift")

        #expect(source.contains("Task.detached(priority: .userInitiated) { [weak self] in"))
        #expect(source.contains("defer { writeMeetSpeakerStopDiagnosticsOnce() }"))
        #expect(!source.contains("Task { [weak self] in\n            guard let self else { return }\n            var meetingTitle = \"Meeting\""))
    }

#if DEBUG
    private func makeSession() -> MeetingSession {
        var config = AppConfig()
        config.meetingSummaryBackend = "openai"
        config.openAIAPIKey = ""
        config.useCoreAudioTap = false
        config.enableScreenContext = false
        config.enableMeetingTranscriptCleanup = false

        return MeetingSession(
            title: "Stop ordering",
            calendarEventID: nil,
            backend: .whisperTinyEnglish,
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            config: config,
            transcriptionCoordinator: TranscriptionCoordinator(),
            meetingMicRecorder: StopOrderingMicRecorder(),
            systemAudioRecorder: StopOrderingSystemRecorder()
        )
    }

    private func index(_ phase: String, in phases: [String]) -> Int {
        phases.firstIndex(of: phase) ?? Int.max
    }
#endif

    private func stalledTask() -> Task<[SpeechSegment], Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
            }
            return []
        }
    }

    private func sourceFile(named name: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/MuesliNativeApp", isDirectory: true)
            .appendingPathComponent(name)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

#if DEBUG
private final class LockedStopEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [String] = []

    func append(_ phase: String) {
        lock.withLock {
            phases.append(phase)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { phases }
    }
}

private final class StopOrderingMicRecorder: MeetingMicRecording {
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

private final class StopOrderingSystemRecorder: SystemAudioCapturing {
    var onPCMSamples: (([Int16]) -> Void)?
    private(set) var isRecording = false
    private(set) var isPaused = false

    func start() async throws {
        isRecording = true
        isPaused = false
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    func stop() -> URL? {
        isRecording = false
        isPaused = false
        onPCMSamples = nil
        return nil
    }
}
#endif
