import ArgumentParser
import AVFoundation
import FluidAudio
import Foundation
import MuesliCore
import MuesliNativeApp

enum TranscribeOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case text
    case json
    case markdown
}

enum TranscribeModel: String, CaseIterable, ExpressibleByArgument, Encodable {
    case gigaAMONNX = "gigaam-onnx"
    case parakeetV3 = "parakeet-v3"
    case parakeetV2 = "parakeet-v2"
    case parakeetUnified = "parakeet-unified"
    case parakeetEou320ms = "parakeet-eou-320ms"
    case senseVoice = "sensevoice"
    case qwen3Asr = "qwen3-asr"
    case nemotron35 = "nemotron35"
    case cohere = "cohere"
    case whisperTinyEnglish = "whisper-tiny-english"
    case whisperSmallEnglish = "whisper-small-english"
    case whisperMediumEnglish = "whisper-medium-english"
    case whisperLargeTurbo = "whisper-large-turbo"

    var isStreaming: Bool { self == .parakeetEou320ms }

    var runtimeModel: HeadlessTranscriptionModel {
        HeadlessTranscriptionModel(rawValue: rawValue)!
    }
}

struct TranscribeJSONPayload: Encodable {
    let transcript: String
    let summary: String?
    let durationSeconds: Double
    let wordCount: Int
    let model: String
    let warnings: [String]
    let savedMeetingID: Int64?
    let title: String

    enum CodingKeys: String, CodingKey {
        case transcript
        case summary
        case durationSeconds
        case wordCount
        case model
        case warnings
        case savedMeetingID
        case title
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcript, forKey: .transcript)
        if let summary {
            try container.encode(summary, forKey: .summary)
        } else {
            try container.encodeNil(forKey: .summary)
        }
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encode(model, forKey: .model)
        try container.encode(warnings, forKey: .warnings)
        if let savedMeetingID {
            try container.encode(savedMeetingID, forKey: .savedMeetingID)
        } else {
            try container.encodeNil(forKey: .savedMeetingID)
        }
        try container.encode(title, forKey: .title)
    }
}

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe a local audio file with Guesli's local ASR models."
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Audio file to transcribe. Supported extensions: mp3, mp4, m4a, wav.")
    var file: String
    @Option(name: .long, help: "Output format: text, json, or markdown.")
    var format: TranscribeOutputFormat = .text
    @Option(name: .long, help: "Transcription model: gigaam-onnx, parakeet-v3, parakeet-v2, parakeet-unified, parakeet-eou-320ms, sensevoice, qwen3-asr, nemotron35, cohere, whisper-tiny-english, whisper-small-english, whisper-medium-english, or whisper-large-turbo.")
    var model: TranscribeModel = .gigaAMONNX
    @Flag(name: .long, help: "Generate meeting notes using the configured Guesli summary backend when available.")
    var summarize = false
    @Flag(name: .long, help: "Save the transcript as an imported Muesli meeting.")
    var saveMeeting = false
    @Option(name: .long, help: "Optional title override for saved meetings and markdown output.")
    var title: String?
    @Option(name: .long, help: "Write command output to a file instead of stdout.")
    var output: String?
    @Option(name: .long, help: "Path to a portable dictionary JSON array ({word, replacement, matching_threshold}), or an app config JSON object with custom_words, to apply to the transcript.")
    var dictionary: String?
    @Option(name: .long, help: "Streaming models only: write cumulative partials as JSON lines ({t, text}) to this path.")
    var emitPartials: String?

    mutating func validate() throws {
        let url = URL(fileURLWithPath: file)
        guard MuesliAudioFilePreparer.isSupportedFileURL(url) else {
            throw ValidationError("Unsupported audio file extension. Supported extensions: mp3, mp4, m4a, wav.")
        }
        if emitPartials != nil, !model.isStreaming {
            throw ValidationError("--emit-partials is only supported with parakeet-eou-320ms.")
        }
    }

    func run() async throws {
        let context = CLIContext(options: global)
        let sourceURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CLIError.notFound("Audio file does not exist: \(sourceURL.path)", fix: "Pass a local .mp3, .mp4, .m4a, or .wav file path.")
        }

        let pipeline = MuesliAudioTranscriptionPipeline()
        let result = try await pipeline.run(
            request: MuesliAudioTranscriptionRequest(
                sourceURL: sourceURL,
                model: model,
                title: title,
                summarize: summarize,
                saveMeeting: saveMeeting,
                dictionaryURL: dictionary.map { URL(fileURLWithPath: $0) },
                emitPartialsURL: emitPartials.map { URL(fileURLWithPath: $0) }
            ),
            context: context
        )

        let outputText: String
        switch format {
        case .text:
            outputText = result.textOutput
        case .markdown:
            outputText = result.markdownOutput + "\n"
        case .json:
            let payload = TranscribeJSONPayload(result)
            let envelope = SuccessEnvelope(
                command: "muesli-cli transcribe",
                data: payload,
                meta: MetaBody(
                    schemaVersion: 1,
                    generatedAt: timestampString(),
                    dbPath: context.databaseURL.path,
                    warnings: result.warnings
                )
            )
            outputText = String(decoding: try encodedJSON(envelope), as: UTF8.self)
        }

        if let output {
            try writeOutput(outputText, to: URL(fileURLWithPath: output))
        } else {
            FileHandle.standardOutput.write(Data(outputText.utf8))
        }
    }
}

extension TranscribeJSONPayload {
    init(_ result: MuesliAudioTranscriptionResult) {
        self.init(
            transcript: result.transcript,
            summary: result.summary,
            durationSeconds: result.durationSeconds,
            wordCount: result.wordCount,
            model: result.model.rawValue,
            warnings: result.warnings,
            savedMeetingID: result.savedMeetingID,
            title: result.title
        )
    }
}

func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(value)
    data.append(Data("\n".utf8))
    return data
}

func writeOutput(_ text: String, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
}

struct MuesliAudioTranscriptionRequest {
    let sourceURL: URL
    let model: TranscribeModel
    let title: String?
    let summarize: Bool
    let saveMeeting: Bool
    /// Path to a JSON array of `CustomWord`-shaped entries. When set, applied to the
    /// transcript via `CustomWordMatcher.apply` after transcription — the same dictionary
    /// correction step Muesli applies to dictations, so this measures "what if the
    /// dictionary were enabled" against exactly the shipped implementation.
    var dictionaryURL: URL? = nil
    var emitPartialsURL: URL? = nil
}

struct MuesliAudioTranscriptionResult {
    let title: String
    let transcript: String
    let summary: String?
    let durationSeconds: Double
    let wordCount: Int
    let model: TranscribeModel
    let warnings: [String]
    let savedMeetingID: Int64?

    var textOutput: String {
        transcript + "\n"
    }

    var markdownOutput: String {
        var sections = ["# \(title)"]
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(summary)
        }
        sections.append("## Raw Transcript\n\n\(transcript)")
        return sections.joined(separator: "\n\n")
    }
}

struct PreparedAudioFile {
    let wavURL: URL
    let durationSeconds: Double
    let deleteWhenDone: Bool
}

protocol AudioPreparing {
    func prepareAudio(sourceURL: URL) async throws -> PreparedAudioFile
}

protocol AudioTranscribing {
    func transcribe(
        wavURL: URL,
        model: TranscribeModel,
        onPartial: (@Sendable (Double, String) -> Void)?,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> HeadlessTranscription
}

protocol MeetingSummarizing {
    func summarize(transcript: String, title: String, supportDirectory: URL) async throws -> String
}

struct HeadlessTranscription {
    let text: String
    let durationSeconds: Double?
}

struct MuesliAudioTranscriptionPipeline {
    var audioPreparer: AudioPreparing
    var transcriber: AudioTranscribing
    var summarizer: MeetingSummarizing
    var dataChangePoster: () -> Void

    init(
        audioPreparer: AudioPreparing = MuesliAudioFilePreparer(),
        transcriber: AudioTranscribing = CoordinatorAudioTranscriber(),
        summarizer: MeetingSummarizing = ConfiguredCLIMeetingSummarizer(),
        dataChangePoster: @escaping () -> Void = MuesliNotifications.postDataDidChange
    ) {
        self.audioPreparer = audioPreparer
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.dataChangePoster = dataChangePoster
    }

    func run(request: MuesliAudioTranscriptionRequest, context: CLIContext) async throws -> MuesliAudioTranscriptionResult {
        let customWords: [CustomWord]?
        if let dictionaryURL = request.dictionaryURL {
            customWords = try Self.loadCustomWords(from: dictionaryURL)
        } else {
            customWords = nil
        }

        fputs("[muesli-cli] preparing audio...\n", stderr)
        let prepared = try await audioPreparer.prepareAudio(sourceURL: request.sourceURL)
        defer {
            if prepared.deleteWhenDone {
                try? FileManager.default.removeItem(at: prepared.wavURL)
            }
        }

        fputs("[muesli-cli] loading \(request.model.rawValue) and transcribing...\n", stderr)
        let partialsWriter = try request.emitPartialsURL.map { try PartialsJSONLWriter(url: $0) }
        let transcription: HeadlessTranscription
        do {
            transcription = try await transcriber.transcribe(
                wavURL: prepared.wavURL,
                model: request.model,
                onPartial: partialsWriter.map { writer in
                    { @Sendable seconds, text in writer.record(t: seconds, text: text) }
                },
                progress: { message in
                    fputs("[muesli-cli] \(message)\n", stderr)
                }
            )
            try partialsWriter?.close()
        } catch {
            partialsWriter?.discard()
            throw error
        }
        var transcript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.hasMeaningfulSpeech(transcript) else {
            throw CLIError.invalidInput("No speech was transcribed from the selected audio file.", fix: "Check that the file contains audible speech and try again.")
        }
        if let customWords {
            transcript = CustomWordMatcher.apply(text: transcript, customWords: customWords)
            transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.hasMeaningfulSpeech(transcript) else {
                throw CLIError.invalidInput("No speech remains after applying the selected dictionary.", fix: "Remove dictionary entries that replace all recognized speech with empty text.")
            }
        }

        var warnings: [String] = []
        let title = resolvedTitle(override: request.title, sourceURL: request.sourceURL)
        let duration = transcription.durationSeconds ?? prepared.durationSeconds
        let wordCount = DictationStore.countWords(in: transcript)

        let summary: String?
        if request.summarize {
            do {
                summary = try await summarizer.summarize(transcript: transcript, title: title, supportDirectory: context.supportDirectory)
            } catch {
                let message = "Summary failed: \(error.localizedDescription)"
                warnings.append(message)
                fputs("[muesli-cli] \(message)\n", stderr)
                summary = nil
            }
        } else {
            summary = nil
        }

        let savedMeetingID: Int64?
        if request.saveMeeting {
            try context.store.migrateIfNeeded()
            let savedRecordingPath: String?
            do {
                savedRecordingPath = try persistRecording(sourceURL: request.sourceURL, title: title, supportDirectory: context.supportDirectory)
            } catch {
                let message = "Saving audio copy failed: \(error.localizedDescription)"
                warnings.append(message)
                fputs("[muesli-cli] \(message)\n", stderr)
                savedRecordingPath = nil
            }
            let now = Date()
            let notes = summary ?? Self.rawTranscriptNotes(transcript: transcript, title: title, summaryRequested: request.summarize, warnings: warnings)
            savedMeetingID = try context.store.insertMeeting(
                title: title,
                calendarEventID: nil,
                startTime: now.addingTimeInterval(-max(duration, 0)),
                endTime: now,
                rawTranscript: transcript,
                formattedNotes: notes,
                micAudioPath: nil,
                systemAudioPath: nil,
                savedRecordingPath: savedRecordingPath,
                selectedTemplateID: "cli-audio-import",
                selectedTemplateName: "CLI Audio Import",
                selectedTemplateKind: .custom,
                selectedTemplatePrompt: nil,
                source: .audioImport
            )
            dataChangePoster()
        } else {
            savedMeetingID = nil
        }

        return MuesliAudioTranscriptionResult(
            title: title,
            transcript: transcript,
            summary: summary,
            durationSeconds: duration,
            wordCount: wordCount,
            model: request.model,
            warnings: warnings,
            savedMeetingID: savedMeetingID
        )
    }

    private static func hasMeaningfulSpeech(_ transcript: String) -> Bool {
        transcript.rangeOfCharacter(from: .alphanumerics) != nil
    }

    static func rawTranscriptNotes(transcript: String, title: String, summaryRequested: Bool, warnings: [String]) -> String {
        var sections: [String] = []
        if summaryRequested {
            sections.append("## Summary unavailable")
            if warnings.isEmpty {
                sections.append("Muesli could not generate structured notes from the configured summary backend.")
            } else {
                sections.append(warnings.joined(separator: "\n"))
            }
        } else {
            sections.append("## Summary")
            sections.append("No generated summary was requested.")
        }
        sections.append("## Raw Transcript\n\n\(transcript)")
        return sections.joined(separator: "\n\n")
    }

    /// Loads `--dictionary`'s JSON file: either a plain array of `CustomWord`-shaped
    /// objects, or an object with a `custom_words` key (so a real `config.json`'s
    /// dictionary can be pointed at directly).
    static func loadCustomWords(from url: URL) throws -> [CustomWord] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.notFound("Dictionary file does not exist: \(url.path)", fix: "Pass a JSON array of {word, replacement, matching_threshold} entries.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CLIError.invalidInput(
                "Could not read dictionary file \(url.path): \(error.localizedDescription)",
                fix: "Check that the path is a readable file and pass a JSON array of {word, replacement, matching_threshold} entries."
            )
        }
        do {
            return try CustomWordDictionaryCodec.decode(data)
        } catch {
            throw CLIError.invalidInput(
                "Could not parse \(url.path) as a dictionary.",
                fix: "Provide a JSON array of {\"word\": ..., \"replacement\": ..., \"matching_threshold\": ...} objects, or an object with a \"custom_words\" key in that shape."
            )
        }
    }

    private func resolvedTitle(override: String?, sourceURL: URL) -> String {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        let stem = sourceURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "Imported Audio" : stem
    }

    private func persistRecording(sourceURL: URL, title: String, supportDirectory: URL) throws -> String {
        let recordingsDirectory = supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let fileExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "wav"
            : sourceURL.pathExtension.lowercased()
        let filename = "\(formatter.string(from: Date()))_\(safeFilenameComponent(title))_\(UUID().uuidString.prefix(8)).\(fileExtension)"
        let destinationURL = recordingsDirectory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL.path
    }

    private func safeFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return collapsed.isEmpty ? "Imported-Audio" : String(collapsed.prefix(80))
    }
}

struct MuesliAudioFilePreparer: AudioPreparing {
    static let supportedExtensions: Set<String> = ["m4a", "mp4", "wav", "mp3"]

    static func isSupportedFileURL(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    enum PreparationError: Error, LocalizedError {
        case unsupportedFormat
        case conversionFailed(String)
        case noAudioTracks
        case readError(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "This audio file format is not supported."
            case .conversionFailed(let detail):
                return "Could not convert the audio file. \(detail)"
            case .noAudioTracks:
                return "The selected file does not contain any audio tracks."
            case .readError(let detail):
                return "Could not read the audio file. \(detail)"
            }
        }
    }

    func prepareAudio(sourceURL: URL) async throws -> PreparedAudioFile {
        guard Self.isSupportedFileURL(sourceURL) else {
            throw PreparationError.unsupportedFormat
        }
        try Task.checkCancellation()

        if let compatible = try compatibleWAVInfo(sourceURL: sourceURL) {
            let outputURL = try temporaryWAVURL()
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)
            return PreparedAudioFile(wavURL: outputURL, durationSeconds: compatible.duration, deleteWhenDone: true)
        }

        let duration = try await audioDuration(sourceURL: sourceURL)
        try Task.checkCancellation()

        let decoded = try await decodeAssetReaderToTemporaryWAV(sourceURL: sourceURL)
        guard decoded.sampleCount > 0 else {
            try? FileManager.default.removeItem(at: decoded.wavURL)
            throw PreparationError.noAudioTracks
        }
        let resolvedDuration = duration ?? Double(decoded.sampleCount) / Double(CLIWavWriter.sampleRate)
        guard resolvedDuration > 0, resolvedDuration.isFinite else {
            try? FileManager.default.removeItem(at: decoded.wavURL)
            throw PreparationError.readError("Invalid audio duration.")
        }
        return PreparedAudioFile(wavURL: decoded.wavURL, durationSeconds: resolvedDuration, deleteWhenDone: true)
    }

    private struct CompatibleWAVInfo {
        let duration: TimeInterval
    }

    private func compatibleWAVInfo(sourceURL: URL) throws -> CompatibleWAVInfo? {
        guard sourceURL.pathExtension.lowercased() == "wav" else { return nil }
        let file = try AVAudioFile(forReading: sourceURL)
        let format = file.fileFormat
        guard format.sampleRate == Double(CLIWavWriter.sampleRate),
              format.channelCount == UInt32(CLIWavWriter.channels),
              format.commonFormat == .pcmFormatInt16 else {
            return nil
        }
        let duration = Double(file.length) / format.sampleRate
        guard duration > 0, duration.isFinite else {
            throw PreparationError.readError("Invalid audio duration.")
        }
        return CompatibleWAVInfo(duration: duration)
    }

    private func temporaryWAVURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cli-import", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("import_\(UUID().uuidString).wav")
    }

    private func audioDuration(sourceURL: URL) async throws -> TimeInterval? {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .audio }) else {
            throw PreparationError.noAudioTracks
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        return duration > 0 && duration.isFinite ? duration : nil
    }

    private func decodeAssetReaderToTemporaryWAV(sourceURL: URL) async throws -> (wavURL: URL, sampleCount: Int) {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks)
        guard let audioTrack = tracks.first(where: { $0.mediaType == .audio }) else {
            throw PreparationError.noAudioTracks
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw PreparationError.conversionFailed("Could not read audio samples from the selected file.")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw PreparationError.readError(reader.error?.localizedDescription ?? "Unknown read error")
        }

        let converter = AudioConverter()
        let wavURL = try CLIWavWriter.temporaryWAVURL(directoryName: "muesli-cli-import")
        do {
            let sampleCount = try CLIWavWriter.writeWAV(to: wavURL) { handle in
                var totalSamples = 0
                while reader.status == .reading {
                    try Task.checkCancellation()
                    guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
                    let chunk = try converter.resampleSampleBuffer(sampleBuffer)
                    totalSamples += try CLIWavWriter.append(samples: chunk, to: handle)
                }
                guard reader.status == .completed else {
                    throw PreparationError.readError(reader.error?.localizedDescription ?? "Read did not complete")
                }
                return totalSamples
            }
            return (wavURL, sampleCount)
        } catch {
            try? FileManager.default.removeItem(at: wavURL)
            throw error
        }
    }
}

actor CoordinatorAudioTranscriber: AudioTranscribing {
    private let runtime = HeadlessTranscriptionRuntime()

    func transcribe(
        wavURL: URL,
        model: TranscribeModel,
        onPartial: (@Sendable (Double, String) -> Void)?,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> HeadlessTranscription {
        let result = try await runtime.transcribe(
            wavURL: wavURL,
            model: model.runtimeModel,
            progress: { fraction, message in
                progress(message ?? "model \(Int((fraction * 100).rounded()))%")
            },
            onPartial: onPartial
        )
        return HeadlessTranscription(text: result.text, durationSeconds: result.durationSeconds)
    }
}

final class PartialsJSONLWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let destinationURL: URL
    private let stagingURL: URL
    private let lock = NSLock()
    private var isClosed = false

    init(url: URL) throws {
        destinationURL = url
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stagingURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: stagingURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: stagingURL)
    }

    deinit {
        guard !isClosed else { return }
        try? handle.close()
        try? FileManager.default.removeItem(at: stagingURL)
    }

    func record(t: Double, text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["t": t, "text": text]) else { return }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        }
        isClosed = true
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        try? handle.close()
        try? FileManager.default.removeItem(at: stagingURL)
        isClosed = true
    }
}

enum CLIWavWriter {
    static let sampleRate: UInt32 = 16_000
    static let channels: UInt16 = 1
    static let bitsPerSample: UInt16 = 16

    static func temporaryWAVURL(directoryName: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
    }

    static func writeTemporaryWAV(samples: [Float], directoryName: String) throws -> URL {
        let url = try temporaryWAVURL(directoryName: directoryName)
        try writeWAV(samples: samples, to: url)
        return url
    }

    static func writeWAV(samples: [Float], to url: URL) throws {
        _ = try writeWAV(to: url) { handle in
            try append(samples: samples, to: handle)
        }
    }

    @discardableResult
    static func writeWAV(to url: URL, writeSamples: (FileHandle) throws -> Int) throws -> Int {
        _ = FileManager.default.createFile(atPath: url.path, contents: header(dataSize: 0))
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seekToEnd()
            let sampleCount = try writeSamples(handle)
            let dataSize = UInt32(sampleCount * Int(bitsPerSample / 8))
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(dataSize: dataSize))
            try handle.close()
            return sampleCount
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    @discardableResult
    static func append(samples: [Float], to handle: FileHandle) throws -> Int {
        guard !samples.isEmpty else { return 0 }
        var data = Data()
        data.reserveCapacity(samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1.0, min(1.0, sample)) * 32767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        return samples.count
    }

    private static func header(dataSize: UInt32) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: (dataSize + 36).littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        return header
    }
}

struct ConfiguredCLIMeetingSummarizer: MeetingSummarizing {
    func summarize(transcript: String, title: String, supportDirectory: URL) async throws -> String {
        try await HeadlessMeetingSummaryRuntime.summarize(
            transcript: transcript,
            title: title,
            supportDirectory: supportDirectory
        )
    }
}
