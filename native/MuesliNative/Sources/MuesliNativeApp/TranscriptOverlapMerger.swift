import Foundation

enum TranscriptOverlapMerger {
    private static let overlapSearchWordLimit = 15
    private static let retainedContextWordLimit = 80

    /// Merge transcripts from overlapping audio chunks by deduplicating shared content.
    /// Uses hash-based trigram matching near the previous tail and next head.
    static func merge(_ transcripts: [String]) -> String {
        guard transcripts.count > 1 else {
            return transcripts.first ?? ""
        }

        var merged = transcripts[0]
        var context = retainedContext(from: merged)
        for transcript in transcripts.dropFirst() {
            let addition = uniqueAddition(previous: context, next: transcript)
            if !addition.isEmpty {
                merged += (merged.isEmpty ? "" : " ") + addition
            }
            context = retainedContextAfterAppending(addition, to: context)
        }

        return merged
    }

    static func uniqueAddition(previous: String, next: String) -> String {
        let prevWords = previous.split(separator: " ").map(String.init)
        let nextWords = next.split(separator: " ").map(String.init)
        guard !prevWords.isEmpty, !nextWords.isEmpty else {
            return next
        }

        let tailSize = min(prevWords.count, overlapSearchWordLimit)
        let tail = prevWords.suffix(tailSize).map(normalizedWord)
        var trigramIndex: [String: Int] = [:]
        if tail.count >= 3 {
            for j in 0...(tail.count - 3) {
                let key = "\(tail[j])|\(tail[j + 1])|\(tail[j + 2])"
                trigramIndex[key] = j
            }
        }

        let headSize = min(nextWords.count, overlapSearchWordLimit)
        let head = nextWords.prefix(headSize).map(normalizedWord)
        var bestAnchorStart = -1
        var bestRunEnd = 0

        if head.count >= 3 {
            for j in 0...(head.count - 3) {
                let key = "\(head[j])|\(head[j + 1])|\(head[j + 2])"
                if let tailPos = trigramIndex[key] {
                    var run = 3
                    var ti = tailPos + 3
                    var hi = j + 3
                    while ti < tail.count && hi < head.count && tail[ti] == head[hi] {
                        run += 1
                        ti += 1
                        hi += 1
                    }
                    if bestAnchorStart < 0 {
                        bestAnchorStart = j
                        bestRunEnd = j + run
                    }
                }
            }
        }

        guard bestAnchorStart >= 0 else {
            let overlap = suffixPrefixOverlap(prevWords, nextWords)
            return nextWords.dropFirst(overlap).joined(separator: " ")
        }

        let preAnchor = nextWords.prefix(bestAnchorStart).joined(separator: " ")
        let postOverlap = nextWords.dropFirst(bestRunEnd).joined(separator: " ")
        return [preAnchor, postOverlap].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func deduplicateSegments(_ segments: [SpeechSegment]) -> [SpeechSegment] {
        guard !segments.isEmpty else { return [] }
        var previousText = ""
        var result: [SpeechSegment] = []

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let addition = uniqueAddition(previous: previousText, next: text)
            guard !addition.isEmpty else { continue }
            previousText = retainedContextAfterAppending(addition, to: previousText)
            result.append(SpeechSegment(start: segment.start, end: segment.end, text: addition))
        }

        return result
    }

    static func retainedContextAfterAppending(_ addition: String, to previous: String) -> String {
        guard !addition.isEmpty else {
            return retainedContext(from: previous)
        }
        return retainedContext(from: [previous, addition].filter { !$0.isEmpty }.joined(separator: " "))
    }

    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func suffixPrefixOverlap(_ left: [String], _ right: [String]) -> Int {
        let limit = min(overlapSearchWordLimit, left.count, right.count)
        guard limit >= 2 else { return 0 }

        for count in stride(from: limit, through: 2, by: -1) {
            let leftSuffix = left.suffix(count).map(normalizedWord)
            let rightPrefix = right.prefix(count).map(normalizedWord)
            if !leftSuffix.contains(""), leftSuffix == rightPrefix {
                return count
            }
        }

        return 0
    }

    private static func retainedContext(from text: String) -> String {
        let words = text.split(separator: " ")
        guard words.count > retainedContextWordLimit else { return text }
        return words.suffix(retainedContextWordLimit).joined(separator: " ")
    }
}
