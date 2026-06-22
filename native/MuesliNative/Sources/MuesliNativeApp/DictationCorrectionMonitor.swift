import AppKit
import ApplicationServices
import Foundation
import os

struct DictationCorrectionTargetApp: Sendable {
    let processID: pid_t
    let appName: String
    let bundleID: String

    var appContext: String {
        "\(appName)|\(bundleID)"
    }

    init?(app: NSRunningApplication?) {
        guard let app else { return nil }
        self.processID = app.processIdentifier
        self.appName = app.localizedName ?? "Unknown"
        self.bundleID = app.bundleIdentifier ?? ""
    }
}

struct DictionaryCorrectionDetector {
    private static let minimumCorrectionSimilarity = 0.64
    private static let maxObservedTokensPerDictionaryWord = 2

    private struct CorrectionCandidate {
        let observed: String
        let replacement: String
    }

    static func suggestion(
        originalText: String,
        editedText: String,
        appContext: String = ""
    ) -> DictionarySuggestion? {
        suggestions(
            originalText: originalText,
            baselineText: originalText,
            currentText: editedText,
            appContext: appContext,
            maxSuggestions: 1
        ).first
    }

    static func suggestions(
        originalText: String,
        editedText: String,
        appContext: String = "",
        maxSuggestions: Int = Int.max
    ) -> [DictionarySuggestion] {
        suggestions(
            originalText: originalText,
            baselineText: originalText,
            currentText: editedText,
            appContext: appContext,
            maxSuggestions: maxSuggestions
        )
    }

    static func suggestion(
        originalText: String,
        baselineText: String,
        currentText: String,
        appContext: String = ""
    ) -> DictionarySuggestion? {
        suggestions(
            originalText: originalText,
            baselineText: baselineText,
            currentText: currentText,
            appContext: appContext,
            maxSuggestions: 1
        ).first
    }

    static func suggestions(
        originalText: String,
        baselineText: String,
        currentText: String,
        appContext: String = "",
        maxSuggestions: Int = Int.max
    ) -> [DictionarySuggestion] {
        guard isDetectionRequestValid(
            originalText: originalText,
            baselineText: baselineText,
            currentText: currentText,
            maxSuggestions: maxSuggestions
        ) else { return [] }

        var results: [DictionarySuggestion] = []
        var seenKeys = Set<String>()

        func append(_ candidate: CorrectionCandidate) {
            guard results.count < maxSuggestions else { return }
            let suggestion = DictionarySuggestion(
                observed: candidate.observed,
                replacement: candidate.replacement,
                appContext: appContext
            )
            guard !seenKeys.contains(suggestion.key) else { return }
            seenKeys.insert(suggestion.key)
            results.append(suggestion)
        }

        for candidate in extractCandidateCorrections(
            originalText: originalText,
            baselineText: baselineText,
            currentText: currentText,
            maxCandidates: maxSuggestions
        ) {
            append(candidate)
        }

        return results
    }

    private static func isDetectionRequestValid(
        originalText: String,
        baselineText: String,
        currentText: String,
        maxSuggestions: Int
    ) -> Bool {
        guard maxSuggestions > 0 else { return false }
        guard !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard baselineText != currentText else { return false }
        return hasSufficientSharedContext(originalText: originalText, editedText: currentText)
    }

    private static func extractCandidateCorrections(
        originalText: String,
        baselineText: String,
        currentText: String,
        maxCandidates: Int
    ) -> [CorrectionCandidate] {
        var candidates: [CorrectionCandidate] = []

        func append(_ candidate: CorrectionCandidate?) {
            guard candidates.count < maxCandidates, let candidate else { return }
            candidates.append(candidate)
        }

        append(fragmentCandidate(
            originalText: originalText,
            baselineText: baselineText,
            currentText: currentText
        ))

        if candidates.count < maxCandidates {
            for candidate in tokenAlignedCandidates(
                originalText: originalText,
                editedText: currentText,
                maxCandidates: maxCandidates - candidates.count
            ) {
                append(candidate)
            }
        }

        return candidates
    }

    private static func fragmentCandidate(
        originalText: String,
        baselineText: String,
        currentText: String
    ) -> CorrectionCandidate? {
        let diff = changedFragments(from: baselineText, to: currentText)
        guard let observed = normalizedCandidate(diff.removed),
              let replacement = normalizedCandidate(diff.inserted)
        else { return nil }

        guard isWordScopedSuggestion(observed: observed, replacement: replacement) else {
            return nil
        }
        guard originalText.range(of: observed, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
            return nil
        }
        guard isLikelyDictionaryCorrection(observed: observed, replacement: replacement) else { return nil }

        return CorrectionCandidate(
            observed: observed,
            replacement: replacement
        )
    }

    private struct WordToken: Equatable {
        let text: String
        let normalized: String
    }

    private static func tokenAlignedCandidates(
        originalText: String,
        editedText: String,
        maxCandidates: Int
    ) -> [CorrectionCandidate] {
        guard maxCandidates > 0 else { return [] }
        let originalTokens = wordTokens(in: originalText)
        let editedTokens = wordTokens(in: editedText)
        guard !originalTokens.isEmpty, !editedTokens.isEmpty else { return [] }
        guard originalTokens.count <= 160, editedTokens.count <= 220 else { return [] }

        let operations = alignmentOperations(from: originalTokens, to: editedTokens)
        var candidates: [CorrectionCandidate] = []
        var seenKeys = Set<String>()

        func append(_ candidate: CorrectionCandidate) {
            guard candidates.count < maxCandidates else { return }
            let key = DictionarySuggestion.key(observed: candidate.observed, replacement: candidate.replacement)
            guard !seenKeys.contains(key) else { return }
            seenKeys.insert(key)
            candidates.append(candidate)
        }

        for run in tokenChangeRuns(in: operations) {
            for candidate in candidatesFromTokenRun(
                fromTokenRun: run,
                originalText: originalText,
                maxCandidates: maxCandidates - candidates.count
            ) {
                append(candidate)
            }
            if candidates.count >= maxCandidates { break }
        }
        return candidates
    }

    private struct TokenChangeRun {
        let observedTokens: [WordToken]
        let replacementTokens: [WordToken]
    }

    private static func tokenChangeRuns(in operations: [AlignmentOperation]) -> [TokenChangeRun] {
        var runs: [TokenChangeRun] = []
        var observedTokens: [WordToken] = []
        var replacementTokens: [WordToken] = []

        func flush() {
            guard !observedTokens.isEmpty, !replacementTokens.isEmpty else {
                observedTokens.removeAll()
                replacementTokens.removeAll()
                return
            }
            runs.append(TokenChangeRun(observedTokens: observedTokens, replacementTokens: replacementTokens))
            observedTokens.removeAll()
            replacementTokens.removeAll()
        }

        for operation in operations {
            switch operation {
            case .match:
                flush()
            case .deletion(let token):
                observedTokens.append(token)
            case .insertion(let token):
                replacementTokens.append(token)
            case .substitution(let observed, let replacement):
                observedTokens.append(observed)
                replacementTokens.append(replacement)
            }
        }
        flush()
        return runs
    }

    private static func candidatesFromTokenRun(
        fromTokenRun run: TokenChangeRun,
        originalText: String,
        maxCandidates: Int
    ) -> [CorrectionCandidate] {
        guard maxCandidates > 0 else { return [] }
        guard run.observedTokens.count <= run.replacementTokens.count * maxObservedTokensPerDictionaryWord else {
            return []
        }
        var results: [CorrectionCandidate] = []
        var observedIndex = 0

        for replacementToken in run.replacementTokens {
            guard results.count < maxCandidates, observedIndex < run.observedTokens.count else { break }

            var bestCandidate: CorrectionCandidate?
            var bestObservedLength = 0
            var bestSimilarity = 0.0
            let maxObservedLength = min(maxObservedTokensPerDictionaryWord, run.observedTokens.count - observedIndex)

            for observedLength in 1...maxObservedLength {
                let observedText = run.observedTokens[observedIndex..<(observedIndex + observedLength)]
                    .map(\.text)
                    .joined(separator: " ")
                guard let observedCandidate = normalizedCandidate(observedText),
                      let replacementCandidate = normalizedCandidate(replacementToken.text),
                      isWordScopedSuggestion(observed: observedCandidate, replacement: replacementCandidate),
                      originalText.range(of: observedCandidate, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                      isLikelyDictionaryCorrection(observed: observedCandidate, replacement: replacementCandidate)
                else { continue }

                let similarity = CustomWordMatcher.jaroWinklerSimilarity(
                    observedCandidate.replacingOccurrences(of: " ", with: "").lowercased(),
                    replacementCandidate.lowercased()
                )
                if similarity > bestSimilarity {
                    bestCandidate = CorrectionCandidate(
                        observed: observedCandidate,
                        replacement: replacementCandidate
                    )
                    bestObservedLength = observedLength
                    bestSimilarity = similarity
                }
            }

            if let bestCandidate {
                results.append(bestCandidate)
                observedIndex += bestObservedLength
            } else {
                observedIndex += 1
            }
        }
        return results
    }

    static func hasSufficientSharedContext(originalText: String, editedText: String) -> Bool {
        let originalTokens = wordTokens(in: originalText).map(\.normalized)
        let editedTokens = wordTokens(in: editedText).map(\.normalized)
        guard !originalTokens.isEmpty, !editedTokens.isEmpty else { return false }

        if originalTokens.count <= 3 {
            return true
        }

        let anchorLength = originalTokens.count == 4 ? 2 : min(4, originalTokens.count - 2)
        guard anchorLength > 0, editedTokens.count >= anchorLength else { return false }

        let editedWindows = Set(windows(in: editedTokens, length: anchorLength))
        return windows(in: originalTokens, length: anchorLength).contains { editedWindows.contains($0) }
    }

    private static func windows(in tokens: [String], length: Int) -> [String] {
        guard length > 0, tokens.count >= length else { return [] }
        return (0...(tokens.count - length)).map { index in
            tokens[index..<(index + length)].joined(separator: "\u{1f}")
        }
    }

    private static func wordTokens(in text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        var current = ""

        func flush() {
            let candidate = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                tokens.append(WordToken(text: candidate, normalized: candidate.lowercased()))
            }
            current = ""
        }

        for character in text {
            if character.isLetter || character.isNumber || character == "-" || character == "_" || character == "/" || character == "+" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    private enum AlignmentOperation {
        case match
        case insertion(WordToken)
        case deletion(WordToken)
        case substitution(observed: WordToken, replacement: WordToken)
    }

    private static func alignmentOperations(from old: [WordToken], to new: [WordToken]) -> [AlignmentOperation] {
        let rows = old.count + 1
        let columns = new.count + 1
        var costs = Array(repeating: Array(repeating: 0, count: columns), count: rows)

        for row in 0..<rows { costs[row][0] = row }
        for column in 0..<columns { costs[0][column] = column }

        for row in 1..<rows {
            for column in 1..<columns {
                let substitutionCost = old[row - 1].text == new[column - 1].text ? 0 : 1
                costs[row][column] = min(
                    costs[row - 1][column] + 1,
                    costs[row][column - 1] + 1,
                    costs[row - 1][column - 1] + substitutionCost
                )
            }
        }

        var row = old.count
        var column = new.count
        var operations: [AlignmentOperation] = []

        while row > 0 || column > 0 {
            if row > 0, column > 0 {
                let substitutionCost = old[row - 1].text == new[column - 1].text ? 0 : 1
                if costs[row][column] == costs[row - 1][column - 1] + substitutionCost {
                    if substitutionCost == 0 {
                        operations.append(.match)
                    } else {
                        operations.append(.substitution(observed: old[row - 1], replacement: new[column - 1]))
                    }
                    row -= 1
                    column -= 1
                    continue
                }
            }
            if row > 0, costs[row][column] == costs[row - 1][column] + 1 {
                operations.append(.deletion(old[row - 1]))
                row -= 1
                continue
            }
            if column > 0 {
                operations.append(.insertion(new[column - 1]))
                column -= 1
            }
        }

        return operations.reversed()
    }

    private static func changedFragments(from oldText: String, to newText: String) -> (removed: String, inserted: String) {
        let old = Array(oldText)
        let new = Array(newText)

        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }

        var oldSuffix = old.count
        var newSuffix = new.count
        while oldSuffix > prefix, newSuffix > prefix, old[oldSuffix - 1] == new[newSuffix - 1] {
            oldSuffix -= 1
            newSuffix -= 1
        }

        while prefix > 0, !isBoundary(old[prefix - 1]), !isBoundary(new[prefix - 1]) {
            prefix -= 1
        }
        while oldSuffix < old.count, !isBoundary(old[oldSuffix]) {
            oldSuffix += 1
        }
        while newSuffix < new.count, !isBoundary(new[newSuffix]) {
            newSuffix += 1
        }

        return (
            String(old[prefix..<oldSuffix]),
            String(new[prefix..<newSuffix])
        )
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation && character != "-" && character != "_" && character != "/" && character != "+"
    }

    private static func normalizedCandidate(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }

        let boundaryPunctuation = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .subtracting(CharacterSet(charactersIn: "_-+/"))
        let cleaned = trimmed.trimmingCharacters(in: boundaryPunctuation)
        guard !cleaned.isEmpty, cleaned.count <= 60 else { return nil }

        let tokens = cleaned.split(whereSeparator: \.isWhitespace)
        guard (1...3).contains(tokens.count) else { return nil }
        guard tokens.allSatisfy({ token in
            token.contains { $0.isLetter || $0.isNumber }
        }) else { return nil }

        return tokens.joined(separator: " ")
    }

    private static func isWordScopedSuggestion(observed: String, replacement: String) -> Bool {
        let observedTokens = observed.split(whereSeparator: \.isWhitespace)
        let replacementTokens = replacement.split(whereSeparator: \.isWhitespace)
        guard replacementTokens.count == 1,
              (1...maxObservedTokensPerDictionaryWord).contains(observedTokens.count)
        else {
            return false
        }
        if observedTokens.count == 1 {
            if isAcronymLike(replacement), observed.lowercased() != replacement.lowercased() {
                return false
            }
            if replacement.contains("-"), !observed.contains("-") {
                return CustomWordMatcher.jaroWinklerSimilarity(
                    observed.lowercased(),
                    replacement.lowercased()
                ) >= 0.82
            }
            return true
        }

        guard !replacement.contains("-"),
              !replacement.contains("_"),
              !replacement.contains("/"),
              !isAcronymLike(replacement)
        else { return false }

        let compactObserved = observedTokens.joined().lowercased()
        let compactReplacement = replacement.lowercased()
        return CustomWordMatcher.jaroWinklerSimilarity(compactObserved, compactReplacement) >= minimumCorrectionSimilarity
    }

    private static func isLikelyDictionaryCorrection(observed: String, replacement: String) -> Bool {
        guard observed != replacement else { return false }
        guard observed.count >= 2, replacement.count >= 2 else { return false }

        let observedTokens = observed.split(whereSeparator: \.isWhitespace).map(String.init)
        let replacementTokens = replacement.split(whereSeparator: \.isWhitespace).map(String.init)

        let normalizedReplacement = replacement.lowercased()
        let normalizedObserved = observed.lowercased()
        let hasFormattingDictionarySignal = hasStrongDictionarySignal(replacement)
            || replacement.contains("-")

        let similarity = CustomWordMatcher.jaroWinklerSimilarity(
            normalizedObserved,
            normalizedReplacement
        )

        if observedTokens.count != replacementTokens.count {
            guard !observedTokens.contains(where: { commonWords.contains($0.lowercased()) }) else { return false }
            let compactObserved = observedTokens.joined().lowercased()
            let compactReplacement = replacementTokens.joined().lowercased()
            let compactSimilarity = CustomWordMatcher.jaroWinklerSimilarity(
                compactObserved,
                compactReplacement
            )
            return compactSimilarity >= 0.82
                || isLikelySingleWordSplitCorrection(
                    replacement: replacement,
                    replacementTokens: replacementTokens,
                    similarity: compactSimilarity
                )
                || isLikelyStrongDictionaryCorrection(
                observed: observed,
                replacement: replacement,
                observedTokens: observedTokens,
                similarity: compactSimilarity
            )
        }

        if commonWords.contains(normalizedObserved) {
            if observed.lowercased() == replacement.lowercased() {
                return hasFormattingDictionarySignal || replacement.contains(where: \.isUppercase)
            }
            return similarity >= 0.82 && hasFormattingDictionarySignal
        }

        if commonWords.contains(normalizedReplacement), !hasFormattingDictionarySignal {
            return false
        }

        if observed.lowercased() == replacement.lowercased() {
            return hasFormattingDictionarySignal || replacement.contains(where: \.isUppercase)
        }

        guard !isCommonWordTruncation(observed: normalizedObserved, replacement: normalizedReplacement) else {
            return false
        }

        return similarity >= minimumCorrectionSimilarity || isLikelyStrongDictionaryCorrection(
            observed: observed,
            replacement: replacement,
            observedTokens: observedTokens,
            similarity: similarity
        )
    }

    private static func hasStrongDictionarySignal(_ value: String) -> Bool {
        hasInternalCapital(value)
            || value.contains(where: \.isNumber)
            || value.contains("_")
            || value.contains("/")
            || isAcronymLike(value)
    }

    private static func isLikelyStrongDictionaryCorrection(
        observed: String,
        replacement: String,
        observedTokens: [String],
        similarity: Double
    ) -> Bool {
        guard hasStrongDictionarySignal(replacement) else { return false }
        if isNumericShorthand(observed: observed, replacement: replacement) {
            return true
        }
        if isAcronymLike(replacement), isAcronymCorrection(observedTokens: observedTokens, replacement: replacement) {
            return true
        }
        if replacement.contains("_") || replacement.contains("/") || hasInternalCapital(replacement) {
            return similarity >= 0.55
        }
        return false
    }

    private static func isLikelySingleWordSplitCorrection(
        replacement: String,
        replacementTokens: [String],
        similarity: Double
    ) -> Bool {
        guard replacementTokens.count == 1,
              !replacement.contains("-"),
              !replacement.contains("_"),
              !replacement.contains("/"),
              !isAcronymLike(replacement),
              !commonWords.contains(replacement.lowercased()),
              similarity >= minimumCorrectionSimilarity
        else { return false }
        return replacement.contains(where: \.isUppercase)
            || !isRecognizedEnglishWord(replacement.lowercased())
    }

    private static func isNumericShorthand(observed: String, replacement: String) -> Bool {
        let observedLetters = observed.lowercased().filter(\.isLetter)
        let replacementCharacters = Array(replacement.lowercased())
        guard observedLetters.count >= 4,
              replacementCharacters.count >= 3,
              let firstObserved = observedLetters.first,
              let lastObserved = observedLetters.last,
              replacementCharacters.first == firstObserved,
              replacementCharacters.last == lastObserved
        else { return false }

        let middleCharacters = replacementCharacters.dropFirst().dropLast()
        guard !middleCharacters.isEmpty,
              middleCharacters.allSatisfy(\.isNumber),
              let omittedCount = Int(String(middleCharacters))
        else { return false }
        return omittedCount == observedLetters.count - 2
    }

    private static func isAcronymCorrection(observedTokens: [String], replacement: String) -> Bool {
        guard observedTokens.count > 1 else { return false }
        let initials = observedTokens.compactMap { $0.first?.lowercased() }.joined()
        let replacementLetters = replacement.lowercased().filter(\.isLetter)
        guard !initials.isEmpty, !replacementLetters.isEmpty else { return false }
        return replacementLetters.hasPrefix(initials)
    }

    private static func isCommonWordTruncation(observed: String, replacement: String) -> Bool {
        guard observed.split(whereSeparator: \.isWhitespace).count == 1,
              replacement.split(whereSeparator: \.isWhitespace).count == 1,
              observed.allSatisfy(\.isLowercase),
              replacement.allSatisfy(\.isLowercase),
              observed != replacement,
              (observed.hasPrefix(replacement) || replacement.hasPrefix(observed)),
              isRecognizedEnglishWord(observed),
              isRecognizedEnglishWord(replacement)
        else { return false }
        return true
    }

    private static func isRecognizedEnglishWord(_ value: String) -> Bool {
        spellCheckerLock.lock()
        defer { spellCheckerLock.unlock() }
        let range = NSSpellChecker.shared.checkSpelling(
            of: value,
            startingAt: 0,
            language: "en",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return range.location == NSNotFound
    }

    private static func hasInternalCapital(_ value: String) -> Bool {
        let scalars = Array(value)
        guard scalars.count > 1 else { return false }
        return scalars.dropFirst().contains(where: \.isUppercase)
    }

    private static func isAcronymLike(_ value: String) -> Bool {
        let letters = value.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        return letters.allSatisfy(\.isUppercase)
    }

    private static let commonWords: Set<String> = [
        "a", "about", "after", "all", "also", "am", "an", "and", "are", "as", "at",
        "be", "because", "but", "by", "can", "could", "did", "do", "does", "for",
        "from", "get", "go", "had", "has", "have", "he", "her", "here", "him", "his",
        "how", "i", "if", "in", "is", "it", "its", "just", "like", "me", "my", "not",
        "now", "of", "on", "or", "our", "out", "she", "so", "that", "the", "their",
        "them", "then", "there", "they", "this", "to", "up", "us", "was", "we", "were",
        "what", "when", "where", "which", "who", "will", "with", "would", "you", "your",
    ]

    private static let spellCheckerLock = NSLock()
}

struct DictationCorrectionSnapshotStabilizer {
    private var snapshotChangedAt: [String: Date] = [:]
    private var evaluatedSnapshots = Set<String>()

    mutating func observe(snapshots: [String], now: Date, quietWindow: TimeInterval) -> [String] {
        let currentSnapshots = Set(snapshots)
        snapshotChangedAt = snapshotChangedAt.filter { currentSnapshots.contains($0.key) }

        for snapshot in snapshots where snapshotChangedAt[snapshot] == nil {
            snapshotChangedAt[snapshot] = now
        }

        var stableSnapshots: [String] = []
        for snapshot in snapshots {
            guard !evaluatedSnapshots.contains(snapshot),
                  let changedAt = snapshotChangedAt[snapshot],
                  now.timeIntervalSince(changedAt) >= quietWindow
            else { continue }
            evaluatedSnapshots.insert(snapshot)
            stableSnapshots.append(snapshot)
        }
        return stableSnapshots
    }
}

@MainActor
final class DictationCorrectionMonitor {
    nonisolated private static let logger = Logger(subsystem: "com.muesli.native", category: "DictionaryCorrection")

    private static let initialPollDelayNanoseconds: UInt64 = 100_000_000
    private static let fastPollIntervalNanoseconds: UInt64 = 150_000_000
    private static let steadyPollIntervalNanoseconds: UInt64 = 1_000_000_000
    private static let fastPollingWindowSeconds: TimeInterval = 10
    private static let monitoringWindowSeconds: TimeInterval = 45
    private static let snapshotQuietWindowSeconds: TimeInterval = 1.5
    nonisolated private static let maxSuggestionsPerSession = 3
    nonisolated private static let maxAccessibilityNodes = 140
    nonisolated private static let maxCandidateCharacters = 2_000

    private var task: Task<Void, Never>?

    func start(
        originalText: String,
        appContext: String,
        targetApp: DictationCorrectionTargetApp?,
        onSuggestion: @escaping @MainActor (DictionarySuggestion, Bool) -> Void
    ) {
        cancel()
        Self.log("start originalCharacters=\(originalText.count) target=\(targetApp?.appContext ?? appContext)")
        guard AXIsProcessTrusted() else {
            Self.log("not-started axTrusted=false")
            return
        }

        task = Task {
            let fastPollingDeadline = Date().addingTimeInterval(Self.fastPollingWindowSeconds)
            let deadline = Date().addingTimeInterval(Self.monitoringWindowSeconds)
            var stabilizer = DictationCorrectionSnapshotStabilizer()
            var pollCount = 0
            var observedSnapshotCount = 0
            var stableSnapshotCount = 0
            var emittedSuggestionCount = 0
            var emittedSuggestionKeys = Set<String>()
            var lastLoggedSnapshotCount: Int?
            try? await Task.sleep(nanoseconds: Self.initialPollDelayNanoseconds)
            while !Task.isCancelled, Date() < deadline {
                pollCount += 1
                let snapshots = await Task.detached(priority: .utility) {
                    Self.detectEditedSnapshots(
                        originalText: originalText,
                        targetApp: targetApp
                    )
                }.value
                if Task.isCancelled { return }
                if !snapshots.isEmpty {
                    observedSnapshotCount += snapshots.count
                    if lastLoggedSnapshotCount != snapshots.count {
                        Self.log("poll=\(pollCount) snapshots=\(snapshots.count)")
                        lastLoggedSnapshotCount = snapshots.count
                    }
                } else {
                    lastLoggedSnapshotCount = nil
                }
                let stableSnapshots = stabilizer.observe(
                    snapshots: snapshots,
                    now: Date(),
                    quietWindow: Self.snapshotQuietWindowSeconds
                )
                if !stableSnapshots.isEmpty {
                    stableSnapshotCount += stableSnapshots.count
                    Self.log("poll=\(pollCount) stableSnapshots=\(stableSnapshots.count)")
                }
                for stableSnapshot in stableSnapshots {
                    let suggestions = await Task.detached(priority: .utility) {
                        Self.suggestions(
                            originalText: originalText,
                            editedSnapshot: stableSnapshot,
                            appContext: appContext,
                            targetApp: targetApp,
                            maxSuggestions: Self.maxSuggestionsPerSession
                        )
                    }.value
                    if Task.isCancelled { return }
                    if suggestions.isEmpty {
                        Self.log("stableSnapshot rejected suggestions=0")
                    }
                    for suggestion in suggestions where !emittedSuggestionKeys.contains(suggestion.key) {
                        let shouldPresentPrompt = emittedSuggestionCount == 0
                        emittedSuggestionKeys.insert(suggestion.key)
                        emittedSuggestionCount += 1
                        Self.log("emit suggestion=\(suggestion.key) presentPrompt=\(shouldPresentPrompt)")
                        await MainActor.run {
                            onSuggestion(suggestion, shouldPresentPrompt)
                        }
                        if emittedSuggestionCount >= Self.maxSuggestionsPerSession {
                            Self.log("complete reason=maxSuggestions count=\(emittedSuggestionCount)")
                            return
                        }
                    }
                }
                let interval = Date() < fastPollingDeadline
                    ? Self.fastPollIntervalNanoseconds
                    : Self.steadyPollIntervalNanoseconds
                try? await Task.sleep(nanoseconds: interval)
            }
            Self.log("complete reason=timeout polls=\(pollCount) snapshots=\(observedSnapshotCount) stableSnapshots=\(stableSnapshotCount) suggestions=\(emittedSuggestionCount)")
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    nonisolated private static func suggestions(
        originalText: String,
        editedSnapshot: String,
        appContext: String,
        targetApp: DictationCorrectionTargetApp?,
        maxSuggestions: Int
    ) -> [DictionarySuggestion] {
        let resolvedAppContext = appContext.isEmpty ? (targetApp?.appContext ?? "") : appContext
        return DictionaryCorrectionDetector.suggestions(
            originalText: originalText,
            editedText: editedSnapshot,
            appContext: resolvedAppContext,
            maxSuggestions: maxSuggestions
        )
    }

    nonisolated private static func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        fputs("[dictionary-monitor] \(message)\n", stderr)
    }

    nonisolated private static func detectEditedSnapshots(
        originalText: String,
        targetApp: DictationCorrectionTargetApp?
    ) -> [String] {
        var seen = Set<String>()
        var snapshots: [String] = []

        func addSnapshot(from value: String?) {
            guard let snapshot = normalizedSnapshot(value, originalText: originalText),
                  !seen.contains(snapshot),
                  DictionaryCorrectionDetector.hasSufficientSharedContext(
                      originalText: originalText,
                      editedText: snapshot
                  )
            else { return }
            seen.insert(snapshot)
            snapshots.append(snapshot)
        }

        var focusedProcessID: pid_t?
        addSnapshot(from: systemFocusedTextSnapshot(
            maxCharacters: maxCandidateCharacters,
            processID: &focusedProcessID
        ))

        if let targetApp {
            collectTextSnapshots(fromProcessID: targetApp.processID, add: addSnapshot(from:))
        }
        return snapshots
    }

    nonisolated private static func normalizedSnapshot(_ value: String?, originalText: String) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= maxCandidateCharacters else { return nil }
        guard normalized != originalText else { return nil }

        let originalLength = originalText.count
        let lengthDelta = abs(normalized.count - originalLength)
        let allowedDelta = max(240, originalLength * 2)
        guard normalized.count >= max(2, originalLength / 2), lengthDelta <= allowedDelta else { return nil }
        return normalized
    }

    nonisolated private static func collectTextSnapshots(
        fromProcessID processID: pid_t,
        add: (String?) -> Void
    ) {
        let axApp = AXUIElementCreateApplication(processID)
        var roots: [AXUIElement] = []

        for attribute in [
            kAXFocusedUIElementAttribute,
            kAXFocusedWindowAttribute,
            kAXMainWindowAttribute,
        ] {
            if let element = axElementAttribute(attribute, from: axApp) {
                roots.append(element)
            }
        }
        roots.append(axApp)

        var remainingNodes = maxAccessibilityNodes
        var visited = Set<String>()
        for root in roots {
            collectTextSnapshots(
                from: root,
                depth: 0,
                remainingNodes: &remainingNodes,
                visited: &visited,
                add: add
            )
            if remainingNodes <= 0 { return }
        }
    }

    nonisolated private static func collectTextSnapshots(
        from element: AXUIElement,
        depth: Int,
        remainingNodes: inout Int,
        visited: inout Set<String>,
        add: (String?) -> Void
    ) {
        guard depth <= 8, remainingNodes > 0 else { return }
        let visitKey = elementVisitKey(element)
        guard !visited.contains(visitKey) else { return }
        visited.insert(visitKey)
        remainingNodes -= 1

        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success {
            add(valueRef as? String)
        }

        for childAttribute in [
            kAXVisibleChildrenAttribute,
            kAXChildrenAttribute,
            kAXContentsAttribute,
        ] {
            for child in axElementArrayAttribute(childAttribute, from: element) {
                collectTextSnapshots(
                    from: child,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes,
                    visited: &visited,
                    add: add
                )
                if remainingNodes <= 0 { return }
            }
        }
    }

    nonisolated private static func systemFocusedTextSnapshot(
        maxCharacters: Int = 20_000,
        processID focusedProcessID: inout pid_t?
    ) -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }

        let element = focused as! AXUIElement
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success {
            focusedProcessID = pid
        }
        return textSnapshot(from: element, maxCharacters: maxCharacters)
    }

    nonisolated private static func textSnapshot(from element: AXUIElement, maxCharacters: Int) -> String? {
        var charCountRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &charCountRef) == .success,
           let count = charCountRef as? Int,
           count > maxCharacters {
            return nil
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String,
              value.count <= maxCharacters
        else { return nil }
        return value
    }

    nonisolated private static func elementVisitKey(_ element: AXUIElement) -> String {
        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)

        let role = axStringAttribute(kAXRoleAttribute, from: element)
        let position = cgPointAttribute(kAXPositionAttribute, from: element)
        let size = cgSizeAttribute(kAXSizeAttribute, from: element)

        if let position, let size {
            return "\(pid)|\(role)|\(Int(position.x))|\(Int(position.y))|\(Int(size.width))|\(Int(size.height))"
        }
        return "\(pid)|\(role)|\(CFHash(element))"
    }

    nonisolated private static func axElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let value = valueRef,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated private static func axElementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let value = valueRef
        else { return [] }

        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            return [value as! AXUIElement]
        }
        return (value as? [AXUIElement]) ?? []
    }

    nonisolated private static func axStringAttribute(_ attribute: String, from element: AXUIElement) -> String {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success else {
            return ""
        }
        return (valueRef as? String) ?? ""
    }

    nonisolated private static func cgPointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXValueGetTypeID()
        else { return nil }
        let value = valueRef as! AXValue
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    nonisolated private static func cgSizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let valueRef,
              CFGetTypeID(valueRef) == AXValueGetTypeID()
        else { return nil }
        let value = valueRef as! AXValue
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
}
