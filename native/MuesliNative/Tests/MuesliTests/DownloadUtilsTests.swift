import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("DownloadUtils", .muesliHermeticSupport)
struct DownloadUtilsTests {

    @Test("failed move deletes temp")
    func failedMoveDeletesTemp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("download-utils-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let tempURL = root.appendingPathComponent("model.tmp")
        let destination = root.appendingPathComponent("missing/model.bin")
        try Data("payload".utf8).write(to: tempURL)

        #expect(throws: Error.self) {
            try moveDownloadedTemporaryFile(tempURL, to: destination)
        }

        #expect(try fm.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(!fm.fileExists(atPath: destination.path))
    }

    @Test("successful move creates destination and removes temp")
    func successfulMoveCreatesDestinationAndRemovesTemp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("download-utils-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let tempURL = root.appendingPathComponent("model.tmp")
        let destination = root.appendingPathComponent("model.bin")
        let payload = Data("payload".utf8)
        try payload.write(to: tempURL)

        try moveDownloadedTemporaryFile(tempURL, to: destination)

        #expect(fm.fileExists(atPath: destination.path))
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["model.bin"])
        let movedPayload = try Data(contentsOf: destination)
        #expect(movedPayload == payload)
    }
}
