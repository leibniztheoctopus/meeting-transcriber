import AVFoundation
import CoreAudio
import Foundation
import os.log

private func micDebugLog(_ message: String) {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("MeetingTranscriber", isDirectory: true)
    guard let dir = base else { return }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let logURL = dir.appendingPathComponent("meetingtranscriber-debug.log")
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] [MicCapture] \(message)\n"
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

public class MicCaptureHandler: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let outputURL: URL
    private var isRecording = false
    private var isRestarting = false
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var configChangeObserver: NSObjectProtocol?
    private var selectedDeviceUID: String?
    public private(set) var firstFrameTime: UInt64 = 0
    private var callbackCount: Int = 0
    private var lastLevelLogTime: TimeInterval = 0

    private var session: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let callbackQueue = DispatchQueue(label: "com.meetingtranscriber.miccapture")
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?

    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )

    public init(outputURL: URL) {
        self.outputURL = outputURL
    }

    deinit {
        stop()
    }

    private static func deviceIDForUID(_ uid: String) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID: Unmanaged<CFString>? = Unmanaged.passUnretained(uid as CFString)
        let qualifierSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, qualifierSize, &cfUID,
            &size, &deviceID,
        )
        return deviceID
    }

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            &size, &deviceID,
        )
        return status == noErr ? deviceID : kAudioObjectUnknown
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let unmanaged else { return nil }
        return unmanaged.takeUnretainedValue() as String
    }

    public func start(deviceUID: String? = nil) throws {
        selectedDeviceUID = deviceUID
        micDebugLog("start requested: output=\(outputURL.lastPathComponent) selectedUID=\(deviceUID ?? "default")")
        try startEngine(deviceUID: deviceUID)
        installDeviceChangeListener()
        installConfigChangeObserver()
    }

    private func startEngine(deviceUID: String? = nil) throws {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw MicCaptureError.noInputDevice
        }

        callbackCount = 0
        lastLevelLogTime = 0
        firstFrameTime = 0

        let defaultDeviceID = Self.defaultInputDeviceID()
        if defaultDeviceID != kAudioObjectUnknown {
            let defaultUID = Self.stringProperty(deviceID: defaultDeviceID, selector: kAudioDevicePropertyDeviceUID) ?? "unknown"
            let defaultName = Self.stringProperty(deviceID: defaultDeviceID, selector: kAudioObjectPropertyName) ?? "unknown"
            micDebugLog("default input device: name=\(defaultName) uid=\(defaultUID) id=\(defaultDeviceID)")
        }

        let device = if let uid = deviceUID,
                        let found = AVCaptureDevice.devices(for: .audio).first(where: { $0.uniqueID == uid || $0.localizedName == uid }) {
            found
        } else {
            AVCaptureDevice.default(for: .audio)!
        }

        micDebugLog("capture device: localizedName=\(device.localizedName) uniqueID=\(device.uniqueID)")

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw MicCaptureError.sessionConfigurationFailed
        }
        captureSession.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: callbackQueue)
        guard captureSession.canAddOutput(output) else {
            throw MicCaptureError.sessionConfigurationFailed
        }
        captureSession.addOutput(output)
        captureSession.commitConfiguration()

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: speechSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(writerInput) else {
            throw MicCaptureError.sessionConfigurationFailed
        }
        writer.add(writerInput)

        assetWriter = writer
        self.writerInput = writerInput
        session = captureSession
        audioOutput = output

        captureSession.startRunning()
        isRecording = true
        logger.info("Mic recording started: \(self.outputURL.lastPathComponent)")
        micDebugLog("capture session started: output=\(self.outputURL.lastPathComponent)")
    }

    private func installDeviceChangeListener() {
        guard deviceChangeListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultInputDeviceChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            DispatchQueue.main,
            listener,
        )
        if status == noErr {
            deviceChangeListener = listener
            logger.info("Mic: listening for default input device changes")
            micDebugLog("installed default input device listener")
        } else {
            logger.warning("Failed to install device change listener (status: \(status))")
            micDebugLog("failed to install device change listener: status=\(status)")
        }
    }

    private func installConfigChangeObserver() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            self?.handleEngineConfigChange()
        }
        logger.info("Mic: listening for capture device changes")
        micDebugLog("installed capture device observer")
    }

    private func handleEngineConfigChange() {
        logger.info("Mic: capture configuration changed")
        micDebugLog("capture configuration changed")
        handleDeviceChange()
    }

    private func handleDefaultInputDeviceChanged() {
        logger.info("Mic: default input device changed")
        micDebugLog("default input device changed")
        handleDeviceChange()
    }

    private func handleDeviceChange() {
        let isDeviceAvailable = selectedDeviceUID.map { Self.deviceIDForUID($0) != kAudioObjectUnknown } ?? false
        let action = MicRestartPolicy.decideRestart(
            isRecording: isRecording,
            isRestarting: isRestarting,
            selectedDeviceUID: selectedDeviceUID,
            isSelectedDeviceAvailable: isDeviceAvailable,
        )

        switch action {
        case let .restart(deviceUID):
            executeRestart(deviceUID: deviceUID)
        case .skip:
            break
        }
    }

    private func executeRestart(deviceUID: String?) {
        isRestarting = true
        defer { isRestarting = false }

        if deviceUID == nil, let uid = selectedDeviceUID {
            logger.warning("Mic: selected device '\(uid)' no longer available, falling back to system default")
            micDebugLog("selected device unavailable, falling back to default: \(uid)")
        }

        stop()
        do {
            try start(deviceUID: deviceUID)
            logger.info("Mic: capture session restarted on \(deviceUID != nil ? "selected" : "default") device")
            micDebugLog("capture session restarted on \(deviceUID != nil ? "selected" : "default") device")
        } catch {
            isRecording = false
            logger.error("Failed to restart mic after device change: \(error.localizedDescription)")
            micDebugLog("failed to restart mic after device change: \(error.localizedDescription)")
        }
    }

    public func stop() {
        isRecording = false
        if let listener = deviceChangeListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultInputAddress,
                DispatchQueue.main,
                listener,
            )
            deviceChangeListener = nil
        }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        if let writerInput { writerInput.markAsFinished() }
        if let assetWriter, assetWriter.status == .writing {
            let semaphore = DispatchSemaphore(value: 0)
            assetWriter.finishWriting { semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 2)
        }
        session = nil
        audioOutput = nil
        assetWriter = nil
        writerInput = nil
        logger.info("Mic recording stopped")
        micDebugLog("recording stopped: callbacks=\(callbackCount)")
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection,
    ) {
        if firstFrameTime == 0 {
            firstFrameTime = mach_absolute_time()
            micDebugLog("first mic frame received")
        }
        callbackCount += 1

        if let desc = CMSampleBufferGetFormatDescription(sampleBuffer), callbackCount == 1,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            micDebugLog("sample buffer format: rate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) formatID=\(asbd.mFormatID)")
        }

        var rms: Float = 0
        var peak: Float = 0
        if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { ptr in
                if let base = ptr.baseAddress {
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
                }
            }
            let sampleCount = length / MemoryLayout<Int16>.size
            if sampleCount > 0 {
                data.withUnsafeBytes { raw in
                    let samples = raw.bindMemory(to: Int16.self)
                    var sumSq: Float = 0
                    var peakValue: Float = 0
                    for sample in samples {
                        let normalized = Float(sample) / Float(Int16.max)
                        let absSample = abs(normalized)
                        sumSq += normalized * normalized
                        if absSample > peakValue { peakValue = absSample }
                    }
                    rms = sqrt(sumSq / Float(samples.count))
                    peak = peakValue
                }
            }
            let now = Date().timeIntervalSince1970
            if callbackCount <= 5 || now - lastLevelLogTime >= 2 {
                lastLevelLogTime = now
                micDebugLog("callback=\(callbackCount) bytes=\(length) rms=\(rms) peak=\(peak)")
            }
        }

        guard let assetWriter, let writerInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if assetWriter.status == .unknown {
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: pts)
            micDebugLog("asset writer session started")
        }
        if writerInput.isReadyForMoreMediaData {
            if !writerInput.append(sampleBuffer) {
                micDebugLog("writer append failed: \(assetWriter.error?.localizedDescription ?? "unknown")")
            }
        }
    }
}

public enum MicCaptureError: LocalizedError {
    case noInputDevice
    case sessionConfigurationFailed

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone hardware available"
        case .sessionConfigurationFailed: "Failed to configure microphone capture session"
        }
    }
}
