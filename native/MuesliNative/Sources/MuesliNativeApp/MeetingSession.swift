import FluidAudio
import Atomics
import ApplicationServices
import Foundation
import MuesliCore
import os

final class MeetingChunkCollector {
    private struct PendingTask {
        let id: UUID
        let sequence: Int
        let task: Task<[SpeechSegment], Never>
    }

    private struct State {
        // Only in-flight tasks live here. Completed tasks are retired into
        // completedSegments so Task objects and their captured state don't
        // accumulate for the full meeting duration.
        var pendingTasks: [PendingTask] = []
        var completedSegments: [SpeechSegment] = []
        var nextSequence = 0
        var nextLiveSequenceToEmit = 0
        var completedLiveChunks: [Int: [SpeechSegment]] = [:]
        var retiredChunkCount = 0
        var isClosed = false
    }

    struct Snapshot: Equatable {
        let registeredChunkCount: Int
        let retiredChunkCount: Int
        let pendingChunkCount: Int
        let bufferedLiveChunkCount: Int
    }

    private enum DrainPoll {
        case ready([(Int, [SpeechSegment])])
        case waiting
        case timedOut
    }

    private final class DrainResults: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [(Int, [SpeechSegment])] = []
        private var lastProgress = Date()

        func append(sequence: Int, segments: [SpeechSegment]) {
            lock.withLock {
                chunks.append((sequence, segments))
                lastProgress = Date()
            }
        }

        func poll(inactivityTimeout: TimeInterval) -> DrainPoll {
            lock.withLock {
                if !chunks.isEmpty {
                    let result = chunks.sorted { $0.0 < $1.0 }
                    chunks.removeAll(keepingCapacity: true)
                    return .ready(result)
                }
                if Date().timeIntervalSince(lastProgress) >= inactivityTimeout {
                    return .timedOut
                }
                return .waiting
            }
        }
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Register a transcription task. Returns the retire ID to pass to retire(id:segments:)
    /// once the task completes.
    func add(_ task: Task<[SpeechSegment], Never>) -> (registered: Bool, retireID: UUID) {
        let id = UUID()
        let registered = lock.withLock { state in
            guard !state.isClosed else { return false }
            let sequence = state.nextSequence
            state.nextSequence += 1
            state.pendingTasks.append(PendingTask(id: id, sequence: sequence, task: task))
            return true
        }
        return (registered, id)
    }

    /// Move a completed task's result into the collector and drop the Task reference.
    /// Must be called from the watcher Task after awaiting the transcription task's value.
    func retire(id: UUID, segments: [SpeechSegment]) -> [[SpeechSegment]]? {
        lock.withLock { state in
            guard !state.isClosed else { return nil }
            guard let pending = state.pendingTasks.first(where: { $0.id == id }) else {
                return nil
            }
            state.completedSegments.append(contentsOf: segments)
            state.pendingTasks.removeAll { $0.id == id }
            state.retiredChunkCount += 1

            state.completedLiveChunks[pending.sequence] = segments
            var readyChunks: [[SpeechSegment]] = []
            while let ready = state.completedLiveChunks.removeValue(forKey: state.nextLiveSequenceToEmit) {
                readyChunks.append(ready)
                state.nextLiveSequenceToEmit += 1
            }
            return readyChunks
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock { state in
            Snapshot(
                registeredChunkCount: state.nextSequence,
                retiredChunkCount: state.retiredChunkCount,
                pendingChunkCount: state.pendingTasks.count,
                bufferedLiveChunkCount: state.completedLiveChunks.count
            )
        }
    }

    func closeAndDrainSortedSegments(
        inactivityTimeout: TimeInterval = 120,
        logger: ((String) -> Void)? = nil,
        onDrainTimeoutDroppedChunkCount: ((Int) -> Void)? = nil
    ) async -> [SpeechSegment] {
        let (tasksToAwait, alreadyCompleted) = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks
            let completed = state.completedSegments
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            state.completedLiveChunks.removeAll()
            return (tasks, completed)
        }

        var segments = alreadyCompleted
        guard !tasksToAwait.isEmpty else { return Self.sorted(segments) }

        let drainResults = DrainResults()
        let watcherTasks = tasksToAwait.map { pending in
            Task {
                let chunkSegments = await pending.task.value
                drainResults.append(sequence: pending.sequence, segments: chunkSegments)
            }
        }

        var remainingTaskCount = tasksToAwait.count
        var pendingSequences = Set(tasksToAwait.map(\.sequence))
        drainLoop: while remainingTaskCount > 0 {
            switch drainResults.poll(inactivityTimeout: inactivityTimeout) {
            case .ready(let ready):
                for (sequence, chunkSegments) in ready {
                    segments.append(contentsOf: chunkSegments)
                    pendingSequences.remove(sequence)
                }
                remainingTaskCount -= ready.count

            case .timedOut:
                tasksToAwait.forEach { $0.task.cancel() }
                watcherTasks.forEach { $0.cancel() }
                logger?("[live-collector] drain timeout pending=\(remainingTaskCount) flushedSegments=\(segments.count)")
                onDrainTimeoutDroppedChunkCount?(pendingSequences.count)
                for sequence in pendingSequences.sorted() {
                    logger?("[live-collector] dropped pending chunk sequence=\(sequence) reason=drain_timeout")
                }
                break drainLoop

            case .waiting:
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        return Self.sorted(segments)
    }

    private static func sorted(_ segments: [SpeechSegment]) -> [SpeechSegment] {
        segments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
    }

    func cancelAll() {
        let tasksToCancel = lock.withLock { state in
            state.isClosed = true
            let tasks = state.pendingTasks.map { $0.task }
            state.pendingTasks.removeAll()
            state.completedSegments.removeAll()
            state.completedLiveChunks.removeAll()
            return tasks
        }
        tasksToCancel.forEach { $0.cancel() }
    }
}

struct MeetingSessionResult {
    let title: String
    let originalTitle: String
    let calendarEventID: String?
    let startTime: Date
    let endTime: Date
    let durationSeconds: Double
    let rawTranscript: String
    let rawOriginalTranscript: String?
    let formattedNotes: String
    let retainedRecordingURL: URL?
    let retainedRecordingError: Error?
    let retainedRecordingSavedURL: URL?
    let systemRecordingURL: URL?
    let sourceMicRecordingURL: URL?
    let sourceSystemRecordingURL: URL?
    let templateSnapshot: MeetingTemplateSnapshot
    let liveCollectorDrainTimeoutDroppedChunkCount: Int

    init(
        title: String,
        originalTitle: String,
        calendarEventID: String?,
        startTime: Date,
        endTime: Date,
        durationSeconds: Double,
        rawTranscript: String,
        rawOriginalTranscript: String? = nil,
        formattedNotes: String,
        retainedRecordingURL: URL?,
        retainedRecordingError: Error?,
        retainedRecordingSavedURL: URL? = nil,
        systemRecordingURL: URL?,
        sourceMicRecordingURL: URL? = nil,
        sourceSystemRecordingURL: URL? = nil,
        templateSnapshot: MeetingTemplateSnapshot,
        liveCollectorDrainTimeoutDroppedChunkCount: Int = 0
    ) {
        self.title = title
        self.originalTitle = originalTitle
        self.calendarEventID = calendarEventID
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = durationSeconds
        self.rawTranscript = rawTranscript
        self.rawOriginalTranscript = rawOriginalTranscript
        self.formattedNotes = formattedNotes
        self.retainedRecordingURL = retainedRecordingURL
        self.retainedRecordingError = retainedRecordingError
        self.retainedRecordingSavedURL = retainedRecordingSavedURL
        self.systemRecordingURL = systemRecordingURL
        self.sourceMicRecordingURL = sourceMicRecordingURL
        self.sourceSystemRecordingURL = sourceSystemRecordingURL
        self.templateSnapshot = templateSnapshot
        self.liveCollectorDrainTimeoutDroppedChunkCount = liveCollectorDrainTimeoutDroppedChunkCount
    }
}

struct RetainedMeetingRecordingFinalizeRequest: Sendable {
    let tempURL: URL
    let meetingTitle: String
    let startedAt: Date
}

struct PostMeetingRecordingFinalizeRequest: Sendable {
    let sourceTracks: MeetingSourceTrackRecording
    let mixedTempURL: URL?
    let meetingTitle: String
    let startedAt: Date
}

struct PersistedPostMeetingRecording: Sendable {
    let micURL: URL?
    let systemURL: URL?
    let mixedURL: URL?
}

enum MeetingProcessingStage {
    case transcribingAudio
    case cleaningAudio
    case generatingTitle
    case summarizingNotes
}

private enum MeetingTranscriptRecoveryResult: Sendable {
    case none
    case append([SpeechSegment])
    case replace([SpeechSegment])
}

private enum MeetingStopPhaseTimeouts {
    static let finalChunkTranscription: TimeInterval = 120
    static let collectorDrain: TimeInterval = 130
    static let systemDiarization: TimeInterval = 180
    static let systemSegmentRepair: TimeInterval = 180
    static let transcriptCleanup: TimeInterval = 120
    static let liveTitle: TimeInterval = 5
    static let titleGeneration: TimeInterval = 60
    static let screenContextDrain: TimeInterval = 15
    static let manualNotes: TimeInterval = 15
    static let summaryGeneration: TimeInterval = 180
}

private enum MeetingStopPhaseError: LocalizedError, Sendable {
    case timedOut(phase: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let phase, let seconds):
            return "\(phase) timed out after \(String(format: "%.1f", seconds))s"
        }
    }
}

private struct MeetingStopDiarizationResult: Sendable {
    let samples: [Float]
    let segments: [TimedSpeakerSegment]?
}

private struct MeetingStopDrainResult: Sendable {
    let segments: [SpeechSegment]
    let droppedChunkCount: Int
}

struct LiveMeetingChunkingConfiguration: Equatable, Sendable {
    static let defaultSampleRate = 16_000

    let minChunkDuration: TimeInterval
    let maxChunkDuration: TimeInterval
    let overlapSampleCount: Int
    let deduplicatesText: Bool

    static func configuration(for backend: BackendOption) -> LiveMeetingChunkingConfiguration {
        if backend.backend == BackendOption.gigaAMV3Russian.backend
            || backend.backend == BackendOption.sherpaGigaAMRNNT.backend {
            return LiveMeetingChunkingConfiguration(
                minChunkDuration: 3.0,
                maxChunkDuration: 20.0,
                overlapSampleCount: 2 * defaultSampleRate,
                deduplicatesText: true
            )
        }

        return LiveMeetingChunkingConfiguration(
            minChunkDuration: 3.0,
            maxChunkDuration: 5.0,
            overlapSampleCount: 0,
            deduplicatesText: false
        )
    }
}

final class MeetingSession {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingSession")

    private let title: String
    private let calendarEventID: String?
    private let liveMeetingID: Int64?
    private let participantCandidates: [MeetingParticipant]
    private let backendLock = OSAllocatedUnfairLock(initialState: BackendOption.whisper)
    private let runtime: RuntimePaths
    private let config: AppConfig
    private var liveChunkingConfiguration: LiveMeetingChunkingConfiguration
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let transcriptCleaner: any MeetingTranscriptCleaning
    private let systemAudioRecorder: SystemAudioCapturing
    private let neuralAec = MeetingNeuralAec()

    /// Route-aware mic recorder with real-time 16 kHz mono PCM access.
    private var meetingMicRecorder: MeetingMicRecording
    private var rawMicChunkRecorder: PCMChunkRecorder?
    private var retainedRecordingWriter: MeetingRecordingWriter?
    private var retainedRecordingWriterError: Error?
    private var retainedRecordingWriterFactory: (Int64?) throws -> MeetingRecordingWriter = { meetingID in
        try MeetingRecordingWriter(meetingID: meetingID)
    }
    private var postModeTrackWriter: MeetingDualTrackRecordingWriter?
    private var postModeTrackWriterFactory: (Int64?, Date) throws -> MeetingDualTrackRecordingWriter = { meetingID, startedAt in
        try MeetingDualTrackRecordingWriter(meetingID: meetingID, startedAt: startedAt)
    }
    /// VAD controller for speech-boundary chunk rotation
    private var vadController: StreamingVadController?
    private var systemVadController: StreamingVadController?
    private let micChunkCollector = MeetingChunkCollector()
    private let systemChunkCollector = MeetingChunkCollector()
    private let micChunkHealthTracker = MeetingTranscriptChunkHealthTracker()
    private let systemChunkHealthTracker = MeetingTranscriptChunkHealthTracker()
    private let micHealthTracker = MeetingMicHealthTracker()
    private let speakerObservationLock = OSAllocatedUnfairLock(initialState: [MeetSpeakerObservation]())
    private let chunkRotationQueue = DispatchQueue(label: "MuesliNative.MeetingSession.chunkRotation")
    private let pausedDisplayLock = OSAllocatedUnfairLock(initialState: false)
    private let stopIntakeRequested = ManagedAtomic(false)
    private var chunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkTimingTracker = MeetingChunkTimingTracker()
    private var systemChunkRecorder: PCMChunkRecorder?
    var onProgress: ((MeetingProcessingStage) -> Void)?
    var onMicHealthChanged: ((MeetingMicHealthSnapshot) -> Void)?
    var manualNotesProvider: (() async -> String?)?
    var liveTitleProvider: (() async -> String?)?
    var onRetainedRecordingReady: ((RetainedMeetingRecordingFinalizeRequest) async throws -> URL?)?
    var onPostMeetingRecordingReady: ((PostMeetingRecordingFinalizeRequest) async throws -> PersistedPostMeetingRecording?)?
    var onChunkTranscribed: (([SpeechSegment], String) -> Void)?
    private let screenContextCollector = MeetingScreenContextCollector()
    private var diagnostics: MeetingSessionDiagnostics?

    /// Current mic power level for waveform visualization.
    func currentPower() -> Float {
        if pausedDisplayLock.withLock({ $0 }) {
            return -160
        }
        return meetingMicRecorder.currentPower()
    }

    private(set) var startTime: Date?
    private(set) var isRecording = false
    private(set) var isPaused = false

    private func setPausedStateOnQueue(_ paused: Bool) {
        isPaused = paused
        pausedDisplayLock.withLock { $0 = paused }
    }

    init(
        title: String,
        calendarEventID: String?,
        liveMeetingID: Int64? = nil,
        participantCandidates: [MeetingParticipant] = [],
        backend: BackendOption,
        runtime: RuntimePaths,
        config: AppConfig,
        transcriptionCoordinator: TranscriptionCoordinator,
        transcriptCleaner: any MeetingTranscriptCleaning = ChatGPTMeetingTranscriptCleaner(),
        meetingMicRecorder: MeetingMicRecording = RouteAwareMeetingMicRecorder(),
        systemAudioRecorder: SystemAudioCapturing? = nil
    ) {
        self.title = title
        self.calendarEventID = calendarEventID
        self.liveMeetingID = liveMeetingID
        self.participantCandidates = participantCandidates
        backendLock.withLock { $0 = backend }
        self.runtime = runtime
        self.config = config
        self.liveChunkingConfiguration = Self.liveChunkingConfiguration(for: backend)
        self.transcriptionCoordinator = transcriptionCoordinator
        self.transcriptCleaner = transcriptCleaner
        self.meetingMicRecorder = meetingMicRecorder
        if let systemAudioRecorder {
            self.systemAudioRecorder = systemAudioRecorder
        } else if config.useCoreAudioTap {
            self.systemAudioRecorder = CoreAudioSystemRecorder()
        } else {
            self.systemAudioRecorder = SystemAudioRecorder()
        }
    }

    @discardableResult
    func updateBackend(_ backend: BackendOption) -> Bool {
        chunkRotationQueue.sync {
            guard !isRecording else { return false }
            backendLock.withLock { $0 = backend }
            liveChunkingConfiguration = Self.liveChunkingConfiguration(for: backend)
            return true
        }
    }

    func recordSpeakerObservation(_ observation: MeetSpeakerObservation) {
        guard isRecording else { return }
        speakerObservationLock.withLock { observations in
            observations.append(observation)
            if observations.count > 2000 {
                observations.removeFirst(observations.count - 2000)
            }
        }
    }

    func speakerObservationStats() -> MeetSpeakerObservationStats {
        speakerObservationLock.withLock { MeetSpeakerObservationStats.make(from: $0) }
    }

    private func currentBackend() -> BackendOption {
        backendLock.withLock { $0 }
    }

    static func liveChunkingConfiguration(for backend: BackendOption) -> LiveMeetingChunkingConfiguration {
        LiveMeetingChunkingConfiguration.configuration(for: backend)
    }

#if DEBUG
    var onStopPhaseForTesting: ((String) -> Void)?

    func setRecordingForTesting(_ recording: Bool) {
        chunkRotationQueue.sync {
            isRecording = recording
        }
    }

    func speakerObservationsForTesting() -> [MeetSpeakerObservation] {
        speakerObservationLock.withLock { $0 }
    }

    func currentBackendForTesting() -> BackendOption {
        currentBackend()
    }

    func enqueueRealtimeMicSamplesForTesting(_ samples: [Int16]) {
        enqueueRealtimeMicSamples(samples)
    }

    func enqueueRealtimeSystemSamplesForTesting(_ samples: [Int16]) {
        enqueueRealtimeSystemSamples(samples)
    }

    func enqueueChunkRotationPauseForTesting(started: @escaping @Sendable () -> Void, release: DispatchSemaphore) {
        chunkRotationQueue.async {
            started()
            release.wait()
        }
    }

    func setRetainedRecordingWriterForTesting(_ writer: MeetingRecordingWriter?) {
        retainedRecordingWriter = writer
        retainedRecordingWriterError = nil
    }

    func setRetainedRecordingWriterFactoryForTesting(_ factory: @escaping (Int64?) throws -> MeetingRecordingWriter) {
        retainedRecordingWriterFactory = factory
    }

    var stopIntakeRequestedForTesting: Bool {
        stopIntakeRequested.load(ordering: .acquiring)
    }
#endif

    private func noteStopPhaseForTesting(_ phase: String) {
#if DEBUG
        onStopPhaseForTesting?(phase)
#endif
    }

    private func withStopPhaseTimeout<Value: Sendable>(
        _ phase: String,
        timeout seconds: TimeInterval,
        operation: @escaping () async throws -> Value
    ) async throws -> Value {
        noteStopPhaseForTesting(phase)
        let boundedSeconds = min(max(seconds, 0.001), 86_400)
        let nanoseconds = UInt64(boundedSeconds * 1_000_000_000)

        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw MeetingStopPhaseError.timedOut(phase: phase, seconds: boundedSeconds)
            }

            do {
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func stopPhaseValue<Value: Sendable>(
        _ phase: String,
        timeout seconds: TimeInterval,
        fallback: @autoclosure () -> Value,
        operation: @escaping () async throws -> Value
    ) async -> Value {
        do {
            return try await withStopPhaseTimeout(phase, timeout: seconds, operation: operation)
        } catch {
            logStopPhaseFailure(phase, timeout: seconds, error: error)
            return fallback()
        }
    }

    private func logStopPhaseFailure(_ phase: String, timeout seconds: TimeInterval, error: Error) {
        let outcome: String
        if case .timedOut = error as? MeetingStopPhaseError {
            outcome = "timed_out"
        } else {
            outcome = "failed"
        }
        DiagnosticsLog.write(
            "[meeting-stop] \(outcome) phase=\(phase) timeout=\(String(format: "%.1f", seconds))s error=\(error.localizedDescription)"
        )
    }

    func start() async throws {
        let vadManager = await transcriptionCoordinator.getVadManager()
        let now = Date()
        diagnostics = MeetingSessionDiagnostics(title: title, startedAt: now)
        stopIntakeRequested.store(false, ordering: .releasing)

        if config.resolvedMeetingProcessingMode == .post {
            try await startPostProcessingMode(startedAt: now)
            return
        }

        // AEC must be loaded before audio pipeline starts (streaming mode)
        await neuralAec.preload()

        chunkRotationQueue.sync {
            startTime = now
            chunkTimingTracker.start()
            systemChunkTimingTracker.start()
            isRecording = true
            setPausedStateOnQueue(false)
        }

        do {
            try prepareRealtimeAudioPipeline(vadManager: vadManager)
            try meetingMicRecorder.prepare()
            try setupRetainedRecordingWriterIfNeeded()
            try await systemAudioRecorder.start()
            try meetingMicRecorder.start()
        } catch {
            vadController?.stop()
            vadController = nil
            systemVadController?.stop()
            systemVadController = nil
            stopIntakeRequested.store(true, ordering: .releasing)
            meetingMicRecorder.onRawPCMSamples = nil
            systemAudioRecorder.onPCMSamples = nil
            retainedRecordingWriter?.cancel()
            retainedRecordingWriter = nil
            rawMicChunkRecorder?.cancel()
            rawMicChunkRecorder = nil
            systemChunkRecorder?.cancel()
            systemChunkRecorder = nil
            chunkRotationQueue.sync {
                isRecording = false
                setPausedStateOnQueue(false)
                startTime = nil
                chunkTimingTracker.discard()
                systemChunkTimingTracker.discard()
            }
            meetingMicRecorder.cancel()
            if let url = systemAudioRecorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
            systemChunkCollector.cancelAll()
            throw error
        }
        if vadController != nil {
            fputs("[meeting] started with VAD-driven chunk rotation\n", stderr)
        } else {
            fputs("[meeting] VAD not available, using max-duration fallback only\n", stderr)
        }
        if config.enableScreenContext && CGPreflightScreenCaptureAccess() {
            // OCR screenshots are safe when using CoreAudio tap (no SCStream conflict)
            await screenContextCollector.startPeriodicCapture(useOCR: config.useCoreAudioTap)
        }
    }

    private func startPostProcessingMode(startedAt now: Date) async throws {
        chunkRotationQueue.sync {
            startTime = now
            isRecording = true
            setPausedStateOnQueue(false)
        }

        do {
            postModeTrackWriter = try postModeTrackWriterFactory(liveMeetingID, now)
            meetingMicRecorder.onRawPCMSamples = { [weak self] samples in
                self?.enqueuePostModeMicSamples(samples)
            }
            systemAudioRecorder.onPCMSamples = { [weak self] samples in
                self?.enqueuePostModeSystemSamples(samples)
            }
            try meetingMicRecorder.prepare()
            try await systemAudioRecorder.start()
            try meetingMicRecorder.start()
        } catch {
            stopIntakeRequested.store(true, ordering: .releasing)
            meetingMicRecorder.onRawPCMSamples = nil
            systemAudioRecorder.onPCMSamples = nil
            postModeTrackWriter?.cancel()
            postModeTrackWriter = nil
            chunkRotationQueue.sync {
                isRecording = false
                setPausedStateOnQueue(false)
                startTime = nil
            }
            meetingMicRecorder.cancel()
            if let url = systemAudioRecorder.stop() {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        fputs("[meeting] started in post-processing mode; live ASR disabled\n", stderr)
        if config.enableScreenContext && CGPreflightScreenCaptureAccess() {
            await screenContextCollector.startPeriodicCapture(useOCR: config.useCoreAudioTap)
        }
    }

    func pause() {
        let shouldPause = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, !isPaused else { return false }
            if config.resolvedMeetingProcessingMode == .live {
                appendFlushedStreamingMicOnQueue()
                rotateChunkOnQueue()
                rotateSystemChunkOnQueue()
                retainedRecordingWriter?.markPauseBoundary()
                neuralAec.resetForStreaming()
            }
            setPausedStateOnQueue(true)
            return true
        }
        guard shouldPause else { return }

        meetingMicRecorder.pause()
        systemAudioRecorder.pause()
        Task { await screenContextCollector.setPaused(true) }
        fputs("[meeting] recording paused\n", stderr)
    }

    func resume() {
        let shouldResume = chunkRotationQueue.sync { () -> Bool in
            guard isRecording, isPaused else { return false }
            setPausedStateOnQueue(false)
            return true
        }
        guard shouldResume else { return }

        meetingMicRecorder.resume()
        systemAudioRecorder.resume()
        Task { await screenContextCollector.setPaused(false) }
        fputs("[meeting] recording resumed\n", stderr)
    }

    /// Abandon the recording — stop everything, delete temp files, don't transcribe.
    func discard() {
        stopIntakeRequested.store(true, ordering: .releasing)
        Task { await screenContextCollector.stopAndDrain() }
        let (rawRecorder, systemRecorder) = chunkRotationQueue.sync { () -> (PCMChunkRecorder?, PCMChunkRecorder?) in
            isRecording = false
            setPausedStateOnQueue(false)
            chunkTimingTracker.discard()
            systemChunkTimingTracker.discard()
            let rawRecorder = rawMicChunkRecorder
            let systemRecorder = systemChunkRecorder
            rawMicChunkRecorder = nil
            systemChunkRecorder = nil
            return (rawRecorder, systemRecorder)
        }
        vadController?.stop()
        vadController = nil
        systemVadController?.stop()
        systemVadController = nil
        retainedRecordingWriter?.cancel()
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil
        postModeTrackWriter?.cancel()
        postModeTrackWriter = nil
        rawRecorder?.cancel()
        systemRecorder?.cancel()
        meetingMicRecorder.onRawPCMSamples = nil
        meetingMicRecorder.cancel()
        systemAudioRecorder.onPCMSamples = nil
        if let url = systemAudioRecorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        micChunkCollector.cancelAll()
        systemChunkCollector.cancelAll()
        fputs("[meeting] recording discarded\n", stderr)
    }

    func stop() async throws -> MeetingSessionResult {
        onProgress?(.transcribingAudio)
        let endTime = Date()
        if config.resolvedMeetingProcessingMode == .post {
            return try await stopPostProcessingMode(endTime: endTime)
        }
        var micSegments: [SpeechSegment] = []
        var systemSegments: [SpeechSegment] = []
        var didWriteStopCounters = false
        func writeStopCountersOnce() {
            guard !didWriteStopCounters else { return }
            didWriteStopCounters = true
            let micCollectorSnapshot = micChunkCollector.snapshot()
            let systemCollectorSnapshot = systemChunkCollector.snapshot()
            let micHealthSnapshot = micChunkHealthTracker.snapshot()
            let systemHealthSnapshot = systemChunkHealthTracker.snapshot()
            DiagnosticsLog.write(
                "[live-collector] stop mic registered=\(micCollectorSnapshot.registeredChunkCount) retired=\(micCollectorSnapshot.retiredChunkCount) pending=\(micCollectorSnapshot.pendingChunkCount) buffered=\(micCollectorSnapshot.bufferedLiveChunkCount) failed=\(micHealthSnapshot.failedChunkCount); system registered=\(systemCollectorSnapshot.registeredChunkCount) retired=\(systemCollectorSnapshot.retiredChunkCount) pending=\(systemCollectorSnapshot.pendingChunkCount) buffered=\(systemCollectorSnapshot.bufferedLiveChunkCount) failed=\(systemHealthSnapshot.failedChunkCount)"
            )
        }
        defer { writeStopCountersOnce() }

        noteStopPhaseForTesting("stop_requested")
        vadController?.stop()
        vadController = nil
        systemVadController?.stop()
        systemVadController = nil
        meetingMicRecorder.onRawPCMSamples = nil
        systemAudioRecorder.onPCMSamples = nil
        noteStopPhaseForTesting("mic_recorder_stop")
        let rawStreamingMicURL = meetingMicRecorder.stop()
        noteStopPhaseForTesting("system_recorder_stop")
        let systemAudioURL = systemAudioRecorder.stop()
        let (meetingStart, lastChunkTiming, lastRawMicURL, lastSystemChunkTiming, lastSystemChunkURL) = chunkRotationQueue.sync { () -> (Date, MeetingChunkTimingSnapshot?, URL?, MeetingChunkTimingSnapshot?, URL?) in
            noteStopPhaseForTesting("chunk_queue_finalize")
            isRecording = false
            setPausedStateOnQueue(false)

            // Flush partial AEC frame before stopping chunk recorder
            appendFlushedStreamingMicOnQueue()

            let meetingStart = self.startTime ?? Date()
            let lastRawMicURL = rawMicChunkRecorder?.stop()
            let lastSystemChunkURL = systemChunkRecorder?.stop()
            rawMicChunkRecorder = nil
            systemChunkRecorder = nil
            let lastChunkTiming = chunkTimingTracker.finish()
            let lastSystemChunkTiming = systemChunkTimingTracker.finish()
            return (meetingStart, lastChunkTiming, lastRawMicURL, lastSystemChunkTiming, lastSystemChunkURL)
        }
        stopIntakeRequested.store(true, ordering: .releasing)
        let retainedRecordingTempURL = retainedRecordingWriter?.stop()
        retainedRecordingWriter = nil
        let retainedRecordingSavedURL = await finalizeRetainedRecordingEarly(
            tempURL: retainedRecordingTempURL,
            meetingStart: meetingStart
        )
        let retainedRecordingURL = retainedRecordingSavedURL == nil ? retainedRecordingTempURL : nil
        defer {
            if let rawStreamingMicURL {
                try? FileManager.default.removeItem(at: rawStreamingMicURL)
            }
        }

        writeStopCountersOnce()

        // Transcribe last mic chunk
        let finalMicSegments = await stopPhaseValue(
            "final_mic_chunk_transcription",
            timeout: MeetingStopPhaseTimeouts.finalChunkTranscription,
            fallback: []
        ) {
            await self.transcribeMicChunk(
                rawURL: lastRawMicURL,
                chunkTiming: lastChunkTiming,
                isFinalChunk: true
            )
        }
        micSegments.append(contentsOf: finalMicSegments)

        if let lastSystemChunkURL {
            let chunkOffset = lastSystemChunkTiming?.startTimeSeconds ?? 0
            let chunkDuration = lastSystemChunkTiming?.durationSeconds ?? 0
            fputs("[meeting] transcribing final system chunk (offset=\(String(format: "%.0f", chunkOffset))s)\n", stderr)
            do {
                let result = try await withStopPhaseTimeout(
                    "final_system_chunk_transcription",
                    timeout: MeetingStopPhaseTimeouts.finalChunkTranscription
                ) {
                    try await self.transcriptionCoordinator.transcribeMeetingChunk(
                        at: lastSystemChunkURL,
                        backend: self.currentBackend(),
                        cohereLanguage: self.config.resolvedCohereLanguageMeetings
                    )
                }
                let normalizedSegments = normalizeSystemTranscription(
                    result: result,
                    startTime: chunkOffset,
                    endTime: chunkOffset + max(chunkDuration, 0.1)
                )
                if normalizedSegments.isEmpty {
                    systemChunkHealthTracker.noteEmptyChunk()
                } else {
                    systemChunkHealthTracker.noteSuccessfulChunk()
                }
                systemSegments.append(contentsOf: normalizedSegments)
            } catch {
                systemChunkHealthTracker.noteFailedChunk()
                logStopPhaseFailure(
                    "final_system_chunk_transcription",
                    timeout: MeetingStopPhaseTimeouts.finalChunkTranscription,
                    error: error
                )
                DiagnosticsLog.write("[live-collector] final system chunk failed offset=\(String(format: "%.1f", chunkOffset)) duration=\(String(format: "%.1f", chunkDuration)) error=\(error.localizedDescription)")
                fputs("[meeting] final system chunk transcription failed: \(error)\n", stderr)
            }
            try? FileManager.default.removeItem(at: lastSystemChunkURL)
        }

        var systemAudioSamples: [Float]?
        var diarizationSegments: [TimedSpeakerSegment]?
        if let systemAudioURL {
            let diarizationResult = await stopPhaseValue(
                "system_diarization",
                timeout: MeetingStopPhaseTimeouts.systemDiarization,
                fallback: Optional<MeetingStopDiarizationResult>.none
            ) {
                guard let diarizerManager = await self.transcriptionCoordinator.getDiarizerManager(),
                      diarizerManager.isAvailable else {
                    return nil
                }
                let samples = try AudioConverter().resampleAudioFile(systemAudioURL)
                let result = try await self.transcriptionCoordinator.diarizeSystemAudio(samples: samples)
                return MeetingStopDiarizationResult(samples: samples, segments: result?.segments)
            }
            systemAudioSamples = diarizationResult?.samples
            diarizationSegments = diarizationResult?.segments
        }

        var drainTimeoutDroppedChunkCount = 0
        let micDrainFallbackDroppedCount = micChunkCollector.snapshot().pendingChunkCount
        let micDrainResult = await stopPhaseValue(
            "mic_collector_drain",
            timeout: MeetingStopPhaseTimeouts.collectorDrain,
            fallback: MeetingStopDrainResult(segments: [], droppedChunkCount: micDrainFallbackDroppedCount)
        ) {
            var droppedChunkCount = 0
            let segments = await self.micChunkCollector.closeAndDrainSortedSegments(
                logger: { DiagnosticsLog.write($0) },
                onDrainTimeoutDroppedChunkCount: { droppedChunkCount += $0 }
            )
            return MeetingStopDrainResult(segments: segments, droppedChunkCount: droppedChunkCount)
        }
        drainTimeoutDroppedChunkCount += micDrainResult.droppedChunkCount
        micSegments.append(contentsOf: micDrainResult.segments)
        micSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        let systemDrainFallbackDroppedCount = systemChunkCollector.snapshot().pendingChunkCount
        let systemDrainResult = await stopPhaseValue(
            "system_collector_drain",
            timeout: MeetingStopPhaseTimeouts.collectorDrain,
            fallback: MeetingStopDrainResult(segments: [], droppedChunkCount: systemDrainFallbackDroppedCount)
        ) {
            var droppedChunkCount = 0
            let segments = await self.systemChunkCollector.closeAndDrainSortedSegments(
                logger: { DiagnosticsLog.write($0) },
                onDrainTimeoutDroppedChunkCount: { droppedChunkCount += $0 }
            )
            return MeetingStopDrainResult(segments: segments, droppedChunkCount: droppedChunkCount)
        }
        drainTimeoutDroppedChunkCount += systemDrainResult.droppedChunkCount
        systemSegments.append(contentsOf: systemDrainResult.segments)
        systemSegments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        if let systemAudioURL {
            let systemSegmentsBeforeRepair = systemSegments
            let systemRecovery = await stopPhaseValue(
                "system_segment_repair",
                timeout: MeetingStopPhaseTimeouts.systemSegmentRepair,
                fallback: MeetingTranscriptRecoveryResult.none
            ) {
                await self.repairSystemSegmentsIfNeeded(
                    existingSystemSegments: systemSegmentsBeforeRepair,
                    systemAudioURL: systemAudioURL,
                    systemAudioSamples: systemAudioSamples,
                    meetingStart: meetingStart,
                    endTime: endTime
                )
            }
            switch systemRecovery {
            case .none:
                break
            case .append(let repairedSystemSegments):
                systemSegments.append(contentsOf: repairedSystemSegments)
                systemSegments.sort { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            case .replace(let fallbackSystemSegments):
                systemSegments = fallbackSystemSegments.sorted { lhs, rhs in
                    if lhs.start == rhs.start {
                        return lhs.text < rhs.text
                    }
                    return lhs.start < rhs.start
                }
            }
        }
        systemAudioSamples = nil

        if liveChunkingConfiguration.deduplicatesText {
            micSegments = TranscriptOverlapMerger.deduplicateSegments(micSegments)
            systemSegments = TranscriptOverlapMerger.deduplicateSegments(systemSegments)
        }

        fputs("[meeting] \(micSegments.count) mic chunks transcribed during meeting\n", stderr)
        fputs("[meeting] \(systemSegments.count) system chunks transcribed during meeting\n", stderr)

        let reconciledTranscriptInputs = TranscriptReconciler.reconcile(
            micTurns: micSegments,
            systemSegments: systemSegments,
            diarizationSegments: diarizationSegments
        )
        let protectedTranscriptInputs = reconciledTranscriptInputs
        let speakerObservations = speakerObservationLock.withLock { $0 }
        let observedParticipants = Self.observedParticipants(from: speakerObservations)
        let allParticipantCandidates = Self.mergedParticipants(
            participantCandidates,
            observedParticipants
        )
        let speakerNameMap = Self.speakerNameMap(
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            observations: speakerObservations,
            meetingStart: meetingStart
        )

        let rawTranscript = TranscriptFormatter.merge(
            micSegments: protectedTranscriptInputs.micSegments,
            systemSegments: protectedTranscriptInputs.systemSegments,
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            speakerNameMap: speakerNameMap,
            meetingStart: meetingStart
        )
        if let reason = MeetingRetranscriptionPipeline.suspiciousTranscriptReason(
            transcript: rawTranscript,
            meetingDuration: endTime.timeIntervalSince(meetingStart),
            systemSegmentCount: systemSegments.count,
            systemCoveredDuration: MeetingRetranscriptionPipeline.coveredDuration(systemSegments)
        ) {
            DiagnosticsLog.write("[meeting] transcript quality_guard_failed \(reason)")
            throw MeetingPostProcessingError.suspiciouslyShortTranscript(reason)
        }
        let cleanupResult = await stopPhaseValue(
            "transcript_cleanup",
            timeout: MeetingStopPhaseTimeouts.transcriptCleanup,
            fallback: MeetingTranscriptCleanupResult(transcript: rawTranscript, originalTranscript: nil)
        ) {
            await MeetingTranscriptCleanupPipeline.cleanIfNeeded(
                transcript: rawTranscript,
                config: self.config,
                isChatGPTAuthenticated: ChatGPTAuthManager.shared.isAuthenticated,
                cleaner: self.transcriptCleaner
            )
        }
        let finalTranscript = cleanupResult.transcript

        let generatedTitle: String
        onProgress?(.generatingTitle)
        let liveTitle = await stopPhaseValue(
            "live_title_provider",
            timeout: MeetingStopPhaseTimeouts.liveTitle,
            fallback: Optional<String>.none
        ) {
            await self.userEditedLiveTitle()
        }
        if let liveTitle {
            generatedTitle = liveTitle
        } else if let calendarTitle = Self.calendarTitleCandidate(
            originalTitle: title,
            calendarEventID: calendarEventID
        ) {
            generatedTitle = calendarTitle
        } else {
            let autoTitle = await stopPhaseValue(
                "title_generation",
                timeout: MeetingStopPhaseTimeouts.titleGeneration,
                fallback: Optional<String>.none
            ) {
                await MeetingSummaryClient.generateTitle(transcript: finalTranscript, config: self.config)
            }
            if let autoTitle, !autoTitle.isEmpty {
                generatedTitle = autoTitle
                fputs("[meeting] auto-generated title: \(generatedTitle)\n", stderr)
            } else {
                generatedTitle = title
            }
        }

        let templateSnapshot = MeetingTemplates.resolveSnapshot(
            id: config.defaultMeetingTemplateID,
            customTemplates: config.customMeetingTemplates
        )
        let visualContext = await stopPhaseValue(
            "screen_context_drain",
            timeout: MeetingStopPhaseTimeouts.screenContextDrain,
            fallback: ""
        ) {
            await self.screenContextCollector.stopAndDrain()
        }
        let summaryContext = Self.summaryContext(
            participants: allParticipantCandidates,
            visualContext: visualContext
        )
        Self.logger.info("visual context drained chars=\(visualContext.count) includedInPrompt=\(!summaryContext.isEmpty) useOCR=\(self.config.useCoreAudioTap)")
        fputs("[meeting] visual context drained chars=\(visualContext.count) participants=\(allParticipantCandidates.count) observedParticipants=\(observedParticipants.count) includedInPrompt=\(!summaryContext.isEmpty) useOCR=\(config.useCoreAudioTap)\n", stderr)
        onProgress?(.summarizingNotes)
        let manualNotes = await stopPhaseValue(
            "manual_notes_provider",
            timeout: MeetingStopPhaseTimeouts.manualNotes,
            fallback: Optional<String>.none
        ) {
            await self.manualNotesProvider?()
        }
        let formattedNotes: String
        do {
            formattedNotes = try await withStopPhaseTimeout(
                "summary_generation",
                timeout: MeetingStopPhaseTimeouts.summaryGeneration
            ) {
                try await MeetingSummaryClient.summarize(
                    transcript: finalTranscript,
                    meetingTitle: generatedTitle,
                    config: self.config,
                    template: templateSnapshot,
                    existingNotes: nil,
                    manualNotesToRetain: manualNotes,
                    visualContext: summaryContext.isEmpty ? nil : summaryContext
                )
            }
        } catch {
            logStopPhaseFailure(
                "summary_generation",
                timeout: MeetingStopPhaseTimeouts.summaryGeneration,
                error: error
            )
            fputs("[meeting] summary generation failed: \(error.localizedDescription)\n", stderr)
            formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: finalTranscript,
                meetingTitle: generatedTitle,
                error: error,
                manualNotes: manualNotes
            )
        }

        diagnostics?.writeFinalReport(
            title: generatedTitle,
            startedAt: meetingStart,
            endedAt: endTime,
            rawTranscript: finalTranscript,
            rawMicURL: rawStreamingMicURL,
            systemAudioURL: systemAudioURL,
            systemCapture: (systemAudioRecorder as? SystemAudioDiagnosticsProviding)?.diagnosticsSnapshot,
            micRecorder: meetingMicRecorder.diagnosticsSnapshot(),
            micHealth: micHealthTracker.snapshot(),
            aec: neuralAec.diagnosticsSnapshot,
            micChunks: micChunkHealthTracker.snapshot(),
            systemChunks: systemChunkHealthTracker.snapshot(),
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            protectedSystemSegmentCount: protectedTranscriptInputs.systemSegments.count
        )

        return MeetingSessionResult(
            title: generatedTitle,
            originalTitle: title,
            calendarEventID: calendarEventID,
            startTime: meetingStart,
            endTime: endTime,
            durationSeconds: max(endTime.timeIntervalSince(meetingStart), 0),
            rawTranscript: finalTranscript,
            rawOriginalTranscript: cleanupResult.originalTranscript,
            formattedNotes: formattedNotes,
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: retainedRecordingWriterError,
            retainedRecordingSavedURL: retainedRecordingSavedURL,
            systemRecordingURL: systemAudioURL,
            templateSnapshot: templateSnapshot,
            liveCollectorDrainTimeoutDroppedChunkCount: liveChunkingConfiguration.deduplicatesText
                ? drainTimeoutDroppedChunkCount
                : 0
        )
    }

    private struct PostModeTrackTranscription {
        let segments: [SpeechSegment]
        let samples: [Float]
        let duration: TimeInterval
        let vadSegmentCount: Int
        let coveredDuration: TimeInterval
    }

    private func stopPostProcessingMode(endTime: Date) async throws -> MeetingSessionResult {
        noteStopPhaseForTesting("stop_requested")
        meetingMicRecorder.onRawPCMSamples = nil
        systemAudioRecorder.onPCMSamples = nil
        noteStopPhaseForTesting("mic_recorder_stop")
        let rawStreamingMicURL = meetingMicRecorder.stop()
        noteStopPhaseForTesting("system_recorder_stop")
        let systemAudioURL = systemAudioRecorder.stop()
        let meetingStart = chunkRotationQueue.sync { () -> Date in
            noteStopPhaseForTesting("chunk_queue_finalize")
            isRecording = false
            setPausedStateOnQueue(false)
            return self.startTime ?? Date()
        }
        stopIntakeRequested.store(true, ordering: .releasing)
        let sourceTracks = postModeTrackWriter?.stop() ?? MeetingSourceTrackRecording(
            micURL: nil,
            systemURL: nil,
            micStartOffset: 0,
            systemStartOffset: 0
        )
        postModeTrackWriter = nil
        defer {
            if let rawStreamingMicURL {
                try? FileManager.default.removeItem(at: rawStreamingMicURL)
            }
            if let systemAudioURL {
                try? FileManager.default.removeItem(at: systemAudioURL)
            }
        }

        let mixedTempURL = try MeetingDualTrackRecordingWriter.writeMixedTemporaryWAV(from: sourceTracks)
        let persistedRecording = await finalizePostMeetingRecording(
            sourceTracks: sourceTracks,
            mixedTempURL: mixedTempURL,
            meetingStart: meetingStart
        )
        let sourceMicURL = persistedRecording?.micURL ?? sourceTracks.micURL
        let sourceSystemURL = persistedRecording?.systemURL ?? sourceTracks.systemURL
        let retainedRecordingSavedURL = persistedRecording?.mixedURL
        let retainedRecordingURL = retainedRecordingSavedURL == nil ? mixedTempURL : nil

        let backend = currentBackend()
        let micTrack = try await transcribePostModeTrack(
            url: sourceMicURL,
            trackRole: .mic,
            backend: backend
        )
        let systemTrack = try await transcribePostModeTrack(
            url: sourceSystemURL,
            trackRole: .system,
            backend: backend
        )
        var micSegments = MeetingRetranscriptionPipeline.applyTrackOffset(
            micTrack.segments,
            offset: sourceTracks.micStartOffset
        )
        var systemSegments = MeetingRetranscriptionPipeline.applyTrackOffset(
            systemTrack.segments,
            offset: sourceTracks.systemStartOffset
        )
        micSegments.sort { lhs, rhs in
            if lhs.start == rhs.start { return lhs.text < rhs.text }
            return lhs.start < rhs.start
        }
        systemSegments.sort { lhs, rhs in
            if lhs.start == rhs.start { return lhs.text < rhs.text }
            return lhs.start < rhs.start
        }

        let diarizationSegments = await postModeDiarizationSegments(
            samples: systemTrack.samples,
            offset: sourceTracks.systemStartOffset
        )

        fputs("[meeting] post-mode transcribed mic=\(micSegments.count) system=\(systemSegments.count)\n", stderr)

        let reconciledTranscriptInputs = TranscriptReconciler.reconcile(
            micTurns: micSegments,
            systemSegments: systemSegments,
            diarizationSegments: diarizationSegments
        )
        let protectedTranscriptInputs = reconciledTranscriptInputs
        let speakerObservations = speakerObservationLock.withLock { $0 }
        let observedParticipants = Self.observedParticipants(from: speakerObservations)
        let allParticipantCandidates = Self.mergedParticipants(
            participantCandidates,
            observedParticipants
        )
        let speakerNameMap = Self.speakerNameMap(
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            observations: speakerObservations,
            meetingStart: meetingStart
        )

        let rawTranscript = TranscriptFormatter.merge(
            micSegments: protectedTranscriptInputs.micSegments,
            systemSegments: protectedTranscriptInputs.systemSegments,
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            speakerNameMap: speakerNameMap,
            meetingStart: meetingStart
        )
        if let reason = MeetingRetranscriptionPipeline.suspiciousTranscriptReason(
            transcript: rawTranscript,
            meetingDuration: max(endTime.timeIntervalSince(meetingStart), systemTrack.duration),
            systemSegmentCount: systemSegments.count,
            systemCoveredDuration: max(
                systemTrack.coveredDuration,
                MeetingRetranscriptionPipeline.coveredDuration(systemSegments)
            )
        ) {
            DiagnosticsLog.write("[meeting] post-mode quality_guard_failed \(reason)")
            throw MeetingPostProcessingError.suspiciouslyShortTranscript(reason)
        }
        let cleanupResult = await stopPhaseValue(
            "transcript_cleanup",
            timeout: MeetingStopPhaseTimeouts.transcriptCleanup,
            fallback: MeetingTranscriptCleanupResult(transcript: rawTranscript, originalTranscript: nil)
        ) {
            await MeetingTranscriptCleanupPipeline.cleanIfNeeded(
                transcript: rawTranscript,
                config: self.config,
                isChatGPTAuthenticated: ChatGPTAuthManager.shared.isAuthenticated,
                cleaner: self.transcriptCleaner
            )
        }
        let finalTranscript = cleanupResult.transcript

        let generatedTitle: String
        onProgress?(.generatingTitle)
        let liveTitle = await stopPhaseValue(
            "live_title_provider",
            timeout: MeetingStopPhaseTimeouts.liveTitle,
            fallback: Optional<String>.none
        ) {
            await self.userEditedLiveTitle()
        }
        if let liveTitle {
            generatedTitle = liveTitle
        } else if let calendarTitle = Self.calendarTitleCandidate(
            originalTitle: title,
            calendarEventID: calendarEventID
        ) {
            generatedTitle = calendarTitle
        } else {
            let autoTitle = await stopPhaseValue(
                "title_generation",
                timeout: MeetingStopPhaseTimeouts.titleGeneration,
                fallback: Optional<String>.none
            ) {
                await MeetingSummaryClient.generateTitle(transcript: finalTranscript, config: self.config)
            }
            if let autoTitle, !autoTitle.isEmpty {
                generatedTitle = autoTitle
                fputs("[meeting] auto-generated title: \(generatedTitle)\n", stderr)
            } else {
                generatedTitle = title
            }
        }

        let templateSnapshot = MeetingTemplates.resolveSnapshot(
            id: config.defaultMeetingTemplateID,
            customTemplates: config.customMeetingTemplates
        )
        let visualContext = await stopPhaseValue(
            "screen_context_drain",
            timeout: MeetingStopPhaseTimeouts.screenContextDrain,
            fallback: ""
        ) {
            await self.screenContextCollector.stopAndDrain()
        }
        let summaryContext = Self.summaryContext(
            participants: allParticipantCandidates,
            visualContext: visualContext
        )
        Self.logger.info("visual context drained chars=\(visualContext.count) includedInPrompt=\(!summaryContext.isEmpty) useOCR=\(self.config.useCoreAudioTap)")
        fputs("[meeting] visual context drained chars=\(visualContext.count) participants=\(allParticipantCandidates.count) observedParticipants=\(observedParticipants.count) includedInPrompt=\(!summaryContext.isEmpty) useOCR=\(config.useCoreAudioTap)\n", stderr)
        onProgress?(.summarizingNotes)
        let manualNotes = await stopPhaseValue(
            "manual_notes_provider",
            timeout: MeetingStopPhaseTimeouts.manualNotes,
            fallback: Optional<String>.none
        ) {
            await self.manualNotesProvider?()
        }
        let formattedNotes: String
        do {
            formattedNotes = try await withStopPhaseTimeout(
                "summary_generation",
                timeout: MeetingStopPhaseTimeouts.summaryGeneration
            ) {
                try await MeetingSummaryClient.summarize(
                    transcript: finalTranscript,
                    meetingTitle: generatedTitle,
                    config: self.config,
                    template: templateSnapshot,
                    existingNotes: nil,
                    manualNotesToRetain: manualNotes,
                    visualContext: summaryContext.isEmpty ? nil : summaryContext
                )
            }
        } catch {
            logStopPhaseFailure(
                "summary_generation",
                timeout: MeetingStopPhaseTimeouts.summaryGeneration,
                error: error
            )
            fputs("[meeting] summary generation failed: \(error.localizedDescription)\n", stderr)
            formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: finalTranscript,
                meetingTitle: generatedTitle,
                error: error,
                manualNotes: manualNotes
            )
        }

        diagnostics?.writeFinalReport(
            title: generatedTitle,
            startedAt: meetingStart,
            endedAt: endTime,
            rawTranscript: finalTranscript,
            rawMicURL: rawStreamingMicURL,
            systemAudioURL: systemAudioURL,
            systemCapture: (systemAudioRecorder as? SystemAudioDiagnosticsProviding)?.diagnosticsSnapshot,
            micRecorder: meetingMicRecorder.diagnosticsSnapshot(),
            micHealth: micHealthTracker.snapshot(),
            aec: neuralAec.diagnosticsSnapshot,
            micChunks: micChunkHealthTracker.snapshot(),
            systemChunks: systemChunkHealthTracker.snapshot(),
            diarizationSegments: protectedTranscriptInputs.diarizationSegments,
            protectedSystemSegmentCount: protectedTranscriptInputs.systemSegments.count
        )

        return MeetingSessionResult(
            title: generatedTitle,
            originalTitle: title,
            calendarEventID: calendarEventID,
            startTime: meetingStart,
            endTime: endTime,
            durationSeconds: max(endTime.timeIntervalSince(meetingStart), 0),
            rawTranscript: finalTranscript,
            rawOriginalTranscript: cleanupResult.originalTranscript,
            formattedNotes: formattedNotes,
            retainedRecordingURL: retainedRecordingURL,
            retainedRecordingError: retainedRecordingWriterError,
            retainedRecordingSavedURL: retainedRecordingSavedURL,
            systemRecordingURL: systemAudioURL,
            sourceMicRecordingURL: persistedRecording?.micURL,
            sourceSystemRecordingURL: persistedRecording?.systemURL,
            templateSnapshot: templateSnapshot,
            liveCollectorDrainTimeoutDroppedChunkCount: 0
        )
    }

    private func finalizePostMeetingRecording(
        sourceTracks: MeetingSourceTrackRecording,
        mixedTempURL: URL?,
        meetingStart: Date
    ) async -> PersistedPostMeetingRecording? {
        noteStopPhaseForTesting("post_recording_finalize")
        guard let onPostMeetingRecordingReady else { return nil }
        do {
            return try await onPostMeetingRecordingReady(
                PostMeetingRecordingFinalizeRequest(
                    sourceTracks: sourceTracks,
                    mixedTempURL: mixedTempURL,
                    meetingTitle: title,
                    startedAt: meetingStart
                )
            )
        } catch {
            retainedRecordingWriterError = error
            logStopPhaseFailure(
                "post_recording_finalize",
                timeout: 0,
                error: error
            )
            return nil
        }
    }

    private func transcribePostModeTrack(
        url: URL?,
        trackRole: MeetingRetranscriptionPipeline.TrackRole,
        backend: BackendOption
    ) async throws -> PostModeTrackTranscription {
        guard let url else {
            DiagnosticsLog.write("[meeting] post-mode track_missing track=\(trackRole)")
            return PostModeTrackTranscription(segments: [], samples: [], duration: 0, vadSegmentCount: 0, coveredDuration: 0)
        }
        let wavData = try WavReader.readFloatMonoWAV(from: url)
        let duration = Double(wavData.samples.count) / Double(max(wavData.sampleRate, 1))
        let audioStats = MeetingRetranscriptionPipeline.audioLevelStats(
            samples: wavData.samples,
            sampleRate: wavData.sampleRate
        )
        DiagnosticsLog.write(
            "[meeting] post-mode track_start track=\(trackRole) backend=\(backend.backend) model=\(backend.model) file=\(url.lastPathComponent) sample_rate=\(wavData.sampleRate) duration=\(String(format: "%.1f", audioStats.duration)) rms=\(String(format: "%.6f", audioStats.rms)) peak=\(String(format: "%.6f", audioStats.peak)) nonzero=\(String(format: "%.3f", audioStats.nonZeroRatio))"
        )
        guard !wavData.samples.isEmpty else {
            DiagnosticsLog.write("[meeting] post-mode track_empty track=\(trackRole) file=\(url.lastPathComponent)")
            return PostModeTrackTranscription(segments: [], samples: [], duration: 0, vadSegmentCount: 0, coveredDuration: 0)
        }
        guard let vadManager = await transcriptionCoordinator.getVadManager() else {
            DiagnosticsLog.write("[meeting] post-mode VAD unavailable; transcribing full \(trackRole) track")
            let transcription = try await transcriptionCoordinator.transcribeMeeting(
                at: url,
                samples: wavData.samples,
                backend: backend,
                cohereLanguage: config.resolvedCohereLanguageMeetings
            )
            let segments = normalizePostModeTrack(
                transcription,
                trackRole: trackRole,
                duration: duration
            )
            DiagnosticsLog.write(
                "[meeting] post-mode full_track_done track=\(trackRole) segments=\(segments.count) chars=\(MeetingRetranscriptionPipeline.characterCount(segments)) text_chars=\(transcription.text.count)"
            )
            return PostModeTrackTranscription(
                segments: segments,
                samples: wavData.samples,
                duration: duration,
                vadSegmentCount: 0,
                coveredDuration: duration
            )
        }

        let vadSegments = try await vadManager.segmentSpeech(
            wavData.samples,
            config: MeetingRetranscriptionPipeline.vadSegmentationConfig
        )
        let audioSegments = MeetingRetranscriptionPipeline.audioSegments(
            from: vadSegments,
            sampleCount: wavData.samples.count
        )
        let coveredDuration = MeetingRetranscriptionPipeline.coveredDuration(audioSegments)
        DiagnosticsLog.write(
            "[meeting] post-mode VAD track=\(trackRole) segments=\(vadSegments.count) audio_segments=\(audioSegments.count) covered=\(String(format: "%.1f", coveredDuration)) duration=\(String(format: "%.1f", duration))"
        )
        guard !vadSegments.isEmpty else {
            if trackRole == .system, duration >= 900 {
                return try await transcribeFullPostModeTrack(
                    url: url,
                    wavData: wavData,
                    duration: duration,
                    trackRole: trackRole,
                    backend: backend,
                    reason: "empty_vad"
                )
            }
            return PostModeTrackTranscription(
                segments: [],
                samples: wavData.samples,
                duration: duration,
                vadSegmentCount: 0,
                coveredDuration: 0
            )
        }

        let transcription: SpeechTranscriptionResult
        if backend.backend == SherpaGigaAMRNNTModelStore.backendIdentifier {
            transcription = try await MeetingRetranscriptionPipeline.transcribeSegmentedAudio(
                samples: wavData.samples,
                vadSegments: vadSegments,
                trackRole: trackRole,
                diagnosticsLabel: "[meeting] post-mode",
                logger: { DiagnosticsLog.write($0) }
            ) { [transcriptionCoordinator] segmentAudio in
                try await transcriptionCoordinator.transcribeMeetingBatchWithSherpaGigaAMRNNT(
                    samplesBatch: segmentAudio.map(\.samples)
                )
            }
        } else {
            transcription = try await MeetingRetranscriptionPipeline.transcribeSegmentedAudio(
                samples: wavData.samples,
                vadSegments: vadSegments,
                trackRole: trackRole,
                diagnosticsLabel: "[meeting] post-mode",
                logger: { DiagnosticsLog.write($0) }
            ) { [transcriptionCoordinator, config] _, samples in
                let segmentURL = try WavWriter.writeTemporaryWAV(
                    samples: samples,
                    directoryName: AppTemporaryDirectories.meetingRetranscription
                )
                defer { try? FileManager.default.removeItem(at: segmentURL) }
                return try await transcriptionCoordinator.transcribeMeeting(
                    at: segmentURL,
                    samples: samples,
                    backend: backend,
                    cohereLanguage: config.resolvedCohereLanguageMeetings
                )
            }
        }
        let segmentedChars = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        if MeetingRetranscriptionPipeline.shouldRetryFullTrack(
            trackRole: trackRole,
            segmentedCharacterCount: segmentedChars,
            sourceDuration: duration,
            coveredDuration: coveredDuration
        ) {
            return try await transcribeFullPostModeTrack(
                url: url,
                wavData: wavData,
                duration: duration,
                trackRole: trackRole,
                backend: backend,
                reason: "segmented_chars_\(segmentedChars)"
            )
        }
        DiagnosticsLog.write(
            "[meeting] post-mode track_done track=\(trackRole) segments=\(transcription.segments.count) chars=\(MeetingRetranscriptionPipeline.characterCount(transcription.segments)) text_chars=\(segmentedChars) covered=\(String(format: "%.1f", coveredDuration))"
        )
        return PostModeTrackTranscription(
            segments: transcription.segments,
            samples: wavData.samples,
            duration: duration,
            vadSegmentCount: vadSegments.count,
            coveredDuration: coveredDuration
        )
    }

    private func transcribeFullPostModeTrack(
        url: URL,
        wavData: WavReader.WavData,
        duration: TimeInterval,
        trackRole: MeetingRetranscriptionPipeline.TrackRole,
        backend: BackendOption,
        reason: String
    ) async throws -> PostModeTrackTranscription {
        DiagnosticsLog.write("[meeting] post-mode full_track_retry track=\(trackRole) reason=\(reason)")
        let transcription = try await transcriptionCoordinator.transcribeMeeting(
            at: url,
            samples: wavData.samples,
            backend: backend,
            cohereLanguage: config.resolvedCohereLanguageMeetings
        )
        let segments = normalizePostModeTrack(
            transcription,
            trackRole: trackRole,
            duration: duration
        )
        DiagnosticsLog.write(
            "[meeting] post-mode full_track_done track=\(trackRole) segments=\(segments.count) chars=\(MeetingRetranscriptionPipeline.characterCount(segments)) text_chars=\(transcription.text.count)"
        )
        return PostModeTrackTranscription(
            segments: segments,
            samples: wavData.samples,
            duration: duration,
            vadSegmentCount: 0,
            coveredDuration: duration
        )
    }

    private func normalizePostModeTrack(
        _ transcription: SpeechTranscriptionResult,
        trackRole: MeetingRetranscriptionPipeline.TrackRole,
        duration: TimeInterval
    ) -> [SpeechSegment] {
        switch trackRole {
        case .mic:
            return MicTurnNormalizer.normalize(
                result: transcription,
                startTime: 0,
                endTime: max(duration, 0.1)
            )
        case .system:
            return SystemTurnNormalizer.normalize(
                result: transcription,
                startTime: 0,
                endTime: max(duration, 0.1)
            )
        }
    }

    private func postModeDiarizationSegments(
        samples: [Float],
        offset: TimeInterval
    ) async -> [TimedSpeakerSegment]? {
        guard !samples.isEmpty else { return nil }
        let diarizationResult = await stopPhaseValue(
            "system_diarization",
            timeout: MeetingStopPhaseTimeouts.systemDiarization,
            fallback: Optional<MeetingStopDiarizationResult>.none
        ) {
            guard let diarizerManager = await self.transcriptionCoordinator.getDiarizerManager(),
                  diarizerManager.isAvailable else {
                return nil
            }
            let result = try await self.transcriptionCoordinator.diarizeSystemAudio(samples: samples)
            return MeetingStopDiarizationResult(samples: samples, segments: result?.segments)
        }
        return MeetingRetranscriptionPipeline.applyDiarizationOffset(
            diarizationResult?.segments,
            offset: offset
        )
    }

    static func calendarTitleCandidate(originalTitle: String, calendarEventID: String?) -> String? {
        guard calendarEventID != nil else { return nil }
        guard !originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return originalTitle
    }

    static func summaryContext(participants: [MeetingParticipant], visualContext: String) -> String {
        var sections: [String] = []
        let participantLabels = participants
            .filter { !$0.isSelf }
            .map(\.summaryLabel)
        if !participantLabels.isEmpty {
            sections.append("""
            Meeting participant candidates:
            \(participantLabels.map { "- \($0)" }.joined(separator: "\n"))
            Use these names only as possible participant names. Do not assign a Speaker N label to a person unless the transcript or captured context supports it.
            """)
        }

        let trimmedVisualContext = visualContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVisualContext.isEmpty {
            sections.append(trimmedVisualContext)
        }
        return sections.joined(separator: "\n\n---\n\n")
    }

    static func observedParticipants(from observations: [MeetSpeakerObservation]) -> [MeetingParticipant] {
        mergedParticipants([], observations.flatMap(\.participants))
    }

    static func mergedParticipants(
        _ calendarParticipants: [MeetingParticipant],
        _ observedParticipants: [MeetingParticipant]
    ) -> [MeetingParticipant] {
        var seen = Set<String>()
        var result: [MeetingParticipant] = []
        for participant in calendarParticipants + observedParticipants {
            let nameKey = "name:\(participant.name.lowercased())"
            let emailKey = participant.email.map { "email:\($0.lowercased())" }
            guard !seen.contains(nameKey),
                  emailKey.map({ !seen.contains($0) }) ?? true else { continue }
            seen.insert(nameKey)
            if let emailKey {
                seen.insert(emailKey)
            }
            result.append(participant)
        }
        return result
    }

    static func speakerNameMap(
        diarizationSegments: [TimedSpeakerSegment]?,
        observations: [MeetSpeakerObservation],
        meetingStart: Date
    ) -> [String: String] {
        guard let diarizationSegments, !diarizationSegments.isEmpty, !observations.isEmpty else { return [:] }

        var votes: [String: [String: Int]] = [:]
        for observation in observations {
            guard let speakerName = validSpeakerNameCandidate(from: observation) else { continue }
            let relativeTime = Float(observation.observedAt.timeIntervalSince(meetingStart))
            guard relativeTime >= -2 else { continue }
            guard let speakerID = nearestSpeakerID(
                at: relativeTime,
                in: diarizationSegments,
                maxGapSeconds: 3.0
            ) else { continue }
            votes[speakerID, default: [:]][speakerName, default: 0] += 1
        }

        var bestBySpeaker: [(speakerID: String, name: String, count: Int)] = []
        for (speakerID, nameVotes) in votes {
            guard let best = nameVotes.max(by: { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedDescending
                }
                return lhs.value < rhs.value
            }) else { continue }
            bestBySpeaker.append((speakerID: speakerID, name: best.key, count: best.value))
        }

        var result: [String: String] = [:]
        for candidate in bestBySpeaker {
            result[candidate.speakerID] = candidate.name
        }
        return result
    }

    private static func validSpeakerNameCandidate(from observation: MeetSpeakerObservation) -> String? {
        guard let name = observation.speakerName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              !isClockLikeSpeakerName(name) else {
            return nil
        }
        let participantNames = observation.participants
            .filter { !$0.isSelf }
            .map(\.name)
        guard !participantNames.isEmpty else { return name }
        return participantNames.contains { speakerName(name, matches: $0) } ? name : nil
    }

    private static func speakerName(_ lhs: String, matches rhs: String) -> Bool {
        normalizedSpeakerName(lhs) == normalizedSpeakerName(rhs)
    }

    private static func normalizedSpeakerName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isClockLikeSpeakerName(_ name: String) -> Bool {
        let parts = name.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return false }
        guard (0...23).contains(values[0]), (0...59).contains(values[1]) else { return false }
        return parts.count == 2 || (0...59).contains(values[2])
    }

    private static func nearestSpeakerID(
        at relativeTime: Float,
        in diarizationSegments: [TimedSpeakerSegment],
        maxGapSeconds: Float
    ) -> String? {
        let nearest = diarizationSegments.min { lhs, rhs in
            temporalGap(from: relativeTime, to: lhs) < temporalGap(from: relativeTime, to: rhs)
        }
        guard let nearest else { return nil }
        return temporalGap(from: relativeTime, to: nearest) <= maxGapSeconds ? nearest.speakerId : nil
    }

    private static func temporalGap(from relativeTime: Float, to segment: TimedSpeakerSegment) -> Float {
        if relativeTime < segment.startTimeSeconds {
            return segment.startTimeSeconds - relativeTime
        }
        if relativeTime > segment.endTimeSeconds {
            return relativeTime - segment.endTimeSeconds
        }
        return 0
    }

    private func userEditedLiveTitle() async -> String? {
        guard let candidate = await liveTitleProvider?() else { return nil }
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginal = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else { return nil }
        guard trimmedCandidate != trimmedOriginal else { return nil }
        return trimmedCandidate
    }

    private func appendFlushedStreamingMicOnQueue() {
        let flushed = neuralAec.flushStreamingMic()
        appendCleanedMicSamplesOnQueue(flushed)
    }

    /// Called by VAD on speech boundaries or max-duration fallback.
    /// Rotates the streaming mic file and sends the completed chunk for transcription.
    private func rotateChunk() {
        chunkRotationQueue.async { [weak self] in
            self?.rotateChunkOnQueue()
        }
    }

    private func rotateChunkOnQueue() {
        guard isRecording, !isPaused else { return }
        appendFlushedStreamingMicOnQueue()
        guard let chunkTiming = chunkTimingTracker.rotate(
            overlapSampleCount: liveChunkingConfiguration.overlapSampleCount
        ) else {
            return
        }
        let rawChunkURL = rawMicChunkRecorder?.rotateFile()

        guard rawChunkURL != nil else {
            return
        }

        // Transcribe the completed chunk async
        let chunkOffset = chunkTiming.startTimeSeconds

        fputs("[meeting] rotating raw mic chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)

        let task = Task { [weak self] () -> [SpeechSegment] in
            guard let self else { return [] }
            if Task.isCancelled {
                self.cleanupTemporaryChunkURLs(rawChunkURL)
                return []
            }
            let segments = await self.transcribeMicChunk(
                rawURL: rawChunkURL,
                chunkTiming: chunkTiming,
                isFinalChunk: false
            )
            return segments
        }
        let (registered, retireID) = micChunkCollector.add(task)
        if registered {
            Task { [weak self] in
                let segments = await task.value
                guard let readyChunks = self?.micChunkCollector.retire(id: retireID, segments: segments) else { return }
                for readySegments in readyChunks where !readySegments.isEmpty {
                    self?.onChunkTranscribed?(readySegments, "You")
                }
            }
        } else {
            task.cancel()
            cleanupTemporaryChunkURLs(rawChunkURL)
        }
    }

    private func rotateSystemChunk() {
        chunkRotationQueue.async { [weak self] in
            self?.rotateSystemChunkOnQueue()
        }
    }

    private func rotateSystemChunkOnQueue() {
        guard isRecording, !isPaused else { return }
        guard let chunkURL = systemChunkRecorder?.rotateFile(),
              let chunkTiming = systemChunkTimingTracker.rotate(
                overlapSampleCount: liveChunkingConfiguration.overlapSampleCount
              ) else {
            return
        }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        fputs("[meeting] rotating system chunk at offset=\(String(format: "%.0f", chunkOffset))s\n", stderr)

        let task = Task { [weak self] () -> [SpeechSegment] in
            defer {
                try? FileManager.default.removeItem(at: chunkURL)
            }
            guard let self else { return [] }
            do {
                if Task.isCancelled {
                    return []
                }
                let backend = self.currentBackend()
                let result = try await self.transcriptionCoordinator.transcribeMeetingChunk(
                    at: chunkURL,
                    backend: backend,
                    cohereLanguage: config.resolvedCohereLanguageMeetings
                )
                if !result.text.isEmpty {
                    fputs("[meeting] system chunk transcribed: \"\(String(result.text.prefix(60)))...\"\n", stderr)
                    let normalizedSegments = self.normalizeSystemTranscription(
                        result: result,
                        startTime: chunkOffset,
                        endTime: chunkOffset + max(chunkDuration, 0.1)
                    )
                    if normalizedSegments.isEmpty {
                        self.systemChunkHealthTracker.noteEmptyChunk()
                    } else {
                        self.systemChunkHealthTracker.noteSuccessfulChunk()
                    }
                    return normalizedSegments
                }
                self.systemChunkHealthTracker.noteEmptyChunk()
            } catch {
                self.systemChunkHealthTracker.noteFailedChunk()
                DiagnosticsLog.write("[live-collector] system chunk failed offset=\(String(format: "%.1f", chunkOffset)) duration=\(String(format: "%.1f", chunkDuration)) error=\(error.localizedDescription)")
                fputs("[meeting] system chunk transcription failed: \(error)\n", stderr)
            }
            return []
        }
        let (registered, retireID) = systemChunkCollector.add(task)
        if registered {
            Task { [weak self] in
                let segments = await task.value
                guard let readyChunks = self?.systemChunkCollector.retire(id: retireID, segments: segments) else { return }
                for readySegments in readyChunks where !readySegments.isEmpty {
                    self?.onChunkTranscribed?(readySegments, "Others")
                }
            }
        } else {
            task.cancel()
        }
    }

    private func setupRetainedRecordingWriterIfNeeded() throws {
        retainedRecordingWriter = nil
        retainedRecordingWriterError = nil

        do {
            retainedRecordingWriter = try retainedRecordingWriterFactory(liveMeetingID)
        } catch {
            retainedRecordingWriterError = error
            fputs("[meeting] failed to prepare retained recording writer: \(error)\n", stderr)
            throw error
        }
    }

    private func finalizeRetainedRecordingEarly(tempURL: URL?, meetingStart: Date) async -> URL? {
        guard let tempURL else { return nil }
        noteStopPhaseForTesting("retained_recording_finalize")
        guard let onRetainedRecordingReady else { return nil }

        do {
            return try await onRetainedRecordingReady(
                RetainedMeetingRecordingFinalizeRequest(
                    tempURL: tempURL,
                    meetingTitle: title,
                    startedAt: meetingStart
                )
            )
        } catch {
            retainedRecordingWriterError = error
            logStopPhaseFailure(
                "retained_recording_finalize",
                timeout: 0,
                error: error
            )
            return nil
        }
    }

    private func prepareRealtimeAudioPipeline(vadManager: VadManager?) throws {
        rawMicChunkRecorder = try PCMChunkRecorder(
            directoryName: AppTemporaryDirectories.meetingMicChunks,
            overlapSampleCount: liveChunkingConfiguration.overlapSampleCount
        )
        systemChunkRecorder = try PCMChunkRecorder(
            directoryName: AppTemporaryDirectories.meetingSystemChunks,
            overlapSampleCount: liveChunkingConfiguration.overlapSampleCount
        )
        configureRealtimeAudioCallbacks(vadManager: vadManager)
    }

    private func configureRealtimeAudioCallbacks(vadManager: VadManager?) {
        if let vadManager {
            let controller = StreamingVadController(
                vadManager: vadManager,
                minChunkDuration: liveChunkingConfiguration.minChunkDuration,
                maxChunkDuration: liveChunkingConfiguration.maxChunkDuration
            )
            controller.onChunkBoundary = { [weak self] in
                // Streaming VAD callbacks can arrive off-main; serialize chunk rotation explicitly.
                self?.chunkRotationQueue.async { [weak self] in
                    self?.rotateChunkOnQueue()
                }
            }
            controller.start()
            vadController = controller

            let systemController = StreamingVadController(
                vadManager: vadManager,
                minChunkDuration: liveChunkingConfiguration.minChunkDuration,
                maxChunkDuration: liveChunkingConfiguration.maxChunkDuration
            )
            systemController.onChunkBoundary = { [weak self] in
                // Streaming VAD callbacks can arrive off-main; serialize chunk rotation explicitly.
                self?.chunkRotationQueue.async { [weak self] in
                    self?.rotateSystemChunkOnQueue()
                }
            }
            systemController.start()
            systemVadController = systemController
        } else {
            vadController = nil
            systemVadController = nil
        }
        neuralAec.resetForStreaming()
        meetingMicRecorder.onRawPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeMicSamples(samples)
        }
        systemAudioRecorder.onPCMSamples = { [weak self] samples in
            self?.enqueueRealtimeSystemSamples(samples)
        }
    }

    private func enqueueRealtimeMicSamples(_ rawSamples: [Int16]) {
        guard !rawSamples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self,
                  !self.stopIntakeRequested.load(ordering: .acquiring),
                  self.isRecording,
                  !self.isPaused else { return }

            let healthSnapshot = self.micHealthTracker.noteRawMicSamples(rawSamples)
            self.onMicHealthChanged?(healthSnapshot)
            self.retainedRecordingWriter?.appendMic(rawSamples)

            let floatSamples = rawSamples.map { Float($0) / 32767.0 }

            // AEC: clean mic using position-aligned system reference
            let cleanedFloat = self.neuralAec.processStreamingMic(floatSamples)
            self.appendCleanedMicSamplesOnQueue(cleanedFloat)

            // Meeting mic chunks must be driven by the cleaned mic stream. Raw
            // mic VAD sees speaker playback bleed and can create false `You`
            // chunks even when AEC removed that speech from the final mic audio.
            if let vadController = self.vadController, !cleanedFloat.isEmpty {
                vadController.processAudio(cleanedFloat)
            }
        }
    }

    private func enqueueRealtimeSystemSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self,
                  !self.stopIntakeRequested.load(ordering: .acquiring),
                  self.isRecording,
                  !self.isPaused else { return }

            let healthSnapshot = self.micHealthTracker.noteSystemSamples(samples)
            self.onMicHealthChanged?(healthSnapshot)
            self.retainedRecordingWriter?.appendSystem(samples)
            self.systemChunkRecorder?.append(samples)
            self.systemChunkTimingTracker.append(sampleCount: samples.count)

            let floatSamples = samples.map { Float($0) / 32767.0 }
            self.neuralAec.feedSystemSamples(floatSamples)
            let cleanedFloat = self.neuralAec.processStreamingMic([])
            self.appendCleanedMicSamplesOnQueue(cleanedFloat)

            if let vadController = self.vadController, !cleanedFloat.isEmpty {
                vadController.processAudio(cleanedFloat)
            }

            if let systemVadController = self.systemVadController {
                systemVadController.processAudio(floatSamples)
            }
        }
    }

    private func enqueuePostModeMicSamples(_ rawSamples: [Int16]) {
        guard !rawSamples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self,
                  !self.stopIntakeRequested.load(ordering: .acquiring),
                  self.isRecording,
                  !self.isPaused else { return }

            let healthSnapshot = self.micHealthTracker.noteRawMicSamples(rawSamples)
            self.onMicHealthChanged?(healthSnapshot)
            self.postModeTrackWriter?.appendMic(rawSamples)
        }
    }

    private func enqueuePostModeSystemSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }

        chunkRotationQueue.async { [weak self] in
            guard let self,
                  !self.stopIntakeRequested.load(ordering: .acquiring),
                  self.isRecording,
                  !self.isPaused else { return }

            let healthSnapshot = self.micHealthTracker.noteSystemSamples(samples)
            self.onMicHealthChanged?(healthSnapshot)
            self.postModeTrackWriter?.appendSystem(samples)
        }
    }

    private func appendCleanedMicSamplesOnQueue(_ cleanedFloat: [Float]) {
        guard !cleanedFloat.isEmpty else { return }
        let cleanedInt16 = cleanedFloat.map { sample -> Int16 in
            Int16(max(-1.0, min(1.0, sample)) * 32767)
        }
        rawMicChunkRecorder?.append(cleanedInt16)
        chunkTimingTracker.append(sampleCount: cleanedInt16.count)
        diagnostics?.appendCleanedMicSamples(cleanedInt16)
    }

    private func transcribeMicChunk(
        rawURL: URL?,
        chunkTiming: MeetingChunkTimingSnapshot?,
        isFinalChunk: Bool
    ) async -> [SpeechSegment] {
        defer {
            cleanupTemporaryChunkURLs(rawURL)
        }

        guard let chunkTiming, let rawURL else { return [] }

        let chunkOffset = chunkTiming.startTimeSeconds
        let chunkDuration = chunkTiming.durationSeconds
        let logPrefix = isFinalChunk ? "[meeting] transcribing final mic chunk" : "[meeting] transcribing mic chunk"

        return await transcribeMicChunk(
            at: rawURL,
            chunkOffset: chunkOffset,
            chunkDuration: chunkDuration,
            logPrefix: logPrefix
        ) ?? []
    }

    private func transcribeMicChunk(
        at url: URL,
        chunkOffset: TimeInterval,
        chunkDuration: TimeInterval,
        logPrefix: String
    ) async -> [SpeechSegment]? {
        fputs("\(logPrefix) (offset=\(String(format: "%.0f", chunkOffset))s, source=raw)\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeetingChunk(
                at: url,
                backend: currentBackend(),
                cohereLanguage: config.resolvedCohereLanguageMeetings
            )
            if !result.text.isEmpty {
                fputs("[meeting] mic chunk transcribed (raw): \"\(String(result.text.prefix(60)))...\"\n", stderr)
                let normalizedSegments = MicTurnNormalizer.normalize(
                    result: result,
                    startTime: chunkOffset,
                    endTime: chunkOffset + max(chunkDuration, 0.1)
                )
                if normalizedSegments.isEmpty {
                    micChunkHealthTracker.noteEmptyChunk()
                } else {
                    micChunkHealthTracker.noteSuccessfulChunk()
                }
                return normalizedSegments
            }
            micChunkHealthTracker.noteEmptyChunk()
            return []
        } catch {
            micChunkHealthTracker.noteFailedChunk()
            DiagnosticsLog.write("[live-collector] mic chunk failed offset=\(String(format: "%.1f", chunkOffset)) duration=\(String(format: "%.1f", chunkDuration)) error=\(error.localizedDescription)")
            fputs("[meeting] mic chunk transcription failed (raw): \(error)\n", stderr)
            return nil
        }
    }

    private func cleanupTemporaryChunkURLs(_ urls: URL?...) {
        urls.compactMap { $0 }.forEach { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func normalizeSystemTranscription(
        result: SpeechTranscriptionResult,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [SpeechSegment] {
        SystemTurnNormalizer.normalize(
            result: result,
            startTime: startTime,
            endTime: endTime
        )
    }

    private func durationSeconds(from start: Date, to end: Date) -> Double {
        max(end.timeIntervalSince(start), 0)
    }

    private func repairSystemSegmentsIfNeeded(
        existingSystemSegments: [SpeechSegment],
        systemAudioURL: URL,
        systemAudioSamples: [Float]? = nil,
        meetingStart: Date,
        endTime: Date
    ) async -> MeetingTranscriptRecoveryResult {
        let totalDuration = durationSeconds(from: meetingStart, to: endTime)

        guard let vadManager = await transcriptionCoordinator.getVadManager() else {
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration,
                    samples: systemAudioSamples
                ))
            }
            return .none
        }

        do {
            let samples = try systemAudioSamples ?? AudioConverter().resampleAudioFile(systemAudioURL)
            let speechSegments = try await vadManager.segmentSpeech(
                samples,
                config: VadSegmentationConfig(maxSpeechDuration: 10.0, speechPadding: 0.15)
            )
            let health = MeetingTranscriptHealthMonitor.evaluate(
                existingSegments: existingSystemSegments,
                offlineSpeechSegments: speechSegments,
                chunkHealth: systemChunkHealthTracker.snapshot()
            )
            fputs("[meeting] system \(health.summaryLine.dropFirst("[meeting] ".count))\n", stderr)

            switch health.action {
            case .accept:
                return .none
            case .fullFallback(let reason):
                fputs("[meeting] transcript health triggered full system fallback: \(reason)\n", stderr)
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration,
                    samples: samples
                ))
            case .selectiveRepair(let repairSegments):
                guard !repairSegments.isEmpty else { return .none }

                fputs("[meeting] repairing \(repairSegments.count) uncovered system speech regions\n", stderr)

                var repairedSegments: [SpeechSegment] = []
                for speechSegment in repairSegments {
                    let startSample = max(0, speechSegment.startSample(sampleRate: VadManager.sampleRate))
                    let endSample = min(samples.count, speechSegment.endSample(sampleRate: VadManager.sampleRate))
                    guard endSample > startSample else { continue }

                    let segmentURL = try MeetingMicRepairPlanner.writeTemporaryWAV(
                        samples: Array(samples[startSample..<endSample])
                    )
                    defer { try? FileManager.default.removeItem(at: segmentURL) }

                    let result = try await transcriptionCoordinator.transcribeMeeting(
                        at: segmentURL,
                        backend: currentBackend(),
                        cohereLanguage: config.resolvedCohereLanguageMeetings
                    )
                    repairedSegments.append(contentsOf: normalizeSystemTranscription(
                        result: result,
                        startTime: speechSegment.startTime,
                        endTime: speechSegment.endTime
                    ))
                }
                return repairedSegments.isEmpty ? .none : .append(repairedSegments)
            }
        } catch {
            fputs("[meeting] system repair pass failed: \(error)\n", stderr)
            if existingSystemSegments.isEmpty {
                return .replace(await fallbackToFullSessionSystemTranscription(
                    systemAudioURL: systemAudioURL,
                    meetingDuration: totalDuration,
                    samples: systemAudioSamples
                ))
            }
            return .none
        }
    }

    private func fallbackToFullSessionSystemTranscription(
        systemAudioURL: URL,
        meetingDuration: Double,
        samples: [Float]? = nil
    ) async -> [SpeechSegment] {
        fputs("[meeting] no system chunks survived, falling back to full-session system transcription\n", stderr)
        do {
            let result = try await transcriptionCoordinator.transcribeMeeting(
                at: systemAudioURL,
                samples: samples,
                backend: currentBackend(),
                cohereLanguage: config.resolvedCohereLanguageMeetings
            )
            return normalizeSystemTranscription(
                result: result,
                startTime: 0,
                endTime: meetingDuration
            )
        } catch {
            fputs("[meeting] full-session system fallback transcription failed: \(error)\n", stderr)
            return []
        }
    }
}
