import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("BrowserMeetingActivityCollector")
struct BrowserMeetingActivityCollectorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func chrome(isActive: Bool) -> RunningAppSnapshot {
        RunningAppSnapshot(
            bundleID: "com.google.Chrome",
            appName: "Chrome",
            processIdentifier: 1234,
            isActive: isActive
        )
    }

    private func brave(isActive: Bool) -> RunningAppSnapshot {
        RunningAppSnapshot(
            bundleID: "com.brave.Browser",
            appName: "Brave Browser",
            processIdentifier: 4321,
            isActive: isActive
        )
    }

    @Test("refresh probes inactive uncached browsers")
    func refreshProbesInactiveUncachedBrowsers() async {
        let collector = BrowserMeetingActivityCollector(
            focusedDocumentURLProvider: { app in
                app.bundleID == "com.google.Chrome" ? "https://meet.google.com/pwm-txwq-txy" : nil
            }
        )

        let meetings = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptActiveTabFallback: { _ in false }
        )

        #expect(meetings.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
        #expect(meetings.first?.isFocused == false)
    }

    @Test("refresh clears stale cached room when browser no longer reports a meeting URL")
    func refreshClearsStaleCachedRoom() async {
        var focusedURL: String? = "https://meet.google.com/pwm-txwq-txy"
        let collector = BrowserMeetingActivityCollector(
            focusedDocumentURLProvider: { _ in focusedURL }
        )

        let first = await collector.collect(
            runningApps: [chrome(isActive: true)],
            refresh: true,
            now: now,
            shouldAttemptActiveTabFallback: { _ in false }
        )

        focusedURL = nil
        let second = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now.addingTimeInterval(1),
            shouldAttemptActiveTabFallback: { _ in false }
        )
        let cachedAfterFailedRefresh = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(2),
            shouldAttemptActiveTabFallback: { _ in false }
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(cachedAfterFailedRefresh.isEmpty)
    }

    @Test("refresh falls through to active-tab fallback when document URL is not a meeting")
    func refreshFallsThroughToActiveTabFallbackWhenDocumentURLIsNotMeeting() async {
        let collector = BrowserMeetingActivityCollector(
            focusedDocumentURLProvider: { _ in "https://example.com" },
            activeTabURLProvider: { _ in "https://meet.google.com/pwm-txwq-txy" }
        )

        let meetings = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptActiveTabFallback: { _ in true }
        )

        #expect(meetings.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
    }

    @Test("refresh skips cached room when ordinary active-tab fallback probe is throttled")
    func refreshSkipsCachedRoomWhenOrdinaryActiveTabFallbackProbeIsThrottled() async {
        var activeTabURL: String? = "https://meet.google.com/pwm-txwq-txy"
        let collector = BrowserMeetingActivityCollector(
            activeTabURLProvider: { _ in activeTabURL }
        )

        let first = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptActiveTabFallback: { _ in true }
        )

        activeTabURL = nil
        let second = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now.addingTimeInterval(1),
            shouldAttemptActiveTabFallback: { _ in false }
        )
        let cachedAfterSkippedRefresh = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(2),
            shouldAttemptActiveTabFallback: { _ in false }
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(cachedAfterSkippedRefresh.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
    }

    @Test("refresh returns cached room when active-tab fallback times out")
    func refreshReturnsCachedRoomWhenActiveTabFallbackTimesOut() async {
        var activeTabResult: BrowserActiveTabProbeResult = .url("https://meet.google.com/pwm-txwq-txy")
        var documentURLProbe: BrowserDocumentURLProbeResult = .noDocumentURL
        let collector = BrowserMeetingActivityCollector(
            documentURLProbeProvider: { _ in documentURLProbe },
            activeTabProbeResultProvider: { _ in activeTabResult }
        )

        let first = await collector.collect(
            runningApps: [chrome(isActive: true)],
            refresh: true,
            now: now,
            shouldAttemptActiveTabFallback: { _ in true }
        )

        activeTabResult = .timedOut
        let second = await collector.collect(
            runningApps: [chrome(isActive: true)],
            refresh: true,
            now: now.addingTimeInterval(1),
            shouldAttemptActiveTabFallback: { _ in true }
        )
        let cachedAfterTimeout = await collector.collect(
            runningApps: [chrome(isActive: true)],
            refresh: false,
            now: now.addingTimeInterval(2),
            shouldAttemptActiveTabFallback: { _ in false }
        )
        let throttledAfterTimeout = await collector.collect(
            runningApps: [chrome(isActive: true)],
            refresh: true,
            now: now.addingTimeInterval(3),
            shouldAttemptActiveTabFallback: { _ in false }
        )

        documentURLProbe = .nonMeetingDocument
        let clearedByNonMeetingDocument = await collector.collect(
            runningApps: [chrome(isActive: true)],
            refresh: true,
            now: now.addingTimeInterval(4),
            shouldAttemptActiveTabFallback: { _ in false }
        )
        let cachedAfterNonMeetingDocument = await collector.collect(
            runningApps: [chrome(isActive: true)],
            refresh: false,
            now: now.addingTimeInterval(5),
            shouldAttemptActiveTabFallback: { _ in false }
        )

        #expect(first.count == 1)
        #expect(second.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
        #expect(cachedAfterTimeout.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
        #expect(throttledAfterTimeout.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
        #expect(clearedByNonMeetingDocument.isEmpty)
        #expect(cachedAfterNonMeetingDocument.isEmpty)
    }

    @Test("refresh clears cache when active-tab fallback probe runs and finds no meeting URL")
    func refreshClearsCacheWhenActiveTabFallbackProbeFindsNoMeetingURL() async {
        var activeTabURL: String? = "https://meet.google.com/pwm-txwq-txy"
        let collector = BrowserMeetingActivityCollector(
            activeTabURLProvider: { _ in activeTabURL }
        )

        let first = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptActiveTabFallback: { _ in true }
        )

        activeTabURL = "https://example.com"
        let second = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now.addingTimeInterval(1),
            shouldAttemptActiveTabFallback: { _ in true }
        )
        let cachedAfterFailedRefresh = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(2),
            shouldAttemptActiveTabFallback: { _ in false }
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(cachedAfterFailedRefresh.isEmpty)
    }

    @Test("refresh clears cache when active-tab fallback has no URL")
    func refreshClearsCacheWhenActiveTabFallbackHasNoURL() async {
        var activeTabURL: String? = "https://meet.google.com/pwm-txwq-txy"
        let collector = BrowserMeetingActivityCollector(
            activeTabURLProvider: { _ in activeTabURL }
        )

        let first = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptActiveTabFallback: { _ in true }
        )

        activeTabURL = nil
        let second = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now.addingTimeInterval(1),
            shouldAttemptActiveTabFallback: { _ in true }
        )
        let cachedAfterMissingURL = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(2),
            shouldAttemptActiveTabFallback: { _ in false }
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(cachedAfterMissingURL.isEmpty)
    }

    @Test("refresh skips active-tab fallback when fallback is disabled")
    func refreshSkipsActiveTabFallbackWhenFallbackIsDisabled() async {
        var didAttemptActiveTabFallbackProbe = false
        let collector = BrowserMeetingActivityCollector(activeTabFallbackEnabled: false)

        let meetings = await collector.collect(
            runningApps: [brave(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptActiveTabFallback: { _ in
                didAttemptActiveTabFallbackProbe = true
                return true
            }
        )

        #expect(meetings.isEmpty)
        #expect(didAttemptActiveTabFallbackProbe == false)
    }

    @Test("non-refresh pass can reuse recent cached browser room")
    func nonRefreshPassCanReuseRecentCachedRoom() async {
        var focusedURL: String? = "https://meet.google.com/pwm-txwq-txy"
        let collector = BrowserMeetingActivityCollector(
            focusedDocumentURLProvider: { _ in focusedURL }
        )

        _ = await collector.collect(
            runningApps: [chrome(isActive: true)],
            refresh: true,
            now: now,
            shouldAttemptActiveTabFallback: { _ in false }
        )

        focusedURL = nil
        let cached = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(1),
            shouldAttemptActiveTabFallback: { _ in false }
        )

        #expect(cached.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
        #expect(cached.first?.isFocused == false)
    }

    @Test("non-refresh pass does not promote cached background room to focused")
    func nonRefreshPassDoesNotPromoteCachedBackgroundRoomToFocused() async {
        let collector = BrowserMeetingActivityCollector(
            activeTabURLProvider: { _ in "https://meet.google.com/pwm-txwq-txy" }
        )

        _ = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptActiveTabFallback: { _ in true }
        )

        let cached = await collector.collect(
            runningApps: [chrome(isActive: true)],
            refresh: false,
            now: now.addingTimeInterval(1),
            shouldAttemptActiveTabFallback: { _ in false }
        )

        #expect(cached.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
        #expect(cached.first?.isFocused == false)
    }
}
