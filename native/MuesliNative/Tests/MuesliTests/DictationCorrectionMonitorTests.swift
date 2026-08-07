import Foundation
import Testing
@testable import MuesliNativeApp

@Test("AX visit key rejects non-finite geometry")
func axVisitKeyRejectsNonFiniteGeometry() {
    let fallback = DictationCorrectionMonitor.elementVisitKey(
        processID: 42,
        role: "AXTextArea",
        position: CGPoint(x: CGFloat.nan, y: 20),
        size: CGSize(width: 100, height: 50),
        fallbackHash: 9_001
    )
    let finite = DictationCorrectionMonitor.elementVisitKey(
        processID: 42,
        role: "AXTextArea",
        position: CGPoint(x: 12.9, y: -3.7),
        size: CGSize(width: 100.8, height: 50.2),
        fallbackHash: 9_001
    )

    #expect(fallback == "42|AXTextArea|9001")
    #expect(finite == "42|AXTextArea|12|-3|100|50")
}
