import Foundation
import MuesliCore

final class ConfigStore {
    private struct LegacySettingsImportResult {
        let didAttempt: Bool
        let importedFields: [String]
        let copiedFiles: [String]

        var didChangeConfig: Bool {
            !importedFields.isEmpty
        }
    }

    private struct LegacySettingsMarker: Codable {
        let sourceConfigPath: String
        let importedAt: String
        let importedFields: [String]
        let copiedFiles: [String]
    }

    private let configURL: URL
    private let supportURL: URL
    private let legacySupportURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        supportURL: URL = AppIdentity.supportDirectoryURL,
        legacySupportURL: URL = MuesliPaths.defaultSupportDirectoryURL(appName: "Muesli"),
        fileManager: FileManager = .default
    ) {
        self.supportURL = supportURL.standardizedFileURL
        self.legacySupportURL = legacySupportURL.standardizedFileURL
        self.fileManager = fileManager
        self.configURL = supportURL.appendingPathComponent("config.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> AppConfig {
        ensureDirectory()
        var config: AppConfig
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? decoder.decode(AppConfig.self, from: data) {
            config = decoded
        } else {
            config = AppConfig()
        }

        let legacyImport = importLegacySettingsIfNeeded(into: &config)
        if legacyImport.didChangeConfig {
            save(config)
        }
        if legacyImport.didAttempt {
            writeLegacySettingsMarker(importResult: legacyImport)
        }
        return config
    }

    func save(_ config: AppConfig) {
        ensureDirectory()
        guard let data = try? encoder.encode(config) else { return }
        do {
            try data.write(to: configURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configURL.path
            )
        } catch {
            fputs("[config-store] failed to save config: \(error)\n", stderr)
        }
    }

    func configPath() -> URL {
        configURL
    }

    func supportDirectory() -> URL {
        supportURL
    }

    private func ensureDirectory() {
        try? fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func importLegacySettingsIfNeeded(into config: inout AppConfig) -> LegacySettingsImportResult {
        let markerURL = legacySettingsMarkerURL()
        guard supportURL != legacySupportURL else {
            return LegacySettingsImportResult(didAttempt: false, importedFields: [], copiedFiles: [])
        }
        guard !fileManager.fileExists(atPath: markerURL.path) else {
            return LegacySettingsImportResult(didAttempt: false, importedFields: [], copiedFiles: [])
        }
        guard fileManager.fileExists(atPath: legacySupportURL.path) else {
            return LegacySettingsImportResult(didAttempt: false, importedFields: [], copiedFiles: [])
        }

        var importedFields: [String] = []
        let legacyConfigURL = legacySupportURL.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: legacyConfigURL),
           let legacyConfig = try? decoder.decode(AppConfig.self, from: data) {
            importedFields = mergeLegacyUserSettings(from: legacyConfig, into: &config)
        }

        let copiedFiles = copyLegacyAuthFiles()
        return LegacySettingsImportResult(
            didAttempt: true,
            importedFields: importedFields,
            copiedFiles: copiedFiles
        )
    }

    private func mergeLegacyUserSettings(from legacy: AppConfig, into config: inout AppConfig) -> [String] {
        var importedFields: [String] = []

        func importValue<T: Equatable>(_ name: String, _ keyPath: WritableKeyPath<AppConfig, T>) {
            let legacyValue = legacy[keyPath: keyPath]
            guard config[keyPath: keyPath] != legacyValue else { return }
            config[keyPath: keyPath] = legacyValue
            importedFields.append(name)
        }

        func importNonEmptyStringIfCurrentEmpty(_ name: String, _ keyPath: WritableKeyPath<AppConfig, String>) {
            let legacyValue = legacy[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !legacyValue.isEmpty else { return }
            guard config[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            config[keyPath: keyPath] = legacy[keyPath: keyPath]
            importedFields.append(name)
        }

        importValue("dictation_hotkey", \.dictationHotkey)
        importValue("computer_use_hotkey", \.computerUseHotkey)
        importValue("enable_computer_use_hotkey", \.enableComputerUseHotkey)
        importValue("meeting_recording_hotkey", \.meetingRecordingHotkey)
        importValue("enable_meeting_recording_hotkey", \.enableMeetingRecordingHotkey)
        importValue("enable_computer_use_planner", \.enableComputerUsePlanner)
        importNonEmptyStringIfCurrentEmpty("computer_use_planner_model", \.computerUsePlannerModel)
        importValue("computer_use_timeout_seconds", \.computerUseTimeoutSeconds)

        if config.dictationInputDeviceUID == nil, legacy.dictationInputDeviceUID != nil {
            config.dictationInputDeviceUID = legacy.dictationInputDeviceUID
            importedFields.append("dictation_input_device_uid")
        }
        importValue("cohere_language_dictation", \.cohereLanguageDictation)
        importValue("cohere_language_meetings", \.cohereLanguageMeetings)
        importValue("nemotron35_language", \.nemotron35Language)

        if config.preferredMeetingBrowserBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !legacy.preferredMeetingBrowserBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.preferredMeetingBrowserBundleID = legacy.preferredMeetingBrowserBundleID
            importedFields.append("preferred_meeting_browser_bundle_id")
        }

        importValue("meeting_summary_backend", \.meetingSummaryBackend)
        importValue("idle_timeout", \.idleTimeout)
        importValue("auto_record_meetings", \.autoRecordMeetings)
        importValue("upcoming_meetings_day_count", \.upcomingMeetingsDayCount)
        importValue("show_scheduled_meeting_notifications", \.showScheduledMeetingNotifications)
        importValue("scheduled_meeting_notification_lead_time", \.scheduledMeetingNotificationLeadTime)
        importValue("show_meeting_detection_notification", \.showMeetingDetectionNotification)
        config.mutedMeetingDetectionAppBundleIDs = mergedStrings(
            current: config.mutedMeetingDetectionAppBundleIDs,
            legacy: legacy.mutedMeetingDetectionAppBundleIDs,
            fieldName: "muted_meeting_detection_app_bundle_ids",
            importedFields: &importedFields
        )
        importValue("meeting_recording_save_policy", \.meetingRecordingSavePolicy)
        importNonEmptyStringIfCurrentEmpty("meeting_recording_folder_path", \.meetingRecordingFolderPath)

        importValue("dark_mode", \.darkMode)
        importValue("enable_double_tap_dictation", \.enableDoubleTapDictation)
        importValue("hotkey_trigger_threshold_ms", \.hotkeyTriggerThresholdMS)
        importValue("computer_use_hotkey_trigger_threshold_ms", \.computerUseHotkeyTriggerThresholdMS)
        importValue("meeting_recording_hotkey_trigger_threshold_ms", \.meetingRecordingHotkeyTriggerThresholdMS)
        importValue("launch_at_login", \.launchAtLogin)
        importValue("open_dashboard_on_launch", \.openDashboardOnLaunch)
        importValue("show_floating_indicator", \.showFloatingIndicator)
        importValue("indicator_anchor", \.indicatorAnchor)
        if config.dashboardWindowFrame == nil, legacy.dashboardWindowFrame != nil {
            config.dashboardWindowFrame = legacy.dashboardWindowFrame
            importedFields.append("dashboard_window_frame")
        }
        if config.indicatorOrigin == nil, legacy.indicatorOrigin != nil {
            config.indicatorOrigin = legacy.indicatorOrigin
            importedFields.append("indicator_origin")
        }

        importNonEmptyStringIfCurrentEmpty("openai_api_key", \.openAIAPIKey)
        importNonEmptyStringIfCurrentEmpty("openrouter_api_key", \.openRouterAPIKey)
        importNonEmptyStringIfCurrentEmpty("openai_model", \.openAIModel)
        importNonEmptyStringIfCurrentEmpty("openrouter_model", \.openRouterModel)
        importNonEmptyStringIfCurrentEmpty("chatgpt_model", \.chatGPTModel)
        importValue("ollama_url", \.ollamaURL)
        importNonEmptyStringIfCurrentEmpty("ollama_model", \.ollamaModel)
        importValue("lmstudio_url", \.lmStudioURL)
        importNonEmptyStringIfCurrentEmpty("lmstudio_model", \.lmStudioModel)
        importNonEmptyStringIfCurrentEmpty("custom_llm_url", \.customLLMURL)
        importNonEmptyStringIfCurrentEmpty("custom_llm_api_key", \.customLLMAPIKey)
        importNonEmptyStringIfCurrentEmpty("custom_llm_model", \.customLLMModel)
        importValue("custom_llm_format", \.customLLMFormat)
        importNonEmptyStringIfCurrentEmpty("summary_model", \.summaryModel)
        importNonEmptyStringIfCurrentEmpty("meeting_summary_model", \.meetingSummaryModel)

        importValue("has_completed_onboarding", \.hasCompletedOnboarding)
        importValue("onboarding_use_case", \.onboardingUseCase)
        let legacyUserName = legacy.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacyUserName.isEmpty, config.userName != legacy.userName {
            config.userName = legacy.userName
            importedFields.append("user_name")
        }

        mergeLegacyMeetingTemplates(from: legacy, into: &config, importedFields: &importedFields)
        mergeLegacyCustomWords(from: legacy, into: &config, importedFields: &importedFields)
        mergeLegacyDictionaryState(from: legacy, into: &config, importedFields: &importedFields)

        importValue("sound_enabled", \.soundEnabled)
        importValue("pause_media_during_dictation", \.pauseMediaDuringDictation)
        importValue("mute_system_audio_during_dictation", \.muteSystemAudioDuringDictation)
        importValue("recording_color_hex", \.recordingColorHex)
        importValue("menu_bar_icon", \.menuBarIcon)
        importValue("show_next_meeting_in_menu_bar", \.showNextMeetingInMenuBar)
        importValue("marauders_map_unlocked", \.maraudersMapUnlocked)
        importValue("marauders_map_audio_clip", \.maraudersMapAudioClip)
        if config.maraudersMapCustomAudioPath == nil, legacy.maraudersMapCustomAudioPath != nil {
            config.maraudersMapCustomAudioPath = legacy.maraudersMapCustomAudioPath
            importedFields.append("marauders_map_custom_audio_path")
        }

        config.hiddenCalendarEventIDs = mergedStrings(
            current: config.hiddenCalendarEventIDs,
            legacy: legacy.hiddenCalendarEventIDs,
            fieldName: "hidden_calendar_event_ids",
            importedFields: &importedFields
        )
        config.disabledCalendarIDs = mergedStrings(
            current: config.disabledCalendarIDs,
            legacy: legacy.disabledCalendarIDs,
            fieldName: "disabled_calendar_ids",
            importedFields: &importedFields
        )
        if !legacy.hiddenCalendarEventSourceHints.isEmpty {
            var mergedHints = config.hiddenCalendarEventSourceHints
            var changedHints = false
            for (key, value) in legacy.hiddenCalendarEventSourceHints where mergedHints[key] == nil {
                mergedHints[key] = value
                changedHints = true
            }
            if changedHints {
                config.hiddenCalendarEventSourceHints = mergedHints
                importedFields.append("hidden_calendar_event_source_hints")
            }
        }

        importValue("enable_post_processor", \.enablePostProcessor)
        importValue("transcript_cleanup_provider", \.transcriptCleanupProvider)
        importValue("enable_meeting_transcript_cleanup", \.enableMeetingTranscriptCleanup)
        importValue("meeting_transcript_cleanup_provider", \.meetingTranscriptCleanupProvider)
        importValue("active_post_processor_id", \.activePostProcessorId)
        importValue("post_processor_system_prompt", \.postProcessorSystemPrompt)
        importValue("enable_screen_context", \.enableScreenContext)
        importValue("use_core_audio_tap", \.useCoreAudioTap)
        importValue("show_ios_companion_prompt", \.showIOSCompanionPrompt)

        return importedFields
    }

    private func mergeLegacyMeetingTemplates(
        from legacy: AppConfig,
        into config: inout AppConfig,
        importedFields: inout [String]
    ) {
        var existingIDs = Set(config.customMeetingTemplates.map(\.id))
        let missingTemplates = legacy.customMeetingTemplates.filter { existingIDs.insert($0.id).inserted }
        if !missingTemplates.isEmpty {
            config.customMeetingTemplates.append(contentsOf: missingTemplates)
            importedFields.append("custom_meeting_templates")
        }

        let legacyDefault = legacy.defaultMeetingTemplateID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyDefault.isEmpty else { return }
        guard MeetingTemplates.resolveExactDefinition(id: legacyDefault, customTemplates: config.customMeetingTemplates) != nil else {
            return
        }
        guard config.defaultMeetingTemplateID != legacyDefault else { return }
        config.defaultMeetingTemplateID = legacyDefault
        importedFields.append("default_meeting_template_id")
    }

    private func mergeLegacyCustomWords(
        from legacy: AppConfig,
        into config: inout AppConfig,
        importedFields: inout [String]
    ) {
        var seen = Set(config.customWords.map(customWordKey))
        let missing = legacy.customWords.filter { seen.insert(customWordKey($0)).inserted }
        guard !missing.isEmpty else { return }
        config.customWords.append(contentsOf: missing)
        importedFields.append("custom_words")
    }

    private func mergeLegacyDictionaryState(
        from legacy: AppConfig,
        into config: inout AppConfig,
        importedFields: inout [String]
    ) {
        var seenSuggestions = Set(config.dictionarySuggestions.map { DictionarySuggestion.key(observed: $0.observed, replacement: $0.replacement) })
        let missingSuggestions = legacy.dictionarySuggestions.filter {
            seenSuggestions.insert(DictionarySuggestion.key(observed: $0.observed, replacement: $0.replacement)).inserted
        }
        if !missingSuggestions.isEmpty {
            config.dictionarySuggestions.append(contentsOf: missingSuggestions)
            importedFields.append("dictionary_suggestions")
        }

        config.dismissedDictionarySuggestionKeys = mergedStrings(
            current: config.dismissedDictionarySuggestionKeys,
            legacy: legacy.dismissedDictionarySuggestionKeys,
            fieldName: "dismissed_dictionary_suggestion_keys",
            importedFields: &importedFields
        )
        if config.enableDictionaryCorrectionPrompts != legacy.enableDictionaryCorrectionPrompts {
            config.enableDictionaryCorrectionPrompts = legacy.enableDictionaryCorrectionPrompts
            importedFields.append("enable_dictionary_correction_prompts")
        }
    }

    private func mergedStrings(
        current: [String],
        legacy: [String],
        fieldName: String,
        importedFields: inout [String]
    ) -> [String] {
        var seen = Set(current)
        let missing = legacy.filter { seen.insert($0).inserted }
        guard !missing.isEmpty else { return current }
        importedFields.append(fieldName)
        return current + missing
    }

    private func customWordKey(_ word: CustomWord) -> String {
        [
            word.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            (word.replacement ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ].joined(separator: "->")
    }

    private func copyLegacyAuthFiles() -> [String] {
        var copiedFiles: [String] = []
        for fileName in ["chatgpt-auth.json", "google-calendar-auth.json"] {
            let sourceURL = legacySupportURL.appendingPathComponent(fileName)
            let destinationURL = supportURL.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
                copiedFiles.append(fileName)
            } catch {
                fputs("[config-store] failed to import legacy \(fileName): \(error)\n", stderr)
            }
        }
        return copiedFiles
    }

    private func legacySettingsMarkerURL() -> URL {
        supportURL.appendingPathComponent("legacy-muesli-settings-import.json")
    }

    private func writeLegacySettingsMarker(importResult: LegacySettingsImportResult) {
        let legacyConfigURL = legacySupportURL.appendingPathComponent("config.json")
        let marker = LegacySettingsMarker(
            sourceConfigPath: legacyConfigURL.path,
            importedAt: ISO8601DateFormatter().string(from: Date()),
            importedFields: importResult.importedFields,
            copiedFiles: importResult.copiedFiles
        )
        do {
            try encoder.encode(marker).write(to: legacySettingsMarkerURL(), options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: legacySettingsMarkerURL().path
            )
        } catch {
            fputs("[config-store] failed to write legacy settings marker: \(error)\n", stderr)
        }
    }
}
