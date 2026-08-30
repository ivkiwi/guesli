import Testing
@testable import MuesliNativeApp

@Suite("Settings permission refresh reasons")
struct SettingsPermissionRefreshReasonTests {
    @Test("polling avoids expensive permission probes")
    func pollingAvoidsExpensiveProbes() {
        #expect(!SettingsPermissionRefreshReason.periodicPoll.refreshesSystemAudio)
        #expect(!SettingsPermissionRefreshReason.periodicPoll.refreshesLaunchAtLogin)
        #expect(SettingsPermissionRefreshReason.initialDisplay.refreshesSystemAudio)
        #expect(SettingsPermissionRefreshReason.settingsSelected.refreshesSystemAudio)
        #expect(SettingsPermissionRefreshReason.appActivated.refreshesSystemAudio)
        #expect(SettingsPermissionRefreshReason.appActivated.refreshesLaunchAtLogin)
    }
}
