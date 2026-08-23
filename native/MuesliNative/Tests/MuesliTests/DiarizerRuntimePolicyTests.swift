import Foundation
import Testing
@testable import MuesliNativeApp

final class TestLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

@Suite("Diarizer runtime policy")
struct DiarizerRuntimePolicyTests {
    @Test("M1 family on macOS 15.1 avoids GPU compute")
    func m1OnMacOS151UsesCPUAndNeuralEngine() {
        for cpuBrand in ["Apple M1", "Apple M1 Pro", "Apple M1 Max", "Apple M1 Ultra"] {
            let policy = DiarizerRuntimePolicy.resolve(
                for: environment(cpuBrand: cpuBrand, os: (15, 1, 1))
            )
            #expect(policy.computePolicy == .cpuAndNeuralEngine)
            #expect(policy.compatibilityRule == DiarizerRuntimePolicy.m1MacOS151CompatibilityRule)
        }
    }

    @Test("other chips and newer macOS keep GPU available")
    func unaffectedSystemsUseDefault() {
        #expect(DiarizerRuntimePolicy.resolve(
            for: environment(cpuBrand: "Apple M2", os: (15, 1, 1))
        ).computePolicy == .all)
        #expect(DiarizerRuntimePolicy.resolve(
            for: environment(cpuBrand: "Apple M1", os: (15, 2, 0))
        ).computePolicy == .all)
    }

    private func environment(
        cpuBrand: String?,
        hardwareModel: String? = nil,
        os: (Int, Int, Int)
    ) -> DiarizerRuntimeEnvironment {
        DiarizerRuntimeEnvironment(
            cpuBrand: cpuBrand,
            hardwareModel: hardwareModel,
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: os.0,
                minorVersion: os.1,
                patchVersion: os.2
            )
        )
    }
}

@Suite("ASR helper preload coordination")
struct ASRHelperPreloadCoordinationTests {
    private enum TestError: Error { case failed }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("required ASR finishes before optional helpers start")
    func requiredASRLoadsFirst() async throws {
        let gate = Gate()
        let events = TestLockedBox<[String]>([])
        let coordinator = TranscriptionCoordinator(
            diarizerModelLoader: { _ in
                events.withLock { $0.append("diarizer") }
                throw TestError.failed
            },
            vadLoader: {
                events.withLock { $0.append("vad") }
                throw TestError.failed
            },
            requiredBackendLoader: { _ in
                events.withLock { $0.append("asr-start") }
                await gate.wait()
                events.withLock { $0.append("asr-ready") }
            }
        )

        let preload = Task {
            try await coordinator.preloadRequired(
                backend: .parakeetMultilingual,
                includeMeetingHelpers: true,
                meetingHelperTrigger: .meetingStart
            )
        }
        #expect(await waitUntil { events.withLock { $0 == ["asr-start"] } })
        await gate.release()
        try await preload.value
        #expect(await waitUntil {
            events.withLock { $0.contains("vad") && $0.contains("diarizer") }
        })

        let snapshot = events.withLock { $0 }
        let readyIndex = try #require(snapshot.firstIndex(of: "asr-ready"))
        let vadIndex = try #require(snapshot.firstIndex(of: "vad"))
        let diarizerIndex = try #require(snapshot.firstIndex(of: "diarizer"))
        #expect(readyIndex < vadIndex)
        #expect(readyIndex < diarizerIndex)
    }

    @Test("cancelled joiner leaves one shared diarizer load")
    func cancelledJoinerDoesNotCancelSharedLoad() async {
        let attempts = TestLockedBox(0)
        let gate = Gate()
        let coordinator = TranscriptionCoordinator(
            diarizerModelLoader: { _ in
                attempts.withLock { $0 += 1 }
                await gate.wait()
                throw TestError.failed
            }
        )

        let first = Task {
            await coordinator.preloadDiarizer(waitTimeout: .seconds(10))
        }
        #expect(await waitUntil {
            let state = await coordinator.helperPreloadStateForTesting()
            return attempts.withLock { $0 == 1 } && state.waiterCount == 1
        })
        let joined = Task {
            await coordinator.preloadDiarizer(waitTimeout: .seconds(10))
        }
        #expect(await waitUntil {
            await coordinator.helperPreloadStateForTesting().waiterCount == 2
        })

        joined.cancel()
        await joined.value
        #expect(await waitUntil {
            let state = await coordinator.helperPreloadStateForTesting()
            return state.diarizerLoading && state.waiterCount == 1
        })
        #expect(attempts.withLock { $0 } == 1)
        await gate.release()
        await first.value
        #expect(await waitUntil {
            !(await coordinator.helperPreloadStateForTesting().diarizerLoading)
        })
    }

    @Test("shared diarizer load has an operation deadline")
    func sharedLoadHasDeadline() async {
        let coordinator = TranscriptionCoordinator(
            diarizerModelLoader: { _ in
                try await Task.sleep(for: .seconds(10))
                throw TestError.failed
            },
            diarizerLoadOperationTimeout: .milliseconds(20)
        )

        await coordinator.preloadDiarizer(waitTimeout: .seconds(10))
        #expect(await waitUntil {
            !(await coordinator.helperPreloadStateForTesting().diarizerLoading)
        })
    }

    @Test("non-cooperative timed-out load detaches and allows retry")
    func nonCooperativeTimedOutLoadAllowsRetry() async {
        let attempts = TestLockedBox(0)
        let completions = TestLockedBox(0)
        let firstAttemptGate = Gate()
        let coordinator = TranscriptionCoordinator(
            diarizerModelLoader: { _ in
                let attempt = attempts.withLock {
                    $0 += 1
                    return $0
                }
                if attempt == 1 {
                    await firstAttemptGate.wait()
                }
                completions.withLock { $0 += 1 }
                throw TestError.failed
            },
            diarizerLoadOperationTimeout: .milliseconds(20)
        )

        await coordinator.preloadDiarizer(waitTimeout: .seconds(1))
        #expect(await waitUntil {
            let state = await coordinator.helperPreloadStateForTesting()
            return attempts.withLock { $0 == 1 } && !state.diarizerLoading
        })

        await coordinator.preloadDiarizer(waitTimeout: .seconds(1))
        #expect(await waitUntil {
            let state = await coordinator.helperPreloadStateForTesting()
            return attempts.withLock { $0 == 2 } && !state.diarizerLoading
        })

        await firstAttemptGate.release()
        #expect(await waitUntil {
            completions.withLock { $0 == 2 }
        })
        #expect(!(await coordinator.helperPreloadStateForTesting().diarizerLoading))
        #expect(attempts.withLock { $0 } == 2)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}
