import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("PCMChunkRecorder", .muesliHermeticSupport)
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

    @Test("rotateFile carries configured overlap into the next chunk")
    func rotatesWithOverlapCarryover() throws {
        let recorder = try PCMChunkRecorder(
            directoryName: "pcm-chunk-recorder-tests",
            overlapSampleCount: 2
        )
        recorder.append([100, 200, 300])

        let firstChunkURL = try #require(recorder.rotateFile())
        recorder.append([400, 500])
        let secondChunkURL = try #require(recorder.stop())

        #expect(try readMonoPCM16WAVSamples(from: firstChunkURL) == [100, 200, 300])
        #expect(try readMonoPCM16WAVSamples(from: secondChunkURL) == [200, 300, 400, 500])
    }

    @Test("stop ignores a carryover-only chunk")
    func stopIgnoresCarryoverOnlyChunk() throws {
        let recorder = try PCMChunkRecorder(
            directoryName: "pcm-chunk-recorder-tests",
            overlapSampleCount: 2
        )
        recorder.append([100, 200, 300])

        let firstChunkURL = try #require(recorder.rotateFile())
        #expect(try readMonoPCM16WAVSamples(from: firstChunkURL) == [100, 200, 300])
        #expect(recorder.stop() == nil)
    }

    @Test("GigaAM-sized rotations share exact two second audio tails across multiple chunks")
    func gigaAMSizedRotationsShareExactOverlap() throws {
        let sampleRate = 16_000
        let overlapSamples = 2 * sampleRate
        let recorder = try PCMChunkRecorder(
            directoryName: "pcm-chunk-recorder-tests",
            overlapSampleCount: overlapSamples
        )
        let firstFresh = rampSamples(from: 0, count: 20 * sampleRate)
        let secondFresh = rampSamples(from: firstFresh.count, count: 20 * sampleRate)
        let finalFresh = rampSamples(from: firstFresh.count + secondFresh.count, count: 1_337)

        recorder.append(firstFresh)
        let firstChunkURL = try #require(recorder.rotateFile())
        recorder.append(secondFresh)
        let secondChunkURL = try #require(recorder.rotateFile())
        recorder.append(finalFresh)
        let finalChunkURL = try #require(recorder.stop())

        let firstChunk = try readMonoPCM16WAVSamples(from: firstChunkURL)
        let secondChunk = try readMonoPCM16WAVSamples(from: secondChunkURL)
        let finalChunk = try readMonoPCM16WAVSamples(from: finalChunkURL)

        #expect(firstChunk.count == firstFresh.count)
        #expect(secondChunk.count == overlapSamples + secondFresh.count)
        #expect(finalChunk.count == overlapSamples + finalFresh.count)
        #expect(Array(firstChunk.suffix(overlapSamples)) == Array(secondChunk.prefix(overlapSamples)))
        #expect(Array(secondChunk.suffix(overlapSamples)) == Array(finalChunk.prefix(overlapSamples)))
        #expect(Array(finalChunk.suffix(finalFresh.count)) == finalFresh)
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

    private func rampSamples(from start: Int, count: Int) -> [Int16] {
        (start..<(start + count)).map { Int16(truncatingIfNeeded: $0) }
    }
}
