import Foundation
import MuesliCore
import Testing

@Suite("Guesli identity", .muesliHermeticSupport)
struct GuesliIdentityTests {
    @Test("core defaults use the Guesli support directory")
    func coreDefaultsUseGuesliSupportDirectory() {
        let supportURL = MuesliPaths.defaultSupportDirectoryURL()
        let databaseURL = MuesliPaths.defaultDatabaseURL()

        #expect(supportURL.lastPathComponent == "Guesli")
        #expect(databaseURL.deletingLastPathComponent().lastPathComponent == "Guesli")
        #expect(databaseURL.lastPathComponent == "muesli.db")
    }
}
