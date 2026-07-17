import Foundation
import FluidAudio
import os
import Testing
@testable import MuesliNativeApp

@Suite("Optional Parakeet meeting captions")
struct MeetingParakeetLiveCaptionSessionTests {
    @Test("model is available only after every artifact exists")
    func modelAvailabilityRequiresEveryArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = MeetingParakeetLiveCaptionModelStore.modelDirectory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(!MeetingParakeetLiveCaptionModelStore.isDownloaded(in: root))
        for artifact in ModelNames.ParakeetEOU.requiredModels {
            let url = directory.appendingPathComponent(artifact)
            if artifact.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data().write(to: url)
            }
        }
        #expect(MeetingParakeetLiveCaptionModelStore.isDownloaded(in: root))
    }

    @Test("bounded queue keeps freshest live-caption chunks")
    func backpressureDropsOldestChunks() async {
        let engine = ParakeetEchoPartialEngine()
        let session = MeetingStreamingPartialSession(engine: engine, label: "You")
        let collector = ParakeetPartialCollector()
        session.onPartialUpdate = { collector.record($0) }
        await session.connect()

        var input: [Float] = []
        for marker in 0..<7 {
            input.append(contentsOf: [Float](
                repeating: Float(marker),
                count: MeetingStreamingPartialSession.feedSamples
            ))
        }
        session.enqueue(input)

        #expect(await waitForParakeetCaption { collector.latest == "c4 c5 c6" })
        #expect(engine.processCalls == MeetingStreamingPartialSession.maxQueuedChunks)
    }

    @Test("finalization drains residual audio without replacing durable transcript")
    func finishDrainsResidualAudio() async {
        let engine = ParakeetScriptedPartialEngine(finishText: "partial final")
        let session = MeetingStreamingPartialSession(engine: engine, label: "Others")
        await session.connect()

        session.enqueue([Float](
            repeating: 0,
            count: MeetingStreamingPartialSession.feedSamples - 1
        ))
        let tail = await session.finish()

        #expect(engine.processCalls == 1)
        #expect(engine.finishCalls == 1)
        #expect(tail == "partial final")
    }
}

private final class ParakeetEchoPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (String) -> Void)?
        var processCalls = 0
        var text = ""
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var processCalls: Int { state.withLock { $0.processCalls } }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        state.withLock { $0.handler = handler }
    }

    func process(samples: [Float]) async throws {
        let update = state.withLock { state -> (String, (@Sendable (String) -> Void)?) in
            state.processCalls += 1
            state.text += state.text.isEmpty ? "c\(Int(samples.first ?? -1))" : " c\(Int(samples.first ?? -1))"
            return (state.text, state.handler)
        }
        update.1?(update.0)
    }

    func shutdown() async {}
}

private final class ParakeetScriptedPartialEngine: MeetingStreamingPartialEngine, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (String) -> Void)?
        var processCalls = 0
        var finishCalls = 0
    }

    private let finishText: String
    private let state = OSAllocatedUnfairLock(initialState: State())
    var processCalls: Int { state.withLock { $0.processCalls } }
    var finishCalls: Int { state.withLock { $0.finishCalls } }

    init(finishText: String) {
        self.finishText = finishText
    }

    func setPartialHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        state.withLock { $0.handler = handler }
    }

    func process(samples: [Float]) async throws {
        state.withLock { $0.processCalls += 1 }
    }

    func finish() async throws {
        let handler = state.withLock { state -> (@Sendable (String) -> Void)? in
            state.finishCalls += 1
            return state.handler
        }
        handler?(finishText)
    }

    func shutdown() async {}
}

private final class ParakeetPartialCollector: @unchecked Sendable {
    private let updates = OSAllocatedUnfairLock(initialState: [String]())

    func record(_ text: String) {
        updates.withLock { $0.append(text) }
    }

    var latest: String? { updates.withLock { $0.last } }
}

private func waitForParakeetCaption(
    timeout: TimeInterval = 2,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
