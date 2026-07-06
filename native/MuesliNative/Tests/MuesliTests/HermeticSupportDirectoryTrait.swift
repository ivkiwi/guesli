import Foundation
import MuesliCore
import Testing

struct HermeticSupportDirectoryTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        MuesliPaths.markRunningTestsForCurrentProcess()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-test-support", isDirectory: true)
            .appendingPathComponent(safeDirectoryName(for: test), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try await MuesliPaths.$testSupportDirectoryRoot.withValue(root) {
            try await function()
        }
    }

    private func safeDirectoryName(for test: Test) -> String {
        let rawName = test.id.description.isEmpty ? test.name : test.id.description
        let safeScalars = rawName.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(safeScalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? UUID().uuidString : collapsed
    }
}

extension Trait where Self == HermeticSupportDirectoryTrait {
    static var muesliHermeticSupport: Self { Self() }
}
