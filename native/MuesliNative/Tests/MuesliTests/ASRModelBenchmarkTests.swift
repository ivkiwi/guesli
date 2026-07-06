import Darwin
import Foundation
import MuesliCore
import SQLite3
import Testing
@testable import MuesliNativeApp

@Suite("ASR model efficiency benchmarks", .serialized, .muesliHermeticSupport)
struct ASRModelEfficiencyBenchmarks {
    @Test("compare production ASR models on real meeting recordings")
    func compareProductionASRModelsOnRealRecordings() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MUESLI_ASR_BENCH"] == "1" else {
            return
        }

        let config = try BenchmarkConfig(environment: environment)
        let recordings = try config.recordings()
        #expect(!recordings.isEmpty, "Set MUESLI_ASR_BENCH_RECORDINGS or keep readable meetings in the configured DB.")

        let output = BenchmarkOutput(outputURL: config.outputURL, reportURL: config.reportURL)
        try output.reset()
        try output.writeHeader(config: config, recordings: recordings)

        var rows: [BenchmarkRow] = []
        for candidate in config.candidates() {
            for recording in recordings {
                let prepared: PreparedBenchmarkAudio
                do {
                    prepared = try await PreparedBenchmarkAudio.make(
                        recording: recording,
                        startSeconds: config.startSeconds,
                        maxSeconds: config.maxSeconds
                    )
                } catch {
                    let row = BenchmarkRow.inputError(candidate: candidate, recording: recording, error: error)
                    rows.append(row)
                    try output.append(row)
                    try output.writeReport(rows: rows)
                    print(row.markdownLine)
                    continue
                }
                defer { prepared.cleanup() }

                let row = await runCandidate(candidate, prepared: prepared, config: config)
                rows.append(row)
                try output.append(row)
                try output.writeReport(rows: rows)
                print(row.markdownLine)
            }
        }

        try output.writeReport(rows: rows)
    }
}

private struct BenchmarkConfig {
    let databaseURL: URL
    let outputURL: URL
    let reportURL: URL
    let modelIDs: [String]
    let meetingIDs: [Int64]
    let recordingPaths: [String]
    let limit: Int
    let startSeconds: Double
    let maxSeconds: Double?
    let allowDownloads: Bool
    let cohereLanguage: CohereTranscribeLanguage
    let includeText: Bool

    init(environment: [String: String]) throws {
        databaseURL = URL(
            fileURLWithPath: environment["MUESLI_ASR_BENCH_DB"]?.expandedPath
                ?? "~/Library/Application Support/Guesli/muesli.db".expandedPath
        )
        outputURL = URL(
            fileURLWithPath: environment["MUESLI_ASR_BENCH_OUTPUT"]?.expandedPath
                ?? "/tmp/muesli-asr-bench.jsonl"
        )
        reportURL = URL(
            fileURLWithPath: environment["MUESLI_ASR_BENCH_REPORT"]?.expandedPath
                ?? outputURL.deletingPathExtension().appendingPathExtension("md").path
        )
        modelIDs = Self.csv(environment["MUESLI_ASR_BENCH_MODELS"])
        meetingIDs = Self.csv(environment["MUESLI_ASR_BENCH_MEETING_IDS"]).compactMap(Int64.init)
        recordingPaths = Self.csv(environment["MUESLI_ASR_BENCH_RECORDINGS"]).map(\.expandedPath)
        limit = Int(environment["MUESLI_ASR_BENCH_LIMIT"] ?? "") ?? 2
        startSeconds = max(Double(environment["MUESLI_ASR_BENCH_START_SECONDS"] ?? "") ?? 0, 0)
        if let raw = environment["MUESLI_ASR_BENCH_MAX_SECONDS"], let value = Double(raw), value > 0 {
            maxSeconds = value
        } else {
            maxSeconds = nil
        }
        allowDownloads = environment["MUESLI_ASR_BENCH_ALLOW_DOWNLOADS"] == "1"
        cohereLanguage = CohereTranscribeLanguage.resolved(environment["MUESLI_ASR_BENCH_COHERE_LANGUAGE"] ?? CohereTranscribeLanguage.defaultLanguage.rawValue)
        includeText = environment["MUESLI_ASR_BENCH_INCLUDE_TEXT"] == "1"
    }

    func candidates() -> [BenchmarkCandidate] {
        let requested = modelIDs.isEmpty ? ["downloaded", "gigaam-coreml"] : modelIDs
        var result: [BenchmarkCandidate] = []
        for id in requested {
            if id == "downloaded" {
                result.append(contentsOf: productionCandidates(downloadedOnly: true))
            } else if id == "all-production" {
                result.append(contentsOf: productionCandidates(downloadedOnly: false))
            } else if let option = Self.productionOption(id: id) {
                result.append(.production(id: id, option: option))
            }
        }
        return result.uniqued()
    }

    func recordings() throws -> [BenchmarkRecording] {
        if !recordingPaths.isEmpty {
            return recordingPaths.prefix(limit).map { path in
                BenchmarkRecording(
                    id: nil,
                    title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                    sourceURL: URL(fileURLWithPath: path),
                    referenceText: nil,
                    storedDuration: nil
                )
            }
        }

        do {
            let store = DictationStore(databaseURL: databaseURL)
            let meetings: [MeetingRecord]
            if !meetingIDs.isEmpty {
                meetings = try meetingIDs.compactMap { try store.meeting(id: $0) }
            } else {
                meetings = try store.recentMeetings(limit: 200)
                    .filter { meeting in
                        guard let path = meeting.savedRecordingPath else { return false }
                        return !meeting.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && FileManager.default.fileExists(atPath: path)
                            && meeting.durationSeconds > 0
                    }
                    .sorted { $0.durationSeconds < $1.durationSeconds }
                    .prefix(limit)
                    .map { $0 }
            }

            return meetings.compactMap { meeting in
                guard let path = meeting.savedRecordingPath else { return nil }
                return BenchmarkRecording(
                    id: meeting.id,
                    title: meeting.title,
                    sourceURL: URL(fileURLWithPath: path),
                    referenceText: referenceText(for: meeting.id, startTime: meeting.startTime, fallback: meeting.rawTranscript),
                    storedDuration: meeting.durationSeconds
                )
            }
        } catch {
            return try LegacyBenchmarkMeetingReader(databaseURL: databaseURL)
                .recordings(meetingIDs: meetingIDs, limit: limit, startSeconds: startSeconds, maxSeconds: maxSeconds)
        }
    }

    private func referenceText(for meetingID: Int64, startTime: String, fallback: String) -> String? {
        guard maxSeconds != nil || startSeconds > 0 else { return fallback }
        return checkpointReferenceText(meetingID: meetingID)
            ?? timestampedTranscriptWindow(fallback, startTime: startTime, startSeconds: startSeconds, maxSeconds: maxSeconds)
    }

    private func checkpointReferenceText(meetingID: Int64) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let endSeconds = maxSeconds.map { startSeconds + $0 } ?? Double.greatestFiniteMagnitude
        let sql = """
        SELECT text
        FROM meeting_transcript_checkpoints
        WHERE meeting_id = ? AND start_seconds < ? AND end_seconds > ?
        ORDER BY start_seconds ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        sqlite3_bind_double(statement, 2, endSeconds)
        sqlite3_bind_double(statement, 3, startSeconds)

        var texts: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            texts.append(String(cString: cString))
        }
        let text = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func productionCandidates(downloadedOnly: Bool) -> [BenchmarkCandidate] {
        let all = [
            ("gigaam-coreml", BackendOption.gigaAMV3Russian),
            ("parakeet-v3", BackendOption.parakeetMultilingual),
            ("parakeet-v2", BackendOption.parakeetEnglish),
            ("whisper-tiny-en", BackendOption.whisperTinyEnglish),
            ("whisper-small", BackendOption.whisperSmall),
            ("whisper-medium", BackendOption.whisperMedium),
            ("whisper-large-turbo", BackendOption.whisperLargeTurbo),
            ("sensevoice", BackendOption.senseVoiceSmall),
            ("nemotron35", BackendOption.nemotron35Multilingual),
            ("qwen3", BackendOption.qwen3Asr),
            ("canary-qwen", BackendOption.canaryQwen),
            ("cohere", BackendOption.cohereTranscribe),
        ]
        return all.compactMap { id, option in
            if downloadedOnly, !isBenchmarkModelAvailable(option) { return nil }
            return .production(id: id, option: option)
        }
    }

    private static func productionOption(id: String) -> BackendOption? {
        switch id {
        case "gigaam-coreml": return .gigaAMV3Russian
        case "parakeet-v3": return .parakeetMultilingual
        case "parakeet-v2": return .parakeetEnglish
        case "whisper-tiny-en": return .whisperTinyEnglish
        case "whisper-small": return .whisperSmall
        case "whisper-medium": return .whisperMedium
        case "whisper-large-turbo": return .whisperLargeTurbo
        case "sensevoice": return .senseVoiceSmall
        case "nemotron35": return .nemotron35Multilingual
        case "qwen3": return .qwen3Asr
        case "canary-qwen": return .canaryQwen
        case "cohere": return .cohereTranscribe
        default: return nil
        }
    }

    private static func csv(_ raw: String?) -> [String] {
        raw?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }
}

private enum BenchmarkCandidate {
    case production(id: String, option: BackendOption)

    var id: String {
        switch self {
        case .production(let id, _): return id
        }
    }

    var label: String {
        switch self {
        case .production(_, let option): return option.label
        }
    }
}

private struct BenchmarkRecording {
    let id: Int64?
    let title: String
    let sourceURL: URL
    let referenceText: String?
    let storedDuration: Double?
}

private final class LegacyBenchmarkMeetingReader {
    private let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func recordings(meetingIDs: [Int64], limit: Int, startSeconds: Double, maxSeconds: Double?) throws -> [BenchmarkRecording] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_close(db) }

        if !meetingIDs.isEmpty {
            return try meetingIDs.compactMap { id in
                try queryOne(db: db, id: id, startSeconds: startSeconds, maxSeconds: maxSeconds)
            }
        }

        let sql = """
        SELECT id, title, start_time, duration_seconds, raw_transcript, saved_recording_path
        FROM meetings
        WHERE deleted_at IS NULL
          AND raw_transcript IS NOT NULL
          AND length(raw_transcript) > 0
          AND saved_recording_path IS NOT NULL
          AND duration_seconds > 0
        ORDER BY duration_seconds ASC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var rows: [BenchmarkRecording] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let row = row(statement, startSeconds: startSeconds, maxSeconds: maxSeconds) {
                rows.append(row)
            }
        }
        return rows
    }

    private func queryOne(db: OpaquePointer?, id: Int64, startSeconds: Double, maxSeconds: Double?) throws -> BenchmarkRecording? {
        let sql = """
        SELECT id, title, start_time, duration_seconds, raw_transcript, saved_recording_path
        FROM meetings
        WHERE id = ? AND deleted_at IS NULL
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(db)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return row(statement, startSeconds: startSeconds, maxSeconds: maxSeconds)
    }

    private func row(_ statement: OpaquePointer?, startSeconds: Double, maxSeconds: Double?) -> BenchmarkRecording? {
        let path = stringColumn(statement, 5)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let id = sqlite3_column_int64(statement, 0)
        return BenchmarkRecording(
            id: id,
            title: stringColumn(statement, 1),
            sourceURL: URL(fileURLWithPath: path),
            referenceText: referenceText(
                db: sqlite3_db_handle(statement),
                meetingID: id,
                startTime: stringColumn(statement, 2),
                fallback: stringColumn(statement, 4),
                startSeconds: startSeconds,
                maxSeconds: maxSeconds
            ),
            storedDuration: sqlite3_column_double(statement, 3)
        )
    }

    private func referenceText(db: OpaquePointer?, meetingID: Int64, startTime: String, fallback: String, startSeconds: Double, maxSeconds: Double?) -> String? {
        guard maxSeconds != nil || startSeconds > 0 else { return fallback }
        let endSeconds = maxSeconds.map { startSeconds + $0 } ?? Double.greatestFiniteMagnitude
        let sql = """
        SELECT text
        FROM meeting_transcript_checkpoints
        WHERE meeting_id = ? AND start_seconds < ? AND end_seconds > ?
        ORDER BY start_seconds ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, meetingID)
        sqlite3_bind_double(statement, 2, endSeconds)
        sqlite3_bind_double(statement, 3, startSeconds)

        var texts: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            texts.append(String(cString: cString))
        }
        let text = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return timestampedTranscriptWindow(fallback, startTime: startTime, startSeconds: startSeconds, maxSeconds: maxSeconds)
    }

    private func stringColumn(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func lastError(_ db: OpaquePointer?) -> NSError {
        NSError(domain: "LegacyBenchmarkMeetingReader", code: 1, userInfo: [
            NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error",
        ])
    }
}

private func timestampedTranscriptWindow(_ transcript: String, startTime: String, startSeconds: Double, maxSeconds: Double?) -> String? {
    guard let startDate = ISO8601DateFormatter().date(from: startTime) else { return nil }
    let components = Calendar.current.dateComponents([.hour, .minute, .second], from: startDate)
    guard
        let startHour = components.hour,
        let startMinute = components.minute,
        let startSecond = components.second
    else { return nil }
    let startOfDaySecond = startHour * 3_600 + startMinute * 60 + startSecond

    let pattern = #"^\[(\d{2}):(\d{2}):(\d{2})\]\s*[^:]+:\s*(.*)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let endSeconds = maxSeconds.map { startSeconds + $0 }
    var texts: [String] = []
    for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
        let lineString = String(line)
        let range = NSRange(lineString.startIndex..<lineString.endIndex, in: lineString)
        guard let match = regex.firstMatch(in: lineString, range: range), match.numberOfRanges == 5 else { continue }
        let captures = (1...4).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: lineString) else { return nil }
            return String(lineString[range])
        }
        guard
            captures.count == 4,
            let hour = Int(captures[0]),
            let minute = Int(captures[1]),
            let second = Int(captures[2])
        else { continue }
        var lineSecond = hour * 3_600 + minute * 60 + second
        if lineSecond < startOfDaySecond {
            lineSecond += 86_400
        }
        let offset = Double(lineSecond - startOfDaySecond)
        guard offset >= startSeconds else { continue }
        if let endSeconds, offset >= endSeconds { continue }
        texts.append(captures[3])
    }
    let text = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

private struct PreparedBenchmarkAudio {
    let recording: BenchmarkRecording
    let wavURL: URL
    let samples: [Float]
    let duration: Double
    let isTruncated: Bool
    private let cleanupURLs: [URL]

    static func make(recording: BenchmarkRecording, startSeconds: Double, maxSeconds: Double?) async throws -> PreparedBenchmarkAudio {
        let prepared = try await AudioFileImportController.prepareAudioForImport(sourceURL: recording.sourceURL)
        var cleanupURLs = [prepared.wavURL]
        guard startSeconds > 0 || maxSeconds != nil else {
            return PreparedBenchmarkAudio(
                recording: recording,
                wavURL: prepared.wavURL,
                samples: prepared.samples,
                duration: prepared.duration,
                isTruncated: false,
                cleanupURLs: cleanupURLs
            )
        }

        let startSample = min(prepared.samples.count, Int((startSeconds * Double(WavWriter.sampleRate)).rounded()))
        let endSample = maxSeconds.map {
            min(prepared.samples.count, startSample + Int(($0 * Double(WavWriter.sampleRate)).rounded()))
        } ?? prepared.samples.count
        guard startSample < endSample else {
            throw NSError(domain: "ASRModelBenchmark", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Benchmark slice starts beyond audio duration: \(format(startSeconds))s",
            ])
        }
        guard startSample > 0 || endSample < prepared.samples.count else {
            return PreparedBenchmarkAudio(
                recording: recording,
                wavURL: prepared.wavURL,
                samples: prepared.samples,
                duration: prepared.duration,
                isTruncated: false,
                cleanupURLs: cleanupURLs
            )
        }

        let truncatedSamples = Array(prepared.samples[startSample..<endSample])
        let truncatedURL = try WavWriter.writeTemporaryWAV(samples: truncatedSamples, directoryName: "muesli-asr-bench")
        cleanupURLs.append(truncatedURL)
        return PreparedBenchmarkAudio(
            recording: recording,
            wavURL: truncatedURL,
            samples: truncatedSamples,
            duration: Double(truncatedSamples.count) / Double(WavWriter.sampleRate),
            isTruncated: true,
            cleanupURLs: cleanupURLs
        )
    }

    func cleanup() {
        for url in cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private struct BenchmarkRow: Codable {
    let modelID: String
    let modelLabel: String
    let recordingID: Int64?
    let recordingTitle: String
    let sourcePath: String
    let durationSec: Double
    let truncated: Bool
    let status: String
    let loadSec: Double?
    let transcribeSec: Double?
    let totalSec: Double?
    let rtf: Double?
    let speedX: Double?
    let rssMB: Double
    let diskMB: Double?
    let outputChars: Int?
    let outputWords: Int?
    let wer: Double?
    let cer: Double?
    let notes: String?
    let outputText: String?
    let referenceText: String?

    var markdownLine: String {
        "| \(modelID) | \(recordingID.map(String.init) ?? "-") | \(status) | \(format(durationSec)) | \(format(totalSec)) | \(format(rtf)) | \(format(speedX)) | \(format(wer)) | \(format(cer)) | \(format(rssMB)) | \(notes ?? "") |"
    }
}

private func runCandidate(
    _ candidate: BenchmarkCandidate,
    prepared: PreparedBenchmarkAudio,
    config: BenchmarkConfig
) async -> BenchmarkRow {
    let totalStart = now()
    do {
        let diskMB = diskFootprintMB(candidate: candidate, config: config)
        var notes: [String] = []
        let result: CandidateRunResult
        switch candidate {
        case .production(_, let option):
            if !config.allowDownloads, !isBenchmarkModelAvailable(option) {
                return BenchmarkRow.skipped(
                    candidate: candidate,
                    prepared: prepared,
                    diskMB: diskMB,
                    reason: "model not downloaded"
                )
            }
            if candidate.id == "gigaam-coreml" {
                notes.append(gigaAMChunkingNote(sampleCount: prepared.samples.count, sampleRate: Int(WavWriter.sampleRate)))
            }
            result = try await runProduction(option: option, prepared: prepared, config: config)
        }
        if let resultNote = result.notes {
            notes.append(resultNote)
        }
        if prepared.isTruncated {
            if prepared.recording.referenceText == nil {
                notes.append("quality skipped: sliced audio without timed reference")
            } else {
                notes.append("quality reference: stored transcript window")
            }
        }

        let totalSec = now() - totalStart
        let reference = prepared.recording.referenceText
        let accuracy = reference.map { referenceText in
            TextDistance.compare(reference: referenceText, hypothesis: result.text)
        }
        let outputWords = TextDistance.words(result.text).count
        return BenchmarkRow(
            modelID: candidate.id,
            modelLabel: candidate.label,
            recordingID: prepared.recording.id,
            recordingTitle: prepared.recording.title,
            sourcePath: prepared.recording.sourceURL.path,
            durationSec: prepared.duration,
            truncated: prepared.isTruncated,
            status: "ok",
            loadSec: result.loadSec,
            transcribeSec: result.transcribeSec,
            totalSec: totalSec,
            rtf: totalSec / max(prepared.duration, 0.000_001),
            speedX: prepared.duration / max(totalSec, 0.000_001),
            rssMB: maxRSSMB(),
            diskMB: diskMB,
            outputChars: result.text.count,
            outputWords: outputWords,
            wer: accuracy?.wer,
            cer: accuracy?.cer,
            notes: notes.isEmpty ? nil : notes.joined(separator: "; "),
            outputText: config.includeText ? result.text : nil,
            referenceText: config.includeText ? reference : nil
        )
    } catch {
        return BenchmarkRow(
            modelID: candidate.id,
            modelLabel: candidate.label,
            recordingID: prepared.recording.id,
            recordingTitle: prepared.recording.title,
            sourcePath: prepared.recording.sourceURL.path,
            durationSec: prepared.duration,
            truncated: prepared.isTruncated,
            status: "error",
            loadSec: nil,
            transcribeSec: nil,
            totalSec: now() - totalStart,
            rtf: nil,
            speedX: nil,
            rssMB: maxRSSMB(),
            diskMB: diskFootprintMB(candidate: candidate, config: config),
            outputChars: nil,
            outputWords: nil,
            wer: nil,
            cer: nil,
            notes: error.localizedDescription,
            outputText: nil,
            referenceText: nil
        )
    }
}

private struct CandidateRunResult {
    let text: String
    let loadSec: Double
    let transcribeSec: Double
    let notes: String?
}

private func runProduction(
    option: BackendOption,
    prepared: PreparedBenchmarkAudio,
    config: BenchmarkConfig
) async throws -> CandidateRunResult {
    let coordinator = TranscriptionCoordinator()
    let loadStart = now()
    try await coordinator.preloadRequired(
        backend: option,
        enablePostProcessor: false,
        includeMeetingHelpers: false
    )
    let loadSec = now() - loadStart
    let transcribeStart = now()
    let result = try await coordinator.transcribeMeeting(
        at: prepared.wavURL,
        samples: prepared.samples,
        backend: option,
        cohereLanguage: config.cohereLanguage
    )
    let transcribeSec = now() - transcribeStart
    await coordinator.shutdown()
    return CandidateRunResult(text: result.text, loadSec: loadSec, transcribeSec: transcribeSec, notes: nil)
}

private func gigaAMChunkingNote(sampleCount: Int, sampleRate: Int) -> String {
    let windows = GigaAMV3FileChunking.windows(sampleCount: sampleCount, sampleRate: sampleRate)
    let maxWindowSeconds = windows
        .map { Double($0.count) / Double(sampleRate) }
        .max() ?? 0
    return "gigaam windows=\(windows.count) maxWindow=\(format(maxWindowSeconds))s overlap=\(format(GigaAMV3FileChunking.overlapSeconds))s"
}

private struct TextDistance {
    static func compare(reference: String, hypothesis: String) -> (wer: Double, cer: Double) {
        let referenceWords = words(reference)
        let hypothesisWords = words(hypothesis)
        let referenceChars = chars(reference)
        let hypothesisChars = chars(hypothesis)
        return (
            wer: Double(distance(referenceWords, hypothesisWords)) / Double(max(referenceWords.count, 1)),
            cer: Double(distance(referenceChars, hypothesisChars)) / Double(max(referenceChars.count, 1))
        )
    }

    static func words(_ text: String) -> [String] {
        normalize(text)
            .split(separator: " ")
            .map(String.init)
    }

    private static func chars(_ text: String) -> [Character] {
        Array(normalize(text).filter { !$0.isWhitespace })
    }

    private static func normalize(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return " "
            }
            return " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    private static func distance<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}

private final class BenchmarkOutput {
    private let outputURL: URL
    private let reportURL: URL
    private let encoder = JSONEncoder()

    init(outputURL: URL, reportURL: URL) {
        self.outputURL = outputURL
        self.reportURL = reportURL
        encoder.outputFormatting = [.sortedKeys]
    }

    func reset() throws {
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: reportURL)
    }

    func writeHeader(config: BenchmarkConfig, recordings: [BenchmarkRecording]) throws {
        struct Header: Encodable {
            let type: String
            let generatedAt: String
            let databasePath: String
            let startSeconds: Double
            let maxSeconds: Double?
            let models: [String]
            let recordings: [String]
        }
        let header = Header(
            type: "header",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            databasePath: config.databaseURL.path,
            startSeconds: config.startSeconds,
            maxSeconds: config.maxSeconds,
            models: config.candidates().map(\.id),
            recordings: recordings.map { recording in
                if let id = recording.id {
                    return "\(id):\(recording.title)"
                }
                return recording.title
            }
        )
        try appendJSON(header)
    }

    func append(_ row: BenchmarkRow) throws {
        try appendJSON(row)
    }

    func writeReport(rows: [BenchmarkRow]) throws {
        var report = """
        # ASR Model Benchmark

        | model | meeting | status | audio s | total s | RTF | speed x | WER | CER | RSS MB | notes |
        | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
        """
        for row in rows {
            report += "\n\(row.markdownLine)"
        }
        report += "\n\nJSONL: \(outputURL.path)\n"
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
    }

    private func appendJSON<T: Encodable>(_ value: T) throws {
        var data = try encoder.encode(value)
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: outputURL)
        }
    }
}

private extension BenchmarkRow {
    static func skipped(
        candidate: BenchmarkCandidate,
        prepared: PreparedBenchmarkAudio,
        diskMB: Double?,
        reason: String
    ) -> BenchmarkRow {
        BenchmarkRow(
            modelID: candidate.id,
            modelLabel: candidate.label,
            recordingID: prepared.recording.id,
            recordingTitle: prepared.recording.title,
            sourcePath: prepared.recording.sourceURL.path,
            durationSec: prepared.duration,
            truncated: prepared.isTruncated,
            status: "skipped",
            loadSec: nil,
            transcribeSec: nil,
            totalSec: nil,
            rtf: nil,
            speedX: nil,
            rssMB: maxRSSMB(),
            diskMB: diskMB,
            outputChars: nil,
            outputWords: nil,
            wer: nil,
            cer: nil,
            notes: reason,
            outputText: nil,
            referenceText: nil
        )
    }

    static func inputError(candidate: BenchmarkCandidate, recording: BenchmarkRecording, error: Error) -> BenchmarkRow {
        BenchmarkRow(
            modelID: candidate.id,
            modelLabel: candidate.label,
            recordingID: recording.id,
            recordingTitle: recording.title,
            sourcePath: recording.sourceURL.path,
            durationSec: recording.storedDuration ?? 0,
            truncated: false,
            status: "input-error",
            loadSec: nil,
            transcribeSec: nil,
            totalSec: nil,
            rtf: nil,
            speedX: nil,
            rssMB: maxRSSMB(),
            diskMB: nil,
            outputChars: nil,
            outputWords: nil,
            wer: nil,
            cer: nil,
            notes: error.localizedDescription,
            outputText: nil,
            referenceText: nil
        )
    }
}

private extension Array where Element == BenchmarkCandidate {
    func uniqued() -> [BenchmarkCandidate] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

private extension Array where Element == URL {
    func uniquedByPath() -> [URL] {
        var seen = Set<String>()
        return filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

private func diskFootprintMB(candidate: BenchmarkCandidate, config: BenchmarkConfig) -> Double? {
    let url: URL?
    switch candidate {
    case .production(_, let option):
        url = diskURL(for: option)
    }
    guard let url else { return nil }
    return directorySize(url) / 1_000_000
}

private func diskURL(for option: BackendOption) -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    switch option {
    case .gigaAMV3Russian:
        return GigaAMV3ModelStore.cacheDirectory()
    case .parakeetMultilingual:
        return fluidAudioModelDirectory(version: "v3")
    case .parakeetEnglish:
        return fluidAudioModelDirectory(version: "v2")
    case .senseVoiceSmall:
        return SenseVoiceTranscriber.cacheDirectory()
    case .whisperTinyEnglish, .whisperSmall, .whisperMedium, .whisperLargeTurbo:
        return home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(option.model)")
    default:
        return nil
    }
}

private func isBenchmarkModelAvailable(_ option: BackendOption) -> Bool {
    switch option {
    case .parakeetMultilingual:
        return fluidAudioModelDirectory(version: "v3").map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    case .parakeetEnglish:
        return fluidAudioModelDirectory(version: "v2").map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    default:
        return option.isDownloaded
    }
}

private func fluidAudioModelDirectory(version: String) -> URL? {
    let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    let candidates = [
        supportDir.appendingPathComponent("parakeet-tdt-0.6b-\(version)", isDirectory: true),
        supportDir.appendingPathComponent("parakeet-tdt-0.6b-\(version)-coreml", isDirectory: true),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates.first
}

private func directorySize(_ url: URL) -> Double {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }
    var total = 0
    for case let fileURL as URL in enumerator {
        let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        total += values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
    }
    return Double(total)
}

private extension String {
    var expandedPath: String {
        (self as NSString).expandingTildeInPath
    }
}

private func now() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}

private func format(_ value: Double?) -> String {
    guard let value else { return "-" }
    return String(format: "%.3f", value)
}

private func maxRSSMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1024.0 / 1024.0
}
