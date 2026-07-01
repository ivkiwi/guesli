import Testing
@testable import MuesliNativeApp

@Suite("Onboarding model download policy")
struct OnboardingModelDownloadPolicyTests {
    @Test("alternative models hide primary onboarding cards")
    func alternativeModelsHidePrimaryCards() {
        let alternatives = makeOnboardingAlternativeModels(
            selectedBackend: .parakeetMultilingual,
            onboardingOptions: BackendOption.onboarding
        )

        #expect(!alternatives.contains(.gigaAMV3Russian))
        #expect(!alternatives.contains(.parakeetMultilingual))
        #expect(alternatives == [.whisperTinyEnglish, .whisperSmall, .cohereTranscribe, .nemotron35Multilingual])
    }

    @Test("alternative models keep selected secondary option visible first")
    func alternativeModelsKeepSelectedSecondaryFirst() {
        let alternatives = makeOnboardingAlternativeModels(
            selectedBackend: .whisperSmall,
            onboardingOptions: [.gigaAMV3Russian, .parakeetMultilingual, .cohereTranscribe]
        )

        #expect(alternatives == [.whisperSmall, .cohereTranscribe])
    }

    @Test("GigaAM stale download progress resets when model is missing")
    func gigaAMStaleDownloadProgressResetsWhenModelIsMissing() {
        let choice = onboardingInitialDownloadProgressStatusChoice(
            backend: .gigaAMV3Russian,
            alreadyDownloaded: false,
            currentProgress: 0.72,
            currentStatus: "920 MB of 1.2 GB"
        )

        #expect(choice == OnboardingInitialDownloadProgressStatusChoice(
            progress: 0.02,
            status: onboardingInitialDownloadStatus(for: .gigaAMV3Russian)
        ))
    }

    @Test("non-GigaAM download resumes stored progress and status")
    func nonGigaAMDownloadResumesStoredProgressAndStatus() {
        let choice = onboardingInitialDownloadProgressStatusChoice(
            backend: .whisperSmall,
            alreadyDownloaded: false,
            currentProgress: 0.72,
            currentStatus: "180 MB of 250 MB"
        )

        #expect(choice == OnboardingInitialDownloadProgressStatusChoice(
            progress: 0.72,
            status: "180 MB of 250 MB"
        ))
    }

    @Test("downloaded model starts warmup without progress")
    func downloadedModelStartsWarmupWithoutProgress() {
        let choice = onboardingInitialDownloadProgressStatusChoice(
            backend: .gigaAMV3Russian,
            alreadyDownloaded: true,
            currentProgress: 0.72,
            currentStatus: "920 MB of 1.2 GB"
        )

        #expect(choice == OnboardingInitialDownloadProgressStatusChoice(
            progress: nil,
            status: "Warming up GigaAM v3 Russian..."
        ))
    }

    @Test("GigaAM progress may decrease")
    func gigaAMProgressMayDecrease() {
        let progress = onboardingNextModelDownloadProgress(
            backend: .gigaAMV3Russian,
            currentProgress: 0.80,
            reportedProgress: 0.30
        )

        #expect(progress == 0.30)
    }

    @Test("non-GigaAM progress stays monotonic")
    func nonGigaAMProgressStaysMonotonic() {
        let progress = onboardingNextModelDownloadProgress(
            backend: .parakeetMultilingual,
            currentProgress: 0.80,
            reportedProgress: 0.30
        )

        #expect(progress == 0.80)
    }

    @Test("progress ignores zero reset after real movement")
    func progressIgnoresZeroResetAfterRealMovement() {
        let progress = onboardingNextModelDownloadProgress(
            backend: .gigaAMV3Russian,
            currentProgress: 0.80,
            reportedProgress: 0
        )

        #expect(progress == nil)
    }
}
