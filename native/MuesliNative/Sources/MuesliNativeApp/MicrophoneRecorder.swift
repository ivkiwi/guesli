@preconcurrency import AVFoundation
import CoreAudio
import Foundation

final class MicrophoneRecorder: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    var preferredInputDeviceID: AudioObjectID?
    var keepsAudioGraphWarm = false
    var onFirstCapturedAudioBuffer: ((Date) -> Void)?
    var onFirstSpeechDetected: ((Date) -> Void)?
    var onNoAudioTimeout: ((Date) -> Void)?

    private static let sampleRate: Double = 16_000
    private static let speechThresholdDB: Float = -58
    private static let noAudioTimeout: TimeInterval = 1.5
    private static let firstBufferDelay: TimeInterval = 0.05
    private static let meterInterval: TimeInterval = 0.08

    private let lock = NSRecursiveLock()
    private let callbackQueue = DispatchQueue(label: "com.muesli.microphone-recorder-callbacks")
    private var recorder: AVAudioRecorder?
    private var preparedURL: URL?
    private var activeInputOverride: DefaultInputOverride?
    private var firstBufferWorkItem: DispatchWorkItem?
    private var noAudioTimeoutWorkItem: DispatchWorkItem?
    private var meterWorkItem: DispatchWorkItem?
    private var isRecording = false
    private var hasReceivedFirstAudioBuffer = false
    private var hasDetectedSpeech = false
    private var hasReportedNoAudioTimeout = false

    func prepare() throws {
        lock.lock()
        defer { lock.unlock() }

        guard recorder == nil else { return }
        try applyPreferredInputIfNeeded()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-native", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let nextRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        nextRecorder.delegate = self
        nextRecorder.isMeteringEnabled = true
        nextRecorder.prepareToRecord()
        preparedURL = fileURL
        recorder = nextRecorder
    }

    func warmUp(preferredInputDeviceID: AudioObjectID?) throws {
        lock.lock()
        defer { lock.unlock() }

        self.preferredInputDeviceID = preferredInputDeviceID
        guard recorder == nil, !isRecording else { return }
        try prepare()
        fputs("[mic-recorder] avrecorder warmed preferredInput=\(preferredInputDeviceID.map(String.init) ?? "default")\n", stderr)
    }

    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws {
        lock.lock()
        defer { lock.unlock() }

        self.preferredInputDeviceID = preferredInputDeviceID
        guard recorder == nil, !isRecording else { return }
        try prepare()
        fputs("[mic-recorder] avrecorder activated preferredInput=\(preferredInputDeviceID.map(String.init) ?? "default")\n", stderr)
    }

    func coolDown() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRecording else { return }
        cleanupPreparedRecording(removeFile: true)
        restorePreferredInputIfNeeded()
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isRecording else { return }
        try prepare()
        guard let recorder else {
            throw NSError(domain: "MicrophoneRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio recorder available",
            ])
        }
        resetCaptureState()
        guard recorder.record() else {
            throw NSError(domain: "MicrophoneRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Microphone recorder failed to start",
            ])
        }
        isRecording = true
        scheduleFirstBufferNotification()
        scheduleMeterPoll()
        scheduleNoAudioTimeout()
    }

    func stop() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        guard let recorder else {
            restorePreferredInputIfNeeded()
            return nil
        }
        cancelTimers()
        isRecording = false
        recorder.stop()
        let url = preparedURL
        self.recorder = nil
        preparedURL = nil
        restorePreferredInputIfNeeded()
        return url
    }

    func pause() {
        lock.lock()
        defer { lock.unlock() }
        recorder?.pause()
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording else { return }
        recorder?.record()
    }

    func currentPower() -> Float {
        lock.lock()
        defer { lock.unlock() }
        recorder?.updateMeters()
        return recorder?.averagePower(forChannel: 0) ?? -160
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }

        cancelTimers()
        isRecording = false
        cleanupPreparedRecording(removeFile: true)
        restorePreferredInputIfNeeded()
    }

    private func applyPreferredInputIfNeeded() throws {
        guard let preferredInputDeviceID else { return }
        if activeInputOverride?.preferredDeviceID == preferredInputDeviceID { return }
        restorePreferredInputIfNeeded()
        activeInputOverride = try DefaultInputOverride(preferredDeviceID: preferredInputDeviceID)
    }

    private func restorePreferredInputIfNeeded() {
        activeInputOverride?.restore()
        activeInputOverride = nil
    }

    private func cleanupPreparedRecording(removeFile: Bool) {
        recorder?.stop()
        recorder = nil
        if removeFile, let preparedURL {
            try? FileManager.default.removeItem(at: preparedURL)
        }
        preparedURL = nil
    }

    private func resetCaptureState() {
        hasReceivedFirstAudioBuffer = false
        hasDetectedSpeech = false
        hasReportedNoAudioTimeout = false
    }

    private func scheduleFirstBufferNotification() {
        firstBufferWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.notifyFirstBufferIfNeeded()
        }
        firstBufferWorkItem = workItem
        callbackQueue.asyncAfter(deadline: .now() + Self.firstBufferDelay, execute: workItem)
    }

    private func notifyFirstBufferIfNeeded() {
        lock.lock()
        guard isRecording, !hasReceivedFirstAudioBuffer else {
            lock.unlock()
            return
        }
        hasReceivedFirstAudioBuffer = true
        lock.unlock()
        onFirstCapturedAudioBuffer?(Date())
    }

    private func scheduleMeterPoll() {
        meterWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pollMeter()
        }
        meterWorkItem = workItem
        callbackQueue.asyncAfter(deadline: .now() + Self.meterInterval, execute: workItem)
    }

    private func pollMeter() {
        lock.lock()
        guard isRecording, let recorder else {
            lock.unlock()
            return
        }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let shouldNotifySpeech = !hasDetectedSpeech && power >= Self.speechThresholdDB
        if shouldNotifySpeech {
            hasDetectedSpeech = true
        }
        lock.unlock()

        if shouldNotifySpeech {
            onFirstSpeechDetected?(Date())
        }
        scheduleMeterPoll()
    }

    private func scheduleNoAudioTimeout() {
        noAudioTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.notifyNoAudioTimeoutIfNeeded()
        }
        noAudioTimeoutWorkItem = workItem
        callbackQueue.asyncAfter(deadline: .now() + Self.noAudioTimeout, execute: workItem)
    }

    private func notifyNoAudioTimeoutIfNeeded() {
        lock.lock()
        guard isRecording, !hasDetectedSpeech, !hasReportedNoAudioTimeout else {
            lock.unlock()
            return
        }
        hasReportedNoAudioTimeout = true
        lock.unlock()
        onNoAudioTimeout?(Date())
    }

    private func cancelTimers() {
        firstBufferWorkItem?.cancel()
        firstBufferWorkItem = nil
        noAudioTimeoutWorkItem?.cancel()
        noAudioTimeoutWorkItem = nil
        meterWorkItem?.cancel()
        meterWorkItem = nil
    }
}

private final class DefaultInputOverride {
    let preferredDeviceID: AudioObjectID
    private let previousDeviceID: AudioObjectID?
    private var didApply = false

    init(preferredDeviceID: AudioObjectID) throws {
        self.preferredDeviceID = preferredDeviceID
        self.previousDeviceID = Self.defaultInputDeviceID()
        guard previousDeviceID != preferredDeviceID else { return }
        guard Self.setDefaultInputDeviceID(preferredDeviceID) else {
            throw NSError(domain: "MicrophoneRecorder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not select preferred microphone",
            ])
        }
        didApply = true
        fputs("[mic-recorder] selected default input \(preferredDeviceID) previous=\(previousDeviceID.map(String.init) ?? "unknown")\n", stderr)
    }

    func restore() {
        guard didApply, let previousDeviceID else { return }
        if Self.setDefaultInputDeviceID(previousDeviceID) {
            fputs("[mic-recorder] restored default input \(previousDeviceID)\n", stderr)
        }
        didApply = false
    }

    private static func defaultInputDeviceID() -> AudioObjectID? {
        var address = defaultInputAddress()
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return deviceID
    }

    private static func setDefaultInputDeviceID(_ deviceID: AudioObjectID) -> Bool {
        var address = defaultInputAddress()
        var mutableDeviceID = deviceID
        let dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &mutableDeviceID
        ) == noErr
    }

    private static func defaultInputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
