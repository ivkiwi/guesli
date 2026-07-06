@preconcurrency import CoreML
import Foundation
import MuesliCore

struct GigaAMV3TranscriptionResult: Sendable {
    let text: String
    let duration: TimeInterval
    let processingTime: TimeInterval
}

enum GigaAMV3FileChunking {
    static let sampleRate = 16_000
    static let passthroughThresholdSeconds: TimeInterval = 25
    static let windowSeconds: TimeInterval = 20
    static let overlapSeconds: TimeInterval = 2

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
            if end == sampleCount {
                break
            }
            start += stepSamples
        }

        return result
    }

    static func shouldChunk(sampleCount: Int, sampleRate: Int = sampleRate) -> Bool {
        Double(sampleCount) / Double(sampleRate) > passthroughThresholdSeconds
    }

    static func mergeTranscripts(_ transcripts: [String]) -> String {
        var chunks = transcripts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var merged = chunks.first?.split(separator: " ").map(String.init) else {
            return ""
        }
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
        guard limit >= 1 else { return 0 }

        for count in stride(from: limit, through: 1, by: -1) {
            let leftSuffix = left.suffix(count).map(normalizedWord)
            let rightPrefix = right.prefix(count).map(normalizedWord)
            if !leftSuffix.contains(""), leftSuffix == rightPrefix {
                return count
            }
        }

        return 0
    }

    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

enum GigaAMV3ModelStore {
    static let repoID = "huggingfinger0/gigaam-v3-coreml"
    static let cacheRelativePath = "Models/gigaam-v3-coreml"
    static let downloadedModelSizeLabel = "~224 MB"
    static let localSeedEnvironmentKey = "MUESLI_GIGAAM_V3_MODEL_DIR"

    private struct RequiredFile {
        let path: String
        let progressWeight: Double
        let minimumBytes: Int64
        let remoteRepoID: String
        let remotePath: String

        init(
            path: String,
            progressWeight: Double,
            minimumBytes: Int64,
            remoteRepoID: String = GigaAMV3ModelStore.repoID,
            remotePath: String? = nil
        ) {
            self.path = path
            self.progressWeight = progressWeight
            self.minimumBytes = minimumBytes
            self.remoteRepoID = remoteRepoID
            self.remotePath = remotePath ?? path
        }
    }

    private static let requiredFileSpecs: [RequiredFile] = [
        .init(path: "Encoder.mlmodelc/weights/weight.bin", progressWeight: 0.92, minimumBytes: 221_625_000),
        .init(path: "Encoder.mlmodelc/model.mil", progressWeight: 0.01, minimumBytes: 590_000),
        .init(path: "Encoder.mlmodelc/metadata.json", progressWeight: 0.005, minimumBytes: 2_000),
        .init(path: "Encoder.mlmodelc/coremldata.bin", progressWeight: 0.001, minimumBytes: 400),
        .init(path: "Predictor.mlmodelc/weights/weight.bin", progressWeight: 0.02, minimumBytes: 1_160_000),
        .init(path: "Predictor.mlmodelc/model.mil", progressWeight: 0.005, minimumBytes: 9_000),
        .init(path: "Predictor.mlmodelc/metadata.json", progressWeight: 0.002, minimumBytes: 3_000),
        .init(path: "Predictor.mlmodelc/coremldata.bin", progressWeight: 0.001, minimumBytes: 400),
        .init(path: "JointDecision.mlmodelc/weights/weight.bin", progressWeight: 0.01, minimumBytes: 685_000),
        .init(path: "JointDecision.mlmodelc/model.mil", progressWeight: 0.003, minimumBytes: 6_000),
        .init(path: "JointDecision.mlmodelc/metadata.json", progressWeight: 0.002, minimumBytes: 2_000),
        .init(path: "JointDecision.mlmodelc/coremldata.bin", progressWeight: 0.001, minimumBytes: 400),
        .init(path: "vocab.txt", progressWeight: 0.005, minimumBytes: 13_000),
        .init(
            path: "hann_window.f32.bin",
            progressWeight: 0.001,
            minimumBytes: 1_280,
            remoteRepoID: "kruatech/gigaam-v3-mlx"
        ),
        .init(
            path: "mel_filterbank_mel_freq.f32.bin",
            progressWeight: 0.002,
            minimumBytes: 41_216,
            remoteRepoID: "kruatech/gigaam-v3-mlx"
        ),
    ]

    static func cacheDirectory(fileManager: FileManager = .default) -> URL {
        MuesliPaths.defaultSupportDirectoryURL(
            appName: AppIdentity.supportDirectoryName,
            fileManager: fileManager
        ).appendingPathComponent(cacheRelativePath, isDirectory: true)
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
        MuesliPaths.preconditionSafeForTestWrite(directory)
        try fileManager.removeItem(at: directory)
    }

    static func downloadIfNeeded(progress: ((Double, String?) -> Void)? = nil) async throws -> URL {
        let directory = cacheDirectory()
        MuesliPaths.preconditionSafeForTestWrite(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if isAvailableLocally() {
            progress?(1.0, nil)
            return directory
        }

        try seedFromLocalMirrors(to: directory, progress: progress)
        if isAvailableLocally() {
            fputs("[muesli-native] GigaAM v3 loaded from local CoreML cache\n", stderr)
            progress?(0.95, "Loading GigaAM v3...")
            return directory
        }

        progress?(0.05, "Preparing GigaAM v3...")

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
            try FileManager.default.createDirectory(
                at: localFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let remoteURL = URL(string: "https://huggingface.co/\(spec.remoteRepoID)/resolve/main/\(spec.remotePath)") else {
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

    private static func seedFromLocalMirrors(
        to directory: URL,
        progress: ((Double, String?) -> Void)? = nil,
        fileManager: FileManager = .default
    ) throws {
        MuesliPaths.preconditionSafeForTestWrite(directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var copied = 0
        for seedDirectory in localSeedDirectories() {
            for (index, spec) in requiredFileSpecs.enumerated() {
                let source = seedDirectory.appendingPathComponent(spec.path)
                let destination = directory.appendingPathComponent(spec.path)
                guard isCompleteLocalFile(at: source, spec: spec, fileManager: fileManager),
                      !isCompleteLocalFile(at: destination, spec: spec, fileManager: fileManager) else {
                    continue
                }
                MuesliPaths.preconditionSafeForTestWrite(destination)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
                copied += 1
                let fraction = 0.05 + (Double(index + 1) / Double(requiredFileSpecs.count)) * 0.85
                progress?(fraction, "Copying local GigaAM v3 model...")
            }
        }

        if copied > 0 {
            fputs("[muesli-native] GigaAM v3 seeded \(copied) CoreML files from local mirrors\n", stderr)
        }
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

}

private final class GigaAMV3CoreMLRecognizer {
    private let encoder: MLModel
    private let predictor: MLModel
    private let joint: MLModel
    private let melProcessor: GigaAMV3MelSpectrogram
    private let vocabulary: [Int: String]
    private let initialToken: Int32 = 1_024
    private let blankToken = 1_024
    private let featureFrames = 3_000

    init(modelDirectory: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        encoder = try MLModel(contentsOf: modelDirectory.appendingPathComponent("Encoder.mlmodelc"), configuration: config)
        predictor = try MLModel(contentsOf: modelDirectory.appendingPathComponent("Predictor.mlmodelc"), configuration: config)
        joint = try MLModel(contentsOf: modelDirectory.appendingPathComponent("JointDecision.mlmodelc"), configuration: config)
        melProcessor = try GigaAMV3MelSpectrogram(assetsDirectory: modelDirectory)
        vocabulary = try Self.loadVocabulary(modelDirectory.appendingPathComponent("vocab.txt"))
    }

    struct Result {
        let text: String
        let steps: Int
    }

    func transcribe(samples: [Float], sampleRate: Int) throws -> Result {
        guard sampleRate == GigaAMV3FileChunking.sampleRate else {
            throw NSError(domain: "GigaAMV3CoreMLRecognizer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "GigaAM v3 CoreML expects 16 kHz mono audio.",
            ])
        }

        let windows = GigaAMV3FileChunking.windows(sampleCount: samples.count, sampleRate: sampleRate)
        fputs("[muesli-native] GigaAM v3 CoreML chunked transcription: \(windows.count) windows, \(String(format: "%.1f", Double(samples.count) / Double(sampleRate)))s\n", stderr)

        var texts: [String] = []
        var totalSteps = 0
        texts.reserveCapacity(windows.count)

        for window in windows {
            try Task.checkCancellation()
            let decoded = try autoreleasepool { () throws -> (text: String, steps: Int) in
                var chunk = Array(samples[window])
                if chunk.count < melProcessor.winLength {
                    chunk.append(contentsOf: repeatElement(0, count: melProcessor.winLength - chunk.count))
                }

                let raw = try melProcessor.computeFlat(samples: chunk)
                let features = Self.padFeatures(raw.features, sourceFrames: raw.length, targetFrames: featureFrames)
                let decodeFrames = min(750, max(1, (raw.length + 3) / 4))
                let decoded = try decode(features: features, decodeFrames: decodeFrames)
                let text = decodeTokens(decoded.tokens).trimmingCharacters(in: .whitespacesAndNewlines)
                return (text, decoded.steps)
            }
            totalSteps += decoded.steps
            if !decoded.text.isEmpty {
                texts.append(decoded.text)
            }
        }

        return Result(text: GigaAMV3FileChunking.mergeTranscripts(texts), steps: totalSteps)
    }

    private func decode(features: [Float], decodeFrames: Int) throws -> (tokens: [Int], steps: Int) {
        let audioSignal = try Self.floatArray(shape: Self.shape(1, 64, featureFrames))
        Self.copy(features, to: audioSignal)

        let encoderOutput = try prediction(encoder, dictionary: [
            "audio_signal": MLFeatureValue(multiArray: audioSignal),
        ])
        guard let encoded = encoderOutput.featureValue(for: "encoded")?.multiArrayValue else {
            throw NSError(domain: "GigaAMV3CoreMLRecognizer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "CoreML encoder missing encoded output.",
            ])
        }

        var hState = try Self.zeroFloatArray(shape: Self.shape(1, 1, 320))
        var cState = try Self.zeroFloatArray(shape: Self.shape(1, 1, 320))
        var cachedDec: MLMultiArray?
        var cachedH: MLMultiArray?
        var cachedC: MLMultiArray?
        var lastToken = initialToken
        var tokens: [Int] = []
        var steps = 0

        let frameLimit = min(decodeFrames, encoded.shape[2].intValue)
        for frame in 0..<frameLimit {
            var emitted = 0
            while emitted < 10 {
                if cachedDec == nil {
                    let token = try Self.intArray(value: lastToken, shape: Self.shape(1, 1))
                    let predictorOutput = try prediction(predictor, dictionary: [
                        "x": MLFeatureValue(multiArray: token),
                        "hi": MLFeatureValue(multiArray: hState),
                        "ci": MLFeatureValue(multiArray: cState),
                    ])
                    cachedDec = try predictorOutput.gigaAMV3Array("dec")
                    cachedH = try predictorOutput.gigaAMV3Array("ho")
                    cachedC = try predictorOutput.gigaAMV3Array("co")
                }

                let encFrame = try Self.encodedFrame(encoded, frame: frame)
                let decFrame = try Self.decoderFrame(cachedDec!)
                let jointOutput = try prediction(joint, dictionary: [
                    "enc": MLFeatureValue(multiArray: encFrame),
                    "dec": MLFeatureValue(multiArray: decFrame),
                ])
                let predicted = try jointOutput.gigaAMV3Array("token_id").gigaAMV3Int32Value(at: 0)
                steps += 1
                if predicted == blankToken {
                    break
                }

                tokens.append(predicted)
                emitted += 1
                lastToken = Int32(predicted)
                hState = try Self.float32Copy(cachedH!)
                cState = try Self.float32Copy(cachedC!)
                cachedDec = nil
                cachedH = nil
                cachedC = nil
            }
        }
        return (tokens, steps)
    }

    private func decodeTokens(_ tokenIds: [Int]) -> String {
        var text = tokenIds.map { vocabulary[$0] ?? "" }.joined()
        text = text.replacingOccurrences(of: "▁", with: " ")
        if text.hasPrefix(" ") {
            text.removeFirst()
        }
        return text
    }

    private func prediction(_ model: MLModel, dictionary: [String: MLFeatureValue]) throws -> MLFeatureProvider {
        try autoreleasepool {
            try model.prediction(from: MLDictionaryFeatureProvider(dictionary: dictionary))
        }
    }

    private static func loadVocabulary(_ url: URL) throws -> [Int: String] {
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        var vocabulary: [Int: String] = [:]
        for line in lines {
            guard let space = line.lastIndex(of: " ") else { continue }
            let piece = String(line[..<space])
            guard let id = Int(line[line.index(after: space)...]), piece != "<blk>" else { continue }
            vocabulary[id] = piece == "<unk>" ? "" : piece
        }
        return vocabulary
    }

    private static func padFeatures(_ source: [Float], sourceFrames: Int, targetFrames: Int) -> [Float] {
        var output = [Float](repeating: 0, count: 64 * targetFrames)
        let frames = min(sourceFrames, targetFrames)
        for mel in 0..<64 {
            let sourceOffset = mel * sourceFrames
            let outputOffset = mel * targetFrames
            output[outputOffset..<outputOffset + frames] = source[sourceOffset..<sourceOffset + frames]
        }
        return output
    }

    private static func floatArray(shape: [NSNumber]) throws -> MLMultiArray {
        try MLMultiArray(shape: shape, dataType: .float32)
    }

    private static func shape(_ values: Int...) -> [NSNumber] {
        values.map { NSNumber(value: $0) }
    }

    private static func zeroFloatArray(shape: [NSNumber]) throws -> MLMultiArray {
        let array = try floatArray(shape: shape)
        memset(array.dataPointer, 0, array.count * MemoryLayout<Float>.size)
        return array
    }

    private static func intArray(value: Int32, shape: [NSNumber]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape, dataType: .int32)
        array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)[0] = value
        return array
    }

    private static func copy(_ values: [Float], to array: MLMultiArray) {
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        values.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            ptr.update(from: baseAddress, count: min(values.count, array.count))
        }
    }

    private static func encodedFrame(_ encoded: MLMultiArray, frame: Int) throws -> MLMultiArray {
        let output = try floatArray(shape: shape(1, 768, 1))
        let dst = output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
        let channelStride = encoded.strides[1].intValue
        let frameStride = encoded.strides[2].intValue
        switch encoded.dataType {
        case .float16:
            let src = encoded.dataPointer.bindMemory(to: Float16.self, capacity: encoded.count)
            for channel in 0..<768 {
                dst[channel] = Float(src[channel * channelStride + frame * frameStride])
            }
        case .float32:
            let src = encoded.dataPointer.bindMemory(to: Float.self, capacity: encoded.count)
            for channel in 0..<768 {
                dst[channel] = src[channel * channelStride + frame * frameStride]
            }
        default:
            throw NSError(domain: "GigaAMV3CoreMLRecognizer", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported encoded dtype \(encoded.dataType.rawValue).",
            ])
        }
        return output
    }

    private static func decoderFrame(_ dec: MLMultiArray) throws -> MLMultiArray {
        let output = try floatArray(shape: shape(1, 320, 1))
        let dst = output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
        switch dec.dataType {
        case .float16:
            let src = dec.dataPointer.bindMemory(to: Float16.self, capacity: dec.count)
            for index in 0..<320 { dst[index] = Float(src[index]) }
        case .float32:
            let src = dec.dataPointer.bindMemory(to: Float.self, capacity: dec.count)
            for index in 0..<320 { dst[index] = src[index] }
        default:
            throw NSError(domain: "GigaAMV3CoreMLRecognizer", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported decoder dtype \(dec.dataType.rawValue).",
            ])
        }
        return output
    }

    private static func float32Copy(_ array: MLMultiArray) throws -> MLMultiArray {
        let output = try floatArray(shape: array.shape)
        let dst = output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
        switch array.dataType {
        case .float16:
            let src = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            for index in 0..<array.count { dst[index] = Float(src[index]) }
        case .float32:
            let src = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for index in 0..<array.count { dst[index] = src[index] }
        default:
            throw NSError(domain: "GigaAMV3CoreMLRecognizer", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported state dtype \(array.dataType.rawValue).",
            ])
        }
        return output
    }
}

private final class GigaAMV3MelSpectrogram {
    let winLength = 320

    private let nMels = 64
    private let nFFT = 320
    private let hopLength = 160
    private let nFreqs = 161

    private let window: [Float]
    private let filterbank: [Float]
    private let cosTable: [Float]
    private let sinTable: [Float]

    init(assetsDirectory: URL) throws {
        let windowURL = assetsDirectory.appendingPathComponent("hann_window.f32.bin")
        let filterbankURL = assetsDirectory.appendingPathComponent("mel_filterbank_mel_freq.f32.bin")
        window = try Self.readFloat32Binary(windowURL, expectedCount: winLength)
        filterbank = try Self.readFloat32Binary(filterbankURL, expectedCount: nMels * nFreqs)

        var cosTable = [Float](repeating: 0, count: nFreqs * nFFT)
        var sinTable = [Float](repeating: 0, count: nFreqs * nFFT)
        let twoPi = 2.0 * Double.pi
        for freq in 0..<nFreqs {
            let offset = freq * nFFT
            for n in 0..<nFFT {
                let angle = twoPi * Double(freq * n) / Double(nFFT)
                cosTable[offset + n] = Float(cos(angle))
                sinTable[offset + n] = Float(sin(angle))
            }
        }
        self.cosTable = cosTable
        self.sinTable = sinTable
    }

    func computeFlat(samples: [Float]) throws -> (features: [Float], length: Int) {
        guard samples.count >= winLength else {
            throw NSError(domain: "GigaAMV3MelSpectrogram", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Audio is shorter than GigaAM v3 window length.",
            ])
        }

        let frameCount = ((samples.count - winLength) / hopLength) + 1
        var power = [Float](repeating: 0, count: nFreqs * frameCount)

        for frame in 0..<frameCount {
            let frameOffset = frame * hopLength
            for freq in 0..<nFreqs {
                let tableOffset = freq * nFFT
                var real = Float(0)
                var imag = Float(0)
                for n in 0..<nFFT {
                    let sample = samples[frameOffset + n] * window[n]
                    real += sample * cosTable[tableOffset + n]
                    imag -= sample * sinTable[tableOffset + n]
                }
                power[freq * frameCount + frame] = real * real + imag * imag
            }
        }

        var result = [Float](repeating: 0, count: nMels * frameCount)
        for mel in 0..<nMels {
            let melOffset = mel * nFreqs
            let outputOffset = mel * frameCount
            for frame in 0..<frameCount {
                var value = Float(0)
                for freq in 0..<nFreqs {
                    value += filterbank[melOffset + freq] * power[freq * frameCount + frame]
                }
                result[outputOffset + frame] = logf(min(max(value, 1e-9), 1e9))
            }
        }

        return (result, frameCount)
    }

    private static func readFloat32Binary(_ url: URL, expectedCount: Int) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count == expectedCount * MemoryLayout<Float>.size else {
            throw NSError(domain: "GigaAMV3MelSpectrogram", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid GigaAM v3 frontend asset size at \(url.path).",
            ])
        }
        var values = [Float](repeating: 0, count: expectedCount)
        _ = values.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return values
    }
}

private extension MLFeatureProvider {
    func gigaAMV3Array(_ name: String) throws -> MLMultiArray {
        guard let array = featureValue(for: name)?.multiArrayValue else {
            throw NSError(domain: "GigaAMV3CoreMLRecognizer", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "Missing CoreML output \(name).",
            ])
        }
        return array
    }
}

private extension MLMultiArray {
    func gigaAMV3Int32Value(at index: Int) -> Int {
        switch dataType {
        case .int32:
            Int(dataPointer.bindMemory(to: Int32.self, capacity: count)[index])
        default:
            self[index].intValue
        }
    }
}

actor GigaAMV3Transcriber {
    private var recognizer: GigaAMV3CoreMLRecognizer?
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
            let loadedRecognizer = try GigaAMV3CoreMLRecognizer(modelDirectory: directory)
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
        do {
            let prepared = try await AudioFileImportController.prepareAudioForImport(sourceURL: wavURL)
            defer {
                if prepared.wavURL.standardizedFileURL.path != wavURL.standardizedFileURL.path {
                    try? FileManager.default.removeItem(at: prepared.wavURL)
                }
            }
            let result = try recognizer.transcribe(samples: prepared.samples, sampleRate: GigaAMV3FileChunking.sampleRate)

            return GigaAMV3TranscriptionResult(
                text: result.text,
                duration: prepared.duration,
                processingTime: CFAbsoluteTimeGetCurrent() - start
            )
        } catch {
            throw Self.readableTranscriptionError(error)
        }
    }

    func transcribe(samples: [Float], sampleRate: Int) async throws -> GigaAMV3TranscriptionResult {
        if recognizer == nil {
            try await loadModels(allowDownload: false)
        }
        guard let recognizer else {
            throw NSError(domain: "GigaAMV3Transcriber", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "GigaAM v3 recognizer is not loaded.",
            ])
        }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let result = try recognizer.transcribe(samples: samples, sampleRate: sampleRate)

            return GigaAMV3TranscriptionResult(
                text: result.text,
                duration: Double(samples.count) / Double(sampleRate),
                processingTime: CFAbsoluteTimeGetCurrent() - start
            )
        } catch {
            throw Self.readableTranscriptionError(error)
        }
    }

    func shutdown() {
        loadGeneration += 1
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        recognizer = nil
        isLoading = false
        completeLoadWaiters(throwing: NSError(domain: "GigaAMV3Transcriber", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "GigaAM v3 load was shut down.",
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

    nonisolated static func readableTranscriptionError(_ error: Error) -> Error {
        if let cancellationError = cancellationError(in: error) {
            return cancellationError
        }
        let nsError = error as NSError
        if nsError.domain == "GigaAMV3Transcriber" {
            return error
        }

        return NSError(domain: "GigaAMV3Transcriber", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "GigaAM v3 transcription failed: \(error.localizedDescription)",
            NSUnderlyingErrorKey: error,
        ])
    }

    private nonisolated static func cancellationError(in error: Error) -> Error? {
        if error is CancellationError {
            return error
        }
        let nsError = error as NSError
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return cancellationError(in: underlyingError)
        }
        return nil
    }
}
