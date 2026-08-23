import AppIntents
import Foundation
import MuesliNativeApp

@available(macOS 13.0, *)
private enum GuesliShortcutsError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case notRunning

    var localizedStringResource: LocalizedStringResource {
        "Guesli did not finish opening. Try again."
    }
}

@available(macOS 13.0, *)
private enum GuesliShortcutsRuntime {
    @MainActor
    static func waitForController(timeout: TimeInterval = 5) async throws -> MuesliController {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let controller = MuesliController.current { return controller }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let controller = MuesliController.current else {
            throw GuesliShortcutsError.notRunning
        }
        return controller
    }
}

@available(macOS 13.0, *)
struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dictation"
    static var description = IntentDescription("Starts hands-free Guesli dictation.")
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let controller = try await GuesliShortcutsRuntime.waitForController()
        return .result(value: controller.startDictationForShortcuts())
    }
}

@available(macOS 13.0, *)
struct StopDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Dictation"
    static var description = IntentDescription("Stops an in-progress Guesli dictation and inserts its transcript.")
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let controller = try await GuesliShortcutsRuntime.waitForController()
        return .result(value: controller.stopDictationForShortcuts())
    }
}

@available(macOS 13.0, *)
struct StartMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Meeting Recording"
    static var description = IntentDescription("Starts a Guesli meeting recording with microphone and system audio.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Title", default: "Meeting")
    var meetingTitle: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let controller = try await GuesliShortcutsRuntime.waitForController()
        return .result(value: controller.startMeetingRecordingForShortcuts(title: meetingTitle))
    }
}

@available(macOS 13.0, *)
struct StopMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Meeting Recording"
    static var description = IntentDescription("Stops an in-progress Guesli meeting recording.")
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let controller = try await GuesliShortcutsRuntime.waitForController()
        return .result(value: controller.stopMeetingRecordingForShortcuts())
    }
}

@available(macOS 13.0, *)
struct GuesliAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: ["Start dictation in \(.applicationName)"],
            shortTitle: "Start Dictation",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: StopDictationIntent(),
            phrases: ["Stop dictation in \(.applicationName)"],
            shortTitle: "Stop Dictation",
            systemImageName: "mic.slash"
        )
        AppShortcut(
            intent: StartMeetingIntent(),
            phrases: ["Start a meeting recording in \(.applicationName)"],
            shortTitle: "Start Meeting Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopMeetingIntent(),
            phrases: ["Stop the meeting recording in \(.applicationName)"],
            shortTitle: "Stop Meeting Recording",
            systemImageName: "stop.circle"
        )
    }
}
