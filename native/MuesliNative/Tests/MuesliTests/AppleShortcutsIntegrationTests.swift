import Foundation
import Testing

@Suite("Apple Shortcuts integration")
struct AppleShortcutsIntegrationTests {
    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    @Test("shell declares four local control intents")
    func declaresControlIntents() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "native/MuesliNative/Sources/MuesliNativeAppShell/GuesliAppIntents.swift"
            ),
            encoding: .utf8
        )

        for intent in [
            "StartDictationIntent",
            "StopDictationIntent",
            "StartMeetingIntent",
            "StopMeetingIntent",
        ] {
            #expect(source.contains("struct \(intent): AppIntent"))
        }
        #expect(source.components(separatedBy: "static var openAppWhenRun: Bool { true }").count - 1 == 4)
        #expect(source.components(separatedBy: "AppShortcut(").count - 1 == 4)
        #expect(source.contains("GuesliAppShortcuts: AppShortcutsProvider"))
        #expect(!source.contains("GetLast"))
    }

    @Test("controller exposes guarded control entry points")
    func controllerEntryPoints() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "native/MuesliNative/Sources/MuesliNativeApp/MuesliController.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("public static weak var current: MuesliController?"))
        #expect(source.contains("public func startDictationForShortcuts() -> Bool"))
        #expect(source.contains("public func stopDictationForShortcuts() -> Bool"))
        #expect(source.contains("public func startMeetingRecordingForShortcuts(title: String = \"Meeting\") -> Bool"))
        #expect(source.contains("public func stopMeetingRecordingForShortcuts() -> Bool"))
        #expect(source.contains("!isStartingMeetingRecording else { return false }"))
    }
}
