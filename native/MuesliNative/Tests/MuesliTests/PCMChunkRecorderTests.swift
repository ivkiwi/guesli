import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("PCMChunkRecorder")
struct PCMChunkRecorderTests {

    @Test("rotateFile finalizes the current chunk and starts a new one")
    func rotatesChunks() throws {
        let recorder = try PCMChunkRecorder(directoryName: "pcm-chunk-recorder-tests")
        recorder.append([100, 200, 300])

        let firstChunkURL = try #require(recorder.rotateFile())
        recorder.append([400, 500])
        let secondChunkURL = try #require(recorder.stop())

        #expect(try readMonoPCM16WAVSamples(from: firstChunkURL) == [100, 200, 300])
        #expect(try readMonoPCM16WAVSamples(from: secondChunkURL) == [400, 500])
    }

    @Test("rotateFile carries overlap bytes across multiple rotations")
    func rotateFileCarriesOverlapAcrossMultipleRotations() throws {
        let recorder = try PCMChunkRecorder(
            directoryName: "pcm-chunk-recorder-tests",
            overlapSampleCount: 3
        )
        recorder.append([1, 2, 3, 4, 5])
        let firstChunkURL = try #require(recorder.rotateFile())
        recorder.append([6, 7, 8, 9])
        let secondChunkURL = try #require(recorder.rotateFile())
        recorder.append([10])
        let finalChunkURL = try #require(recorder.stop())

        let firstBytes = try readPCMBytes(from: firstChunkURL)
        let secondBytes = try readPCMBytes(from: secondChunkURL)
        let finalBytes = try readPCMBytes(from: finalChunkURL)
        let overlapBytes = 3 * MemoryLayout<Int16>.size

        #expect(try readMonoPCM16WAVSamples(from: firstChunkURL) == [1, 2, 3, 4, 5])
        #expect(try readMonoPCM16WAVSamples(from: secondChunkURL) == [3, 4, 5, 6, 7, 8, 9])
        #expect(try readMonoPCM16WAVSamples(from: finalChunkURL) == [7, 8, 9, 10])
        #expect(Array(firstBytes.suffix(overlapBytes)) == Array(secondBytes.prefix(overlapBytes)))
        #expect(Array(secondBytes.suffix(overlapBytes)) == Array(finalBytes.prefix(overlapBytes)))
    }

    @Test("overlap preserves short trailing fresh chunks")
    func overlapPreservesShortTrailingFreshChunks() throws {
        let recorder = try PCMChunkRecorder(
            directoryName: "pcm-chunk-recorder-tests",
            overlapSampleCount: 2
        )
        recorder.append([100, 200, 300])
        _ = try #require(recorder.rotateFile())
        recorder.append([400])

        let finalChunkURL = try #require(recorder.stop())

        #expect(try readMonoPCM16WAVSamples(from: finalChunkURL) == [200, 300, 400])
    }

    @Test("carryover-only chunks are dropped")
    func carryoverOnlyChunksAreDropped() throws {
        let recorder = try PCMChunkRecorder(
            directoryName: "pcm-chunk-recorder-tests",
            overlapSampleCount: 2
        )
        recorder.append([100, 200, 300])
        _ = try #require(recorder.rotateFile())

        #expect(recorder.stop() == nil)
    }

    @Test("cancel removes the in-progress chunk file")
    func cancelRemovesTempFile() throws {
        let recorder = try PCMChunkRecorder(directoryName: "pcm-chunk-recorder-tests")
        recorder.append([100, 200, 300])

        recorder.cancel()
        #expect(recorder.stop() == nil)
    }

    private func readMonoPCM16WAVSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        let sampleBytes = data.subdata(in: 44..<data.count)
        return sampleBytes.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self)).map(Int16.init(littleEndian:))
        }
    }

    private func readPCMBytes(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        return data.subdata(in: 44..<data.count)
    }
}
