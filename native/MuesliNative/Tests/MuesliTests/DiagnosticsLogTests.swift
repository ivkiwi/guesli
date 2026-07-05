import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Diagnostics log")
struct DiagnosticsLogTests {
    @Test("rotates diagnostics log and keeps owner-only permissions")
    func rotatesDiagnosticsLogAndKeepsOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-log-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = root.appendingPathComponent("diagnostics.log")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        DiagnosticsLog.append(
            "[summary] first line",
            to: logURL,
            maxBytes: 80,
            date: Date(timeIntervalSince1970: 0)
        )
        DiagnosticsLog.append(
            "[summary] \(String(repeating: "x", count: 90))",
            to: logURL,
            maxBytes: 80,
            date: Date(timeIntervalSince1970: 1)
        )

        let oldURL = logURL.appendingPathExtension("old")
        let current = try String(contentsOf: logURL, encoding: .utf8)
        let old = try String(contentsOf: oldURL, encoding: .utf8)

        #expect(current.contains(String(repeating: "x", count: 90)))
        #expect(old.contains("[summary] first line"))
        #expect(try permissions(at: logURL) == 0o600)
        #expect(try permissions(at: oldURL) == 0o600)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }
}
