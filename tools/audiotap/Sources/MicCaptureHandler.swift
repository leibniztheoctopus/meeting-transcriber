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
        try? handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}

private let logger = Logger(subsystem: "com.meetingtranscriber.audiotap", category: "MicCapture")

/// Records microphone audio to a WAV file via AVAudioEngine.
/// Monitors for device changes via CoreAudio property listener (default input device)
/// and AVAudioEngine configuration change notification (format/route changes).
/// Automatically restarts the engine on device switch, preserving the selected device
/// when still available or falling back to system default with a warning.
public class MicCaptureHandler {
    private var engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private let outputURL: URL
    private var isRecording = false
    private var isRestarting = false
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var configChangeObserver: NSObjectProtocol?
    private var selectedDeviceUID: String?
    private var fileSampleRate: Double = 0
    private var converter: AVAudioConverter?
    /// Pre-computed resampling ratio (fileSampleRate / tapSampleRate), avoids division in audio callback.
    private var resampleRatio: Double = 1.0
    public private(set) var firstFrameTime: UInt64 = 0
    private var callbackCount: Int = 0
    private var lastLevelLogTime: TimeInterval = 0

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

    public func start(deviceUID: String? = nil) throws {
        selectedDeviceUID = deviceUID
        micDebugLog("start requested: output=\(outputURL.lastPathComponent) selectedUID=\(deviceUID ?? "default")")
        try startEngine(deviceUID: deviceUID)
        installDeviceChangeListener()
        installConfigChangeObserver()
    }

    // swiftlint:disable:next function_body_length
    private func startEngine(deviceUID: String? = nil) throws {
        // No input device available (e.g. Mac Mini server without mic hardware) —
        // accessing AVAudioEngine.inputNode would throw an uncatchable NSException.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw MicCaptureError.noInputDevice
        }

        let inputNode = engine.inputNode
        callbackCount = 0
        lastLevelLogTime = 0

        if let uid = deviceUID {
            var deviceID = Self.deviceIDForUID(uid)
            if deviceID != kAudioObjectUnknown {
                let audioUnit = inputNode.audioUnit! // swiftlint:disable:this force_unwrapping
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size),
                )
                logger.info("Mic device set: \(uid) (ID \(deviceID))")
                micDebugLog("device set explicitly: uid=\(uid) id=\(deviceID)")
            } else {
                logger.warning("Unknown mic device UID '\(uid)', using default")
                micDebugLog("unknown selected mic uid, falling back to default: \(uid)")
            }
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Mic hardware format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount)ch")
        micDebugLog("hardware format: rate=\(hwFormat.sampleRate) channels=\(hwFormat.channelCount)")

        let tapFormat = AVAudioFormat(
            standardFormatWithSampleRate: hwFormat.sampleRate, channels: 1,
        )! // swiftlint:disable:this force_unwrapping
        logger.info("Mic tap format: \(tapFormat.sampleRate) Hz, \(tapFormat.channelCount)ch")
        micDebugLog("tap format: rate=\(tapFormat.sampleRate) channels=\(tapFormat.channelCount)")

        // Always 16kHz — WhisperKit target rate
        if outputFile == nil {
            fileSampleRate = speechSampleRate
            let wavSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: fileSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            outputFile = try AVAudioFile(forWriting: outputURL, settings: wavSettings)
            // Restrict permissions to owner-only (0600) — audio may contain sensitive meeting content
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outputURL.path,
            )
        }

        converter = nil
        resampleRatio = 1.0
        if tapFormat.sampleRate != fileSampleRate {
            let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: fileSampleRate, channels: 1,
            )! // swiftlint:disable:this force_unwrapping
            converter = AVAudioConverter(from: tapFormat, to: outputFormat)
            resampleRatio = fileSampleRate / tapFormat.sampleRate
            logger.info("Mic: resampling \(Int(tapFormat.sampleRate))→\(Int(self.fileSampleRate)) Hz")
            micDebugLog("resampling enabled: \(Int(tapFormat.sampleRate))->\(Int(self.fileSampleRate))")
        }

        // swiftlint:disable closure_parameter_position closure_body_length
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) {
            [weak self] buffer, _ in
            // swiftlint:enable closure_parameter_position closure_body_length
            guard let self else { return }
            if self.firstFrameTime == 0 {
                self.firstFrameTime = mach_absolute_time()
                micDebugLog("first mic frame received")
            }
            self.callbackCount += 1
            if let channelData = buffer.floatChannelData {
                let samples = UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength))
                var sumSq: Float = 0
                var peak: Float = 0
                for sample in samples {
                    let absSample = abs(sample)
                    sumSq += sample * sample
                    if absSample > peak { peak = absSample }
                }
                let rms = samples.isEmpty ? 0 : sqrt(sumSq / Float(samples.count))
                let now = Date().timeIntervalSince1970
                if self.callbackCount <= 5 || now - self.lastLevelLogTime >= 2 {
                    self.lastLevelLogTime = now
                    micDebugLog("callback=\(self.callbackCount) frames=\(buffer.frameLength) rms=\(rms) peak=\(peak)")
                }
            } else if self.callbackCount <= 5 {
                micDebugLog("callback=\(self.callbackCount) has no floatChannelData")
            }
            do {
                if let converter = self.converter {
                    let outputFrames = AVAudioFrameCount(
                        Double(buffer.frameLength) * self.resampleRatio,
                    )
                    guard let outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: converter.outputFormat,
                        frameCapacity: outputFrames,
                    ) else { return }
                    var error: NSError?
                    var consumed = false
                    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                        if consumed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        consumed = true
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if let error {
                        logger.warning("Mic resample error: \(error)")
                        micDebugLog("resample error: \(error.localizedDescription)")
                    } else {
                        try self.outputFile?.write(from: outputBuffer)
                        if self.callbackCount <= 3 { micDebugLog("wrote resampled mic buffer: frames=\(outputBuffer.frameLength)") }
                    }
                } else {
                    try self.outputFile?.write(from: buffer)
                    if self.callbackCount <= 3 { micDebugLog("wrote native mic buffer: frames=\(buffer.frameLength)") }
                }
            } catch {
                logger.warning("Mic write error: \(error)")
                micDebugLog("write error: \(error.localizedDescription)")
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        logger.info("Mic recording started: \(self.outputURL.lastPathComponent)")
        micDebugLog("engine started: output=\(self.outputURL.lastPathComponent)")
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

    /// Listen for AVAudioEngine configuration changes (format changes on current device).
    private func installConfigChangeObserver() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main,
        ) { [weak self] _ in
            self?.handleEngineConfigChange()
        }
        logger.info("Mic: listening for engine configuration changes")
        micDebugLog("installed engine configuration observer")
    }

    private func handleEngineConfigChange() {
        logger.info("Mic: engine configuration changed (format/route change)")
        micDebugLog("engine configuration changed")
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

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        // AVAudioEngine can be in a bad state after config change — must recreate
        engine = AVAudioEngine()

        do {
            try startEngine(deviceUID: deviceUID)
            let hwRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
            if hwRate <= 0 {
                logger.warning("Mic: hardware format rate is \(hwRate) after restart — may produce incorrect audio")
            }
            installConfigChangeObserver()
            logger.info("Mic: engine restarted on \(deviceUID != nil ? "selected" : "default") device (\(Int(hwRate)) Hz)")
            micDebugLog("engine restarted on \(deviceUID != nil ? "selected" : "default") device, rate=\(Int(hwRate))")
        } catch {
            isRecording = false
            logger.error("Failed to restart mic after device change: \(error)")
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        outputFile = nil
        logger.info("Mic recording stopped")
        micDebugLog("recording stopped: callbacks=\(callbackCount)")
    }
}

public enum MicCaptureError: LocalizedError {
    case noInputDevice

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone hardware available"
        }
    }
}
