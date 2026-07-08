import Foundation
import MuesliCore

struct SherpaGigaAMRNNTTranscriptionResult: Sendable {
    let text: String
    let duration: TimeInterval
    let processingTime: TimeInterval
}

enum SherpaGigaAMRNNTChunking {
    static let sampleRate = 16_000
    static let chunkSeconds = 30
    static let chunkSamples = sampleRate * chunkSeconds

    static func ranges(sampleCount: Int) -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }
        var result: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let end = min(sampleCount, start + chunkSamples)
            result.append(start..<end)
            start = end
        }
        return result
    }
}

enum SherpaGigaAMRNNTModelStore {
    static let backendIdentifier = "sherpa_gigaam_rnnt"
    static let modelID = "k2-fsa/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16"
    static let cacheRelativePath = "Models/sherpa-gigaam-rnnt"
    static let downloadedModelSizeLabel = "~260 MB"

    private static let toolArchiveURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.4/sherpa-onnx-v1.13.4-osx-arm64-static.tar.bz2")!
    private static let modelArchiveURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16.tar.bz2")!
    private static let toolRootName = "sherpa-onnx-v1.13.4-osx-arm64-static"
    private static let modelRootName = "sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16"

    private struct RequiredFile {
        let path: String
        let minimumBytes: Int64
        let executable: Bool
    }

    private static let requiredFiles: [RequiredFile] = [
        .init(path: "bin/sherpa-onnx-offline", minimumBytes: 20_000_000, executable: true),
        .init(path: "model/encoder.int8.onnx", minimumBytes: 200_000_000, executable: false),
        .init(path: "model/decoder.onnx", minimumBytes: 4_000_000, executable: false),
        .init(path: "model/joiner.onnx", minimumBytes: 2_000_000, executable: false),
        .init(path: "model/tokens.txt", minimumBytes: 10_000, executable: false),
    ]

    static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        MuesliPaths.defaultSupportDirectoryURL(
            appName: AppIdentity.supportDirectoryName,
            fileManager: fileManager
        ).appendingPathComponent(cacheRelativePath, isDirectory: true)
    }

    static func binaryURL(fileManager: FileManager = .default) -> URL {
        cacheDirectory(fileManager: fileManager).appendingPathComponent("bin/sherpa-onnx-offline")
    }

    static func modelDirectory(fileManager: FileManager = .default) -> URL {
        cacheDirectory(fileManager: fileManager).appendingPathComponent("model", isDirectory: true)
    }

    static func encoderURL(fileManager: FileManager = .default) -> URL {
        modelDirectory(fileManager: fileManager).appendingPathComponent("encoder.int8.onnx")
    }

    static func decoderURL(fileManager: FileManager = .default) -> URL {
        modelDirectory(fileManager: fileManager).appendingPathComponent("decoder.onnx")
    }

    static func joinerURL(fileManager: FileManager = .default) -> URL {
        modelDirectory(fileManager: fileManager).appendingPathComponent("joiner.onnx")
    }

    static func tokensURL(fileManager: FileManager = .default) -> URL {
        modelDirectory(fileManager: fileManager).appendingPathComponent("tokens.txt")
    }

    static func isAvailableLocally(fileManager: FileManager = .default) -> Bool {
        isCompleteInstallDirectory(cacheDirectory(fileManager: fileManager), fileManager: fileManager)
    }

    static func isCompleteInstallDirectory(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        requiredFiles.allSatisfy { spec in
            let url = directory.appendingPathComponent(spec.path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value >= spec.minimumBytes
            else {
                return false
            }
            return !spec.executable || fileManager.isExecutableFile(atPath: url.path)
        }
    }

    static func deleteModelFiles(fileManager: FileManager = .default) throws {
        let directory = cacheDirectory(fileManager: fileManager)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        MuesliPaths.preconditionSafeForTestWrite(directory)
        try fileManager.removeItem(at: directory)
    }

    static func downloadIfNeeded(progress: ((Double, String?) -> Void)? = nil) async throws -> URL {
        let finalDirectory = cacheDirectory()
        if isAvailableLocally() {
            progress?(1.0, nil)
            return finalDirectory
        }

        let fm = FileManager.default
        let modelsRoot = finalDirectory.deletingLastPathComponent()
        MuesliPaths.preconditionSafeForTestWrite(modelsRoot)
        try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        let suffix = UUID().uuidString
        let archiveDirectory = modelsRoot.appendingPathComponent("sherpa-gigaam-rnnt.archives-\(suffix)", isDirectory: true)
        let extractDirectory = modelsRoot.appendingPathComponent("sherpa-gigaam-rnnt.extract-\(suffix)", isDirectory: true)
        let partialDirectory = modelsRoot.appendingPathComponent("sherpa-gigaam-rnnt.partial-\(suffix)", isDirectory: true)
        defer {
            try? fm.removeItem(at: archiveDirectory)
            try? fm.removeItem(at: extractDirectory)
            try? fm.removeItem(at: partialDirectory)
        }

        try fm.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
        progress?(0.03, "Preparing Sherpa GigaAM RNNT...")

        let toolArchive = archiveDirectory.appendingPathComponent(toolArchiveURL.lastPathComponent)
        fputs("[muesli-native] Sherpa GigaAM RNNT downloading sherpa-onnx tool...\n", stderr)
        try await downloadWithRetry(from: toolArchiveURL, to: toolArchive) { fraction in
            progress?(0.05 + 0.25 * fraction, "Downloading Sherpa tool...")
        }

        let modelArchive = archiveDirectory.appendingPathComponent(modelArchiveURL.lastPathComponent)
        fputs("[muesli-native] Sherpa GigaAM RNNT downloading GigaAM v3 RNNT model...\n", stderr)
        try await downloadWithRetry(from: modelArchiveURL, to: modelArchive) { fraction in
            progress?(0.30 + 0.55 * fraction, "Downloading Sherpa GigaAM RNNT...")
        }

        progress?(0.87, "Installing Sherpa GigaAM RNNT...")
        try await SherpaProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xjf", toolArchive.path, "-C", extractDirectory.path],
            captureDirectory: archiveDirectory
        )
        try await SherpaProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xjf", modelArchive.path, "-C", extractDirectory.path],
            captureDirectory: archiveDirectory
        )

        try installExtractedFiles(
            from: extractDirectory,
            to: partialDirectory,
            fileManager: fm
        )

        guard isCompleteInstallDirectory(partialDirectory, fileManager: fm) else {
            throw NSError(domain: "SherpaGigaAMRNNTModelStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Sherpa GigaAM RNNT model did not finish installing.",
            ])
        }

        MuesliPaths.preconditionSafeForTestWrite(finalDirectory)
        try? fm.removeItem(at: finalDirectory)
        try fm.moveItem(at: partialDirectory, to: finalDirectory)

        progress?(1.0, nil)
        return finalDirectory
    }

    private static func installExtractedFiles(
        from extractDirectory: URL,
        to installDirectory: URL,
        fileManager: FileManager
    ) throws {
        let extractedTool = extractDirectory
            .appendingPathComponent(toolRootName, isDirectory: true)
            .appendingPathComponent("bin/sherpa-onnx-offline")
        let extractedModel = extractDirectory.appendingPathComponent(modelRootName, isDirectory: true)

        let binDirectory = installDirectory.appendingPathComponent("bin", isDirectory: true)
        let modelDirectory = installDirectory.appendingPathComponent("model", isDirectory: true)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let installedBinary = binDirectory.appendingPathComponent("sherpa-onnx-offline")
        try fileManager.copyItem(at: extractedTool, to: installedBinary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBinary.path)

        for name in ["encoder.int8.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"] {
            try fileManager.copyItem(
                at: extractedModel.appendingPathComponent(name),
                to: modelDirectory.appendingPathComponent(name)
            )
        }
    }
}

actor SherpaGigaAMRNNTTranscriber {
    private var loadedDirectory: URL?
    private var activeDownloadTask: Task<URL, Error>?

    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        if SherpaGigaAMRNNTModelStore.isAvailableLocally() {
            loadedDirectory = SherpaGigaAMRNNTModelStore.cacheDirectory()
            progress?(1.0, nil)
            return
        }

        if let activeDownloadTask {
            loadedDirectory = try await activeDownloadTask.value
            progress?(1.0, nil)
            return
        }

        let task = Task {
            try await SherpaGigaAMRNNTModelStore.downloadIfNeeded(progress: progress)
        }
        activeDownloadTask = task
        do {
            loadedDirectory = try await task.value
            activeDownloadTask = nil
        } catch {
            activeDownloadTask = nil
            throw error
        }
    }

    func shutdown() async {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        loadedDirectory = nil
    }

    func transcribe(wavURL: URL) async throws -> SherpaGigaAMRNNTTranscriptionResult {
        let prepared = try await AudioFileImportController.prepareAudioForImport(sourceURL: wavURL)
        defer { try? FileManager.default.removeItem(at: prepared.wavURL) }
        return try await transcribe(samples: prepared.samples, sampleRate: SherpaGigaAMRNNTChunking.sampleRate)
    }

    func transcribe(samples: [Float], sampleRate: Int) async throws -> SherpaGigaAMRNNTTranscriptionResult {
        guard sampleRate == SherpaGigaAMRNNTChunking.sampleRate else {
            throw NSError(domain: "SherpaGigaAMRNNTTranscriber", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Sherpa GigaAM RNNT expects 16 kHz mono audio.",
            ])
        }
        guard !samples.isEmpty else {
            return SherpaGigaAMRNNTTranscriptionResult(text: "", duration: 0, processingTime: 0)
        }
        try ensureModelsAvailable()

        let start = CFAbsoluteTimeGetCurrent()
        let fm = FileManager.default
        let workRoot = AppTemporaryDirectories.url(named: AppTemporaryDirectories.wavTemp)
        let workDirectory = workRoot.appendingPathComponent("sherpa-rnnt-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDirectory) }

        let chunkURLs = try writeChunks(samples: samples, to: workDirectory)
        let output = try await SherpaProcessRunner.run(
            executable: SherpaGigaAMRNNTModelStore.binaryURL(),
            arguments: recognitionArguments(chunkURLs: chunkURLs),
            captureDirectory: workDirectory
        )
        let text = try SherpaOfflineOutputParser.text(from: output.stdout)
        let duration = TimeInterval(samples.count) / TimeInterval(sampleRate)
        return SherpaGigaAMRNNTTranscriptionResult(
            text: text,
            duration: duration,
            processingTime: CFAbsoluteTimeGetCurrent() - start
        )
    }

    private func ensureModelsAvailable() throws {
        if loadedDirectory != nil, SherpaGigaAMRNNTModelStore.isAvailableLocally() {
            return
        }
        guard SherpaGigaAMRNNTModelStore.isAvailableLocally() else {
            throw NSError(domain: "SherpaGigaAMRNNTTranscriber", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Sherpa GigaAM RNNT is not downloaded. Download it before transcribing.",
            ])
        }
        loadedDirectory = SherpaGigaAMRNNTModelStore.cacheDirectory()
    }

    private func writeChunks(samples: [Float], to directory: URL) throws -> [URL] {
        try SherpaGigaAMRNNTChunking.ranges(sampleCount: samples.count).enumerated().map { index, range in
            let chunkURL = directory.appendingPathComponent(String(format: "chunk-%05d.wav", index))
            try WavWriter.writeWAV(samples: Array(samples[range]), to: chunkURL)
            return chunkURL
        }
    }

    private func recognitionArguments(chunkURLs: [URL]) -> [String] {
        [
            "--tokens=\(SherpaGigaAMRNNTModelStore.tokensURL().path)",
            "--encoder=\(SherpaGigaAMRNNTModelStore.encoderURL().path)",
            "--decoder=\(SherpaGigaAMRNNTModelStore.decoderURL().path)",
            "--joiner=\(SherpaGigaAMRNNTModelStore.joinerURL().path)",
            "--num-threads=4",
            "--decoding-method=greedy_search",
            "--debug=false",
            "--print-args=false",
        ] + chunkURLs.map(\.path)
    }
}

enum SherpaOfflineOutputParser {
    private struct ResultLine: Decodable {
        let text: String
    }

    static func text(from stdout: String) throws -> String {
        let lines = stdout.split(whereSeparator: \.isNewline)
        let parts = try lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let decoded = try JSONDecoder().decode(ResultLine.self, from: Data(trimmed.utf8))
            return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        return GigaAMV3FileChunking.mergeTranscripts(parts)
    }
}

enum SherpaProcessRunner {
    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        captureDirectory: URL
    ) async throws -> (stdout: String, stderr: String) {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
            let suffix = UUID().uuidString
            let stdoutURL = captureDirectory.appendingPathComponent("stdout-\(suffix).log")
            let stderrURL = captureDirectory.appendingPathComponent("stderr-\(suffix).log")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                try? FileManager.default.removeItem(at: stdoutURL)
                try? FileManager.default.removeItem(at: stderrURL)
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            try process.run()
            process.waitUntilExit()

            let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
            let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "SherpaProcessRunner", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: "\(executable.lastPathComponent) failed: \(stderr.nonEmpty ?? stdout.nonEmpty ?? "exit \(process.terminationStatus)")",
                ])
            }
            return (stdout, stderr)
        }.value
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
