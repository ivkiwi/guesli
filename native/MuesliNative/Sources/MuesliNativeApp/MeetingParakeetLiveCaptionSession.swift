import AVFoundation
import FluidAudio
import Foundation
import os

/// Optional Parakeet EOU model storage. Nothing here downloads or preloads the
/// model implicitly; callers must explicitly invoke `download()` or `makeEngine`.
enum MeetingParakeetLiveCaptionModelStore {
    static let repo = Repo.parakeetEou320
    static let sizeLabel = "~430 MB"
    static let label = "Parakeet Realtime EOU"

    static func cacheRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    static func modelDirectory(fileManager: FileManager = .default) -> URL {
        modelDirectory(in: cacheRoot(fileManager: fileManager))
    }

    static func modelDirectory(in cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    static func isDownloaded(fileManager: FileManager = .default) -> Bool {
        isDownloaded(in: cacheRoot(fileManager: fileManager), fileManager: fileManager)
    }

    static func isDownloaded(in cacheRoot: URL, fileManager: FileManager = .default) -> Bool {
        let directory = modelDirectory(in: cacheRoot)
        return ModelNames.ParakeetEOU.requiredModels.allSatisfy {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func download(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await DownloadUtils.downloadRepo(repo, to: cacheRoot()) { update in
            progress?(update.fractionCompleted)
        }
    }

    static func delete(fileManager: FileManager = .default) throws {
        let directory = modelDirectory(fileManager: fileManager)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    static func makeEngine(label: String) async throws -> MeetingStreamingPartialEngine {
        guard isDownloaded() else {
            throw NSError(
                domain: "MeetingLiveCaptions",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Parakeet Realtime EOU is not downloaded."]
            )
        }
        let engine = ParakeetEOUMeetingPartialEngine(label: label)
        try await engine.loadModels(from: modelDirectory())
        return engine
    }

    static func makeEngines() async throws -> (
        mic: MeetingStreamingPartialEngine,
        system: MeetingStreamingPartialEngine
    ) {
        let mic = try await makeEngine(label: "You")
        do {
            return (mic, try await makeEngine(label: "Others"))
        } catch {
            await mic.shutdown()
            throw error
        }
    }
}

protocol MeetingStreamingPartialEngine: AnyObject, Sendable {
    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async
    func process(samples: [Float]) async throws
    func finish() async throws
    func shutdown() async
}

extension MeetingStreamingPartialEngine {
    func finish() async throws {}
}

private actor ParakeetEOUMeetingPartialEngine: MeetingStreamingPartialEngine {
    private let manager = StreamingEouAsrManager(chunkSize: .ms320)
    private let label: String

    init(label: String) {
        self.label = label
    }

    func loadModels(from directory: URL) async throws {
        try await manager.loadModels(from: directory)
    }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        await manager.setPartialCallback(handler)
    }

    func process(samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw NSError(
                domain: "MeetingLiveCaptions",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate a 16 kHz live-caption buffer."]
            )
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)
        _ = try await manager.process(audioBuffer: buffer)
    }

    func shutdown() async {
        await manager.cleanup()
        fputs("[meeting-partials] \(label) Parakeet EOU session stopped\n", stderr)
    }
}

/// Display-only streaming partials for one meeting audio source ("You" or
/// "Others"). Durable chunk transcription remains authoritative.
final class MeetingStreamingPartialSession: @unchecked Sendable {
    var onPartialUpdate: ((String) -> Void)?

    static let feedSamples = StreamingChunkSize.ms320.shiftSamples
    static let maxQueuedChunks = 3
    static let publicationIntervalNanoseconds: UInt64 = 250_000_000
    static let finishDrainTimeoutNanoseconds: UInt64 = 30_000_000_000

    private let engine: MeetingStreamingPartialEngine
    private let label: String

    private struct PendingSegment {
        let id: UUID
        let prefixLength: Int
        var isCommitted = false
    }

    private struct State {
        var sampleBuffer: [Float] = []
        var chunkQueue: [[Float]] = []
        var isDraining = false
        var engineText = ""
        var committedPrefixLength = 0
        var pendingSegments: [PendingSegment] = []
        var isStopped = false
        var isSuspended = false
        var didFail = false
        var pendingPublicationTail: String?
        var lastPublishedTail: String?
        var isPublicationScheduled = false
        var lifecycleRevision: UInt64 = 0
        var activeInferenceRevision: UInt64?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(engine: MeetingStreamingPartialEngine, label: String) {
        self.engine = engine
        self.label = label
    }

    func connect() async {
        await engine.setPartialHandler { [weak self] text in
            self?.receiveEnginePartial(text)
        }
    }

    func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let shouldStartDrain = state.withLock { state -> Bool in
            guard !state.isStopped, !state.isSuspended, !state.didFail else { return false }
            state.sampleBuffer.append(contentsOf: samples)
            while state.sampleBuffer.count >= Self.feedSamples {
                state.chunkQueue.append(Array(state.sampleBuffer.prefix(Self.feedSamples)))
                state.sampleBuffer.removeFirst(Self.feedSamples)
            }
            if state.chunkQueue.count > Self.maxQueuedChunks {
                state.chunkQueue.removeFirst(state.chunkQueue.count - Self.maxQueuedChunks)
            }
            guard !state.chunkQueue.isEmpty, !state.isDraining else { return false }
            state.isDraining = true
            return true
        }
        if shouldStartDrain {
            Task.detached(priority: .utility) { [weak self] in
                await self?.drain()
            }
        }
    }

    func markSegmentBoundary(id: UUID) {
        state.withLock { state in
            state.pendingSegments.append(PendingSegment(id: id, prefixLength: state.engineText.count))
        }
    }

    func pendingSegmentText(id: UUID) -> String? {
        state.withLock { state in
            guard !state.isStopped, !state.didFail,
                  let index = state.pendingSegments.firstIndex(where: { $0.id == id }) else { return nil }
            let segment = state.pendingSegments[index]
            let previousPrefixLength = index > 0
                ? state.pendingSegments[index - 1].prefixLength
                : state.committedPrefixLength
            let startOffset = min(previousPrefixLength, state.engineText.count)
            let endOffset = min(max(segment.prefixLength, startOffset), state.engineText.count)
            guard endOffset > startOffset else { return nil }
            let start = state.engineText.index(state.engineText.startIndex, offsetBy: startOffset)
            let end = state.engineText.index(state.engineText.startIndex, offsetBy: endOffset)
            let text = String(state.engineText[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    func commitSegment(id: UUID) {
        let publication: (tail: String, revision: UInt64)? = state.withLock { state in
            guard !state.isStopped, !state.isSuspended, !state.didFail else { return nil }
            guard let index = state.pendingSegments.firstIndex(where: { $0.id == id }) else { return nil }
            state.pendingSegments[index].isCommitted = true
            var didAdvance = false
            while let first = state.pendingSegments.first, first.isCommitted {
                state.committedPrefixLength = max(
                    state.committedPrefixLength,
                    min(first.prefixLength, state.engineText.count)
                )
                state.pendingSegments.removeFirst()
                didAdvance = true
            }
            guard didAdvance else { return nil }
            return (visibleTail(for: state), state.lifecycleRevision)
        }
        if let publication {
            publishImmediately(publication.tail, expectedRevision: publication.revision)
        }
    }

    func suspend() {
        state.withLock { state in
            state.isSuspended = true
            state.lifecycleRevision &+= 1
            state.sampleBuffer.removeAll(keepingCapacity: true)
            state.chunkQueue.removeAll(keepingCapacity: true)
            state.committedPrefixLength = state.engineText.count
            state.pendingSegments.removeAll(keepingCapacity: true)
        }
        publishImmediately("")
    }

    func resume() {
        state.withLock { $0.isSuspended = false }
    }

    func finish(
        drainTimeoutNanoseconds: UInt64 = MeetingStreamingPartialSession.finishDrainTimeoutNanoseconds
    ) async -> String? {
        let shouldDrain = state.withLock { state -> Bool in
            guard !state.isStopped, !state.isSuspended, !state.didFail else { return false }
            if !state.sampleBuffer.isEmpty {
                state.sampleBuffer.append(
                    contentsOf: repeatElement(0, count: Self.feedSamples - state.sampleBuffer.count)
                )
                state.chunkQueue.append(state.sampleBuffer)
                state.sampleBuffer.removeAll(keepingCapacity: true)
            }
            guard !state.chunkQueue.isEmpty, !state.isDraining else { return false }
            state.isDraining = true
            return true
        }
        if shouldDrain {
            Task.detached(priority: .utility) { [weak self] in
                await self?.drain()
            }
        }

        let deadline = DispatchTime.now().uptimeNanoseconds &+ drainTimeoutNanoseconds
        while state.withLock({ $0.isDraining || !$0.chunkQueue.isEmpty }) {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                goDormant(error: NSError(
                    domain: "MeetingStreamingPartialSession",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out finalizing live transcript audio."]
                ))
                return nil
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !state.withLock({ $0.didFail || $0.isStopped }) else { return nil }

        let finishRevision = state.withLock { state -> UInt64 in
            state.activeInferenceRevision = state.lifecycleRevision
            return state.lifecycleRevision
        }
        do {
            try await engine.finish()
        } catch {
            goDormant(error: error)
            return nil
        }
        state.withLock { state in
            if state.activeInferenceRevision == finishRevision {
                state.activeInferenceRevision = nil
            }
        }
        return state.withLock { state in
            let text = visibleTail(for: state).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    func stop() {
        state.withLock { state in
            state.isStopped = true
            state.lifecycleRevision &+= 1
            state.sampleBuffer.removeAll()
            state.chunkQueue.removeAll()
            state.engineText = ""
            state.committedPrefixLength = 0
            state.pendingSegments.removeAll()
            state.pendingPublicationTail = nil
            state.activeInferenceRevision = nil
        }
        publishImmediately("")
        Task { await engine.shutdown() }
    }

    private func drain() async {
        while true {
            let work: (chunk: [Float], revision: UInt64)? = state.withLock { state in
                guard !state.isStopped, !state.isSuspended, !state.didFail, !state.chunkQueue.isEmpty else {
                    state.isDraining = false
                    return nil
                }
                let revision = state.lifecycleRevision
                state.activeInferenceRevision = revision
                return (state.chunkQueue.removeFirst(), revision)
            }
            guard let work else { return }

            do {
                try await engine.process(samples: work.chunk)
                state.withLock { state in
                    if state.activeInferenceRevision == work.revision {
                        state.activeInferenceRevision = nil
                    }
                }
            } catch {
                goDormant(error: error)
                return
            }
        }
    }

    private func receiveEnginePartial(_ text: String) {
        let filteredText = TranscriptionEngineArtifactsFilter.apply(text)
        let tail: String? = state.withLock { state in
            guard !state.isStopped, !state.isSuspended, !state.didFail,
                  state.activeInferenceRevision == state.lifecycleRevision else { return nil }
            if filteredText.count < state.committedPrefixLength {
                state.committedPrefixLength = 0
                state.pendingSegments.removeAll()
            }
            state.engineText = filteredText
            return visibleTail(for: state)
        }
        if let tail {
            schedulePublication(tail)
        }
    }

    private func goDormant(error: Error) {
        state.withLock { state in
            state.didFail = true
            state.lifecycleRevision &+= 1
            state.isDraining = false
            state.sampleBuffer.removeAll()
            state.chunkQueue.removeAll()
            state.engineText = ""
            state.committedPrefixLength = 0
            state.pendingSegments.removeAll()
            state.activeInferenceRevision = nil
        }
        fputs("[meeting-partials] \(label) session dormant after error: \(error)\n", stderr)
        publishImmediately("")
        Task { await engine.shutdown() }
    }

    private func schedulePublication(_ tail: String) {
        let shouldSchedule = state.withLock { state -> Bool in
            guard !state.isStopped, !state.isSuspended, !state.didFail else { return false }
            guard tail != state.lastPublishedTail || state.pendingPublicationTail != nil else { return false }
            state.pendingPublicationTail = tail
            guard !state.isPublicationScheduled else { return false }
            state.isPublicationScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: Self.publicationIntervalNanoseconds)
            self?.flushScheduledPublication()
        }
    }

    private func flushScheduledPublication() {
        let tail: String? = state.withLock { state in
            state.isPublicationScheduled = false
            guard !state.isStopped, !state.isSuspended, !state.didFail,
                  let pending = state.pendingPublicationTail else {
                state.pendingPublicationTail = nil
                return nil
            }
            state.pendingPublicationTail = nil
            guard pending != state.lastPublishedTail else { return nil }
            state.lastPublishedTail = pending
            return pending
        }
        if let tail {
            onPartialUpdate?(tail)
        }
    }

    private func publishImmediately(_ tail: String, expectedRevision: UInt64? = nil) {
        let shouldPublish = state.withLock { state -> Bool in
            if let expectedRevision, expectedRevision != state.lifecycleRevision {
                return false
            }
            state.pendingPublicationTail = nil
            guard tail != state.lastPublishedTail else { return false }
            state.lastPublishedTail = tail
            return true
        }
        if shouldPublish {
            onPartialUpdate?(tail)
        }
    }

    private func visibleTail(for state: State) -> String {
        let dropCount = min(state.committedPrefixLength, state.engineText.count)
        return String(state.engineText.dropFirst(dropCount))
    }
}
