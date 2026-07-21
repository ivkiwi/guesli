import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Meeting termination policy", .muesliHermeticSupport)
struct MeetingTerminationPolicyTests {
    @Test("allows termination when no meeting lifecycle is active")
    func allowsIdleTermination() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: false,
                isRecording: false,
                isStopping: false
            ) == .none
        )
    }

    @Test("warns while a meeting is starting")
    func warnsDuringStart() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: true,
                hasActiveSession: false,
                isRecording: false,
                isStopping: false
            ) == .starting
        )
    }

    @Test("warns while a meeting is recording")
    func warnsDuringRecording() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: true,
                isRecording: true,
                isStopping: false
            ) == .recording
        )
    }

    @Test("warns while a session exists before recording state is visible")
    func warnsForActiveSessionBeforeRecording() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: true,
                isRecording: false,
                isStopping: false
            ) == .processing
        )
    }

    @Test("warns while a stopped meeting is still processing")
    func warnsDuringProcessing() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: true,
                isRecording: false,
                isStopping: true
            ) == .processing
        )
    }

    @Test("warns while stopping even when session is already nil")
    func warnsDuringStopWithNoSession() {
        #expect(
            MeetingTerminationPolicy.state(
                isStarting: false,
                hasActiveSession: false,
                isRecording: false,
                isStopping: true
            ) == .processing
        )
    }

    @Test("confirmed quit stops and saves an active meeting instead of discarding it")
    func confirmedQuitUsesSafeStop() throws {
        let source = try sourceFile(named: "MuesliController.swift")
        let start = try #require(source.range(of: "private func requestTerminationAfterMeetingSafetyWork"))
        let end = try #require(source.range(
            of: "private func finishTerminationAfterMeetingSafetyWorkIfNeeded",
            range: start.upperBound..<source.endIndex
        ))
        let implementation = source[start.lowerBound..<end.lowerBound]

        #expect(implementation.contains("stopMeetingRecording()"))
        #expect(!implementation.contains("discard()"))
        #expect(!source.contains("discardMeetingStateForTermination"))
    }

    @Test("pending quit completes after start cancellation or audio import exits")
    func pendingQuitCompletesOnPreparationExitPaths() throws {
        let source = try sourceFile(named: "MuesliController.swift")
        let cancelStart = try #require(source.range(of: "func cancelMeetingPreparation()"))
        let cancelEnd = try #require(source.range(
            of: "private func finishMeetingStartAttempt",
            range: cancelStart.upperBound..<source.endIndex
        ))
        #expect(source[cancelStart.lowerBound..<cancelEnd.lowerBound]
            .contains("finishTerminationAfterMeetingSafetyWorkIfNeeded()"))

        let importStart = try #require(source.range(of: "func importAudioFile()"))
        let importEnd = try #require(source.range(
            of: "func audioFileImportContext()",
            range: importStart.upperBound..<source.endIndex
        ))
        let importImplementation = source[importStart.lowerBound..<importEnd.lowerBound]
        #expect(importImplementation.components(
            separatedBy: "finishTerminationAfterMeetingSafetyWorkIfNeeded()"
        ).count - 1 == 4)
    }

    private func sourceFile(named name: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/MuesliNativeApp", isDirectory: true)
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }
}
