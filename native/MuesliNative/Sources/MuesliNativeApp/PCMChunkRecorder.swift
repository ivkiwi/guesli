import Foundation
import os

final class PCMChunkRecorder {
    private struct State {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten = 0
        var freshBytesWritten = 0
        var tailSamples: [Int16] = []
    }

    private let directoryName: String
    private let overlapSampleCount: Int
    private let lock = OSAllocatedUnfairLock(initialState: State())

    init(directoryName: String, overlapSampleCount: Int = 0) throws {
        self.directoryName = directoryName
        self.overlapSampleCount = max(0, overlapSampleCount)
        let initialState = try createFileState(carryoverSamples: [])
        lock.withLock {
            $0 = initialState
        }
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let pcmData = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.withLock { state in
            state.fileHandle?.write(pcmData)
            state.bytesWritten += pcmData.count
            state.freshBytesWritten += pcmData.count
            guard overlapSampleCount > 0 else { return }
            state.tailSamples = Array((state.tailSamples + samples).suffix(overlapSampleCount))
        }
    }

    func rotateFile() -> URL? {
        let completedState = lock.withLock { state -> State? in
            let oldState = state
            do {
                state = try createFileState(carryoverSamples: oldState.tailSamples)
                return oldState
            } catch {
                fputs("[pcm-chunk-recorder] failed to rotate file: \(error)\n", stderr)
                return nil
            }
        }

        guard let completedState else { return nil }
        return finalizeFile(completedState)
    }

    func stop() -> URL? {
        let finalState = lock.withLock { state -> State in
            let completedState = state
            state = State()
            return completedState
        }
        return finalizeFile(finalState)
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

    private func createFileState(carryoverSamples: [Int16]) throws -> State {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw NSError(
                domain: "PCMChunkRecorder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not open chunk recorder file for writing."]
            )
        }
        fileHandle.write(WavWriter.header(dataSize: 0))
        if !carryoverSamples.isEmpty {
            let carryoverData = carryoverSamples.withUnsafeBufferPointer { Data(buffer: $0) }
            fileHandle.write(carryoverData)
        }
        return State(
            fileHandle: fileHandle,
            fileURL: fileURL,
            bytesWritten: carryoverSamples.count * MemoryLayout<Int16>.size,
            freshBytesWritten: 0,
            tailSamples: carryoverSamples
        )
    }

    private func finalizeFile(_ state: State) -> URL? {
        guard let fileHandle = state.fileHandle, let fileURL = state.fileURL else { return nil }

        fileHandle.seek(toFileOffset: 0)
        fileHandle.write(WavWriter.header(dataSize: UInt32(state.bytesWritten)))
        fileHandle.closeFile()

        guard state.freshBytesWritten > 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return fileURL
    }

}
