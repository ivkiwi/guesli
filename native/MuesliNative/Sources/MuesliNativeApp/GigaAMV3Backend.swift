import Foundation
import GigaAMKit

struct GigaAMV3TranscriptionResult: Sendable {
    let text: String
    let duration: TimeInterval
    let processingTime: TimeInterval
}

enum GigaAMV3ModelStore {
    static let repoID = "kruatech/gigaam-v3-mlx"
    static let cacheRelativePath = "Models/gigaam-v3-mlx"
    static let downloadedModelSizeLabel = "~445 MB"
    static let localSeedEnvironmentKey = "MUESLI_GIGAAM_V3_MODEL_DIR"

    private struct RequiredFile {
        let path: String
        let progressWeight: Double
        let minimumBytes: Int64
    }

    private static let requiredFileSpecs: [RequiredFile] = [
        .init(path: "manifest.json", progressWeight: 0.01, minimumBytes: 1_269),
        .init(path: "hann_window.f32.bin", progressWeight: 0.01, minimumBytes: 1_280),
        .init(path: "mel_filterbank_mel_freq.f32.bin", progressWeight: 0.01, minimumBytes: 41_216),
        .init(path: "tokenizer.model", progressWeight: 0.03, minimumBytes: 255_336),
        .init(path: "tokenizer_vocab.json", progressWeight: 0.02, minimumBytes: 16_691),
        .init(path: "weights.fp16.safetensors", progressWeight: 0.92, minimumBytes: 445_105_914),
    ]

    private static let requiredFiles = Set(requiredFileSpecs.map(\.path))

    static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        AppIdentity.supportDirectoryURL.appendingPathComponent(cacheRelativePath, isDirectory: true)
    }

    static func isAvailableLocally(fileManager: FileManager = .default) -> Bool {
        let directory = cacheDirectory(fileManager: fileManager)
        return isCompleteModelDirectory(directory, fileManager: fileManager)
    }

    static func isCompleteModelDirectory(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        return requiredFileSpecs.allSatisfy { spec in
            isCompleteLocalFile(
                at: directory.appendingPathComponent(spec.path),
                spec: spec,
                fileManager: fileManager
            )
        }
    }

    static func deleteModelFiles(fileManager: FileManager = .default) throws {
        let directory = cacheDirectory(fileManager: fileManager)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    static func downloadIfNeeded(progress: ((Double, String?) -> Void)? = nil) async throws -> URL {
        let directory = cacheDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if isAvailableLocally() {
            progress?(1.0, nil)
            return directory
        }

        if try seedFromLocalMirrorIfAvailable(to: directory, progress: progress) {
            return directory
        }

        progress?(0.05, "Preparing GigaAM v3...")
        let entries = try await fetchRootTree()
        let downloadable = entries.filter { requiredFiles.contains($0.path) }
        let found = Set(downloadable.map(\.path))
        let missingRemote = requiredFiles.subtracting(found)
        guard missingRemote.isEmpty else {
            throw NSError(domain: "GigaAMV3ModelStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "GigaAM v3 model repository is missing: \(missingRemote.sorted().joined(separator: ", "))",
            ])
        }

        let totalWeight = max(requiredFileSpecs.reduce(0) { $0 + $1.progressWeight }, 1)
        var completedWeight = requiredFileSpecs.reduce(0) { partial, spec in
            let localFile = directory.appendingPathComponent(spec.path)
            return partial + (isCompleteLocalFile(at: localFile, spec: spec) ? spec.progressWeight : 0)
        }
        reportDownloadProgress(completedWeight / totalWeight, progress: progress)

        for spec in requiredFileSpecs {
            try Task.checkCancellation()
            let localFile = directory.appendingPathComponent(spec.path)
            guard !isCompleteLocalFile(at: localFile, spec: spec) else {
                continue
            }
            try? FileManager.default.removeItem(at: localFile)
            guard let remoteURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(spec.path)") else {
                throw NSError(domain: "GigaAMV3ModelStore", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid GigaAM v3 download URL for \(spec.path)",
                ])
            }
            fputs("[muesli-native] GigaAM v3 downloading \(spec.path)...\n", stderr)
            try await downloadWithRetry(from: remoteURL, to: localFile) { fileProgress in
                let weightedProgress = (completedWeight + spec.progressWeight * fileProgress) / totalWeight
                reportDownloadProgress(weightedProgress, progress: progress)
            }
            completedWeight += spec.progressWeight
            reportDownloadProgress(completedWeight / totalWeight, progress: progress)
        }

        guard isAvailableLocally() else {
            throw NSError(domain: "GigaAMV3ModelStore", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "GigaAM v3 model did not finish downloading.",
            ])
        }
        progress?(0.95, "Loading GigaAM v3...")
        return directory
    }

    private static func seedFromLocalMirrorIfAvailable(
        to directory: URL,
        progress: ((Double, String?) -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws -> Bool {
        for seedDirectory in localSeedDirectories() {
            guard isCompleteModelDirectory(seedDirectory, fileManager: fileManager) else {
                continue
            }

            progress?(0.05, "Using local GigaAM v3 model...")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            for (index, spec) in requiredFileSpecs.enumerated() {
                let source = seedDirectory.appendingPathComponent(spec.path)
                let destination = directory.appendingPathComponent(spec.path)
                if !isCompleteLocalFile(at: destination, spec: spec, fileManager: fileManager) {
                    try? fileManager.removeItem(at: destination)
                    try fileManager.copyItem(at: source, to: destination)
                }
                let fraction = 0.05 + (Double(index + 1) / Double(requiredFileSpecs.count)) * 0.85
                progress?(fraction, "Copying local GigaAM v3 model...")
            }

            guard isAvailableLocally(fileManager: fileManager) else {
                continue
            }

            fputs("[muesli-native] GigaAM v3 seeded from \(seedDirectory.path)\n", stderr)
            progress?(0.95, "Loading GigaAM v3...")
            return true
        }

        return false
    }

    private static func localSeedDirectories() -> [URL] {
        var directories: [URL] = []
        let environment = ProcessInfo.processInfo.environment

        if let rawValue = environment[localSeedEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawValue.isEmpty {
            directories.append(URL(fileURLWithPath: (rawValue as NSString).expandingTildeInPath, isDirectory: true))
        }

        if let resourceURL = Bundle.main.resourceURL {
            directories.append(resourceURL.appendingPathComponent(cacheRelativePath, isDirectory: true))
        }

        var seen = Set<String>()
        return directories.filter { url in
            let path = url.standardizedFileURL.path
            if seen.contains(path) {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    private static func isCompleteLocalFile(
        at url: URL,
        spec: RequiredFile,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value >= spec.minimumBytes
    }

    private static func reportDownloadProgress(
        _ rawValue: Double,
        progress: ((Double, String?) -> Void)?
    ) {
        let clamped = min(max(rawValue, 0), 1)
        let fraction = 0.05 + clamped * 0.85
        let percent = Int((fraction * 100).rounded())
        progress?(fraction, "Downloading GigaAM v3 (\(percent)%)...")
    }

    private struct HFEntry: Decodable {
        let type: String
        let path: String
    }

    private static func fetchRootTree() async throws -> [HFEntry] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/main") else {
            throw NSError(domain: "GigaAMV3ModelStore", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Invalid GigaAM v3 Hugging Face API URL.",
            ])
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "GigaAMV3ModelStore", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "GigaAM v3 Hugging Face API failed with HTTP \(http.statusCode).",
            ])
        }
        return try JSONDecoder().decode([HFEntry].self, from: data)
            .filter { $0.type == "file" }
    }
}

actor GigaAMV3Transcriber {
    private var recognizer: GigaAMRecognizer?
    private var isLoading = false
    private var activeDownloadTask: Task<URL, Error>?
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private var loadGeneration = 0

    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        try await loadModels(progress: progress, allowDownload: true)
    }

    private func loadModels(
        progress: ((Double, String?) -> Void)? = nil,
        allowDownload: Bool
    ) async throws {
        if recognizer != nil {
            progress?(1.0, nil)
            return
        }
        if isLoading {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loadWaiters.append(continuation)
            }
            progress?(1.0, nil)
            return
        }

        isLoading = true
        let generation = loadGeneration
        do {
            let directory: URL
            if allowDownload {
                let downloadTask = Task {
                    try await GigaAMV3ModelStore.downloadIfNeeded(progress: progress)
                }
                activeDownloadTask = downloadTask
                directory = try await downloadTask.value
            } else {
                guard GigaAMV3ModelStore.isAvailableLocally() else {
                    throw NSError(domain: "GigaAMV3Transcriber", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "GigaAM v3 models are not downloaded. Download them before transcribing.",
                    ])
                }
                progress?(0.95, "Loading GigaAM v3...")
                directory = GigaAMV3ModelStore.cacheDirectory()
            }
            guard generation == loadGeneration else {
                throw NSError(domain: "GigaAMV3Transcriber", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "GigaAM v3 load was cancelled.",
                ])
            }
            activeDownloadTask = nil
            let loadedRecognizer = try GigaAMRecognizer(configuration: .init(modelDirectory: directory))
            guard generation == loadGeneration else {
                throw NSError(domain: "GigaAMV3Transcriber", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "GigaAM v3 load was cancelled.",
                ])
            }
            recognizer = loadedRecognizer
            isLoading = false
            completeLoadWaiters()
            progress?(1.0, nil)
        } catch {
            if generation == loadGeneration {
                activeDownloadTask = nil
                isLoading = false
                completeLoadWaiters(throwing: error)
            }
            throw error
        }
    }

    func transcribe(wavURL: URL) async throws -> GigaAMV3TranscriptionResult {
        if recognizer == nil {
            try await loadModels(allowDownload: false)
        }
        guard let recognizer else {
            throw NSError(domain: "GigaAMV3Transcriber", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "GigaAM v3 recognizer is not loaded.",
            ])
        }

        let start = CFAbsoluteTimeGetCurrent()
        let result = try await recognizer.transcribe(url: wavURL)
        return GigaAMV3TranscriptionResult(
            text: result.text,
            duration: result.duration ?? 0,
            processingTime: CFAbsoluteTimeGetCurrent() - start
        )
    }

    func shutdown() {
        loadGeneration += 1
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        recognizer = nil
        isLoading = false
        completeLoadWaiters(throwing: NSError(domain: "GigaAMV3Transcriber", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "GigaAM v3 recognizer is not loaded.",
        ]))
    }

    private func completeLoadWaiters(throwing error: Error? = nil) {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }
}
