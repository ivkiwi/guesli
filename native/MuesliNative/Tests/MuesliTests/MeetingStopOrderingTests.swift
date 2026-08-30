import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting stop ordering", .muesliHermeticSupport)
struct MeetingStopOrderingTests {
#if DEBUG
    @Test("stop drains accepted queued samples into retained recording")
    func stopDrainsAcceptedQueuedSamplesIntoRetainedRecording() async throws {
        let events = LockedStopEvents()
        let session = makeSession()
        session.onStopPhaseForTesting = { events.append($0) }
        let writer = try MeetingRecordingWriter()
        session.setRetainedRecordingWriterForTesting(writer)
        session.onRetainedRecordingReady = { request in
            events.append("retained_recording_callback")
            events.setRetainedSamples(try readMonoPCM16WAVSamples(from: request.tempURL))
            return nil
        }
        session.setRecordingForTesting(true)

        let releaseQueue = DispatchSemaphore(value: 0)
        session.enqueueChunkRotationPauseForTesting(
            started: { events.append("queue_block_started") },
            release: releaseQueue
        )
        while !events.contains("queue_block_started") {
            try await Task.sleep(for: .milliseconds(1))
        }

        let micSamples = [Int16](repeating: 1_000, count: 512)
        let systemSamples = [Int16](repeating: 3_000, count: 512)
        session.enqueueRealtimeMicSamplesForTesting(micSamples)
        session.enqueueRealtimeSystemSamplesForTesting(systemSamples)

        let stopTask = Task {
            try await session.stop()
        }
        while !events.contains("stop_requested") {
            try await Task.sleep(for: .milliseconds(1))
        }
        releaseQueue.signal()

        let result = try await stopTask.value
        if let retainedURL = result.retainedRecordingURL {
            try? FileManager.default.removeItem(at: retainedURL)
        }

        let phases = events.snapshot().filter { $0 != "queue_block_started" }
        #expect(phases.first == "stop_requested")
        #expect(index("mic_recorder_stop", in: phases) < index("chunk_queue_finalize", in: phases))
        #expect(index("system_recorder_stop", in: phases) < index("chunk_queue_finalize", in: phases))
        #expect(index("chunk_queue_finalize", in: phases) < index("retained_recording_finalize", in: phases))
        #expect(index("retained_recording_finalize", in: phases) < index("final_mic_chunk_transcription", in: phases))
        #expect(index("retained_recording_finalize", in: phases) < index("mic_collector_drain", in: phases))
        #expect(index("retained_recording_callback", in: phases) < index("final_mic_chunk_transcription", in: phases))
        #expect(result.retainedRecordingURL != nil)
        #expect(result.retainedRecordingSavedURL == nil)
        #expect(session.stopIntakeRequestedForTesting)
        #expect(events.retainedSamples() == [Int16](repeating: 2_000, count: 512))

        let diagnostics = try String(contentsOf: DiagnosticsLog.defaultURL, encoding: .utf8)
        #expect(diagnostics.contains("[live-collector] stop mic registered="))
    }

    @Test("start fails when retained recording writer cannot be prepared")
    func startFailsWhenRetainedRecordingWriterCannotBePrepared() async throws {
        let micRecorder = StopOrderingMicRecorder()
        let systemRecorder = StopOrderingSystemRecorder()
        let session = makeSession(meetingMicRecorder: micRecorder, systemAudioRecorder: systemRecorder)
        session.setRetainedRecordingWriterFactoryForTesting { _ in
            throw NSError(domain: "MeetingRecordingWriterTests", code: 99)
        }

        do {
            try await session.start()
            Issue.record("Expected meeting start to fail")
        } catch {
            #expect((error as NSError).domain == "MeetingRecordingWriterTests")
        }

        #expect(micRecorder.didStart == false)
        #expect(micRecorder.didCancel)
        #expect(systemRecorder.didStart == false)
        #expect(systemRecorder.isRecording == false)
    }

    @Test("stop phase timeout is a wall-clock bound for non-cooperative work")
    func stopPhaseTimeoutBoundsNonCooperativeWork() async {
        let session = makeSession()
        let startedAt = ContinuousClock.now

        do {
            _ = try await session.withStopPhaseTimeout("non_cooperative", timeout: 0.02) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        continuation.resume(returning: "Too late")
                    }
                }
            }
            Issue.record("Expected non-cooperative stop phase to time out")
        } catch {
            #expect(startedAt.duration(to: .now) < .seconds(1))
            #expect(error.localizedDescription.contains("non_cooperative timed out"))
        }
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

    @Test("summary starts from raw transcript while cleanup runs")
    func summaryDoesNotWaitForTranscriptCleanup() throws {
        let source = try sourceFile(named: "MeetingSession.swift")

        #expect(source.components(separatedBy: "async let pendingCleanup = cleanupMeetingTranscript(rawTranscript)").count - 1 == 2)
        #expect(source.components(separatedBy: "transcript: rawTranscript,").count >= 4)
        #expect(source.components(separatedBy: "let cleanupResult = await pendingCleanup").count - 1 == 2)
    }

#if DEBUG
    private func makeSession(
        meetingMicRecorder: MeetingMicRecording = StopOrderingMicRecorder(),
        systemAudioRecorder: SystemAudioCapturing = StopOrderingSystemRecorder()
    ) -> MeetingSession {
        var config = AppConfig()
        config.meetingProcessingMode = MeetingProcessingMode.live.rawValue
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
            meetingMicRecorder: meetingMicRecorder,
            systemAudioRecorder: systemAudioRecorder
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

    private func readMonoPCM16WAVSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        #expect(String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        let sampleBytes = data.subdata(in: 44..<data.count)
        let count = sampleBytes.count / MemoryLayout<Int16>.size
        return sampleBytes.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: Int16.self)
            return Array(buffer.prefix(count)).map(Int16.init(littleEndian:))
        }
    }
}

#if DEBUG
private final class LockedStopEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [String] = []
    private var samples: [Int16] = []

    func append(_ phase: String) {
        lock.withLock {
            phases.append(phase)
        }
    }

    func snapshot() -> [String] {
        lock.withLock { phases }
    }

    func contains(_ phase: String) -> Bool {
        lock.withLock { phases.contains(phase) }
    }

    func setRetainedSamples(_ samples: [Int16]) {
        lock.withLock {
            self.samples = samples
        }
    }

    func retainedSamples() -> [Int16] {
        lock.withLock { samples }
    }
}

private final class StopOrderingMicRecorder: MeetingMicRecording {
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    private(set) var didStart = false
    private(set) var didCancel = false

    func prepare() throws {}
    func start() throws { didStart = true }
    func pause() {}
    func resume() {}
    func stop() -> URL? { nil }
    func cancel() { didCancel = true }
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
    private(set) var didStart = false

    func start() async throws {
        didStart = true
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
