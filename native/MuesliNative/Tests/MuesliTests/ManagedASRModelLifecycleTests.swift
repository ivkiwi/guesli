import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Managed ASR model lifecycle")
struct ManagedASRModelLifecycleTests {
    @Test("Whisper canonical cache is outside Documents")
    func whisperCanonicalCacheIsOutsideDocuments() {
        let plan = ManagedASRModelPlans.whisperKit(modelName: "small.en")

        #expect(!plan.cacheDirectory.path.contains("/Documents/"))
        #expect(plan.cacheDirectory.path.contains("/Library/Application Support/Guesli/Models/WhisperKit/"))
    }

    @Test("legacy Whisper cache imports atomically without mutating source")
    func importsLegacyWhisperReadOnly() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("whisper-legacy-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let canonicalRoot = root.appendingPathComponent("canonical", isDirectory: true)
        let legacyRoot = root.appendingPathComponent("legacy", isDirectory: true)
        let legacyPlan = ManagedASRModelPlans.legacyWhisperKit(
            modelName: "small.en",
            legacyRoot: legacyRoot,
            fileManager: fm
        )
        try makeWhisperArtifacts(at: legacyPlan.cacheDirectory, fileManager: fm)

        let imported = try ManagedASRModelPlans.migrateLegacyWhisperKitIfNeeded(
            modelName: "small.en",
            downloadRoot: canonicalRoot,
            legacyRoot: legacyRoot,
            fileManager: fm
        )

        #expect(fm.fileExists(atPath: legacyPlan.cacheDirectory.appendingPathComponent("config.json").path))
        #expect(fm.fileExists(atPath: imported.appendingPathComponent("config.json").path))
        #expect(ManagedASRModelPlans.whisperKit(modelName: "small.en", downloadRoot: canonicalRoot)
            .isAvailableLocally(fileManager: fm))
    }

    @Test("deleting canonical Whisper cache does not resurrect legacy Documents cache")
    func deletionDoesNotRemigrateLegacy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("whisper-no-resurrection-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let canonicalRoot = root.appendingPathComponent("canonical", isDirectory: true)
        let legacyRoot = root.appendingPathComponent("legacy", isDirectory: true)
        let legacyPlan = ManagedASRModelPlans.legacyWhisperKit(
            modelName: "small.en",
            legacyRoot: legacyRoot,
            fileManager: fm
        )
        try makeWhisperArtifacts(at: legacyPlan.cacheDirectory, fileManager: fm)
        let canonicalPlan = ManagedASRModelPlans.whisperKit(modelName: "small.en", downloadRoot: canonicalRoot)
        _ = try ManagedASRModelPlans.migrateLegacyWhisperKitIfNeeded(
            modelName: "small.en",
            downloadRoot: canonicalRoot,
            legacyRoot: legacyRoot,
            fileManager: fm
        )
        try canonicalPlan.delete(fileManager: fm)

        _ = try ManagedASRModelPlans.migrateLegacyWhisperKitIfNeeded(
            modelName: "small.en",
            downloadRoot: canonicalRoot,
            legacyRoot: legacyRoot,
            fileManager: fm
        )

        #expect(!fm.fileExists(atPath: canonicalPlan.cacheDirectory.path))
        #expect(fm.fileExists(atPath: legacyPlan.cacheDirectory.path))
        #expect(!ManagedASRModelPlans.isWhisperKitAvailable(
            modelName: "small.en",
            downloadRoot: canonicalRoot,
            legacyRoot: legacyRoot,
            fileManager: fm
        ))
    }

    @Test("Qwen shutdown invalidates a completing warmup")
    func qwenWarmupReadinessRejectsStaleLoad() {
        #expect(throws: CancellationError.self) {
            try Qwen3AsrWarmupReadiness.validate(isCancelled: false, isCurrent: false)
        }
    }

    @Test("Parakeet unload targets only the loaded version")
    func parakeetUnloadPolicyIsVersionScoped() {
        #expect(FluidAudioUnloadPolicy.shouldUnload(loadedVersion: .v2, deletingVersion: .v2))
        #expect(!FluidAudioUnloadPolicy.shouldUnload(loadedVersion: .v3, deletingVersion: .v2))
    }

    @Test("streaming dictation backend is not meeting eligible")
    func meetingEligibilityExcludesStreamingBackend() {
        #expect(!BackendOption.nemotron35Multilingual.supportsMeetingTranscription)
        #expect(BackendOption.gigaAMV3Russian.supportsMeetingTranscription)
        #expect(BackendOption.parakeetUnified.supportsMeetingTranscription)
    }

    @Test("Qwen language config round trips and rejects unknown codes")
    func qwenLanguageConfigRoundTrips() throws {
        var config = AppConfig()
        config.qwen3AsrLanguage = "ru"
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))

        #expect(decoded.resolvedQwen3AsrLanguage.pinnedCode == "ru")
        #expect(Qwen3AsrLanguage.resolved("not-a-language") == .auto)
    }

    private func makeWhisperArtifacts(at directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            let model = directory.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(
                at: model.appendingPathComponent("weights", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data([0x01]).write(to: model.appendingPathComponent("coremldata.bin"))
            try Data([0x01]).write(to: model.appendingPathComponent("weights/weight.bin"))
        }
        try Data([0x01]).write(to: directory.appendingPathComponent("config.json"))
        try Data([0x01]).write(to: directory.appendingPathComponent("generation_config.json"))
    }
}
