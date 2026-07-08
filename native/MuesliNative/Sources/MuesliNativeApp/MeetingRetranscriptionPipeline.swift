import FluidAudio
import Foundation

enum MeetingRetranscriptionPipeline {
    enum TrackRole: Sendable {
        case mic
        case system
    }

    struct AudioSegment: Equatable, Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let startSample: Int
        let endSample: Int
    }

    struct SegmentAudio: Sendable {
        let segment: AudioSegment
        let samples: [Float]
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
        trackRole: TrackRole = .system,
        transcribeSegment: (AudioSegment, [Float]) async throws -> SpeechTranscriptionResult
    ) async throws -> SpeechTranscriptionResult {
        try await transcribeSegmentedAudio(
            samples: samples,
            vadSegments: vadSegments,
            trackRole: trackRole
        ) { segmentAudio in
            var results: [SpeechTranscriptionResult] = []
            results.reserveCapacity(segmentAudio.count)
            for item in segmentAudio {
                results.append(try await transcribeSegment(item.segment, item.samples))
            }
            return results
        }
    }

    static func transcribeSegmentedAudio(
        samples: [Float],
        vadSegments: [VadSegment],
        trackRole: TrackRole = .system,
        transcribeSegments: ([SegmentAudio]) async throws -> [SpeechTranscriptionResult]
    ) async throws -> SpeechTranscriptionResult {
        let segmentAudio = audioSegments(from: vadSegments, sampleCount: samples.count).map { segment in
            SegmentAudio(
                segment: segment,
                samples: Array(samples[segment.startSample..<segment.endSample])
            )
        }
        let results = try await transcribeSegments(segmentAudio)
        guard results.count == segmentAudio.count else {
            throw NSError(domain: "MeetingRetranscriptionPipeline", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Retranscription batch returned \(results.count) results for \(segmentAudio.count) segments.",
            ])
        }
        var transcriptSegments: [SpeechSegment] = []
        for (item, result) in zip(segmentAudio, results) {
            transcriptSegments.append(contentsOf: normalize(
                result: result,
                trackRole: trackRole,
                startTime: item.segment.startTime,
                endTime: item.segment.endTime
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

    static func applyTrackOffset(
        _ segments: [SpeechSegment],
        offset: TimeInterval
    ) -> [SpeechSegment] {
        guard offset != 0 else { return segments }
        return segments.map {
            SpeechSegment(
                start: $0.start + offset,
                end: $0.end + offset,
                text: $0.text
            )
        }
    }

    static func applyDiarizationOffset(
        _ segments: [TimedSpeakerSegment]?,
        offset: TimeInterval
    ) -> [TimedSpeakerSegment]? {
        guard let segments else { return nil }
        guard offset != 0 else { return segments }
        let floatOffset = Float(offset)
        return segments.map {
            TimedSpeakerSegment(
                speakerId: $0.speakerId,
                embedding: $0.embedding,
                startTimeSeconds: $0.startTimeSeconds + floatOffset,
                endTimeSeconds: $0.endTimeSeconds + floatOffset,
                qualityScore: $0.qualityScore
            )
        }
    }

    static func postModeOrderedSegments(
        micSegments: [SpeechSegment],
        micStartOffset: TimeInterval,
        systemSegments: [SpeechSegment],
        systemStartOffset: TimeInterval
    ) -> [SpeechSegment] {
        (
            applyTrackOffset(micSegments, offset: micStartOffset)
                + applyTrackOffset(systemSegments, offset: systemStartOffset)
        ).sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
    }

    private static func normalize(
        result: SpeechTranscriptionResult,
        trackRole: TrackRole,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [SpeechSegment] {
        switch trackRole {
        case .mic:
            return MicTurnNormalizer.normalize(
                result: result,
                startTime: startTime,
                endTime: endTime
            )
        case .system:
            return SystemTurnNormalizer.normalize(
                result: result,
                startTime: startTime,
                endTime: endTime
            )
        }
    }
}
