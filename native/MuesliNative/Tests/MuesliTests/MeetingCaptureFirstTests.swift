import CoreAudio
import Foundation
import os
import Testing
@testable import MuesliNativeApp

@Suite("Meeting capture-first startup", .muesliHermeticSupport)
struct MeetingCaptureFirstTests {
    @Test(
        "system audio startup is bounded before microphone capture in both modes",
        arguments: [MeetingProcessingMode.post, .live]
    )
    func systemAudioStartupTimeoutIsBounded(mode: MeetingProcessingMode) async throws {
        let micRecorder = CaptureFirstMicRecorder()
        let systemRecorder = HangingCaptureFirstSystemRecorder()
        var config = postModeConfig()
        config.meetingProcessingMode = mode.rawValue
        let session = MeetingSession(
            title: "Bounded capture start",
            calendarEventID: nil,
            backend: .whisperTinyEnglish,
            runtime: testRuntime(),
            config: config,
            transcriptionCoordinator: TranscriptionCoordinator(),
            meetingMicRecorder: micRecorder,
            systemAudioRecorder: systemRecorder,
            systemAudioStartTimeout: 0.03
        )

        let startTask = Task { try await session.start() }
        #expect(await waitUntil { systemRecorder.hasPendingStart })
        let systemStartObservedAt = Date()
        do {
            try await startTask.value
            Issue.record("Expected system audio startup timeout")
        } catch {
            #expect(error.localizedDescription.contains("Timed out while starting system audio capture"))
        }

        #expect(Date().timeIntervalSince(systemStartObservedAt) < 1)
        #expect(!micRecorder.didStart)
        #expect(micRecorder.didCancel)
        #expect(!session.isRecording)

        let stopCountBeforeRelease = systemRecorder.stopCount
        systemRecorder.releaseStart()
        #expect(await waitUntil {
            systemRecorder.stopCount > stopCountBeforeRelease && !systemRecorder.isRecording
        })
    }

    @Test("cancelling a hanging system audio start leaves no late capture")
    func cancellationStopsHangingSystemAudioStart() async throws {
        let micRecorder = CaptureFirstMicRecorder()
        let systemRecorder = HangingCaptureFirstSystemRecorder()
        let session = MeetingSession(
            title: "Cancelled capture start",
            calendarEventID: nil,
            backend: .gigaAMV3Russian,
            runtime: testRuntime(),
            config: postModeConfig(),
            transcriptionCoordinator: TranscriptionCoordinator(),
            meetingMicRecorder: micRecorder,
            systemAudioRecorder: systemRecorder,
            systemAudioStartTimeout: 30
        )

        let startTask = Task { try await session.start() }
        #expect(await waitUntil { systemRecorder.hasPendingStart })
        startTask.cancel()

        do {
            try await startTask.value
            Issue.record("Expected meeting startup cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(!micRecorder.didStart)
        #expect(!session.isRecording)

        let stopCountBeforeRelease = systemRecorder.stopCount
        systemRecorder.releaseStart()
        #expect(await waitUntil {
            systemRecorder.stopCount > stopCountBeforeRelease && !systemRecorder.isRecording
        })
    }

    @Test("discard can cancel a blocking microphone start without lock inversion")
    func discardCancelsBlockingMicrophoneStart() async throws {
        let micRecorder = BlockingCaptureFirstMicRecorder()
        let systemRecorder = CaptureFirstSystemRecorder()
        let session = MeetingSession(
            title: "Blocking microphone start",
            calendarEventID: nil,
            backend: .gigaAMV3Russian,
            runtime: testRuntime(),
            config: postModeConfig(),
            transcriptionCoordinator: TranscriptionCoordinator(),
            meetingMicRecorder: micRecorder,
            systemAudioRecorder: systemRecorder,
            systemAudioStartTimeout: 1
        )

        let startTask = Task { try await session.start() }
        #expect(await waitUntil { micRecorder.hasEnteredStart })

        session.discard()
        micRecorder.releaseStart()
        do {
            try await startTask.value
            Issue.record("Expected discarded meeting startup to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }

        #expect(!micRecorder.isRecording)
        #expect(micRecorder.cancelCount >= 2)
        #expect(!systemRecorder.isRecording)
        #expect(!session.isRecording)
    }

    @Test("system audio start failure never starts microphone")
    func systemAudioStartFailureDoesNotStartMicrophone() async throws {
        let micRecorder = CaptureFirstMicRecorder()
        let session = MeetingSession(
            title: "Failed capture start",
            calendarEventID: nil,
            backend: .gigaAMV3Russian,
            runtime: testRuntime(),
            config: postModeConfig(),
            transcriptionCoordinator: TranscriptionCoordinator(),
            meetingMicRecorder: micRecorder,
            systemAudioRecorder: ThrowingCaptureFirstSystemRecorder(),
            systemAudioStartTimeout: 1
        )

        do {
            try await session.start()
            Issue.record("Expected injected system audio failure")
        } catch CaptureFirstTestError.expectedSystemAudioFailure {
            // Expected.
        }

        #expect(!micRecorder.didStart)
        #expect(micRecorder.didCancel)
        #expect(!session.isRecording)
    }

    @Test("post mode records before optional Parakeet preparation completes")
    func postModeRecordsBeforeLivePartialsAreReady() async throws {
        let micRecorder = CaptureFirstMicRecorder()
        let systemRecorder = CaptureFirstSystemRecorder()
        let micEngine = CaptureFirstPartialEngine()
        let systemEngine = CaptureFirstPartialEngine()
        let factory = BlockingPartialEngineFactory(mic: micEngine, system: systemEngine)
        var config = postModeConfig()
        config.enableLiveStreamingPartials = true
        let session = MeetingSession(
            title: "Capture first",
            calendarEventID: nil,
            backend: .gigaAMV3Russian,
            runtime: testRuntime(),
            config: config,
            transcriptionCoordinator: TranscriptionCoordinator(),
            meetingMicRecorder: micRecorder,
            systemAudioRecorder: systemRecorder,
            livePartialEngineFactory: { try await factory.makeEngines() }
        )

        try await session.start()

        #expect(micRecorder.didStart)
        #expect(systemRecorder.didStart)
        #expect(session.isRecording)
        #expect(await waitUntil { await factory.hasStarted() })

        session.discard()
        await factory.release()

        #expect(await waitUntil {
            micEngine.didShutdown && systemEngine.didShutdown
        })
    }

    @Test("post mode persists stopped audio before required backend preload")
    func postModePersistsBeforePreload() async throws {
        let micRecorder = CaptureFirstMicRecorder()
        let systemRecorder = CaptureFirstSystemRecorder()
        let order = CaptureFirstOrderState()
        let session = MeetingSession(
            title: "Persist first",
            calendarEventID: nil,
            backend: .gigaAMV3Russian,
            runtime: testRuntime(),
            config: postModeConfig(),
            transcriptionCoordinator: TranscriptionCoordinator(),
            meetingMicRecorder: micRecorder,
            systemAudioRecorder: systemRecorder,
            postModePreload: { _ in
                await order.notePreload(
                    micStopped: !micRecorder.isRecording,
                    systemStopped: !systemRecorder.isRecording
                )
                throw CaptureFirstTestError.expectedPreloadFailure
            }
        )
        session.onPostMeetingRecordingReady = { _ in
            await order.notePersisted()
            return nil
        }

        try await session.start()
        #expect(await order.preloadCount == 0)

        do {
            _ = try await session.stop()
            Issue.record("Expected injected preload failure")
        } catch CaptureFirstTestError.expectedPreloadFailure {
            // Expected: the assertion is the ordering captured by the preload hook.
        }

        #expect(await order.persistedBeforePreload)
        #expect(await order.recordersStoppedBeforePreload)
        #expect(await order.preloadCount == 1)
    }

    private func postModeConfig() -> AppConfig {
        var config = AppConfig()
        config.meetingProcessingMode = MeetingProcessingMode.post.rawValue
        config.useCoreAudioTap = false
        config.enableScreenContext = false
        config.enableMeetingTranscriptCleanup = false
        return config
    }

    private func testRuntime() -> RuntimePaths {
        RuntimePaths(
            repoRoot: FileManager.default.temporaryDirectory,
            menuIcon: nil,
            appIcon: nil,
            bundlePath: nil
        )
    }
}

private enum CaptureFirstTestError: Error {
    case expectedPreloadFailure
    case expectedSystemAudioFailure
}

private actor BlockingPartialEngineFactory {
    private let mic: MeetingStreamingPartialEngine
    private let system: MeetingStreamingPartialEngine
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(mic: MeetingStreamingPartialEngine, system: MeetingStreamingPartialEngine) {
        self.mic = mic
        self.system = system
    }

    func makeEngines() async throws -> (
        mic: MeetingStreamingPartialEngine,
        system: MeetingStreamingPartialEngine
    ) {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return (mic, system)
    }

    func hasStarted() -> Bool { started }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class CaptureFirstPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var didShutdown: Bool { state.withLock { $0 } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {}
    func process(samples: [Float]) async throws {}
    func shutdown() async { state.withLock { $0 = true } }
}

private actor CaptureFirstOrderState {
    private(set) var preloadCount = 0
    private(set) var persistedBeforePreload = false
    private(set) var recordersStoppedBeforePreload = false
    private var didPersist = false

    func notePersisted() {
        didPersist = true
    }

    func notePreload(micStopped: Bool, systemStopped: Bool) {
        preloadCount += 1
        persistedBeforePreload = didPersist
        recordersStoppedBeforePreload = micStopped && systemStopped
    }
}

private final class CaptureFirstMicRecorder: MeetingMicRecording, @unchecked Sendable {
    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    private let state = OSAllocatedUnfairLock(initialState: false)
    private let cancelState = OSAllocatedUnfairLock(initialState: false)

    var didStart: Bool { state.withLock { $0 } }
    var isRecording: Bool { state.withLock { $0 } }
    var didCancel: Bool { cancelState.withLock { $0 } }

    func prepare() throws {}
    func start() throws { state.withLock { $0 = true } }
    func pause() {}
    func resume() {}
    func stop() -> URL? {
        state.withLock { $0 = false }
        return nil
    }
    func cancel() {
        cancelState.withLock { $0 = true }
        state.withLock { $0 = false }
    }
    func currentPower() -> Float { -80 }
    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: .systemDefaultStreaming,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
    }
}

private final class HangingCaptureFirstSystemRecorder: SystemAudioCapturing, @unchecked Sendable {
    private struct State {
        var isRecording = false
        var stopCount = 0
        var continuation: CheckedContinuation<Void, Never>?
    }

    var onPCMSamples: (([Int16]) -> Void)?
    private let state = OSAllocatedUnfairLock(initialState: State())
    var isPaused = false
    var isRecording: Bool { state.withLock { $0.isRecording } }
    var stopCount: Int { state.withLock { $0.stopCount } }
    var hasPendingStart: Bool { state.withLock { $0.continuation != nil } }

    func start() async throws {
        await withCheckedContinuation { continuation in
            state.withLock { $0.continuation = continuation }
        }
        state.withLock { $0.isRecording = true }
    }

    func releaseStart() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func pause() { isPaused = true }
    func resume() { isPaused = false }
    func stop() -> URL? {
        state.withLock { state in
            state.stopCount += 1
            state.isRecording = false
        }
        isPaused = false
        onPCMSamples = nil
        return nil
    }
}

private final class ThrowingCaptureFirstSystemRecorder: SystemAudioCapturing, @unchecked Sendable {
    var onPCMSamples: (([Int16]) -> Void)?
    var isRecording = false
    var isPaused = false

    func start() async throws { throw CaptureFirstTestError.expectedSystemAudioFailure }
    func pause() {}
    func resume() {}
    func stop() -> URL? { nil }
}

private final class CaptureFirstSystemRecorder: SystemAudioCapturing, @unchecked Sendable {
    var onPCMSamples: (([Int16]) -> Void)?
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isRecording: Bool { state.withLock { $0 } }
    var isPaused = false
    var didStart: Bool { state.withLock { $0 } }

    func start() async throws { state.withLock { $0 = true } }
    func pause() { isPaused = true }
    func resume() { isPaused = false }
    func stop() -> URL? {
        state.withLock { $0 = false }
        isPaused = false
        onPCMSamples = nil
        return nil
    }
}

private final class BlockingCaptureFirstMicRecorder: MeetingMicRecording, @unchecked Sendable {
    private struct State {
        var hasEnteredStart = false
        var isRecording = false
        var cancelCount = 0
    }

    var preferredInputDeviceID: AudioObjectID?
    var onRawPCMSamples: (([Int16]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let startGate = DispatchSemaphore(value: 0)
    var hasEnteredStart: Bool { state.withLock { $0.hasEnteredStart } }
    var isRecording: Bool { state.withLock { $0.isRecording } }
    var cancelCount: Int { state.withLock { $0.cancelCount } }

    func prepare() throws {}
    func start() throws {
        state.withLock { $0.hasEnteredStart = true }
        startGate.wait()
        state.withLock { $0.isRecording = true }
    }
    func releaseStart() { startGate.signal() }
    func pause() {}
    func resume() {}
    func stop() -> URL? {
        state.withLock { $0.isRecording = false }
        return nil
    }
    func cancel() {
        state.withLock { state in
            state.cancelCount += 1
            state.isRecording = false
        }
    }
    func currentPower() -> Float { -80 }
    func diagnosticsSnapshot() -> MeetingMicRecorderDiagnosticsSnapshot {
        MeetingMicRecorderDiagnosticsSnapshot(
            recorderKind: .systemDefaultStreaming,
            preferredInputDeviceID: preferredInputDeviceID,
            route: nil
        )
    }
}

private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
