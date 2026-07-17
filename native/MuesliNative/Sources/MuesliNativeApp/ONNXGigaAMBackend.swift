import CryptoKit
import Foundation
import MuesliCore

struct ONNXGigaAMTranscriptionResult: Sendable {
    let text: String
    let duration: TimeInterval
    let processingTime: TimeInterval
}

enum ONNXGigaAMChunking {
    static let sampleRate = 16_000

    static func mergeTranscripts(_ transcripts: [String]) -> String {
        var chunks = transcripts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var merged = chunks.first?.split(separator: " ").map(String.init) else { return "" }
        chunks.removeFirst()

        for chunk in chunks {
            let words = chunk.split(separator: " ").map(String.init)
            let overlap = suffixPrefixOverlap(merged, words)
            merged.append(contentsOf: words.dropFirst(overlap))
        }
        return merged.joined(separator: " ")
    }

    private static func suffixPrefixOverlap(_ left: [String], _ right: [String]) -> Int {
        let limit = min(40, left.count, right.count)
        guard limit > 0 else { return 0 }
        for count in stride(from: limit, through: 1, by: -1) {
            let lhs = left.suffix(count).map(normalizedWord)
            let rhs = right.prefix(count).map(normalizedWord)
            if !lhs.contains(""), lhs == rhs { return count }
        }
        return 0
    }

    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

enum ONNXGigaAMModelStore {
    static let backendIdentifier = "gigaam_v3"
    static let modelID = "istupakov/gigaam-v3-onnx:e2e-ctc-int8"
    static let cacheRelativePath = "Models/gigaam-v3-onnx-e2e-ctc-int8"
    static let downloadedModelSizeLabel = "~219 MB"

    struct DownloadArtifact: Sendable {
        let url: URL
        let expectedSHA256: String
        let minimumBytes: Int64
    }

    static let modelArtifact = DownloadArtifact(
        url: URL(string: "https://huggingface.co/istupakov/gigaam-v3-onnx/resolve/322c3b29492673eb7d0b434bfa9dfb8653e34d02/v3_e2e_ctc.int8.onnx?download=true")!,
        expectedSHA256: "2e3fcb7a7b66030336fd10c2fcfb033bd1dc7e1bf238fe5cfd83b1d0cfc9d28e",
        minimumBytes: 224_000_000
    )
    static let vocabularyArtifact = DownloadArtifact(
        url: URL(string: "https://huggingface.co/istupakov/gigaam-v3-onnx/resolve/322c3b29492673eb7d0b434bfa9dfb8653e34d02/v3_e2e_ctc_vocab.txt?download=true")!,
        expectedSHA256: "142de7570b3de5b3035ce111a89c228e80e6085273731d944093ddf24fa539cd",
        minimumBytes: 1_900
    )
    static let onnxASRWheelArtifact = DownloadArtifact(
        url: URL(string: "https://files.pythonhosted.org/packages/6a/60/2fa469a2ee674c35ab48821a1039762ae7b9d0b88188ac1012e779477f76/onnx_asr-0.12.0-py3-none-any.whl")!,
        expectedSHA256: "5e7ceca454609819ea7833f61e2302e0c8f6ece4f8a78b66c5daba53cb51de4a",
        minimumBytes: 3_900_000
    )
    static let preprocessorSHA256 = "919c3bc8a434b6e733e5fe5dcd247974d0a7b1f2bc5b6995b6ad55f7225e014d"

    static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        MuesliPaths.defaultSupportDirectoryURL(
            appName: AppIdentity.supportDirectoryName,
            fileManager: fileManager
        ).appendingPathComponent(cacheRelativePath, isDirectory: true)
    }

    static func modelURL(fileManager: FileManager = .default) -> URL {
        cacheDirectory(fileManager: fileManager).appendingPathComponent("v3_e2e_ctc.int8.onnx")
    }

    static func vocabularyURL(fileManager: FileManager = .default) -> URL {
        cacheDirectory(fileManager: fileManager).appendingPathComponent("v3_e2e_ctc_vocab.txt")
    }

    static func preprocessorURL(fileManager: FileManager = .default) -> URL {
        cacheDirectory(fileManager: fileManager).appendingPathComponent("gigaam_v3.onnx")
    }

    static func isAvailableLocally(fileManager: FileManager = .default) -> Bool {
        isCompleteModelDirectory(cacheDirectory(fileManager: fileManager), fileManager: fileManager)
    }

    static func isCompleteModelDirectory(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        fileMeetsMinimum(directory.appendingPathComponent("v3_e2e_ctc.int8.onnx"), bytes: 224_000_000, fileManager: fileManager)
            && fileMeetsMinimum(directory.appendingPathComponent("v3_e2e_ctc_vocab.txt"), bytes: 1_900, fileManager: fileManager)
            && fileMeetsMinimum(directory.appendingPathComponent("gigaam_v3.onnx"), bytes: 40_000, fileManager: fileManager)
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
            progress?(1, nil)
            return finalDirectory
        }

        let fileManager = FileManager.default
        let root = finalDirectory.deletingLastPathComponent()
        MuesliPaths.preconditionSafeForTestWrite(root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let partial = root.appendingPathComponent("onnx-gigaam.partial-\(UUID().uuidString)", isDirectory: true)
        let extraction = root.appendingPathComponent("onnx-gigaam.extract-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: extraction)
        }
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: extraction, withIntermediateDirectories: true)

        let model = partial.appendingPathComponent("v3_e2e_ctc.int8.onnx")
        progress?(0.01, "Downloading GigaAM E2E CTC INT8...")
        try await downloadWithRetry(from: modelArtifact.url, to: model) { fraction in
            progress?(0.01 + 0.93 * fraction, "Downloading GigaAM E2E CTC INT8...")
        }
        try validateDownloadedArtifact(modelArtifact, at: model, fileManager: fileManager)

        let vocabulary = partial.appendingPathComponent("v3_e2e_ctc_vocab.txt")
        try await downloadWithRetry(from: vocabularyArtifact.url, to: vocabulary)
        try validateDownloadedArtifact(vocabularyArtifact, at: vocabulary, fileManager: fileManager)

        let wheel = partial.appendingPathComponent("onnx_asr-0.12.0-py3-none-any.whl")
        progress?(0.95, "Installing GigaAM preprocessor...")
        try await downloadWithRetry(from: onnxASRWheelArtifact.url, to: wheel)
        try validateDownloadedArtifact(onnxASRWheelArtifact, at: wheel, fileManager: fileManager)
        try extractWheel(wheel, to: extraction)
        let extractedPreprocessor = extraction
            .appendingPathComponent("onnx_asr/preprocessors/data/gigaam_v3.onnx")
        let preprocessor = partial.appendingPathComponent("gigaam_v3.onnx")
        guard sha256Hex(for: extractedPreprocessor) == preprocessorSHA256 else {
            throw modelError(4, "GigaAM preprocessor checksum mismatch.")
        }
        try fileManager.copyItem(at: extractedPreprocessor, to: preprocessor)
        try fileManager.removeItem(at: wheel)

        guard isCompleteModelDirectory(partial, fileManager: fileManager) else {
            throw modelError(5, "GigaAM ONNX model did not finish installing.")
        }
        MuesliPaths.preconditionSafeForTestWrite(finalDirectory)
        try? fileManager.removeItem(at: finalDirectory)
        try fileManager.moveItem(at: partial, to: finalDirectory)
        progress?(1, nil)
        return finalDirectory
    }

    static func validateDownloadedArtifact(
        _ artifact: DownloadArtifact,
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileMeetsMinimum(url, bytes: artifact.minimumBytes, fileManager: fileManager) else {
            try? fileManager.removeItem(at: url)
            throw modelError(2, "Downloaded file is truncated: \(artifact.url.lastPathComponent)")
        }
        let actual = sha256Hex(for: url)
        guard actual == artifact.expectedSHA256 else {
            try? fileManager.removeItem(at: url)
            throw modelError(3, "Checksum mismatch for \(artifact.url.lastPathComponent); downloaded file deleted.")
        }
    }

    private static func fileMeetsMinimum(_ url: URL, bytes: Int64, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value >= bytes
    }

    private static func sha256Hex(for url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func extractWheel(_ wheel: URL, to directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", wheel.path, directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = try? errorPipe.fileHandleForReading.readToEnd()
            let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown error"
            throw modelError(6, "Could not extract GigaAM preprocessor: \(detail)")
        }
    }

    private static func modelError(_ code: Int, _ description: String) -> NSError {
        NSError(domain: "ONNXGigaAMModelStore", code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

private final class ONNXGigaAMLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readLine() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                return Data(line)
            }
            guard let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty else {
                throw NSError(domain: "ONNXGigaAMHelper", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "GigaAM ONNX helper exited before returning a result.",
                ])
            }
            buffer.append(chunk)
        }
    }
}

private final class ONNXGigaAMHelperProcess: @unchecked Sendable {
    private struct Ready: Decodable { let ready: Bool }
    private struct Response: Decodable {
        let text: String?
        let error: String?
    }

    private let process: Process
    private let input: FileHandle
    private let reader: ONNXGigaAMLineReader
    private let requestLock = NSLock()
    private let lifecycleLock = NSLock()
    private var terminated = false

    private init(process: Process, input: FileHandle, reader: ONNXGigaAMLineReader) {
        self.process = process
        self.input = input
        self.reader = reader
    }

    static func start(modelDirectory: URL) throws -> ONNXGigaAMHelperProcess {
        let helper = try helperURL()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = helper
        process.arguments = [
            "--model", modelDirectory.appendingPathComponent("v3_e2e_ctc.int8.onnx").path,
            "--preprocessor", modelDirectory.appendingPathComponent("gigaam_v3.onnx").path,
            "--vocab", modelDirectory.appendingPathComponent("v3_e2e_ctc_vocab.txt").path,
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        try process.run()
        let instance = ONNXGigaAMHelperProcess(
            process: process,
            input: stdin.fileHandleForWriting,
            reader: ONNXGigaAMLineReader(handle: stdout.fileHandleForReading)
        )
        do {
            let ready = try JSONDecoder().decode(Ready.self, from: instance.reader.readLine())
            guard ready.ready else { throw helperError("GigaAM ONNX helper did not become ready.") }
            return instance
        } catch {
            instance.terminate()
            throw error
        }
    }

    func transcribe(wavURL: URL) throws -> String {
        requestLock.lock()
        defer { requestLock.unlock() }
        lifecycleLock.lock()
        let canRun = !terminated && process.isRunning
        lifecycleLock.unlock()
        guard canRun else { throw Self.helperError("GigaAM ONNX helper is not running.") }
        guard !wavURL.path.contains("\n") else { throw Self.helperError("Invalid WAV path.") }
        try input.write(contentsOf: Data((wavURL.path + "\n").utf8))
        let response = try JSONDecoder().decode(Response.self, from: reader.readLine())
        if let error = response.error { throw Self.helperError(error) }
        return response.text ?? ""
    }

    func terminate() {
        lifecycleLock.lock()
        guard !terminated else {
            lifecycleLock.unlock()
            return
        }
        terminated = true
        lifecycleLock.unlock()
        // Never take requestLock here: request may be blocked reading inference output.
        // Terminating process closes pipe and unblocks cancellation promptly.
        if process.isRunning { process.terminate() }
        try? input.close()
    }

    var isRunning: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return !terminated && process.isRunning
    }

    private static func helperURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["MUESLI_ONNX_GIGAAM_HELPER"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw helperError("MUESLI_ONNX_GIGAAM_HELPER is not executable: \(url.path)")
            }
            return url
        }
        guard let executable = Bundle.main.executableURL else {
            throw helperError("Cannot locate GigaAM ONNX helper.")
        }
        let url = executable.deletingLastPathComponent().appendingPathComponent("onnx-gigaam-helper")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw helperError("GigaAM ONNX helper is missing from app bundle: \(url.path)")
        }
        return url
    }

    private static func helperError(_ description: String) -> NSError {
        NSError(domain: "ONNXGigaAMHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

actor ONNXGigaAMTranscriber {
    private var loadedDirectory: URL?
    private var activeDownloadTask: Task<URL, Error>?
    private var helper: ONNXGigaAMHelperProcess?
    private var generation = 0

    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        let expectedGeneration = generation
        let directory: URL
        if ONNXGigaAMModelStore.isAvailableLocally() {
            directory = ONNXGigaAMModelStore.cacheDirectory()
            progress?(0.98, "Starting GigaAM ONNX...")
        } else if let activeDownloadTask {
            directory = try await activeDownloadTask.value
        } else {
            let task = Task { try await ONNXGigaAMModelStore.downloadIfNeeded(progress: progress) }
            activeDownloadTask = task
            do {
                directory = try await task.value
                activeDownloadTask = nil
            } catch {
                if generation == expectedGeneration { activeDownloadTask = nil }
                throw error
            }
        }
        try Task.checkCancellation()
        guard generation == expectedGeneration else { throw CancellationError() }
        if helper?.isRunning != true {
            helper = try await Task.detached { try ONNXGigaAMHelperProcess.start(modelDirectory: directory) }.value
        }
        guard generation == expectedGeneration else {
            helper?.terminate()
            helper = nil
            throw CancellationError()
        }
        loadedDirectory = directory
        progress?(1, nil)
    }

    func shutdown() async {
        generation += 1
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        helper?.terminate()
        helper = nil
        loadedDirectory = nil
    }

    func transcribe(wavURL: URL) async throws -> ONNXGigaAMTranscriptionResult {
        let prepared = try await AudioFileImportController.prepareAudioForImport(sourceURL: wavURL)
        defer { try? FileManager.default.removeItem(at: prepared.wavURL) }
        return try await transcribe(samples: prepared.samples, sampleRate: ONNXGigaAMChunking.sampleRate)
    }

    func transcribe(samples: [Float], sampleRate: Int) async throws -> ONNXGigaAMTranscriptionResult {
        try await transcribe(samplesBatch: [samples], sampleRate: sampleRate).first
            ?? ONNXGigaAMTranscriptionResult(text: "", duration: 0, processingTime: 0)
    }

    func transcribe(samplesBatch: [[Float]], sampleRate: Int) async throws -> [ONNXGigaAMTranscriptionResult] {
        guard sampleRate == ONNXGigaAMChunking.sampleRate else {
            throw NSError(domain: "ONNXGigaAMTranscriber", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "GigaAM ONNX expects 16 kHz mono audio.",
            ])
        }
        guard !samplesBatch.isEmpty else { return [] }
        guard loadedDirectory != nil, let helper, helper.isRunning else {
            throw NSError(domain: "ONNXGigaAMTranscriber", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "GigaAM ONNX is not loaded. Download and load it before transcribing.",
            ])
        }

        let started = CFAbsoluteTimeGetCurrent()
        let workDirectory = AppTemporaryDirectories.url(named: AppTemporaryDirectories.wavTemp)
            .appendingPathComponent("onnx-gigaam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        var texts = Array(repeating: "", count: samplesBatch.count)
        for (index, samples) in samplesBatch.enumerated() where !samples.isEmpty {
            try Task.checkCancellation()
            let wavURL = workDirectory.appendingPathComponent(String(format: "item-%05d.wav", index))
            try WavWriter.writeWAV(samples: samples, to: wavURL)
            do {
                texts[index] = try await withTaskCancellationHandler {
                    try await Task.detached { try helper.transcribe(wavURL: wavURL) }.value
                } onCancel: {
                    helper.terminate()
                }
            } catch {
                if !helper.isRunning { self.helper = nil }
                throw error
            }
        }

        let processingTime = CFAbsoluteTimeGetCurrent() - started
        return samplesBatch.enumerated().map { index, samples in
            ONNXGigaAMTranscriptionResult(
                text: texts[index],
                duration: TimeInterval(samples.count) / TimeInterval(sampleRate),
                processingTime: processingTime
            )
        }
    }
}
