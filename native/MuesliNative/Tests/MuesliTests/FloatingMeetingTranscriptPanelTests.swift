import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Floating meeting transcript")
struct FloatingMeetingTranscriptPanelTests {
    @Test("panel chooses the open side and stays inside the screen")
    func placement() {
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

        #expect(leftFrame.maxX < trailingIndicator.minX)
        #expect(rightFrame.minX > leadingIndicator.maxX)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(leftFrame))
        #expect(screen.insetBy(dx: 8, dy: 8).contains(rightFrame))
    }

    @Test("panel clamps vertically")
    func verticalClamp() {
        let screen = NSRect(x: 100, y: 50, width: 900, height: 360)
        let indicator = NSRect(x: 950, y: 380, width: 40, height: 22)

        let frame = FloatingMeetingTranscriptPlacement.frame(
            beside: indicator,
            visibleFrame: screen
        )

        #expect(frame.minY >= screen.minY + 8)
        #expect(frame.maxY == screen.maxY - 8)
    }
}
