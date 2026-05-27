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
            shouldAttemptAppleScript: { _ in false }
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
            shouldAttemptAppleScript: { _ in false }
        )

        focusedURL = nil
        let second = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now.addingTimeInterval(1),
            shouldAttemptAppleScript: { _ in false }
        )
        let cachedAfterFailedRefresh = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(2),
            shouldAttemptAppleScript: { _ in false }
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(cachedAfterFailedRefresh.isEmpty)
    }

    @Test("refresh preserves cache when AppleScript probe is throttled")
    func refreshPreservesCacheWhenAppleScriptProbeIsThrottled() async {
        var activeTabURL: String? = "https://meet.google.com/pwm-txwq-txy"
        let collector = BrowserMeetingActivityCollector(
            activeBrowserURLProvider: { _ in activeTabURL },
            isBrowserProcessRunningProvider: { _ in true }
        )

        let first = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptAppleScript: { _ in true }
        )

        activeTabURL = nil
        let second = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now.addingTimeInterval(1),
            shouldAttemptAppleScript: { _ in false }
        )
        let cachedAfterSkippedRefresh = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(2),
            shouldAttemptAppleScript: { _ in false }
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(cachedAfterSkippedRefresh.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
    }

    @Test("refresh clears cache when AppleScript probe runs and finds no meeting URL")
    func refreshClearsCacheWhenAppleScriptProbeFindsNoMeetingURL() async {
        var activeTabURL: String? = "https://meet.google.com/pwm-txwq-txy"
        let collector = BrowserMeetingActivityCollector(
            activeBrowserURLProvider: { _ in activeTabURL },
            isBrowserProcessRunningProvider: { _ in true }
        )

        let first = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptAppleScript: { _ in true }
        )

        activeTabURL = "https://example.com"
        let second = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now.addingTimeInterval(1),
            shouldAttemptAppleScript: { _ in true }
        )
        let cachedAfterFailedRefresh = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(2),
            shouldAttemptAppleScript: { _ in false }
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(cachedAfterFailedRefresh.isEmpty)
    }

    @Test("refresh skips AppleScript when browser process from snapshot has exited")
    func refreshSkipsAppleScriptWhenBrowserProcessHasExited() async {
        var didAttemptAppleScriptProbe = false
        let collector = BrowserMeetingActivityCollector(
            activeBrowserURLProvider: { _ in
                didAttemptAppleScriptProbe = true
                return "https://meet.google.com/pwm-txwq-txy"
            },
            isBrowserProcessRunningProvider: { _ in false }
        )

        let meetings = await collector.collect(
            runningApps: [brave(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptAppleScript: { _ in true }
        )

        #expect(meetings.isEmpty)
        #expect(didAttemptAppleScriptProbe == false)
    }

    @Test("refresh checks exact browser process before AppleScript")
    func refreshChecksExactBrowserProcessBeforeAppleScript() async {
        var probedPID: pid_t?
        let collector = BrowserMeetingActivityCollector(
            activeBrowserURLProvider: { app in
                probedPID = app.processIdentifier
                return "https://meet.google.com/pwm-txwq-txy"
            },
            isBrowserProcessRunningProvider: { app in app.processIdentifier == 1234 }
        )

        let meetings = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: true,
            now: now,
            shouldAttemptAppleScript: { _ in true }
        )

        #expect(meetings.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
        #expect(probedPID == 1234)
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
            shouldAttemptAppleScript: { _ in false }
        )

        focusedURL = nil
        let cached = await collector.collect(
            runningApps: [chrome(isActive: false)],
            refresh: false,
            now: now.addingTimeInterval(1),
            shouldAttemptAppleScript: { _ in false }
        )

        #expect(cached.map(\.normalizedID) == ["googleMeet:meet.google.com/pwm-txwq-txy"])
        #expect(cached.first?.isFocused == false)
    }
}
