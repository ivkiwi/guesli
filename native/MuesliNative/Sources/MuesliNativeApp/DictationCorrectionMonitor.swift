import AppKit
import ApplicationServices
import Foundation

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

    static func suggestion(
        originalText: String,
        editedText: String,
        appContext: String = ""
    ) -> DictionarySuggestion? {
        suggestion(
            originalText: originalText,
            baselineText: originalText,
            currentText: editedText,
            appContext: appContext
        )
    }

    static func suggestion(
        originalText: String,
        baselineText: String,
        currentText: String,
        appContext: String = ""
    ) -> DictionarySuggestion? {
        guard !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard baselineText != currentText else { return nil }
        guard hasSufficientSharedContext(originalText: originalText, editedText: currentText) else { return nil }

        if let suggestion = fragmentSuggestion(
            originalText: originalText,
            baselineText: baselineText,
            currentText: currentText,
            appContext: appContext
        ) {
            return suggestion
        }

        if let suggestion = tokenAlignedSuggestion(
            originalText: originalText,
            editedText: currentText,
            appContext: appContext
        ) {
            return suggestion
        }

        return nil
    }

    private static func fragmentSuggestion(
        originalText: String,
        baselineText: String,
        currentText: String,
        appContext: String
    ) -> DictionarySuggestion? {
        let diff = changedFragments(from: baselineText, to: currentText)
        guard let observed = normalizedCandidate(diff.removed),
              let replacement = normalizedCandidate(diff.inserted)
        else { return nil }

        guard originalText.range(of: observed, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
            return nil
        }
        guard isLikelyDictionaryCorrection(observed: observed, replacement: replacement) else { return nil }

        return DictionarySuggestion(
            observed: observed,
            replacement: replacement,
            appContext: appContext
        )
    }

    private struct WordToken: Equatable {
        let text: String
        let normalized: String
    }

    private static func tokenAlignedSuggestion(
        originalText: String,
        editedText: String,
        appContext: String
    ) -> DictionarySuggestion? {
        let originalTokens = wordTokens(in: originalText)
        let editedTokens = wordTokens(in: editedText)
        guard !originalTokens.isEmpty, !editedTokens.isEmpty else { return nil }
        guard originalTokens.count <= 160, editedTokens.count <= 220 else { return nil }

        let operations = alignmentOperations(from: originalTokens, to: editedTokens)
        for operation in operations {
            guard case .substitution(let observed, let replacement) = operation else { continue }
            guard let observedCandidate = normalizedCandidate(observed.text),
                  let replacementCandidate = normalizedCandidate(replacement.text)
            else { continue }
            guard originalText.range(of: observedCandidate, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                continue
            }
            guard isLikelyDictionaryCorrection(observed: observedCandidate, replacement: replacementCandidate) else {
                continue
            }
            return DictionarySuggestion(
                observed: observedCandidate,
                replacement: replacementCandidate,
                appContext: appContext
            )
        }
        return nil
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

    private static func isLikelyDictionaryCorrection(observed: String, replacement: String) -> Bool {
        guard observed != replacement else { return false }
        guard observed.count >= 2, replacement.count >= 2 else { return false }

        let observedTokens = observed.split(whereSeparator: \.isWhitespace).map(String.init)
        let replacementTokens = replacement.split(whereSeparator: \.isWhitespace).map(String.init)

        let normalizedReplacement = replacement.lowercased()
        let normalizedObserved = observed.lowercased()
        let hasSpecialDictionarySignal = hasInternalCapital(replacement)
            || replacement.contains(where: \.isNumber)
            || replacement.contains("-")
            || replacement.contains("_")
            || replacement.contains("/")
            || isAcronymLike(replacement)

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
            return compactSimilarity >= 0.82 || hasSpecialDictionarySignal
        }

        if commonWords.contains(normalizedObserved) {
            if observed.lowercased() == replacement.lowercased() {
                return hasSpecialDictionarySignal || replacement.contains(where: \.isUppercase)
            }
            return similarity >= 0.82 && hasSpecialDictionarySignal
        }

        if commonWords.contains(normalizedReplacement), !hasSpecialDictionarySignal {
            return false
        }

        if observed.lowercased() == replacement.lowercased() {
            return hasSpecialDictionarySignal || replacement.contains(where: \.isUppercase)
        }

        guard !isCommonWordTruncation(observed: normalizedObserved, replacement: normalizedReplacement) else {
            return false
        }

        return similarity >= minimumCorrectionSimilarity || hasSpecialDictionarySignal
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
    private static let initialPollDelayNanoseconds: UInt64 = 100_000_000
    private static let fastPollIntervalNanoseconds: UInt64 = 150_000_000
    private static let steadyPollIntervalNanoseconds: UInt64 = 1_000_000_000
    private static let fastPollingWindowSeconds: TimeInterval = 10
    private static let monitoringWindowSeconds: TimeInterval = 45
    private static let snapshotQuietWindowSeconds: TimeInterval = 1.5
    nonisolated private static let maxAccessibilityNodes = 140
    nonisolated private static let maxCandidateCharacters = 2_000

    private var task: Task<Void, Never>?

    func start(
        originalText: String,
        appContext: String,
        targetApp: DictationCorrectionTargetApp?,
        onSuggestion: @escaping @MainActor (DictionarySuggestion) -> Void
    ) {
        cancel()
        guard AXIsProcessTrusted() else { return }

        task = Task {
            let fastPollingDeadline = Date().addingTimeInterval(Self.fastPollingWindowSeconds)
            let deadline = Date().addingTimeInterval(Self.monitoringWindowSeconds)
            var stabilizer = DictationCorrectionSnapshotStabilizer()
            try? await Task.sleep(nanoseconds: Self.initialPollDelayNanoseconds)
            while !Task.isCancelled, Date() < deadline {
                let snapshots = await Task.detached(priority: .utility) {
                    Self.detectEditedSnapshots(
                        originalText: originalText,
                        targetApp: targetApp
                    )
                }.value
                if Task.isCancelled { return }
                let stableSnapshots = stabilizer.observe(
                    snapshots: snapshots,
                    now: Date(),
                    quietWindow: Self.snapshotQuietWindowSeconds
                )
                for stableSnapshot in stableSnapshots {
                    let suggestion = await Task.detached(priority: .utility) {
                        Self.suggestion(
                            originalText: originalText,
                            editedSnapshot: stableSnapshot,
                            appContext: appContext,
                            targetApp: targetApp
                        )
                    }.value
                    if Task.isCancelled { return }
                    if let suggestion {
                        await MainActor.run {
                            onSuggestion(suggestion)
                        }
                        return
                    }
                }
                let interval = Date() < fastPollingDeadline
                    ? Self.fastPollIntervalNanoseconds
                    : Self.steadyPollIntervalNanoseconds
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    nonisolated private static func suggestion(
        originalText: String,
        editedSnapshot: String,
        appContext: String,
        targetApp: DictationCorrectionTargetApp?
    ) -> DictionarySuggestion? {
        let resolvedAppContext = appContext.isEmpty ? (targetApp?.appContext ?? "") : appContext
        return DictionaryCorrectionDetector.suggestion(
            originalText: originalText,
            editedText: editedSnapshot,
            appContext: resolvedAppContext
        )
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
