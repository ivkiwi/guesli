import Testing
import Foundation
@testable import MuesliCore
@testable import MuesliNativeApp

struct Qwen3VendorTests {

    @Test("Qwen cache detection accepts current layout and requires every artifact")
    func cacheDetectionUsesCompleteCurrentLayout() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("qwen3-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let model = root.appendingPathComponent("qwen3-asr-0.6b/int8", isDirectory: true)
        try fm.createDirectory(at: model, withIntermediateDirectories: true)
        for name in [
            "qwen3_asr_audio_encoder_v2.mlmodelc",
            "qwen3_asr_decoder_stateful.mlmodelc",
        ] {
            let directory = model.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: directory.appendingPathComponent("weights", isDirectory: true), withIntermediateDirectories: true)
            try Data([0x01]).write(to: directory.appendingPathComponent("coremldata.bin"))
            try Data([0x01]).write(to: directory.appendingPathComponent("weights/weight.bin"))
        }
        try Data([0x01]).write(to: model.appendingPathComponent("qwen3_asr_embeddings.bin"))
        try Data([0x01]).write(to: model.appendingPathComponent("vocab.json"))

        #expect(Qwen3AsrModelStore.isModelDownloaded(in: root, fileManager: fm))
        try fm.removeItem(at: model.appendingPathComponent("vocab.json"))
        #expect(!Qwen3AsrModelStore.isModelDownloaded(in: root, fileManager: fm))
    }

    @Test("managed Qwen plan installs directly into the requested destination")
    func managedPlanUsesFinalDestination() {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen3-final-destination-\(UUID().uuidString)", isDirectory: true)
        let plan = ManagedASRModelPlans.qwen3ASRInt8(cacheDirectory: destination)

        #expect(plan.cacheDirectory.standardizedFileURL == destination.standardizedFileURL)
        #expect(plan.modelID == "FluidInference/qwen3-asr-0.6b-coreml")
    }
}

struct Qwen3LanguageTests {

    @Test("Language init parses ISO codes and English names")
    func languageInitParsesCodesAndNames() {
        #expect(MuesliQwen3AsrConfig.Language(from: "en") == .english)
        #expect(MuesliQwen3AsrConfig.Language(from: "English") == .english)
        #expect(MuesliQwen3AsrConfig.Language(from: "ENGLISH") == .english)
        #expect(MuesliQwen3AsrConfig.Language(from: "hi") == .hindi)
    }

    @Test("Language init rejects unknown input")
    func languageInitRejectsUnknownInput() {
        #expect(MuesliQwen3AsrConfig.Language(from: "eng") == nil)
        #expect(MuesliQwen3AsrConfig.Language(from: "") == nil)
        #expect(MuesliQwen3AsrConfig.Language(from: "chinese (simplified)") == nil)
    }
}
