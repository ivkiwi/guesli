import FluidAudio
import Foundation

enum MeetingRetranscriptionPipeline {
    struct AudioSegment: Equatable, Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let startSample: Int
        let endSample: Int
    }

    static let vadSegmentationConfig = VadSegmentationConfig(
        maxSpeechDuration: 10.0,
        speechPadding: 0.15
    )

    static func audioSegments(
        from vadSegments: [VadSegment],
        sampleCount: Int,
        sampleRate: Int = VadManager.sampleRate
    ) -> [AudioSegment] {
        guard sampleCount > 0, sampleRate > 0 else { return [] }
        return vadSegments.compactMap { segment -> AudioSegment? in
            let startSample = max(0, min(sampleCount, segment.startSample(sampleRate: sampleRate)))
            let endSample = max(startSample, min(sampleCount, segment.endSample(sampleRate: sampleRate)))
            guard endSample > startSample else { return nil }
            return AudioSegment(
                startTime: Double(startSample) / Double(sampleRate),
                endTime: Double(endSample) / Double(sampleRate),
                startSample: startSample,
                endSample: endSample
            )
        }.sorted { lhs, rhs in
            if lhs.startSample == rhs.startSample {
                return lhs.endSample < rhs.endSample
            }
            return lhs.startSample < rhs.startSample
        }
    }

    static func transcribeSegmentedAudio(
        samples: [Float],
        vadSegments: [VadSegment],
        transcribeSegment: (AudioSegment, [Float]) async throws -> SpeechTranscriptionResult
    ) async throws -> SpeechTranscriptionResult {
        var transcriptSegments: [SpeechSegment] = []
        for segment in audioSegments(from: vadSegments, sampleCount: samples.count) {
            let audio = Array(samples[segment.startSample..<segment.endSample])
            let result = try await transcribeSegment(segment, audio)
            transcriptSegments.append(contentsOf: SystemTurnNormalizer.normalize(
                result: result,
                startTime: segment.startTime,
                endTime: segment.endTime
            ))
        }
        let ordered = transcriptSegments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
        let text = ordered
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return SpeechTranscriptionResult(text: text, segments: ordered)
    }
}
