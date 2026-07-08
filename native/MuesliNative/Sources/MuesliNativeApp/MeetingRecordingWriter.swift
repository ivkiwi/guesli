import Foundation
import os

final class MeetingRecordingWriter {
    static let minimumRecoverableDuration: TimeInterval = 1
    private static let sampleRate = 16_000
    private static let bytesPerSample = MemoryLayout<Int16>.size
    private static let filePrefix = "live-meeting"

    private struct State {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten: Int = 0
        var pendingMic: [Int16] = []
        var pendingSystem: [Int16] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(meetingID: Int64? = nil) throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(AppTemporaryDirectories.meetingRecordings, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let stem: String
        if let meetingID {
            stem = "\(Self.filePrefix)-\(meetingID)-\(UUID().uuidString)"
        } else {
            stem = UUID().uuidString
        }
        let fileURL = tempDirectory.appendingPathComponent(stem).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw NSError(
                domain: "MeetingRecordingWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open retained meeting recording file for writing."]
            )
        }
        fileHandle.write(Self.wavHeader(dataSize: 0))
        lock.withLock {
            $0 = State(fileHandle: fileHandle, fileURL: fileURL)
        }
    }

    func appendMic(_ samples: [Int16]) {
        append(samples, toMic: true)
    }

    func appendSystem(_ samples: [Int16]) {
        append(samples, toMic: false)
    }

    func stop() -> URL? {
        lock.withLock { state in
            writeMixedSamples(state: &state, flushAll: true)
            guard let fileHandle = state.fileHandle, let fileURL = state.fileURL else { return nil }

            fileHandle.seek(toFileOffset: 0)
            fileHandle.write(Self.wavHeader(dataSize: UInt32(state.bytesWritten)))
            fileHandle.closeFile()

            let outputURL = fileURL
            let bytesWritten = state.bytesWritten
            state = State()
            if bytesWritten == 0 {
                try? FileManager.default.removeItem(at: outputURL)
                return nil
            }
            return outputURL
        }
    }

    func markPauseBoundary() {
        lock.withLock { state in
            writeMixedSamples(state: &state, flushAll: true)
        }
    }

    func cancel() {
        let tempURL = lock.withLock { state -> URL? in
            state.fileHandle?.closeFile()
            let fileURL = state.fileURL
            state = State()
            return fileURL
        }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    static func persistTemporaryRecording(
        from tempURL: URL,
        meetingTitle: String,
        startedAt: Date,
        supportDirectory: URL,
        fileFormat: MeetingRecordingFileFormat = .m4a
    ) throws -> URL {
        try MeetingRecordingStorage.persistTemporaryRecording(
            from: tempURL,
            meetingTitle: meetingTitle,
            startedAt: startedAt,
            destinationDirectory: MeetingRecordingStorage.defaultDirectory(supportDirectory: supportDirectory),
            fileFormat: fileFormat
        )
    }

    static func recoveryCandidates(
        forMeetingID meetingID: Int64?,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [URL] {
        let directory = temporaryDirectory.appendingPathComponent(
            AppTemporaryDirectories.meetingRecordings,
            isDirectory: true
        )
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let prefix = meetingID.map { "\(filePrefix)-\($0)-" }
        return entries
            .filter { url in
                guard url.pathExtension.lowercased() == "wav" else { return false }
                guard let prefix else { return true }
                return url.deletingPathExtension().lastPathComponent.hasPrefix(prefix)
            }
            .sorted { lhs, rhs in
                modificationDate(lhs) > modificationDate(rhs)
            }
    }

    @discardableResult
    static func finalizePartialRecordingIfNonTrivial(at url: URL) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let dataSize = max(fileSize - 44, 0)
        guard Double(dataSize) / Double(sampleRate * bytesPerSample) > minimumRecoverableDuration else {
            return false
        }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        handle.write(wavHeader(dataSize: UInt32(dataSize)))
        return true
    }

#if DEBUG
    func partialURLForTesting() -> URL? {
        lock.withLock { $0.fileURL }
    }

    func closeWithoutFinalizingForTesting() {
        lock.withLock { state in
            state.fileHandle?.closeFile()
            state.fileHandle = nil
        }
    }
#endif

    private func append(_ samples: [Int16], toMic: Bool) {
        guard !samples.isEmpty else { return }
        lock.withLock { state in
            if toMic {
                state.pendingMic.append(contentsOf: samples)
            } else {
                state.pendingSystem.append(contentsOf: samples)
            }
            writeMixedSamples(state: &state, flushAll: false)
        }
    }

    private func writeMixedSamples(state: inout State, flushAll: Bool) {
        let availableCount = flushAll
            ? max(state.pendingMic.count, state.pendingSystem.count)
            : min(state.pendingMic.count, state.pendingSystem.count)
        guard availableCount > 0 else { return }

        let mixedSamples = Self.mix(
            mic: Array(state.pendingMic.prefix(availableCount)),
            system: Array(state.pendingSystem.prefix(availableCount))
        )
        state.pendingMic.removeFirst(min(availableCount, state.pendingMic.count))
        state.pendingSystem.removeFirst(min(availableCount, state.pendingSystem.count))

        let pcmData = mixedSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        state.fileHandle?.write(pcmData)
        state.bytesWritten += pcmData.count
    }

    private static func mix(mic: [Int16], system: [Int16]) -> [Int16] {
        let maxCount = max(mic.count, system.count)
        var output = [Int16]()
        output.reserveCapacity(maxCount)

        for index in 0..<maxCount {
            let hasMic = index < mic.count
            let hasSystem = index < system.count
            let micValue = hasMic ? Int(mic[index]) : 0
            let systemValue = hasSystem ? Int(system[index]) : 0
            let contributors = (hasMic ? 1 : 0) + (hasSystem ? 1 : 0)
            let averaged = contributors == 0 ? 0 : (micValue + systemValue) / contributors
            output.append(Int16(clamping: averaged))
        }

        return output
    }

    private static func wavHeader(dataSize: UInt32) -> Data {
        let sampleRate: UInt32 = UInt32(Self.sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
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

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

struct MeetingSourceTrackRecording: Sendable {
    let micURL: URL?
    let systemURL: URL?
    let micStartOffset: TimeInterval
    let systemStartOffset: TimeInterval
}

struct MeetingSourceTrackRecoveryCandidate: Sendable {
    let stem: String
    let micURL: URL?
    let systemURL: URL?
}

final class MeetingDualTrackRecordingWriter {
    static let minimumRecoverableDuration: TimeInterval = 1
    private static let sampleRate = 16_000
    private static let bytesPerSample = MemoryLayout<Int16>.size
    private static let filePrefix = "post-meeting"

    private struct TrackState {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten = 0
        var firstAppendAt: Date?
    }

    private struct State {
        var startedAt: Date = Date()
        var mic = TrackState()
        var system = TrackState()
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(
        meetingID: Int64? = nil,
        startedAt: Date = Date(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        let tempDirectory = temporaryDirectory
            .appendingPathComponent(AppTemporaryDirectories.meetingRecordings, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let stem: String
        if let meetingID {
            stem = "\(Self.filePrefix)-\(meetingID)-\(UUID().uuidString)"
        } else {
            stem = "\(Self.filePrefix)-\(UUID().uuidString)"
        }
        let mic = try Self.openTrack(
            url: tempDirectory.appendingPathComponent("\(stem)-mic").appendingPathExtension("wav")
        )
        let system = try Self.openTrack(
            url: tempDirectory.appendingPathComponent("\(stem)-system").appendingPathExtension("wav")
        )
        lock.withLock {
            $0 = State(startedAt: startedAt, mic: mic, system: system)
        }
    }

    func appendMic(_ samples: [Int16], now: Date = Date()) {
        append(samples, toMic: true, now: now)
    }

    func appendSystem(_ samples: [Int16], now: Date = Date()) {
        append(samples, toMic: false, now: now)
    }

    func stop() -> MeetingSourceTrackRecording {
        lock.withLock { state in
            let mic = Self.finalize(track: &state.mic)
            let system = Self.finalize(track: &state.system)
            let recording = MeetingSourceTrackRecording(
                micURL: mic.url,
                systemURL: system.url,
                micStartOffset: mic.firstAppendAt?.timeIntervalSince(state.startedAt) ?? 0,
                systemStartOffset: system.firstAppendAt?.timeIntervalSince(state.startedAt) ?? 0
            )
            state = State()
            return recording
        }
    }

    func cancel() {
        let urls = lock.withLock { state -> [URL] in
            state.mic.fileHandle?.closeFile()
            state.system.fileHandle?.closeFile()
            let urls = [state.mic.fileURL, state.system.fileURL].compactMap { $0 }
            state = State()
            return urls
        }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func recoveryCandidates(
        forMeetingID meetingID: Int64?,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [MeetingSourceTrackRecoveryCandidate] {
        let directory = temporaryDirectory.appendingPathComponent(
            AppTemporaryDirectories.meetingRecordings,
            isDirectory: true
        )
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let prefix = meetingID.map { "\(filePrefix)-\($0)-" }
        var grouped: [String: (mic: URL?, system: URL?)] = [:]
        for url in entries where url.pathExtension.lowercased() == "wav" {
            let name = url.deletingPathExtension().lastPathComponent
            guard prefix.map({ name.hasPrefix($0) }) ?? name.hasPrefix(filePrefix + "-") else { continue }
            if name.hasSuffix("-mic") {
                let stem = String(name.dropLast(4))
                grouped[stem, default: (nil, nil)].mic = url
            } else if name.hasSuffix("-system") {
                let stem = String(name.dropLast(7))
                grouped[stem, default: (nil, nil)].system = url
            }
        }
        return grouped.map { stem, urls in
            MeetingSourceTrackRecoveryCandidate(stem: stem, micURL: urls.mic, systemURL: urls.system)
        }.sorted { lhs, rhs in
            modificationDate(lhs.micURL ?? lhs.systemURL) > modificationDate(rhs.micURL ?? rhs.systemURL)
        }
    }

    static func finalizePartialTracksIfNonTrivial(
        _ candidate: MeetingSourceTrackRecoveryCandidate
    ) throws -> MeetingSourceTrackRecording? {
        let micURL = try finalizePartialTrackIfNonTrivial(candidate.micURL)
        let systemURL = try finalizePartialTrackIfNonTrivial(candidate.systemURL)
        guard micURL != nil || systemURL != nil else { return nil }
        return MeetingSourceTrackRecording(
            micURL: micURL,
            systemURL: systemURL,
            micStartOffset: 0,
            systemStartOffset: 0
        )
    }

    static func writeMixedTemporaryWAV(from recording: MeetingSourceTrackRecording) throws -> URL? {
        try writeMixedTemporaryWAV(
            micURL: recording.micURL,
            micStartOffset: recording.micStartOffset,
            systemURL: recording.systemURL,
            systemStartOffset: recording.systemStartOffset
        )
    }

    static func writeMixedTemporaryWAV(
        micURL: URL?,
        micStartOffset: TimeInterval,
        systemURL: URL?,
        systemStartOffset: TimeInterval
    ) throws -> URL? {
        let mic = try readTrack(micURL)
        let system = try readTrack(systemURL)
        guard mic != nil || system != nil else { return nil }

        let micStart = max(0, Int((micStartOffset * Double(sampleRate)).rounded()))
        let systemStart = max(0, Int((systemStartOffset * Double(sampleRate)).rounded()))
        let totalCount = max(
            micStart + (mic?.samples.count ?? 0),
            systemStart + (system?.samples.count ?? 0)
        )
        guard totalCount > 0 else { return nil }

        var output = [Float](repeating: 0, count: totalCount)
        add(mic?.samples, to: &output, startIndex: micStart)
        add(system?.samples, to: &output, startIndex: systemStart)
        return try WavWriter.writeTemporaryWAV(
            samples: output.map { max(-1, min(1, $0)) },
            directoryName: AppTemporaryDirectories.meetingRecordings
        )
    }

#if DEBUG
    func partialURLsForTesting() -> (mic: URL?, system: URL?) {
        lock.withLock { ($0.mic.fileURL, $0.system.fileURL) }
    }

    func closeWithoutFinalizingForTesting() {
        lock.withLock { state in
            state.mic.fileHandle?.closeFile()
            state.mic.fileHandle = nil
            state.system.fileHandle?.closeFile()
            state.system.fileHandle = nil
        }
    }
#endif

    private func append(_ samples: [Int16], toMic: Bool, now: Date) {
        guard !samples.isEmpty else { return }
        lock.withLock { state in
            if toMic {
                Self.write(samples, to: &state.mic, now: now)
            } else {
                Self.write(samples, to: &state.system, now: now)
            }
        }
    }

    private static func openTrack(url: URL) throws -> TrackState {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: url.path) else {
            throw NSError(
                domain: "MeetingDualTrackRecordingWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open post-meeting source track for writing."]
            )
        }
        fileHandle.write(WavWriter.header(dataSize: 0))
        return TrackState(fileHandle: fileHandle, fileURL: url)
    }

    private static func write(_ samples: [Int16], to track: inout TrackState, now: Date) {
        track.firstAppendAt = track.firstAppendAt ?? now
        let pcmData = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        track.fileHandle?.write(pcmData)
        track.bytesWritten += pcmData.count
    }

    private static func finalize(track: inout TrackState) -> (url: URL?, firstAppendAt: Date?) {
        guard let fileHandle = track.fileHandle, let fileURL = track.fileURL else { return (nil, nil) }
        fileHandle.seek(toFileOffset: 0)
        fileHandle.write(WavWriter.header(dataSize: track.bytesWritten))
        fileHandle.closeFile()

        let bytesWritten = track.bytesWritten
        let firstAppendAt = track.firstAppendAt
        track = TrackState()
        guard bytesWritten > 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            return (nil, firstAppendAt)
        }
        return (fileURL, firstAppendAt)
    }

    private static func finalizePartialTrackIfNonTrivial(_ url: URL?) throws -> URL? {
        guard let url else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let dataSize = max(fileSize - 44, 0)
        guard Double(dataSize) / Double(sampleRate * bytesPerSample) > minimumRecoverableDuration else {
            return nil
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        handle.write(WavWriter.header(dataSize: dataSize))
        return url
    }

    private static func readTrack(_ url: URL?) throws -> WavReader.WavData? {
        guard let url else { return nil }
        let data = try WavReader.readFloatMonoWAV(from: url)
        guard data.sampleRate == sampleRate else {
            throw NSError(
                domain: "MeetingDualTrackRecordingWriter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected source track sample rate \(data.sampleRate)."]
            )
        }
        return data
    }

    private static func add(_ samples: [Float]?, to output: inout [Float], startIndex: Int) {
        guard let samples else { return }
        for (offset, sample) in samples.enumerated() {
            let index = startIndex + offset
            guard index < output.count else { break }
            output[index] += sample
        }
    }

    private static func modificationDate(_ url: URL?) -> Date {
        guard let url else { return .distantPast }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
