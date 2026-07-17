import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("ONNX GigaAM backend")
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
}
