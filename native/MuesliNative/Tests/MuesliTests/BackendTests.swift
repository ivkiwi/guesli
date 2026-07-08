import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("WhisperKitTranscriber", .muesliHermeticSupport)
struct WhisperKitTranscriberTests {

    @Test("whisper models use whisper backend")
    func whisperModelsBackend() {
        let whisperOptions = BackendOption.all.filter { $0.backend == "whisper" }
        for option in whisperOptions {
            #expect(option.backend == "whisper", "\(option.label) should use whisper backend")
        }
    }

    @Test("whisper models use WhisperKit variant names")
    func whisperModelsVariantNames() {
        let whisperOptions = BackendOption.all.filter { $0.backend == "whisper" }
        for option in whisperOptions {
            // WhisperKit models should NOT have ggml- prefix (that was the old SwiftWhisper format)
            #expect(!option.model.hasPrefix("ggml-"), "\(option.label) should not use ggml- prefix")
            #expect(!option.model.hasSuffix(".bin"), "\(option.label) should not use .bin suffix")
        }
    }
}

@Suite("FluidAudioTranscriber", .muesliHermeticSupport)
struct FluidAudioTranscriberTests {

    @Test("parakeet models use FluidInference repo")
    func parakeetModels() {
        #expect(BackendOption.parakeetMultilingual.model.contains("FluidInference"))
        #expect(BackendOption.parakeetEnglish.model.contains("FluidInference"))
    }

    @Test("v2 model contains v2 in path")
    func v2Identification() {
        #expect(BackendOption.parakeetEnglish.model.contains("v2"))
        #expect(!BackendOption.parakeetMultilingual.model.contains("v2"))
    }

    @Test("v3 model contains v3 in path")
    func v3Identification() {
        #expect(BackendOption.parakeetMultilingual.model.contains("v3"))
    }
}

@Suite("SenseVoiceTranscriber", .muesliHermeticSupport)
struct SenseVoiceTranscriberTests {

    @Test("sensevoice model uses FluidAudio CoreML repo")
    func senseVoiceModel() {
        #expect(BackendOption.senseVoiceSmall.backend == "sensevoice")
        #expect(BackendOption.senseVoiceSmall.model.contains("FluidInference"))
        #expect(BackendOption.senseVoiceSmall.model.contains("sensevoice"))
    }

    @Test("sensevoice stays experimental")
    func senseVoiceExperimental() {
        #expect(BackendOption.experimental.contains(.senseVoiceSmall))
        #expect(!BackendOption.onboarding.contains(.senseVoiceSmall))
    }

    @Test("sensevoice cache path uses FluidAudio model store")
    func senseVoiceCachePath() {
        #expect(SenseVoiceTranscriber.cacheRelativePath == "Library/Application Support/FluidAudio/Models/sensevoice-small-coreml")
        #expect(SenseVoiceTranscriber.cacheDirectory().path.hasSuffix(SenseVoiceTranscriber.cacheRelativePath))
    }

    @Test("sensevoice metadata reflects INT8 download footprint")
    func senseVoiceInt8DownloadMetadata() {
        #expect(SenseVoiceTranscriber.downloadedModelSizeLabel == "~240 MB")
        #expect(BackendOption.senseVoiceSmall.sizeLabel == SenseVoiceTranscriber.downloadedModelSizeLabel)
        #expect(BackendOption.senseVoiceSmall.description.contains("INT8"))
    }
}

@Suite("SherpaGigaAMRNNTTranscriber", .muesliHermeticSupport)
struct SherpaGigaAMRNNTTranscriberTests {

    @Test("sherpa GigaAM RNNT stays experimental")
    func sherpaGigaAMRNNTExperimental() {
        #expect(BackendOption.experimental.contains(.sherpaGigaAMRNNT))
        #expect(!BackendOption.onboarding.contains(.sherpaGigaAMRNNT))
    }

    @Test("sherpa GigaAM RNNT metadata reflects bundled binary plus INT8 model")
    func sherpaGigaAMRNNTMetadata() {
        #expect(SherpaGigaAMRNNTModelStore.downloadedModelSizeLabel == "~260 MB")
        #expect(BackendOption.sherpaGigaAMRNNT.sizeLabel == SherpaGigaAMRNNTModelStore.downloadedModelSizeLabel)
        #expect(BackendOption.sherpaGigaAMRNNT.description.contains("CPU INT8"))
    }

    @Test("sherpa GigaAM RNNT lets sherpa auto-detect model type")
    func sherpaGigaAMRNNTRecognitionArgumentsAutoDetectModelType() async {
        let transcriber = SherpaGigaAMRNNTTranscriber()
        let args = await transcriber.recognitionArgumentsForTesting(
            chunkURLs: [URL(filePath: "/tmp/sherpa-gigaam-rnnt-test.wav")]
        )

        #expect(!args.contains("--model-type=transducer"))
        #expect(args.contains("--decoder=\(SherpaGigaAMRNNTModelStore.decoderURL().path)"))
        #expect(args.contains("--decoding-method=greedy_search"))
    }

    @Test("sherpa chunk ranges cover a 28 minute recording without gaps")
    func sherpaChunkRangesCoverTwentyEightMinuteRecording() {
        let sampleRate = SherpaGigaAMRNNTChunking.sampleRate
        let sampleCount = 28 * 60 * sampleRate
        let ranges = SherpaGigaAMRNNTChunking.ranges(sampleCount: sampleCount)

        #expect(ranges.count == 56)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.first?.upperBound == 30 * sampleRate)
        #expect(ranges.last?.lowerBound == 55 * 30 * sampleRate)
        #expect(ranges.last?.upperBound == sampleCount)
        #expect(ranges.reduce(0) { $0 + $1.count } == sampleCount)
        for (left, right) in zip(ranges, ranges.dropFirst()) {
            #expect(left.upperBound == right.lowerBound)
        }
    }

    @Test("sherpa chunk ranges include last partial chunk")
    func sherpaChunkRangesIncludeLastPartialChunk() {
        let sampleRate = SherpaGigaAMRNNTChunking.sampleRate
        let sampleCount = 28 * 60 * sampleRate + 123
        let ranges = SherpaGigaAMRNNTChunking.ranges(sampleCount: sampleCount)

        #expect(ranges.count == 57)
        #expect(ranges.last?.lowerBound == 56 * 30 * sampleRate)
        #expect(ranges.last?.upperBound == sampleCount)
        #expect(ranges.last?.count == 123)
    }

    @Test("sherpa parser rejects partial batch output")
    func sherpaParserRejectsPartialBatchOutput() {
        let stdout = """
        {"text":"late chunk two"}
        {"text":"late chunk three"}
        """

        do {
            _ = try SherpaOfflineOutputParser.text(from: stdout, expectedResultCount: 4)
            Issue.record("Partial Sherpa output was accepted as a complete transcript")
        } catch let error as SherpaOfflineOutputParserError {
            #expect(error == .unexpectedResultCount(expected: 4, actual: 2))
        } catch {
            Issue.record("Unexpected parser error: \(error)")
        }
    }

    @Test("sherpa parser counts empty chunk outputs")
    func sherpaParserCountsEmptyChunkOutputs() throws {
        let stdout = """
        {"text":""}
        {"text":"later speech"}
        """

        let text = try SherpaOfflineOutputParser.text(from: stdout, expectedResultCount: 2)

        #expect(text == "later speech")
    }

    @Test("sherpa GigaAM RNNT pins release artifact checksums")
    func sherpaGigaAMRNNTArtifactChecksumsPinned() {
        #expect(SherpaGigaAMRNNTModelStore.toolArchive.expectedSHA256 == "b1830ce2f19169070c23c2a44b70e1d416e0265e98870a2f62f7aa94811db342")
        #expect(SherpaGigaAMRNNTModelStore.modelArchive.expectedSHA256 == "f9620a0099019c6afcee26525ef9ed3297fa50dd5691c1902af0c948fc1a470b")
    }

    @Test("sherpa GigaAM RNNT deletes checksum mismatches")
    func sherpaGigaAMRNNTDeletesChecksumMismatch() throws {
        let directory = makeTemporaryDirectory()
        let archiveURL = directory.appendingPathComponent("bad.tar.bz2")
        try Data("bad archive".utf8).write(to: archiveURL)
        let artifact = SherpaGigaAMRNNTModelStore.DownloadArtifact(
            url: URL(string: "https://example.com/bad.tar.bz2")!,
            expectedSHA256: String(repeating: "0", count: 64)
        )

        #expect(throws: Error.self) {
            try SherpaGigaAMRNNTModelStore.validateDownloadedArtifact(artifact, at: archiveURL)
        }
        #expect(!FileManager.default.fileExists(atPath: archiveURL.path))
    }

    @Test("sherpa GigaAM RNNT load result cannot win after shutdown")
    func sherpaGigaAMRNNTLoadResultCannotWinAfterShutdown() async throws {
        let directory = makeTemporaryDirectory()
        let transcriber = SherpaGigaAMRNNTTranscriber()
        let download = Task<URL, Error> {
            try? await Task.sleep(for: .milliseconds(50))
            return directory
        }
        await transcriber.setActiveDownloadTaskForTesting(download)

        let load = Task {
            try await transcriber.loadModels()
        }
        try await Task.sleep(for: .milliseconds(10))
        await transcriber.shutdown()

        do {
            try await load.value
            Issue.record("Stale Sherpa load unexpectedly completed after shutdown")
        } catch is CancellationError {
            // Expected path.
        } catch {
            Issue.record("Stale Sherpa load failed with unexpected error: \(error)")
        }
        #expect(await transcriber.loadedDirectoryForTesting() == nil)
    }

    @Test("sherpa process runner terminates tar on cancellation")
    func sherpaProcessRunnerTerminatesTarOnCancellation() async throws {
        try await assertProcessRunnerTerminatesOnCancellation(executableName: "tar")
    }

    @Test("sherpa process runner terminates recognizer on cancellation")
    func sherpaProcessRunnerTerminatesRecognizerOnCancellation() async throws {
        try await assertProcessRunnerTerminatesOnCancellation(executableName: "sherpa-onnx-offline")
    }

    private func assertProcessRunnerTerminatesOnCancellation(executableName: String) async throws {
        let directory = makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent(executableName)
        let pidURL = directory.appendingPathComponent("\(executableName).pid")
        let termURL = directory.appendingPathComponent("\(executableName).term")
        let script = """
        #!/bin/sh
        echo $$ > "$1"
        trap 'echo term > "$2"; exit 0' TERM
        while true; do sleep 0.1; done
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let task = Task {
            try await SherpaProcessRunner.run(
                executable: scriptURL,
                arguments: [pidURL.path, termURL.path],
                captureDirectory: directory
            )
        }
        try await waitForFile(pidURL)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("\(executableName) runner unexpectedly completed after cancellation")
        } catch is CancellationError {
            // Expected path.
        } catch {
            Issue.record("\(executableName) runner failed with unexpected error: \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: termURL.path))
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "SherpaGigaAMRNNTTranscriberTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for \(url.path)",
        ])
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sherpa-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Backend coverage", .muesliHermeticSupport)
struct BackendCoverageTests {

    @Test("each backend has at least one model")
    func eachBackendHasModel() {
        let backendCounts = Dictionary(grouping: BackendOption.all, by: \.backend)
            .mapValues(\.count)
        #expect(backendCounts["fluidaudio"]! >= 2, "FluidAudio should have at least 2 models")
        #expect(backendCounts["whisper"]! >= 1, "Whisper should have at least 1 model")
        #expect(backendCounts["sensevoice"]! >= 1, "SenseVoice should have at least 1 model")
        #expect(backendCounts["nemotron35"]! == 1, "Nemotron 3.5 should be the only Nemotron backend")
        #expect(backendCounts["gigaam_v3"]! == 1, "GigaAM v3 should have exactly 1 model")
        #expect(backendCounts["sherpa_gigaam_rnnt"]! == 1, "Sherpa GigaAM RNNT should have exactly 1 model")
    }

    @Test("size labels are human-readable")
    func sizeLabelsReadable() {
        for option in BackendOption.all {
            #expect(option.sizeLabel.contains("MB") || option.sizeLabel.contains("GB"),
                    "\(option.label) sizeLabel should contain MB or GB: \(option.sizeLabel)")
        }
    }

    @Test("descriptions are informative")
    func descriptionsMinLength() {
        for option in BackendOption.all {
            #expect(option.description.count > 20,
                    "\(option.label) description too short: \(option.description)")
        }
    }
}
