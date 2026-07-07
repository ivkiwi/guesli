import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("DiagnosticIncident", .muesliHermeticSupport)
struct DiagnosticIncidentTests {

    @Test("sanitizes incident fields and avoids raw error messages")
    func sanitizesIncidentFields() {
        let metadata = DiagnosticAppMetadata(
            appVersion: "1.2.3",
            buildNumber: "456",
            bundleID: "com.guesli.dev",
            displayName: "GuesliDev",
            macOSVersion: "15.5.0",
            architecture: "arm64"
        )
        let error = NSError(
            domain: "Test Domain /Users/private",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Secret transcript /Users/private/audio.wav"]
        )

        let incident = DiagnosticIncident(
            kind: .dictationTranscriptionFailed,
            stage: "standard dictation/transcribe",
            backend: "fluid audio",
            model: "FluidInference/parakeet tdt v3",
            error: error,
            metadata: metadata
        )

        let fields = incident.diagnosticFields
        #expect(fields["diagnostic.id"] == "Guesli.Diagnostic.dictation_transcription_failed")
        #expect(fields["diagnostic.stage"] == "standard_dictation_transcribe")
        #expect(fields["diagnostic.backend"] == "fluid_audio")
        #expect(fields["diagnostic.model"] == "FluidInference/parakeet_tdt_v3")
        #expect(fields["diagnostic.error_domain"] == "Test_Domain__Users_private")
        #expect(fields["diagnostic.error_code"] == "42")
        #expect(fields["diagnostic.error_summary"] == nil)
        #expect(fields["diagnostic.error_area"] == nil)
        #expect(fields.values.allSatisfy { !$0.contains("Secret transcript") })
        #expect(fields.values.allSatisfy { !$0.contains("audio.wav") })
        #expect(fields.values.allSatisfy { !$0.contains("/Users/") })
    }

    @Test("issue body contains allowlisted diagnostics only")
    func issueBodyAvoidsPrivatePayloads() {
        let metadata = DiagnosticAppMetadata(
            appVersion: "1.2.3",
            buildNumber: "456",
            bundleID: "com.guesli.dev",
            displayName: "GuesliDev",
            macOSVersion: "15.5.0",
            architecture: "arm64"
        )
        let error = NSError(
            domain: "MuesliTranscriptionRuntime",
            code: 7,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed for meeting title and transcript text at /Users/example/private.wav"
            ]
        )

        let incident = DiagnosticIncident(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            kind: .meetingProcessingFailed,
            stage: "meeting_stop_processing",
            backend: "fluidaudio",
            model: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            error: error,
            metadata: metadata
        )

        let body = incident.issueBody
        #expect(body.contains("Incident: meeting_processing_failed"))
        #expect(body.contains("Backend: fluidaudio"))
        #expect(body.contains("Model: FluidInference/parakeet-tdt-0.6b-v3-coreml"))
        #expect(body.contains("Error meaning: Unknown; use domain/code for lookup"))
        #expect(body.contains("Diagnostic area: unknown"))
        #expect(!body.contains("private.wav"))
        #expect(!body.contains("Failed for meeting title"))
        #expect(!body.contains("transcript text at"))
        #expect(!body.contains("Failed for"))
    }

    @Test("issue body excludes diagnostics log content and paths")
    func issueBodyExcludesDiagnosticsLogContentAndPaths() {
        let metadata = DiagnosticAppMetadata(
            appVersion: "1.2.3",
            buildNumber: "456",
            bundleID: "com.guesli.dev",
            displayName: "GuesliDev",
            macOSVersion: "15.5.0",
            architecture: "arm64"
        )
        let error = NSError(
            domain: "MeetingChunkCollector",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "[live-collector] dropped pending chunk sequence=0 reason=drain_timeout at /Users/kiwi/Library/Application Support/Guesli/diagnostics.log"
            ]
        )

        let incident = DiagnosticIncident(
            kind: .meetingProcessingFailed,
            stage: "live_gigaam_collector_drain_timeout",
            backend: "gigaam_v3",
            model: "kruatech/gigaam-v3-coreml",
            error: error,
            metadata: metadata
        )

        #expect(!incident.issueBody.contains("[live-collector]"))
        #expect(!incident.issueBody.contains("diagnostics.log"))
        #expect(!incident.issueBody.contains("/Users/"))
        #expect(!incident.issueBody.contains("Application Support/Guesli"))
        #expect(!incident.diagnosticsLogLine.contains("[live-collector]"))
        #expect(!incident.diagnosticsLogLine.contains("diagnostics.log"))
    }

    @Test("known internal error codes include privacy-safe meanings")
    func knownInternalErrorCodesIncludeMeaning() {
        let incident = DiagnosticIncident(
            kind: .dictationAudioFailed,
            stage: "dictation_audio_session",
            backend: nil,
            error: NSError(domain: "MicrophoneRecorder", code: 3),
            metadata: DiagnosticAppMetadata(
                appVersion: "1.2.3",
                buildNumber: "456",
                bundleID: "com.guesli.dev",
                displayName: "GuesliDev",
                macOSVersion: "15.5.0",
                architecture: "arm64"
            )
        )

        #expect(incident.errorMeaning?.summary == "Preferred microphone input could not be selected")
        #expect(incident.errorMeaning?.area == "audio_route_selection")
        #expect(incident.diagnosticFields["diagnostic.error_summary"] == "Preferred microphone input could not be selected")
        #expect(incident.diagnosticFields["diagnostic.error_area"] == "audio_route_selection")
        #expect(incident.issueBody.contains("Error meaning: Preferred microphone input could not be selected"))
        #expect(incident.issueBody.contains("Diagnostic area: audio_route_selection"))
    }

    @Test("domain fallback covers Swift enum style diagnostic errors")
    func domainFallbackCoversSwiftEnumErrors() {
        let meaning = DiagnosticErrorCatalog.meaning(
            domain: "MuesliNativeApp.MeetingLifecycleError",
            code: "0"
        )

        #expect(meaning?.summary == "Meeting lifecycle persistence failed")
        #expect(meaning?.area == "meeting_persistence")
    }

    @Test("GitHub issue URL is prefilled for Guesli")
    func githubIssueURLIsPrefilled() throws {
        let incident = DiagnosticIncident(
            kind: .manualReport,
            severity: .info,
            stage: "manual_report",
            backend: nil,
            error: nil,
            metadata: DiagnosticAppMetadata(
                appVersion: "1.2.3",
                buildNumber: "456",
                bundleID: "com.guesli.dev",
                displayName: "GuesliDev",
                macOSVersion: "15.5.0",
                architecture: "arm64"
            )
        )

        let url = try #require(incident.githubIssueURL)
        #expect(url.absoluteString.hasPrefix("https://github.com/ivkiwi/guesli/issues/new?"))
        #expect(url.absoluteString.contains("title="))
        #expect(url.absoluteString.contains("body="))
        #expect(DiagnosticIncident.githubIssueFallbackURL.absoluteString == "https://github.com/ivkiwi/guesli/issues/new")
    }

    @Test("controller wires hard-failure incident hooks")
    func controllerWiresHardFailureIncidentHooks() throws {
        let source = try sourceFile(named: "MuesliController.swift")
        let expectedStages = [
            "create_live_meeting",
            "start_meeting_recording",
            "save_meeting_recording",
            "meeting_stop_processing",
            "dictation_audio_session",
            "nemotron_streaming_start",
            "nemotron_streaming_runtime",
            "standard_dictation_transcribe",
            "live_gigaam_collector_drain_timeout",
        ]

        for stage in expectedStages {
            #expect(source.contains("stage: \"\(stage)\""))
        }
        #expect(source.contains("if !isDictationTestMode {\n                recordDiagnosticIncident(\n                    kind: .dictationAudioFailed"))
        #expect(source.contains("if !isDictationTestMode {\n            recordDiagnosticIncident(\n                kind: .streamingDictationStartFailed"))
        #expect(source.contains("if !isDictationTestMode {\n            recordDiagnosticIncident(\n                kind: .streamingDictationRuntimeFailed"))
        #expect(source.contains("if self.isDictationTestMode {\n                        self.dictationTestFailureCallback?"))
        #expect(source.contains("kind: .dictationTranscriptionFailed"))
    }

    @Test("diagnostic incident port has no TelemetryDeck dependency")
    func diagnosticIncidentPortHasNoTelemetryDeckDependency() throws {
        let sourceFiles = [
            try sourceFile(named: "DiagnosticIncident.swift"),
            try sourceFile(named: "DiagnosticIncidentReporter.swift"),
            try sourceFile(named: "MuesliController.swift"),
            try packageFile(named: "Package.swift"),
            try packageFile(named: "Package.resolved"),
        ]

        #expect(sourceFiles.allSatisfy { !$0.contains("TelemetryDeck") })
        #expect(sourceFiles.allSatisfy { !$0.contains("telemetrySink") })
    }

    private func sourceFile(named name: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("MuesliNativeApp")
            .appendingPathComponent(name)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func packageFile(named name: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(name), encoding: .utf8)
    }
}

@Suite("DiagnosticIncidentReporter", .muesliHermeticSupport)
@MainActor
struct DiagnosticIncidentReporterTests {

    @Test("logs local incidents and prompts once per kind per day")
    func logsLocalIncidentsAndThrottlesPrompt() throws {
        let appState = AppState()
        let suiteName = "DiagnosticIncidentReporterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var logged: [DiagnosticIncident] = []
        var prompted: [DiagnosticIncident] = []
        let reporter = DiagnosticIncidentReporter(
            appState: appState,
            defaults: defaults,
            incidentSink: { logged.append($0) },
            onPrompt: { prompted.append($0) }
        )

        let first = reporter.record(
            kind: .dictationAudioFailed,
            stage: "dictation_audio_session",
            backend: nil,
            error: NSError(domain: "Recorder", code: 1)
        )
        #expect(logged.map(\.id) == [first.id])
        #expect(prompted.map(\.id) == [first.id])
        #expect(appState.pendingDiagnosticIncident?.id == first.id)

        appState.pendingDiagnosticIncident = nil
        let second = reporter.record(
            kind: .dictationAudioFailed,
            stage: "dictation_audio_session",
            backend: nil,
            error: NSError(domain: "Recorder", code: 2)
        )
        #expect(logged.map(\.id) == [first.id, second.id])
        #expect(prompted.map(\.id) == [first.id])
        #expect(appState.pendingDiagnosticIncident == nil)

        var restartedPrompted: [DiagnosticIncident] = []
        let restartedReporter = DiagnosticIncidentReporter(
            appState: appState,
            defaults: defaults,
            incidentSink: { logged.append($0) },
            onPrompt: { restartedPrompted.append($0) }
        )
        let third = restartedReporter.record(
            kind: .dictationAudioFailed,
            stage: "dictation_audio_session",
            backend: nil,
            error: NSError(domain: "Recorder", code: 3)
        )
        #expect(logged.map(\.id) == [first.id, second.id, third.id])
        #expect(restartedPrompted.isEmpty)
        #expect(appState.pendingDiagnosticIncident == nil)
    }

    @Test("manual reports prompt without writing incident log")
    func manualReportsDoNotWriteIncidentLog() {
        let appState = AppState()
        var logged: [DiagnosticIncident] = []
        let reporter = DiagnosticIncidentReporter(
            appState: appState,
            incidentSink: { logged.append($0) }
        )

        reporter.recordManualReport()

        #expect(logged.isEmpty)
        #expect(appState.pendingDiagnosticIncident?.kind == .manualReport)
        #expect(appState.pendingDiagnosticIncident?.severity == .info)
    }
}
