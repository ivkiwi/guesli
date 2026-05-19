import AppKit
import AVFoundation
import FluidAudio
import Foundation
import MuesliCore
import UniformTypeIdentifiers

/// Handles importing audio files (m4a, mp4, wav, mp3) for offline transcription.
/// Converts the source file to 16kHz mono WAV, transcribes it, optionally runs
/// speaker diarization, and creates a meeting record with the result.
enum AudioFileImportController {
    private static let allowedTypes: [UTType] = [
        .wav,
        .mp3,
        .mpeg4Audio,
        .appleProtectedMPEG4Audio,
        UTType(filenameExtension: "m4a") ?? .audio,
        UTType(filenameExtension: "mp4") ?? .audio,
    ].filter { $0 != .audio }  // drop fallback if real types are present

    // MARK: - File Selection

    /// Presents an NSOpenPanel for selecting an audio file and returns the chosen URL.
    static func selectFile() async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.title = "Import Audio File for Transcription"
                panel.message = "Choose an audio file (m4a, mp4, wav, mp3)"
                panel.allowedContentTypes = allowedTypes
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canCreateDirectories = false

                NSApp.activate()
                if let window = NSApp.keyWindow {
                    panel.beginSheetModal(for: window) { response in
                        continuation.resume(
                            returning: response == .OK ? panel.url : nil
                        )
                    }
                } else {
                    panel.begin { response in
                        continuation.resume(
                            returning: response == .OK ? panel.url : nil
                        )
                    }
                }
            }
        }
    }

    // MARK: - Audio Conversion

    enum ImportError: Error, LocalizedError {
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

    /// Converts the source audio file to 16kHz mono WAV for transcription.
    /// Returns the temporary WAV URL and the audio duration in seconds.
    static func convertToWAV(sourceURL: URL) throws -> (wavURL: URL, duration: TimeInterval) {
        let asset = AVAsset(url: sourceURL)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw ImportError.noAudioTracks
        }

        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0, duration.isFinite else {
            throw ImportError.readError("Invalid audio duration.")
        }

        let outputURL = try temporaryWAVURL()
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(url: outputURL, fileType: .wav)
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: sourceFormat.settings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard reader.startReading() else {
            throw ImportError.readError(reader.error?.localizedDescription ?? "Unknown read error")
        }
        guard writer.startWriting() else {
            throw ImportError.conversionFailed(writer.error?.localizedDescription ?? "Unknown write error")
        }
        writer.startSession(atSourceTime: .zero)

        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.muesli.import.convert")) {
            while writerInput.isReadyForMoreMediaData {
                if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                    writerInput.append(sampleBuffer)
                } else {
                    writerInput.markAsFinished()
                    dispatchGroup.leave()
                    return
                }
            }
        }
        dispatchGroup.wait()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if let error = writer.error {
            try? FileManager.default.removeItem(at: outputURL)
            throw ImportError.conversionFailed(error.localizedDescription)
        }
        guard reader.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ImportError.readError(reader.error?.localizedDescription ?? "Read did not complete")
        }

        return (outputURL, duration)
    }

    // MARK: - Import Pipeline

    struct ImportResult {
        let meetingID: Int64
        let title: String
        let rawTranscript: String
        let formattedNotes: String
        let durationSeconds: Double
        let wordCount: Int
    }

    /// Runs the full import pipeline: convert, transcribe, diarize, format, persist, summarize.
    static func importAudioFile(
        sourceURL: URL,
        title: String,
        controller: MuesliController,
        progress: @escaping (String) -> Void
    ) async throws -> ImportResult {
        progress("Converting audio file...")
        let (wavURL, duration) = try convertToWAV(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let config = controller.config
        let backend = controller.selectedMeetingTranscriptionBackend
        let transcriptionCoordinator = controller.transcriptionCoordinator

        progress("Loading transcription model...")
        try await transcriptionCoordinator.preloadRequired(
            backend: backend,
            enablePostProcessor: false,
            includeMeetingHelpers: true
        )

        progress("Transcribing audio...")
        let transcription = try await transcriptionCoordinator.transcribeMeeting(
            at: wavURL,
            backend: backend,
            cohereLanguage: config.resolvedCohereLanguage
        )
        let rawTranscript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Run speaker diarization if available
        var diarizedTranscript = rawTranscript
        if let diarizerManager = transcriptionCoordinator.getDiarizerManager(),
           diarizerManager.isAvailable,
           !rawTranscript.isEmpty {
            progress("Identifying speakers...")
            do {
                let converter = AudioConverter()
                let samples = try converter.resampleAudioFile(wavURL)
                let diarizationResult = try diarizerManager.performCompleteDiarization(
                    samples,
                    sampleRate: 16000
                )
                if !diarizationResult.segments.isEmpty {
                    diarizedTranscript = formatTranscriptWithSpeakers(
                        rawText: rawTranscript,
                        diarizationSegments: diarizationResult.segments,
                        duration: duration
                    )
                }
            } catch {
                fputs("[import] diarization failed, using raw transcript: \(error)\n", stderr)
            }
        }

        let wordCount = DictationStore.countWords(in: diarizedTranscript)

        progress("Generating summary...")
        let templateSnapshot = controller.defaultMeetingTemplate()
        let formattedNotes: String
        do {
            formattedNotes = try await MeetingSummaryClient.summarize(
                transcript: diarizedTranscript,
                meetingTitle: title,
                config: config,
                template: templateSnapshot,
                existingNotes: nil,
                manualNotesToRetain: ""
            )
        } catch {
            fputs("[import] summary generation failed: \(error)\n", stderr)
            formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: diarizedTranscript,
                meetingTitle: title,
                error: error,
                manualNotes: ""
            )
        }

        progress("Saving...")
        let now = Date()
        let startTime = now.addingTimeInterval(-duration)
        let meetingID = try controller.dictationStore.insertMeeting(
            title: title,
            calendarEventID: nil,
            startTime: startTime,
            endTime: now,
            rawTranscript: diarizedTranscript,
            formattedNotes: formattedNotes,
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: nil,
            selectedTemplateID: templateSnapshot.id,
            selectedTemplateName: templateSnapshot.name,
            selectedTemplateKind: templateSnapshot.kind,
            selectedTemplatePrompt: templateSnapshot.prompt
        )

        return ImportResult(
            meetingID: meetingID,
            title: title,
            rawTranscript: diarizedTranscript,
            formattedNotes: formattedNotes,
            durationSeconds: duration,
            wordCount: wordCount
        )
    }

    // MARK: - Helpers

    private static func temporaryWAVURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-import", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("import_\(UUID().uuidString).wav")
    }

    /// Formats transcript text with speaker labels based on diarization segments.
    /// Uses a simple approach: if diarization identifies distinct speakers, prefix
    /// transcript lines with speaker labels.
    static func formatTranscriptWithSpeakers(
        rawText: String,
        diarizationSegments: [TimedSpeakerSegment],
        duration: TimeInterval
    ) -> String {
        guard !diarizationSegments.isEmpty else { return rawText }

        let speakerCount = Set(diarizationSegments.map(\.speakerId)).count
        guard speakerCount > 1 else { return rawText }

        // Build a speaker-labeled transcript using diarization segments
        var lines: [String] = []
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = [.pad]

        for segment in diarizationSegments {
            let startStr = formatTimeInterval(segment.startTime)
            let speaker = segment.speakerId.replacingOccurrences(of: "SPEAKER_", with: "Speaker ")
            lines.append("[\(startStr)] \(speaker):")
        }

        // If the raw text has timestamp markers, use those instead
        if rawText.contains("[") && rawText.contains("]") {
            return rawText
        }

        // Fallback: prepend a header and return the raw text
        let header = diarizationSegments.map { segment in
            let startStr = formatTimeInterval(segment.startTime)
            let endStr = formatTimeInterval(segment.endTime)
            let speaker = segment.speakerId.replacingOccurrences(of: "SPEAKER_", with: "Speaker ")
            return "[\(startStr) - \(endStr)] \(speaker)"
        }.joined(separator: "\n")

        return "## Speaker Segments\n\(header)\n\n## Transcript\n\(rawText)"
    }

    private static func formatTimeInterval(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
