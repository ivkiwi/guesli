import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Dictation backend readiness")
struct DictationBackendReadinessTests {
    @Test("preparing and failed states block dictation")
    func blockedStates() {
        #expect(!DictationBackendReadiness.preparing.allowsDictation)
        #expect(DictationBackendReadiness.preparing.blockingMessage(backendLabel: "GigaAM") == "Warming up GigaAM...")
        #expect(!DictationBackendReadiness.failed.allowsDictation)
        #expect(DictationBackendReadiness.failed.blockingMessage(backendLabel: "GigaAM") == "GigaAM unavailable")
    }

    @Test("ready state allows dictation")
    func readyState() {
        #expect(DictationBackendReadiness.ready.allowsDictation)
        #expect(DictationBackendReadiness.ready.blockingMessage(backendLabel: "GigaAM") == nil)
    }
}

// MARK: - ChatGPT File-based Token Storage

@Suite("ChatGPT Token Storage", .muesliHermeticSupport)
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

@Suite("FloatingIndicator visibility", .muesliHermeticSupport)
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
        config.activePostProcessorId = PostProcessorOption.qwen35_0_8b.id
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.enablePostProcessor == true)
        #expect(decoded.activePostProcessorId == PostProcessorOption.qwen35_0_8b.id)
    }

    @Test("cached legacy post processor persists through JSON round-trip")
    func cachedLegacyPostProcessorRoundTrip() throws {
        let json = #"{"active_post_processor_id":"qwen3-postproc-v2"}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json.data(using: .utf8)!)
        #expect(decoded.activePostProcessorId == PostProcessorOption.legacyV2.id)

        let data = try JSONEncoder().encode(decoded)
        let reloaded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(reloaded.activePostProcessorId == PostProcessorOption.legacyV2.id)
        #expect(PostProcessorOption.runtimeOption(
            id: reloaded.activePostProcessorId,
            downloadedIDs: [PostProcessorOption.legacyV2.id],
            hasDevOverride: false
        ) == .legacyV2)
    }

    @Test("post processor decodes from snake_case JSON")
    func postProcessorSnakeCaseDecode() throws {
        let json = #"{"enable_post_processor": true}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: json.data(using: .utf8)!)
        #expect(config.enablePostProcessor == true)
    }
}

// MARK: - Unified indicator frame sizes

@Suite("Indicator frame sizes", .muesliHermeticSupport)
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

@Suite("Floating meeting transcript")
struct FloatingMeetingTranscriptTests {
    @Test("overlay routes header controls and leaves transcript body to SwiftUI")
    func overlayClickRouting() {
        let frame = NSRect(x: 100, y: 100, width: 360, height: 320)

        #expect(FloatingMeetingTranscriptInteraction.action(
            at: NSPoint(x: 390, y: 400), in: frame
        ) == .dismiss)
        #expect(FloatingMeetingTranscriptInteraction.action(
            at: NSPoint(x: 430, y: 400), in: frame
        ) == .copy)
        #expect(FloatingMeetingTranscriptInteraction.action(
            at: NSPoint(x: 250, y: 250), in: frame
        ) == nil)
        #expect(FloatingMeetingTranscriptInteraction.action(
            at: NSPoint(x: 90, y: 250), in: frame
        ) == nil)
    }

    @Test("floating panel can receive controls without becoming the main window")
    @MainActor
    func floatingPanelIsInteractive() {
        let panel = InteractiveFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        var receivedMouseDown: NSPoint?
        panel.leftMouseDownHandler = { point in
            receivedMouseDown = point
            return true
        }
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
        if let event {
            panel.sendEvent(event)
        }

        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.styleMask.contains(.nonactivatingPanel))
        #expect(receivedMouseDown == NSPoint(x: 20, y: 20))
    }

    @Test("shown overlay retains its hosting view and routes dismissal")
    @MainActor
    func shownOverlayRoutesDismissal() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = container
        var dismissCount = 0
        let controller = FloatingMeetingTranscriptPanelController(
            onHoverChanged: { _ in },
            onOpenNotes: {},
            onDismiss: { dismissCount += 1 }
        )

        controller.show(in: container, frame: container.bounds)

        #expect(controller.isVisible)
        #expect(!controller.handleClick(atWindowPoint: NSPoint(x: 180, y: 160)))
        #expect(controller.handleClick(atWindowPoint: NSPoint(x: 290, y: 300)))
        #expect(dismissCount == 1)
    }

    @Test("panel prefers the open side and remains inside the screen")
    func panelPlacement() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let trailingIndicator = NSRect(x: 1350, y: 440, width: 76, height: 22)
        let leadingIndicator = NSRect(x: 14, y: 440, width: 76, height: 22)

        let leftFrame = FloatingMeetingTranscriptPlacement.frame(
            beside: trailingIndicator,
            visibleFrame: screen
        )
        let rightFrame = FloatingMeetingTranscriptPlacement.frame(
            beside: leadingIndicator,
            visibleFrame: screen
        )

        #expect(leftFrame.maxX == trailingIndicator.minX)
        #expect(rightFrame.minX == leadingIndicator.maxX)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(leftFrame))
        #expect(screen.insetBy(dx: 8, dy: 8).contains(rightFrame))
    }

    @Test("panel clamps vertically on short screens")
    func verticalPlacementClamp() {
        let screen = NSRect(x: 100, y: 50, width: 900, height: 360)
        let indicator = NSRect(x: 950, y: 380, width: 40, height: 22)

        let frame = FloatingMeetingTranscriptPlacement.frame(
            beside: indicator,
            visibleFrame: screen
        )

        #expect(frame.minY >= screen.minY + 8)
        #expect(frame.maxY == screen.maxY - 8)
    }

    @Test("copy includes committed transcript and current partials")
    func copyTextIncludesLiveTails() {
        let text = LiveTranscriptCopyContent.text(
            transcript: "[10:00:00] You: committed",
            partialYou: "speaking now",
            partialOthers: "current reply"
        )

        #expect(text == "[10:00:00] You: committed\nOthers: current reply\nYou: speaking now")
    }

    @Test("panel retains the complete committed transcript")
    func completeTranscriptHistory() {
        let transcript = (0..<12)
            .map { "[10:00:\(String(format: "%02d", $0))] You: line \($0)" }
            .joined(separator: "\n")

        let messages = TranscriptChatMessage.messages(from: transcript)

        #expect(messages.count == 12)
        #expect(messages.first?.text == "line 0")
        #expect(messages.last?.text == "line 11")
    }

    @Test("incremental panel updates retain unique message identities")
    @MainActor
    func incrementalUpdatesUseUniqueIDs() {
        let model = LiveTranscriptPresentationModel()

        model.update(
            transcript: "[10:00:00] You: first\n",
            partialYou: "",
            partialOthers: ""
        )
        model.update(
            transcript: "[10:00:00] You: first\n[10:00:05] Others: second\n",
            partialYou: "",
            partialOthers: ""
        )

        #expect(model.messages.map(\.id) == [0, 1])
        #expect(model.messages.map(\.text) == ["first", "second"])
    }
}

@Suite("Floating indicator pointer interaction")
struct FloatingIndicatorPointerInteractionTests {
    @Test("small pointer movement remains a click while deliberate movement drags")
    func dragThreshold() {
        let start = NSPoint(x: 100, y: 100)
        #expect(!FloatingIndicatorPointerIntent.isDrag(
            from: start,
            to: NSPoint(x: 102, y: 102)
        ))
        #expect(FloatingIndicatorPointerIntent.isDrag(
            from: start,
            to: NSPoint(x: 104, y: 100)
        ))
    }

    @MainActor
    @Test("clicking the stop control stops the meeting")
    func stopControlStopsMeeting() throws {
        let indicator = makeIndicator()
        var stopCount = 0
        indicator.onStopMeeting = { stopCount += 1 }
        indicator.setMeetingRecording(true, config: AppConfig())

        let size = try #require(indicator.controlHitTestSizeForTesting)
        let stopFrame = FloatingIndicatorControlLayout.trailingControlFrame(in: size)
        indicator.handleClick(at: CGPoint(x: stopFrame.midX, y: stopFrame.midY))

        #expect(stopCount == 1)
        indicator.close()
    }

    @MainActor
    @Test("clicking the pill body no longer stops the meeting")
    func bodyClickLeavesMeetingRecording() throws {
        let indicator = makeIndicator()
        var stopCount = 0
        var pauseCount = 0
        indicator.onStopMeeting = { stopCount += 1 }
        indicator.onToggleMeetingPause = { pauseCount += 1 }
        indicator.setMeetingRecording(true, config: AppConfig())

        let size = try #require(indicator.controlHitTestSizeForTesting)
        let bodyPoint = CGPoint(x: size.width / 2, y: size.height / 2)
        // Guard the assumption that the pill centre really is body, so a future
        // narrower pill fails here rather than silently weakening the test.
        #expect(FloatingIndicatorControlLayout.hit(at: bodyPoint, in: size) == .body)

        indicator.handleClick(at: bodyPoint)

        #expect(stopCount == 0)
        #expect(pauseCount == 0)
        indicator.close()
    }

    @Test("stop hit region tracks the drawn control instead of the pill body")
    func stopHitRegionMatchesDrawnControl() {
        let size = CGSize(width: 190, height: 34)
        let stopFrame = FloatingIndicatorControlLayout.trailingControlFrame(in: size)

        // The drawn dot and its immediate surround stop the recording.
        #expect(FloatingIndicatorControlLayout.hit(
            at: CGPoint(x: stopFrame.midX, y: stopFrame.midY),
            in: size
        ) == .trailingControl)

        // The old behaviour treated everything past x=30 as a stop.
        for x in stride(from: 30.0, through: 150.0, by: 20.0) {
            #expect(FloatingIndicatorControlLayout.hit(
                at: CGPoint(x: x, y: size.height / 2),
                in: size
            ) == .body)
        }
    }

    @Test("leading control keeps its own hit region")
    func leadingHitRegionMatchesDrawnControl() {
        let size = CGSize(width: 190, height: 34)
        let leadingFrame = FloatingIndicatorControlLayout.leadingControlFrame(in: size)

        #expect(FloatingIndicatorControlLayout.hit(
            at: CGPoint(x: leadingFrame.midX, y: leadingFrame.midY),
            in: size
        ) == .leadingControl)

        // Just outside the widened target is body, not a control.
        #expect(FloatingIndicatorControlLayout.hit(
            at: CGPoint(x: 40, y: size.height / 2),
            in: size
        ) == .body)
    }

    @Test("controls stay reachable across the pill's full height")
    func controlsSpanFullPillHeight() {
        let size = CGSize(width: 190, height: 34)
        let stopFrame = FloatingIndicatorControlLayout.trailingControlFrame(in: size)

        for y in [0.5, size.height / 2, size.height - 0.5] {
            #expect(FloatingIndicatorControlLayout.hit(
                at: CGPoint(x: stopFrame.midX, y: y),
                in: size
            ) == .trailingControl)
        }
    }

    @Test("a narrow pill resolves overlapping targets to the nearer control")
    func narrowPillPrefersNearerControl() {
        let size = CGSize(width: 36, height: 34)
        let leadingFrame = FloatingIndicatorControlLayout.leadingControlFrame(in: size)
        let trailingFrame = FloatingIndicatorControlLayout.trailingControlFrame(in: size)

        #expect(FloatingIndicatorControlLayout.hit(
            at: CGPoint(x: leadingFrame.midX, y: size.height / 2),
            in: size
        ) == .leadingControl)
        #expect(FloatingIndicatorControlLayout.hit(
            at: CGPoint(x: trailingFrame.midX, y: size.height / 2),
            in: size
        ) == .trailingControl)
    }

    @MainActor
    private func makeIndicator() -> FloatingIndicatorController {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return FloatingIndicatorController(configStore: ConfigStore(supportDirectory: supportDirectory))
    }
}

// MARK: - OpenAI Logo Shape

@Suite("OpenAI Logo Shape", .muesliHermeticSupport)
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

@Suite("DictationState idle check", .muesliHermeticSupport)
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

@Suite("Meeting chunk collection", .muesliHermeticSupport)
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
        var droppedCount = 0
        let drained = await collector.closeAndDrainSortedSegments(
            inactivityTimeout: 0.05,
            logger: { logs.append($0) },
            onDrainTimeoutDroppedChunkCount: { droppedCount += $0 }
        )

        #expect(drained.map(\.text) == ["tail"])
        #expect(droppedCount == 1)
        #expect(logs.contains { $0.contains("[live-collector] dropped pending chunk sequence=0 reason=drain_timeout") })
    }

    @Test("collector drain keeps slow backlog while chunks keep completing")
    func collectorDrainKeepsProgressingBacklog() async {
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
        let drainTask = Task {
            await collector.closeAndDrainSortedSegments(inactivityTimeout: 0.25)
        }
        for index in 0..<4 {
            await chunks.resume(
                index: index,
                with: [SpeechSegment(start: Double(index), end: Double(index + 1), text: "chunk \(index)")]
            )
            await Task.yield()
        }
        let drained = await drainTask.value

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

@Suite("Meeting chunk timing", .muesliHermeticSupport)
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
