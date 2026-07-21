import Foundation
import Testing
@testable import MuesliNativeApp

// These fixtures intentionally block on helper pipes. Running several of them
// concurrently can starve Swift's cooperative executor before the shell
// processes have a chance to publish their ready lines.
@Suite("ONNX GigaAM backend", .serialized)
struct ONNXGigaAMBackendTests {
    @Test("merges overlapping chunk text")
    func mergesOverlappingChunkText() {
        #expect(ONNXGigaAMChunking.mergeTranscripts([
            "привет как дела сегодня",
            "дела сегодня отлично спасибо",
        ]) == "привет как дела сегодня отлично спасибо")
    }

    @Test("rejects and deletes checksum mismatch")
    func rejectsChecksumMismatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onnx-gigaam-checksum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("artifact.bin")
        try Data("wrong".utf8).write(to: file)
        let artifact = ONNXGigaAMModelStore.DownloadArtifact(
            url: URL(string: "https://example.invalid/artifact.bin")!,
            expectedSHA256: String(repeating: "0", count: 64),
            minimumBytes: 1
        )

        #expect(throws: Error.self) {
            try ONNXGigaAMModelStore.validateDownloadedArtifact(artifact, at: file)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("rejects wrong sample rate before helper access")
    func rejectsWrongSampleRate() async {
        let transcriber = ONNXGigaAMTranscriber()
        await #expect(throws: Error.self) {
            try await transcriber.transcribe(samplesBatch: [[0]], sampleRate: 48_000)
        }
    }

    @Test("times out when a helper never becomes ready")
    func helperReadyTimeout() throws {
        let fixture = try HelperFixture(scriptBody: "read ignored")
        defer { fixture.cleanup() }

        do {
            _ = try ONNXGigaAMHelperProcess.start(
                modelDirectory: fixture.directory,
                readyTimeout: 0.5,
                helperURLOverride: fixture.scriptURL
            )
            Issue.record("Expected helper startup to time out")
        } catch let error as NSError {
            #expect(error.domain == "ONNXGigaAMHelper")
            #expect(error.code == 3)
        }
    }

    @Test("times out and terminates a helper that never returns inference")
    func helperInferenceTimeoutTerminatesProcess() async throws {
        let fixture = try HelperFixture(
            scriptBody: "echo $$ > \"$PID_FILE\"\nprintf '{\"ready\":true}\\n'\nread wav_path\nread ignored"
        )
        defer { fixture.cleanup() }
        let helper = try ONNXGigaAMHelperProcess.start(
            modelDirectory: fixture.directory,
            readyTimeout: 2,
            helperURLOverride: fixture.scriptURL
        )
        defer { helper.terminate() }
        let pid = try await fixture.waitForPID()

        do {
            _ = try helper.transcribe(
                wavURL: fixture.directory.appendingPathComponent("audio.wav"),
                responseTimeout: 0.5
            )
            Issue.record("Expected helper inference to time out")
        } catch let error as NSError {
            #expect(error.domain == "ONNXGigaAMHelper")
            #expect(error.code == 3)
        }

        #expect(!helper.isRunning)
        #expect(await processExited(pid))
    }

    @Test("concurrent model loads share one helper startup")
    func helperStartupIsSingleFlight() async throws {
        let fixture = try HelperFixture(
            scriptBody: "echo launch >> \"$COUNT_FILE\"\nprintf '{\"ready\":true}\\n'\nread ignored"
        )
        defer { fixture.cleanup() }
        let transcriber = ONNXGigaAMTranscriber { directory in
            try ONNXGigaAMHelperProcess.start(
                modelDirectory: directory,
                readyTimeout: 2,
                helperURLOverride: fixture.scriptURL
            )
        }

        async let first: Void = transcriber.loadHelperForTesting(modelDirectory: fixture.directory)
        async let second: Void = transcriber.loadHelperForTesting(modelDirectory: fixture.directory)
        _ = try await (first, second)

        let launches = try String(contentsOf: fixture.countURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(launches.count == 1)
        await transcriber.shutdown()
    }

    @Test("shutdown cancels and terminates helper startup")
    func shutdownCancelsHelperStartup() async throws {
        let fixture = try HelperFixture(scriptBody: "echo $$ > \"$PID_FILE\"\nread ignored")
        defer { fixture.cleanup() }
        let transcriber = ONNXGigaAMTranscriber { directory in
            try ONNXGigaAMHelperProcess.start(
                modelDirectory: directory,
                readyTimeout: 10,
                helperURLOverride: fixture.scriptURL
            )
        }
        let load = Task {
            try await transcriber.loadHelperForTesting(modelDirectory: fixture.directory)
        }

        let pid = try await fixture.waitForPID()
        await transcriber.shutdown()
        await #expect(throws: CancellationError.self) {
            try await load.value
        }
        #expect(await processExited(pid))
    }
}

private struct HelperFixture: @unchecked Sendable {
    let directory: URL
    let scriptURL: URL
    let pidURL: URL
    let countURL: URL

    init(scriptBody: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onnx-gigaam-helper-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        scriptURL = directory.appendingPathComponent("helper.sh")
        pidURL = directory.appendingPathComponent("pid")
        countURL = directory.appendingPathComponent("count")
        let script = """
        #!/bin/sh
        PID_FILE="\(pidURL.path)"
        COUNT_FILE="\(countURL.path)"
        \(scriptBody)
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    func waitForPID() async throws -> pid_t {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: pidURL, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "ONNXGigaAMBackendTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Helper did not write its PID",
        ])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func processExited(_ pid: pid_t) async -> Bool {
    for _ in 0..<100 {
        if kill(pid, 0) != 0 { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return kill(pid, 0) != 0
}
