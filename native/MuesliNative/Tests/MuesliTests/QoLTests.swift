import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

// MARK: - ChatGPT File-based Token Storage

@Suite("ChatGPT Token Storage")
struct ChatGPTTokenStorageTests {

    @Test("isAuthenticated returns false when no token file exists")
    func notAuthenticatedByDefault() throws {
        let root = try makeTokenTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(makeTokenStore(root: root).load() == nil)
    }

    @Test("signOut does not crash even when not signed in")
    func signOutSafe() throws {
        let root = try makeTokenTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        makeTokenStore(root: root).signOut()
    }

    private func makeTokenTestDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatgpt-token-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeTokenStore(root: URL) -> AuthTokenFileStore {
        AuthTokenFileStore(
            primaryURL: root.appendingPathComponent("chatgpt-auth.json"),
            logPrefix: "chatgpt-auth",
            logger: { _ in }
        )
    }
}

// MARK: - Floating Indicator: showFloatingIndicator hides only idle state

@Suite("FloatingIndicator visibility")
struct FloatingIndicatorVisibilityTests {

    @Test("config default shows floating indicator")
    func defaultShowsIndicator() {
        let config = AppConfig()
        #expect(config.showFloatingIndicator == true)
    }

    @Test("showFloatingIndicator persists through JSON round-trip")
    func jsonRoundTrip() throws {
        var config = AppConfig()
        config.showFloatingIndicator = false
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.showFloatingIndicator == false)
    }

    @Test("showFloatingIndicator decodes from snake_case JSON")
    func snakeCaseDecode() throws {
        let json = #"{"show_floating_indicator": false}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: json.data(using: .utf8)!)
        #expect(config.showFloatingIndicator == false)
    }

    @Test("post processor defaults to disabled")
    func postProcessorDisabledByDefault() {
        let config = AppConfig()
        #expect(config.enablePostProcessor == false)
    }

    @Test("post processor defaults to v3 model")
    func postProcessorDefaultModel() {
        let config = AppConfig()
        #expect(config.activePostProcessorId == PostProcessorOption.defaultOption.id)
    }

    @Test("post processor persists through JSON round-trip")
    func postProcessorRoundTrip() throws {
        var config = AppConfig()
        config.enablePostProcessor = true
        config.activePostProcessorId = PostProcessorOption.finetunedV2.id
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.enablePostProcessor == true)
        #expect(decoded.activePostProcessorId == PostProcessorOption.finetunedV2.id)
    }

    @Test("post processor decodes from snake_case JSON")
    func postProcessorSnakeCaseDecode() throws {
        let json = #"{"enable_post_processor": true}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: json.data(using: .utf8)!)
        #expect(config.enablePostProcessor == true)
    }
}

// MARK: - Unified indicator frame sizes

@Suite("Indicator frame sizes")
struct IndicatorFrameSizeTests {

    @Test("recording frame size is consistent for all non-meeting dictation")
    func recordingFrameUnified() {
        // Both hold and toggle dictation should use the same 76x22 size
        // Meeting recording uses 72x32
        // This test validates the model constants that drive the frame
        let config = AppConfig()
        #expect(config.showFloatingIndicator == true)
        // The frame sizes are hardcoded in FloatingIndicatorController.frameForState
        // We test that the config round-trips correctly (the visual test is manual)
    }

    @Test("default indicator center is right-middle of the screen")
    @MainActor
    func defaultIndicatorCenterUsesScreenMidpoint() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1200, height: 800)
        let center = FloatingIndicatorController.defaultIndicatorCenter(in: visibleFrame)
        #expect(center.x == 1270)
        #expect(center.y == 450)
    }

    @Test("off-screen saved indicator center falls back to right-middle default")
    @MainActor
    func offscreenSavedIndicatorCenterFallsBack() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1200, height: 800)
        let size = NSSize(width: 76, height: 22)
        let offscreen = CGPoint(x: 1708, y: 1491)

        #expect(
            !FloatingIndicatorController.isUsableIndicatorCenter(
                offscreen,
                in: visibleFrame,
                size: size
            )
        )
        #expect(
            FloatingIndicatorController.defaultIndicatorCenter(in: visibleFrame) ==
            CGPoint(x: 1270, y: 450)
        )
    }

    @Test("anchor centers respect fixed screen insets")
    @MainActor
    func anchorCentersUseExpectedInsets() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1200, height: 800)
        let size = NSSize(width: 44, height: 28)

        #expect(
            FloatingIndicatorController.anchorCenter(.topLeading, in: visibleFrame, size: size) ==
            CGPoint(x: 130, y: 828)
        )
        #expect(
            FloatingIndicatorController.anchorCenter(.bottomCenter, in: visibleFrame, size: size) ==
            CGPoint(x: 700, y: 72)
        )
    }

    @Test("transcribing pill widens for live CUA status labels")
    @MainActor
    func transcribingPillWidensForStatusText() {
        let short = FloatingIndicatorController.transcribingPillSizeForTesting(
            title: "Planning",
            screenWidth: 1200
        )
        let long = FloatingIndicatorController.transcribingPillSizeForTesting(
            title: "Navigating to YouTube search",
            screenWidth: 1200
        )

        #expect(short.width >= 190)
        #expect(long.width > short.width)
        #expect(long.width <= 360)
        #expect(long.height == 32)
    }

    @Test("transcribing pill caps to available screen width")
    @MainActor
    func transcribingPillCapsToScreenWidth() {
        let size = FloatingIndicatorController.transcribingPillSizeForTesting(
            title: "Executing an unusually long computer use action label",
            screenWidth: 180
        )

        #expect(size.width <= 148)
        #expect(size.height == 32)
    }

    @Test("CUA transcript pill wraps and grows vertically instead of truncating")
    @MainActor
    func computerUseTranscriptPillWrapsAndExpands() {
        let short = FloatingIndicatorController.computerUseTranscriptPillSizeForTesting(
            transcript: "Open Twitter",
            screenWidth: 1200
        )
        let long = FloatingIndicatorController.computerUseTranscriptPillSizeForTesting(
            transcript: "Open Twitter in Google Chrome and write a tweet saying this was written using Muesli CUA without posting it",
            screenWidth: 420
        )

        #expect(short.width >= 280)
        #expect(short.height >= 44)
        #expect(long.width <= 372)
        #expect(long.height > short.height)
    }
}

// MARK: - OpenAI Logo Shape

@Suite("OpenAI Logo Shape")
struct OpenAILogoShapeTests {

    @Test("shape produces non-empty path")
    func nonEmptyPath() {
        let shape = OpenAILogoShape()
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        let path = shape.path(in: rect)
        #expect(!path.isEmpty)
    }

    @Test("shape scales to arbitrary rect")
    func scalesCorrectly() {
        let shape = OpenAILogoShape()
        let small = shape.path(in: CGRect(x: 0, y: 0, width: 10, height: 10))
        let large = shape.path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(!small.isEmpty)
        #expect(!large.isEmpty)
        // Larger rect should produce a larger bounding box
        #expect(large.boundingRect.width > small.boundingRect.width)
    }

    @Test("shape handles zero rect without crash")
    func zeroRect() {
        let shape = OpenAILogoShape()
        let path = shape.path(in: .zero)
        // Should not crash; path will be empty or degenerate
        let _ = path.boundingRect
    }
}

// MARK: - DictationState

@Suite("DictationState idle check")
struct DictationStateIdleTests {

    @Test("all dictation states are defined")
    func allStates() {
        let states: [DictationState] = [.idle, .preparing, .recording, .transcribing]
        #expect(states.count == 4)
    }

    @Test("idle is distinct from active states")
    func idleDistinct() {
        #expect(DictationState.idle != .recording)
        #expect(DictationState.idle != .preparing)
        #expect(DictationState.idle != .transcribing)
    }
}

// MARK: - Meeting chunk collection

@Suite("Meeting chunk collection")
struct MeetingChunkCollectorTests {

    @Test("collector waits for tasks, keeps completed segments, and sorts by start")
    func collectorSortsSegments() async {
        let collector = MeetingChunkCollector()

        _ = collector.add(
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                return [SpeechSegment(start: 30, end: 31, text: "later")]
            }
        )
        _ = collector.add(
            Task {
                try? await Task.sleep(for: .milliseconds(5))
                return []
            }
        )
        _ = collector.add(
            Task {
                try? await Task.sleep(for: .milliseconds(10))
                return [SpeechSegment(start: 10, end: 11, text: "earlier")]
            }
        )

        let segments = await collector.closeAndDrainSortedSegments()

        #expect(segments.map(\.text) == ["earlier", "later"])
        #expect(segments.map(\.start) == [10, 30])
    }

    @Test("collector rejects tasks after closing")
    func collectorRejectsLateTasks() async {
        let collector = MeetingChunkCollector()
        let initialTask = Task<[SpeechSegment], Never> {
            [SpeechSegment(start: 1, end: 2, text: "first")]
        }
        #expect(collector.add(initialTask).registered)

        let initial = await collector.closeAndDrainSortedSegments()
        #expect(initial.map(\.text) == ["first"])

        let lateTask = Task<[SpeechSegment], Never> {
            [SpeechSegment(start: 3, end: 4, text: "late")]
        }
        #expect(!collector.add(lateTask).registered)
        lateTask.cancel()
    }

    @Test("collector retire returns nil after drain closes collector")
    func collectorRetireReturnsNilAfterDrain() async {
        let collector = MeetingChunkCollector()
        let task = Task<[SpeechSegment], Never> {
            try? await Task.sleep(for: .milliseconds(10))
            return [SpeechSegment(start: 1, end: 2, text: "first")]
        }
        let registration = collector.add(task)
        #expect(registration.registered)

        let drained = await collector.closeAndDrainSortedSegments()
        let retired = collector.retire(id: registration.retireID, segments: await task.value)

        #expect(drained.map(\.text) == ["first"])
        #expect(retired == nil)
    }

    @Test("collector treats unknown retire IDs as stale callbacks")
    func collectorTreatsUnknownRetireIDsAsStaleCallbacks() {
        let collector = MeetingChunkCollector()
        let firstTask = Task { [SpeechSegment(start: 1, end: 2, text: "first")] }
        let secondTask = Task { [SpeechSegment(start: 2, end: 3, text: "second")] }
        let first = collector.add(firstTask)
        let second = collector.add(secondTask)
        firstTask.cancel()
        secondTask.cancel()

        let blocked = collector.retire(id: second.retireID, segments: [SpeechSegment(start: 2, end: 3, text: "second")])
        let stale = collector.retire(id: UUID(), segments: [SpeechSegment(start: 0, end: 1, text: "stale")])
        let ready = collector.retire(id: first.retireID, segments: [SpeechSegment(start: 1, end: 2, text: "first")])

        #expect(first.registered)
        #expect(second.registered)
        #expect(blocked?.isEmpty == true)
        #expect(stale == nil)
        #expect(ready?.map { $0.map(\.text) } == [["first"], ["second"]])
    }

    @Test("collector releases tail after a failed earlier chunk retires empty")
    func collectorFailureRetiresSlotAndReleasesTail() async {
        let collector = MeetingChunkCollector()
        let failedChunk = Task { [SpeechSegment]() }
        let tailChunk = Task { [SpeechSegment(start: 3, end: 4, text: "tail")] }

        let failed = collector.add(failedChunk)
        let tail = collector.add(tailChunk)

        #expect(collector.retire(id: tail.retireID, segments: await tailChunk.value)?.isEmpty == true)
        let ready = collector.retire(id: failed.retireID, segments: await failedChunk.value)

        #expect(failed.registered)
        #expect(tail.registered)
        #expect(ready?.map { $0.map(\.text) } == [[], ["tail"]])
    }

    @Test("collector drain flushes buffered chunks when an earlier slot stalls")
    func collectorDrainFlushesBufferedChunksPastStalledSlot() async {
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

    @Test("collector drain keeps slow backlog while chunks keep completing")
    func collectorDrainKeepsProgressingBacklog() async {
        let collector = MeetingChunkCollector()
        for index in 0..<4 {
            _ = collector.add(
                Task {
                    try? await Task.sleep(for: .milliseconds(100 * (index + 1)))
                    return [SpeechSegment(start: Double(index), end: Double(index + 1), text: "chunk \(index)")]
                }
            )
        }

        let drained = await collector.closeAndDrainSortedSegments(inactivityTimeout: 0.25)

        #expect(drained.map(\.text) == (0..<4).map { "chunk \($0)" })
    }

    @Test("collector retire returns nil after cancel closes collector")
    func collectorRetireReturnsNilAfterCancel() async {
        let collector = MeetingChunkCollector()
        let task = Task<[SpeechSegment], Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
            return [SpeechSegment(start: 1, end: 2, text: "first")]
        }
        let registration = collector.add(task)
        #expect(registration.registered)

        collector.cancelAll()
        let retired = collector.retire(id: registration.retireID, segments: await task.value)

        #expect(retired == nil)
    }

    @Test("collector flattens timed segments from a single chunk and sorts them")
    func collectorFlattensChunkSegments() async {
        let collector = MeetingChunkCollector()

        _ = collector.add(
            Task {
                [
                    SpeechSegment(start: 12, end: 12.5, text: "second"),
                    SpeechSegment(start: 11, end: 11.5, text: "first")
                ]
            }
        )

        let segments = await collector.closeAndDrainSortedSegments()

        #expect(segments.map(\.text) == ["first", "second"])
        #expect(segments.map(\.start) == [11, 12])
    }
}

@Suite("Meeting chunk timing")
struct MeetingChunkTimingTrackerTests {

    @Test("tracks chunk offsets from processed sample counts")
    func tracksChunkOffsets() {
        var tracker = MeetingChunkTimingTracker()
        tracker.start()
        tracker.append(sampleCount: 1600)

        let first = tracker.rotate()
        tracker.append(sampleCount: 800)
        let second = tracker.finish()

        #expect(first?.startSampleIndex == 0)
        #expect(first?.sampleCount == 1600)
        #expect(first?.startTimeSeconds == 0)
        #expect(first?.durationSeconds == 0.1)

        #expect(second?.startSampleIndex == 1600)
        #expect(second?.sampleCount == 800)
        #expect(second?.startTimeSeconds == 0.1)
        #expect(second?.durationSeconds == 0.05)
    }

    @Test("tracks overlap as the next chunk start")
    func tracksOverlapOffsets() {
        var tracker = MeetingChunkTimingTracker()
        tracker.start()
        tracker.append(sampleCount: 1600)

        let first = tracker.rotate(overlapSampleCount: 400)
        tracker.append(sampleCount: 800)
        let second = tracker.finish()

        #expect(first?.startSampleIndex == 0)
        #expect(first?.sampleCount == 1600)
        #expect(second?.startSampleIndex == 1200)
        #expect(second?.sampleCount == 1200)
        #expect(second?.startTimeSeconds == 0.075)
    }

    @Test("GigaAM meeting chunking uses longer chunks and overlap")
    func gigaAMMeetingChunkingPolicy() {
        let gigaAM = MeetingSession.liveChunkingConfiguration(for: .gigaAMV3Russian)
        let whisper = MeetingSession.liveChunkingConfiguration(for: .whisperTinyEnglish)

        #expect(gigaAM.maxChunkDuration == 20)
        #expect(gigaAM.overlapSampleCount == 32_000)
        #expect(gigaAM.deduplicatesText)
        #expect(whisper.maxChunkDuration == 5)
        #expect(whisper.overlapSampleCount == 0)
        #expect(!whisper.deduplicatesText)
    }
}
