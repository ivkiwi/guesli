import AVFoundation
import FluidAudio
import Foundation

enum SenseVoiceFileChunking {
    static let sampleRate = SenseVoiceConfig.sampleRate
    static let passthroughThresholdSeconds: TimeInterval = 15
    static let windowSeconds: TimeInterval = 15
    static let overlapSeconds: TimeInterval = 2

    static func shouldChunk(duration: TimeInterval) -> Bool {
        duration > passthroughThresholdSeconds
    }

    static func shouldChunk(sampleCount: Int, sampleRate: Int = sampleRate) -> Bool {
        guard sampleCount > 0, sampleRate > 0 else { return false }
        return shouldChunk(duration: Double(sampleCount) / Double(sampleRate))
    }

    static func windows(sampleCount: Int, sampleRate: Int = sampleRate) -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }
        guard shouldChunk(sampleCount: sampleCount, sampleRate: sampleRate) else {
            return [0..<sampleCount]
        }

        let windowSamples = max(1, Int((windowSeconds * Double(sampleRate)).rounded()))
        let overlapSamples = min(Int((overlapSeconds * Double(sampleRate)).rounded()), windowSamples - 1)
        let stepSamples = windowSamples - overlapSamples
        var result: [Range<Int>] = []
        var start = 0

        while start < sampleCount {
            let end = min(start + windowSamples, sampleCount)
            result.append(start..<end)
            if end == sampleCount { break }
            start += stepSamples
        }

        return result
    }

    static func mergeTranscripts(_ transcripts: [String]) -> String {
        SenseVoiceTranscriptMerger.merge(transcripts)
    }
}

private enum SenseVoiceTranscriptMerger {
    private static let maxOverlapWords = 40
    private static let maxOverlapCharacters = 120

    static func merge(_ transcripts: [String]) -> String {
        if transcripts.contains(where: containsUnspacedCJKScript) {
            return mergeCharacters(transcripts)
        }
        return mergeWords(transcripts)
    }

    private static func mergeWords(_ transcripts: [String]) -> String {
        var words: [String] = []
        for transcript in transcripts {
            let next = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !next.isEmpty else { continue }
            let overlap = suffixPrefixWordOverlap(words, next)
            words.append(contentsOf: next.dropFirst(overlap))
        }
        return words.joined(separator: " ")
    }

    private static func mergeCharacters(_ transcripts: [String]) -> String {
        var characters: [Character] = []
        for transcript in transcripts {
            let next = Array(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !next.isEmpty else { continue }
            let overlap = suffixPrefixCharacterOverlap(characters, next)
            let tail = next.dropFirst(overlap)
            if overlap == 0,
               let last = characters.last,
               let first = tail.first,
               last.isASCII, first.isASCII,
               (last.isLetter || last.isNumber), (first.isLetter || first.isNumber) {
                characters.append(" ")
            }
            characters.append(contentsOf: tail)
        }
        return String(characters)
    }

    private static func suffixPrefixWordOverlap(_ left: [String], _ right: [String]) -> Int {
        let limit = min(maxOverlapWords, left.count, right.count)
        guard limit >= 2 else { return 0 }

        let normalizedLeft = left.map(normalize)
        let normalizedRight = right.map(normalize)
        for count in stride(from: limit, through: 2, by: -1) {
            let suffix = normalizedLeft.suffix(count)
            if !suffix.contains(""), Array(suffix) == Array(normalizedRight.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private static func suffixPrefixCharacterOverlap(_ left: [Character], _ right: [Character]) -> Int {
        let limit = min(maxOverlapCharacters, left.count, right.count)
        guard limit >= 2 else { return 0 }

        let normalizedLeft = left.map(normalize)
        let normalizedRight = right.map(normalize)
        for count in stride(from: limit, through: 2, by: -1) {
            let suffix = normalizedLeft.suffix(count)
            if !suffix.contains(""), Array(suffix) == Array(normalizedRight.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func normalize(_ character: Character) -> String {
        String(character).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func containsUnspacedCJKScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x3040...0x30FF,
                 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }
}

enum SenseVoiceAudioWindowReaderError: Error, LocalizedError {
    case unsupportedFormat
    case missingFloatChannelData

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Could not create a SenseVoice audio conversion format."
        case .missingFloatChannelData:
            return "Converted SenseVoice audio did not contain float channel data."
        }
    }
}

final class SenseVoiceAudioWindowReader {
    private static let targetSampleRate = Double(SenseVoiceFileChunking.sampleRate)

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let sourceSampleRate: Double

    let sampleCount: Int

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
            throw SenseVoiceAudioWindowReaderError.unsupportedFormat
        }

        self.file = file
        self.converter = converter
        self.outputFormat = outputFormat
        self.sourceSampleRate = file.processingFormat.sampleRate
        self.sampleCount = max(
            0,
            Int((Double(file.length) * Self.targetSampleRate / file.processingFormat.sampleRate).rounded(.up))
        )
    }

    func samples(for targetRange: Range<Int>) throws -> [Float] {
        guard !targetRange.isEmpty else { return [] }

        let sourceStart = AVAudioFramePosition(
            (Double(targetRange.lowerBound) / Self.targetSampleRate * sourceSampleRate).rounded(.down)
        )
        let sourceEnd = AVAudioFramePosition(
            (Double(targetRange.upperBound) / Self.targetSampleRate * sourceSampleRate).rounded(.up)
        )
        let clampedStart = min(max(0, sourceStart), file.length)
        let clampedEnd = min(max(clampedStart, sourceEnd), file.length)
        let sourceFrameCount = AVAudioFrameCount(clampedEnd - clampedStart)
        guard sourceFrameCount > 0 else { return [] }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: sourceFrameCount
        ) else {
            throw SenseVoiceAudioWindowReaderError.unsupportedFormat
        }

        file.framePosition = clampedStart
        try file.read(into: inputBuffer, frameCount: sourceFrameCount)
        guard inputBuffer.frameLength > 0 else { return [] }

        converter.reset()
        let outputCapacity = AVAudioFrameCount(
            max(1, Int((Double(inputBuffer.frameLength) * Self.targetSampleRate / sourceSampleRate).rounded(.up)) + 64)
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw SenseVoiceAudioWindowReaderError.unsupportedFormat
        }

        var didProvideInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if didProvideInput {
                status.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return inputBuffer
        }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        if let conversionError {
            throw conversionError
        }
        guard status != .error, let outputChannel = outputBuffer.floatChannelData?[0] else {
            throw SenseVoiceAudioWindowReaderError.missingFloatChannelData
        }

        let frameLength = min(Int(outputBuffer.frameLength), targetRange.count)
        return Array(UnsafeBufferPointer(start: outputChannel, count: frameLength))
    }
}

/// Native Swift transcription backend for FunASR's SenseVoiceSmall via FluidAudio.
actor SenseVoiceTranscriber {
    private var manager: SenseVoiceManager?
    private var isLoading = false
    private var hasCompletedWarmup = false
    private static let precision: SenseVoiceEncoderPrecision = .int8

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "SenseVoice models not loaded. Call loadModels() first."
            }
        }
    }

    /// Downloads models if needed and initializes the SenseVoice manager.
    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        // Actor isolation makes this check-and-set race-free. Waiters retry after
        // a failed load so a transient download error does not poison the actor.
        while isLoading {
            try await Task.sleep(nanoseconds: 50_000_000)
            if manager != nil { return }
        }
        if manager != nil { return }

        isLoading = true
        defer { isLoading = false }

        fputs("[sensevoice] downloading/loading models...\n", stderr)
        let modelDirectory = try await Self.downloadRequiredModels(progress: progress)
        progress?(0.95, "Loading SenseVoice...")
        let models = try SenseVoiceModels.load(from: modelDirectory, precision: Self.precision)
        self.manager = SenseVoiceManager(models: models)
        await warmupIfNeeded(progress: progress)
        progress?(1.0, nil)
        fputs("[sensevoice] models ready\n", stderr)
    }

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let manager else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()
        let duration = try Self.audioDuration(url: wavURL)
        if !SenseVoiceFileChunking.shouldChunk(duration: duration) {
            let text = try await manager.transcribe(audioURL: wavURL)
            return (text, CFAbsoluteTimeGetCurrent() - start)
        }

        let reader = try SenseVoiceAudioWindowReader(url: wavURL)
        let windows = SenseVoiceFileChunking.windows(sampleCount: reader.sampleCount)
        guard !windows.isEmpty else {
            return ("", CFAbsoluteTimeGetCurrent() - start)
        }

        fputs("[sensevoice] chunked transcription: \(windows.count) windows, \(String(format: "%.1f", duration))s\n", stderr)
        var transcripts: [String] = []
        transcripts.reserveCapacity(windows.count)
        for window in windows {
            try Task.checkCancellation()
            let audio = try reader.samples(for: window)
            guard !audio.isEmpty else { continue }
            let text = try await manager.transcribe(audio: audio)
            transcripts.append(text)
        }

        let text = SenseVoiceFileChunking.mergeTranscripts(transcripts)
        let processingTime = CFAbsoluteTimeGetCurrent() - start
        return (text, processingTime)
    }

    func shutdown() {
        manager = nil
        hasCompletedWarmup = false
    }

    static let cacheRelativePath = "Library/Application Support/FluidAudio/Models/sensevoice-small-coreml"
    static let downloadedModelSizeLabel = "~240 MB"

    static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(cacheRelativePath)
    }

    static func isModelDownloaded() -> Bool {
        requiredModelsExist(at: cacheDirectory())
    }

    static func deleteModelFiles(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: cacheDirectory(fileManager: fileManager))
    }

    private static func downloadRequiredModels(progress: ((Double, String?) -> Void)?) async throws -> URL {
        let directory = cacheDirectory()
        if requiredModelsExist(at: directory) {
            return directory
        }

        // FluidAudio 0.15.x downloads every SenseVoice encoder precision via SenseVoiceManager.load.
        // Muesli only needs the INT8 ANE encoder, so fetch that subset and then use FluidAudio's loader.
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        try await downloadSubdirectory(
            ModelNames.SenseVoice.preprocessorFile,
            to: directory,
            progressRange: 0.0...0.2,
            message: "Downloading SenseVoice preprocessor...",
            progress: progress
        )
        try await downloadSubdirectory(
            ModelNames.SenseVoice.encoderInt8File,
            to: directory,
            progressRange: 0.2...0.9,
            message: "Downloading SenseVoice INT8 encoder...",
            progress: progress
        )
        try await downloadVocabulary(to: directory, progress: progress)

        return directory
    }

    private static func downloadSubdirectory(
        _ subdirectory: String,
        to directory: URL,
        progressRange: ClosedRange<Double>,
        message: String,
        progress: ((Double, String?) -> Void)?
    ) async throws {
        try await DownloadUtils.downloadSubdirectory(
            .senseVoiceSmall,
            subdirectory: subdirectory,
            to: directory,
            progressHandler: { downloadProgress in
                let span = progressRange.upperBound - progressRange.lowerBound
                let fraction = progressRange.lowerBound + span * downloadProgress.fractionCompleted
                progress?(min(max(fraction, 0.0), 1.0), message)
            }
        )
    }

    private static func downloadVocabulary(to directory: URL, progress: ((Double, String?) -> Void)?) async throws {
        let vocabularyURL = directory.appendingPathComponent(ModelNames.SenseVoice.vocabularyFile)
        if FileManager.default.fileExists(atPath: vocabularyURL.path) {
            progress?(0.95, "SenseVoice vocabulary ready...")
            return
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progress?(0.9, "Downloading SenseVoice vocabulary...")
        let remoteURL = try ModelRegistry.resolveModel(
            Repo.senseVoiceSmall.remotePath,
            ModelNames.SenseVoice.vocabularyFile
        )
        let data = try await DownloadUtils.fetchHuggingFaceFile(
            from: remoteURL,
            description: "SenseVoice vocabulary"
        )
        try data.write(to: vocabularyURL, options: .atomic)
        progress?(0.95, "SenseVoice vocabulary ready...")
    }

    private static func requiredModelsExist(at directory: URL, fileManager: FileManager = .default) -> Bool {
        let vocabularyURL = directory.appendingPathComponent(ModelNames.SenseVoice.vocabularyFile)
        return SenseVoiceModels.modelsExist(at: directory, precision: precision)
            && fileManager.fileExists(atPath: vocabularyURL.path)
    }

    private nonisolated static func audioDuration(url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(file.length) / sampleRate
    }

    private func warmupIfNeeded(progress: ((Double, String?) -> Void)?) async {
        guard !hasCompletedWarmup, let manager else { return }

        progress?(0.98, "Warming up SenseVoice...")
        fputs("[sensevoice] warmup: running silent audio for CoreML compilation...\n", stderr)
        do {
            let silence = [Float](repeating: 0, count: 16_000)
            _ = try await manager.transcribe(audio: silence)
            hasCompletedWarmup = true
            fputs("[sensevoice] warmup complete\n", stderr)
        } catch {
            fputs("[sensevoice] warmup failed: \(error)\n", stderr)
        }
    }
}
