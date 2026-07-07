import Foundation

@MainActor
final class DiagnosticIncidentReporter {
    typealias IncidentSink = @MainActor (DiagnosticIncident) -> Void
    typealias PromptHandler = @MainActor (DiagnosticIncident) -> Void

    private let defaults: UserDefaults
    private let appState: AppState
    private let incidentSink: IncidentSink
    private let onPrompt: PromptHandler
    private let calendar: Calendar

    init(
        appState: AppState,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        incidentSink: @escaping IncidentSink = DiagnosticIncidentReporter.writeDiagnosticsLog,
        onPrompt: @escaping PromptHandler = { _ in }
    ) {
        self.appState = appState
        self.defaults = defaults
        self.calendar = calendar
        self.incidentSink = incidentSink
        self.onPrompt = onPrompt
    }

    @discardableResult
    func record(
        kind: DiagnosticIncidentKind,
        severity: DiagnosticIncidentSeverity = .error,
        stage: String,
        backend: BackendOption? = nil,
        error: Error? = nil,
        promptUser: Bool = true
    ) -> DiagnosticIncident {
        let incident = DiagnosticIncident(
            kind: kind,
            severity: severity,
            stage: stage,
            backendOption: backend,
            error: error
        )
        incidentSink(incident)
        if promptUser, shouldPrompt(for: incident) {
            markPrompted(for: incident)
            onPrompt(incident)
            appState.pendingDiagnosticIncident = incident
        }
        return incident
    }

    func recordManualReport() {
        let incident = DiagnosticIncident(
            kind: .manualReport,
            severity: .info,
            stage: "manual_report",
            backend: nil,
            error: nil
        )
        appState.pendingDiagnosticIncident = incident
    }

    func dismissCurrentPrompt() {
        appState.pendingDiagnosticIncident = nil
    }

    private func shouldPrompt(for incident: DiagnosticIncident) -> Bool {
        let key = promptThrottleKey(for: incident)
        return defaults.string(forKey: key) != dayBucket(for: incident.occurredAt)
    }

    private func markPrompted(for incident: DiagnosticIncident) {
        defaults.set(dayBucket(for: incident.occurredAt), forKey: promptThrottleKey(for: incident))
    }

    private func promptThrottleKey(for incident: DiagnosticIncident) -> String {
        "diagnosticIncidentPrompt.\(incident.kind.rawValue).\(incident.metadata.appVersion).\(incident.metadata.buildNumber)"
    }

    private func dayBucket(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private static func writeDiagnosticsLog(_ incident: DiagnosticIncident) {
        DiagnosticsLog.write(incident.diagnosticsLogLine)
    }
}
