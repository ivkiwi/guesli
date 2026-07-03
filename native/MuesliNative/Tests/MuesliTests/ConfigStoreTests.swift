import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("ConfigStore", .serialized)
struct ConfigStoreTests {

    private func makeStore() -> ConfigStore {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-store-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Library/Application Support/Guesli", isDirectory: true)
        let legacySupportURL = supportURL
            .deletingLastPathComponent()
            .appendingPathComponent("Muesli", isDirectory: true)
        return ConfigStore(supportURL: supportURL, legacySupportURL: legacySupportURL)
    }

    @Test("load returns a valid config")
    func loadReturnsConfig() {
        let store = makeStore()
        let config = store.load()
        // Hotkey may have been customized by user — just verify it loaded
        #expect(HotkeyConfig.label(for: config.dictationHotkey.keyCode) != nil)
        #expect(!config.sttBackend.isEmpty)
    }

    @Test("save and load round-trip")
    func saveLoadRoundTrip() {
        let store = makeStore()
        let original = store.load()

        var config = original
        config.openAIAPIKey = "sk-test-roundtrip"
        config.openAIModel = "gpt-5.4-pro"
        config.openRouterAPIKey = "sk-or-test-roundtrip"
        config.openRouterModel = "nvidia/nemotron-3-super-120b-a12b:free"
        config.cohereLanguageDictation = CohereTranscribeLanguage.german.rawValue
        config.cohereLanguageMeetings = CohereTranscribeLanguage.french.rawValue
        config.meetingSummaryBackend = "openrouter"
        store.save(config)

        let loaded = store.load()
        #expect(loaded.openAIAPIKey == "sk-test-roundtrip")
        #expect(loaded.openAIModel == "gpt-5.4-pro")
        #expect(loaded.openRouterAPIKey == "sk-or-test-roundtrip")
        #expect(loaded.openRouterModel == "nvidia/nemotron-3-super-120b-a12b:free")
        #expect(loaded.cohereLanguageDictation == CohereTranscribeLanguage.german.rawValue)
        #expect(loaded.cohereLanguageMeetings == CohereTranscribeLanguage.french.rawValue)
        #expect(loaded.meetingSummaryBackend == "openrouter")

        // Restore original
        store.save(original)
    }

    @Test("config path is in Application Support")
    func configPath() {
        let store = makeStore()
        let path = store.configPath().path
        #expect(path.contains("Application Support"))
        #expect(path.hasSuffix("config.json"))
    }

    @Test("saved config uses owner-only file permissions")
    func configPermissions() throws {
        let store = makeStore()
        let original = store.load()

        store.save(original)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.configPath().path)
        let permissions = attributes[.posixPermissions] as? NSNumber

        #expect(permissions?.intValue == 0o600)
    }

    @Test("load imports legacy user settings once without replacing GigaAM")
    func importsLegacyUserSettingsWithoutReplacingGigaAM() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-settings-import-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacySupport = root.appendingPathComponent("Muesli", isDirectory: true)
        let targetSupport = root.appendingPathComponent("Guesli", isDirectory: true)
        let unusedLegacy = root.appendingPathComponent("Unused", isDirectory: true)

        let legacyStore = ConfigStore(supportURL: legacySupport, legacySupportURL: unusedLegacy)
        let legacyTemplate = CustomMeetingTemplate(
            id: "legacy-template",
            name: "Общий",
            prompt: "legacy prompt",
            icon: "doc.text"
        )
        var legacyConfig = AppConfig()
        legacyConfig.sttBackend = BackendOption.parakeetMultilingual.backend
        legacyConfig.sttModel = BackendOption.parakeetMultilingual.model
        legacyConfig.meetingTranscriptionBackend = BackendOption.parakeetMultilingual.backend
        legacyConfig.meetingTranscriptionModel = BackendOption.parakeetMultilingual.model
        legacyConfig.userName = "Ivan"
        legacyConfig.customMeetingTemplates = [legacyTemplate]
        legacyConfig.defaultMeetingTemplateID = legacyTemplate.id
        legacyConfig.chatGPTModel = "gpt-5.5"
        legacyConfig.meetingRecordingSavePolicy = .always
        legacyConfig.meetingRecordingFileFormat = MeetingRecordingFileFormat.wav.rawValue
        legacyConfig.cohereLanguageDictation = CohereTranscribeLanguage.french.rawValue
        legacyConfig.cohereLanguageMeetings = CohereTranscribeLanguage.german.rawValue
        legacyConfig.enableMeetingTranscriptCleanup = true
        legacyConfig.meetingTranscriptCleanupProvider = MeetingTranscriptCleanupProviderOption.chatGPT.rawValue
        legacyStore.save(legacyConfig)
        try Data("legacy auth".utf8).write(to: legacySupport.appendingPathComponent("chatgpt-auth.json"))

        let targetStore = ConfigStore(supportURL: targetSupport, legacySupportURL: legacySupport)
        var targetConfig = AppConfig()
        targetConfig.sttBackend = BackendOption.gigaAMV3Russian.backend
        targetConfig.sttModel = BackendOption.gigaAMV3Russian.model
        targetConfig.meetingTranscriptionBackend = BackendOption.gigaAMV3Russian.backend
        targetConfig.meetingTranscriptionModel = BackendOption.gigaAMV3Russian.model
        targetConfig.preferredMeetingBrowserBundleID = "com.brave.Browser"
        targetStore.save(targetConfig)

        let loaded = targetStore.load()

        #expect(loaded.sttBackend == BackendOption.gigaAMV3Russian.backend)
        #expect(loaded.sttModel == BackendOption.gigaAMV3Russian.model)
        #expect(loaded.meetingTranscriptionBackend == BackendOption.gigaAMV3Russian.backend)
        #expect(loaded.meetingTranscriptionModel == BackendOption.gigaAMV3Russian.model)
        #expect(loaded.preferredMeetingBrowserBundleID == "com.brave.Browser")
        #expect(loaded.userName == "Ivan")
        #expect(loaded.customMeetingTemplates == [legacyTemplate])
        #expect(loaded.defaultMeetingTemplateID == legacyTemplate.id)
        #expect(loaded.chatGPTModel == "gpt-5.5")
        #expect(loaded.meetingRecordingSavePolicy == .always)
        #expect(loaded.meetingRecordingFileFormat == MeetingRecordingFileFormat.wav.rawValue)
        #expect(loaded.cohereLanguageDictation == CohereTranscribeLanguage.french.rawValue)
        #expect(loaded.cohereLanguageMeetings == CohereTranscribeLanguage.german.rawValue)
        #expect(loaded.enableMeetingTranscriptCleanup == true)
        #expect(loaded.meetingTranscriptCleanupProvider == MeetingTranscriptCleanupProviderOption.chatGPT.rawValue)
        #expect(
            try Data(contentsOf: targetSupport.appendingPathComponent("chatgpt-auth.json"))
                == Data("legacy auth".utf8)
        )
        #expect(
            FileManager.default.fileExists(
                atPath: targetSupport.appendingPathComponent("legacy-muesli-settings-import.json").path
            )
        )

        legacyConfig.userName = "Wrong World"
        legacyStore.save(legacyConfig)
        var manuallyChanged = loaded
        manuallyChanged.userName = "Manual"
        targetStore.save(manuallyChanged)

        #expect(targetStore.load().userName == "Manual")
    }

    @Test("load imports legacy cleanup and cohere split settings")
    func importsLegacyCleanupAndCohereSplitSettings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-recent-settings-import-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacySupport = root.appendingPathComponent("Muesli", isDirectory: true)
        let targetSupport = root.appendingPathComponent("Guesli", isDirectory: true)
        try FileManager.default.createDirectory(at: legacySupport, withIntermediateDirectories: true)
        try Data(
            """
            {
              "cohere_language": "fr",
              "paste_shortcut": "command_shift_v",
              "transcript_cleanup_provider": "chatgpt",
              "enable_meeting_transcript_cleanup": true,
              "meeting_transcript_cleanup_provider": "chatgpt"
            }
            """.utf8
        ).write(to: legacySupport.appendingPathComponent("config.json"))

        let targetStore = ConfigStore(supportURL: targetSupport, legacySupportURL: legacySupport)
        let loaded = targetStore.load()

        #expect(loaded.cohereLanguageDictation == CohereTranscribeLanguage.french.rawValue)
        #expect(loaded.cohereLanguageMeetings == CohereTranscribeLanguage.french.rawValue)
        #expect(loaded.pasteShortcut == .commandShiftV)
        #expect(loaded.transcriptCleanupProvider == TranscriptCleanupProviderOption.chatGPT.rawValue)
        #expect(loaded.enableMeetingTranscriptCleanup == true)
        #expect(loaded.meetingTranscriptCleanupProvider == MeetingTranscriptCleanupProviderOption.chatGPT.rawValue)
    }

    @Test("legacy auth import does not clobber recoverable current backup")
    func legacyAuthImportSkipsRecoverableBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-auth-backup-skip-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacySupport = root.appendingPathComponent("Muesli", isDirectory: true)
        let targetSupport = root.appendingPathComponent("Guesli", isDirectory: true)
        try FileManager.default.createDirectory(at: legacySupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetSupport, withIntermediateDirectories: true)

        try authData(accessToken: "legacy").write(to: legacySupport.appendingPathComponent("chatgpt-auth.json"))
        let primaryURL = targetSupport.appendingPathComponent("chatgpt-auth.json")
        let backupURL = AuthTokenFileStore.backupURL(for: primaryURL)
        try authData(accessToken: "current").write(to: backupURL)

        let targetStore = ConfigStore(supportURL: targetSupport, legacySupportURL: legacySupport)
        _ = targetStore.load()

        #expect(!FileManager.default.fileExists(atPath: primaryURL.path))
        let backupTokensOrNil = try tokens(at: backupURL)
        let backupTokens = try #require(backupTokensOrNil)
        #expect(backupTokens["access_token"] == "current")
    }

    private func authData(accessToken: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["access_token": accessToken], options: .prettyPrinted)
    }

    private func tokens(at url: URL) throws -> [String: String]? {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: String]
    }
}
