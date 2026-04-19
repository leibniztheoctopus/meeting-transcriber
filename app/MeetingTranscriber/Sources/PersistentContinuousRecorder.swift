import AudioTapLib
import AVFoundation
import Darwin
import Foundation
import os.log

private let persistentLogger = Logger(subsystem: AppPaths.logSubsystem, category: "PersistentContinuousRecorder")

private func persistentMachTicksToSeconds(_ ticks: UInt64) -> Double {
    if ticks == 0 { return 0 }
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let nanos = ticks * UInt64(info.numer) / UInt64(info.denom)
    return Double(nanos) / 1_000_000_000
}

@available(macOS 14.2, *)
@MainActor
final class PersistentContinuousRecorder {
    struct ChunkResult {
        let title: String
        let recording: RecordingResult
    }

    private let recordRate = 48000
    private let targetRate = AudioConstants.targetSampleRate
    private let appChannels = 2

    private let captureMode: ContinuousCaptureMode
    private let noMic: Bool
    private let micDeviceUID: String?

    @available(macOS 14.2, *)
    private var appCapture: AppAudioCapture?
    @available(macOS 14.2, *)
    private var micCapture: MicCaptureHandler?

    private var appFileHandle: FileHandle?
    private var activeTimestamp: String?
    private var chunkStartUptime: TimeInterval = 0
    private var activeAppTempURL: URL?
    private var activeMicURL: URL?
    private var currentActualRate: Int = 0
    private var currentActualChannels: Int = 0
    private(set) var isRecording = false

    init(captureMode: ContinuousCaptureMode, noMic: Bool, micDeviceUID: String?) {
        self.captureMode = captureMode
        self.noMic = noMic
        self.micDeviceUID = micDeviceUID
    }

    func start() throws {
        guard !isRecording else { return }

        try FileManager.default.createDirectory(at: AppPaths.recordingsDir, withIntermediateDirectories: true)
        try beginNewChunkFiles()

        let target: AppAudioCapture.CaptureTarget = captureMode == .global ? .global : .defaultOutput
        let capture = AppAudioCapture(
            target: target,
            outputFileDescriptor: appFileHandle!.fileDescriptor,
            sampleRate: recordRate,
            channels: appChannels,
        )
        try capture.start()
        appCapture = capture
        currentActualRate = capture.actualSampleRate
        currentActualChannels = capture.actualChannels

        if let micURL = activeMicURL {
            let mic = MicCaptureHandler(outputURL: micURL)
            do {
                try mic.start(deviceUID: micDeviceUID)
                micCapture = mic
            } catch {
                persistentLogger.error("Failed to start persistent mic capture: \(error.localizedDescription)")
                AppFileLogger.shared.log("persistent mic start failed: \(error.localizedDescription)")
            }
        }

        isRecording = true
        persistentLogger.info("Persistent continuous capture started")
        AppFileLogger.shared.log("persistent continuous capture started")
    }

    func rotateChunk(title: String) throws -> ChunkResult {
        guard isRecording else { throw RecorderError.notRecording }
        guard let appCapture else { throw RecorderError.noAudioData }

        persistentLogger.info("Rotating persistent chunk: \(title)")
        AppFileLogger.shared.log("rotating persistent chunk: \(title)")

        let finishedTimestamp = activeTimestamp ?? Self.timestamp()
        let finishedAppURL = activeAppTempURL
        let finishedMicURL = activeMicURL
        let recordingStart = chunkStartUptime

        try? appFileHandle?.synchronize()
        try? appFileHandle?.close()
        appFileHandle = nil

        micCapture?.stop()
        let micFirstFrame = micCapture?.firstFrameTime ?? 0
        let appFirstFrame = appCapture.appFirstFrameTime
        let micDelay: TimeInterval = if appFirstFrame > 0, micFirstFrame > 0 {
            persistentMachTicksToSeconds(micFirstFrame) - persistentMachTicksToSeconds(appFirstFrame)
        } else {
            0
        }

        let actualRate = appCapture.actualSampleRate > 0 ? appCapture.actualSampleRate : recordRate
        let actualChannels = appCapture.actualChannels > 0 ? appCapture.actualChannels : max(currentActualChannels, 1)
        currentActualRate = actualRate
        currentActualChannels = actualChannels

        try beginNewChunkFiles()
        try appCapture.updateOutputFileDescriptor(appFileHandle!.fileDescriptor)

        if let micURL = activeMicURL {
            let mic = MicCaptureHandler(outputURL: micURL)
            do {
                try mic.start(deviceUID: micDeviceUID)
                micCapture = mic
            } catch {
                micCapture = nil
                persistentLogger.error("Failed restarting persistent mic capture after rotate: \(error.localizedDescription)")
                AppFileLogger.shared.log("persistent mic restart failed after rotate: \(error.localizedDescription)")
            }
        } else {
            micCapture = nil
        }

        guard let finishedAppURL else { throw RecorderError.noAudioData }

        let recording = try finalizeChunk(
            timestamp: finishedTimestamp,
            appTempURL: finishedAppURL,
            micURL: finishedMicURL,
            actualRate: actualRate,
            actualChannels: actualChannels,
            micDelay: micDelay,
            recordingStart: recordingStart,
        )

        return ChunkResult(title: title, recording: recording)
    }

    func stop(finalTitle: String?) throws -> ChunkResult? {
        guard isRecording else { return nil }
        guard let appCapture else { throw RecorderError.noAudioData }

        persistentLogger.info("Stopping persistent continuous capture")
        AppFileLogger.shared.log("stopping persistent continuous capture")

        let title = finalTitle ?? "Continuous Capture"
        let finishedTimestamp = activeTimestamp ?? Self.timestamp()
        let finishedAppURL = activeAppTempURL
        let finishedMicURL = activeMicURL
        let recordingStart = chunkStartUptime

        try? appFileHandle?.synchronize()
        try? appFileHandle?.close()
        appFileHandle = nil

        micCapture?.stop()
        let micFirstFrame = micCapture?.firstFrameTime ?? 0
        let appFirstFrame = appCapture.appFirstFrameTime
        let micDelay: TimeInterval = if appFirstFrame > 0, micFirstFrame > 0 {
            persistentMachTicksToSeconds(micFirstFrame) - persistentMachTicksToSeconds(appFirstFrame)
        } else {
            0
        }

        appCapture.stop()
        self.appCapture = nil
        self.micCapture = nil
        isRecording = false

        let actualRate = appCapture.actualSampleRate > 0 ? appCapture.actualSampleRate : recordRate
        let actualChannels = appCapture.actualChannels > 0 ? appCapture.actualChannels : max(currentActualChannels, 1)

        guard let finishedAppURL else { return nil }

        let recording = try finalizeChunk(
            timestamp: finishedTimestamp,
            appTempURL: finishedAppURL,
            micURL: finishedMicURL,
            actualRate: actualRate,
            actualChannels: actualChannels,
            micDelay: micDelay,
            recordingStart: recordingStart,
        )
        return ChunkResult(title: title, recording: recording)
    }

    private func beginNewChunkFiles() throws {
        let ts = Self.timestamp()
        activeTimestamp = ts
        chunkStartUptime = ProcessInfo.processInfo.systemUptime

        let appURL = AppPaths.recordingsDir.appendingPathComponent("\(ts)_app_raw.tmp")
        FileManager.default.createFile(atPath: appURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        appFileHandle = try FileHandle(forWritingTo: appURL)
        activeAppTempURL = appURL

        if noMic {
            activeMicURL = nil
        } else {
            activeMicURL = AppPaths.recordingsDir.appendingPathComponent("\(ts)_mic.wav")
        }

        AppFileLogger.shared.log("persistent chunk files opened: ts=\(ts)")
    }

    private func finalizeChunk(
        timestamp: String,
        appTempURL: URL,
        micURL: URL?,
        actualRate: Int,
        actualChannels: Int,
        micDelay: TimeInterval,
        recordingStart: TimeInterval,
    ) throws -> RecordingResult {
        let appRawBytes = (try? FileManager.default.attributesOfItem(atPath: appTempURL.path)[.size] as? Int) ?? 0
        AppFileLogger.shared.log("finalizing chunk: ts=\(timestamp) appBytes=\(appRawBytes)")

        let micDuration: Double? = if let micURL,
                                      let micFile = try? AVAudioFile(forReading: micURL),
                                      micFile.processingFormat.sampleRate > 0 {
            Double(micFile.length) / micFile.processingFormat.sampleRate
        } else {
            nil
        }

        let correctedRate = DualSourceRecorder.crossCheckAppRate(
            deviceRate: actualRate,
            appRawBytes: appRawBytes,
            appChannels: actualChannels,
            micDurationSeconds: micDuration,
            micDelay: micDelay,
        )

        var appPath: URL?
        var appSamples16k: [Float] = []
        if appRawBytes > 0 {
            let raw = try Data(contentsOf: appTempURL)
            try? FileManager.default.removeItem(at: appTempURL)

            let floatCount = raw.count / MemoryLayout<Float>.size
            var floats = [Float](repeating: 0, count: floatCount)
            raw.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    floats.withUnsafeMutableBufferPointer { dest in
                        dest.baseAddress!.initialize(from: base.assumingMemoryBound(to: Float.self), count: floatCount)
                    }
                }
            }

            let mono = DualSourceRecorder.downmixToMono(floats, channels: actualChannels)
            appSamples16k = AudioMixer.resample(mono, from: correctedRate, to: targetRate)
            let appFile = AppPaths.recordingsDir.appendingPathComponent("\(timestamp)_app.wav")
            try AudioMixer.saveWAV(samples: appSamples16k, sampleRate: targetRate, url: appFile)
            appPath = appFile
        } else if FileManager.default.fileExists(atPath: appTempURL.path) {
            try? FileManager.default.removeItem(at: appTempURL)
        }

        var micPath: URL?
        var micSamples: [Float] = []
        if let micURL,
           FileManager.default.fileExists(atPath: micURL.path),
           (try? FileManager.default.attributesOfItem(atPath: micURL.path)[.size] as? Int) ?? 0 > 44 {
            micSamples = try AudioMixer.loadAudioFileAsFloat32(url: micURL)
            micPath = micURL
        }

        let mixPath = AppPaths.recordingsDir.appendingPathComponent("\(timestamp)_mix.wav")
        if let app = appPath, let mic = micPath {
            try AudioMixer.mix(
                appAudioPath: app,
                micAudioPath: mic,
                outputPath: mixPath,
                micDelay: micDelay,
                sampleRate: targetRate,
            )
        } else if !appSamples16k.isEmpty {
            try AudioMixer.saveWAV(samples: appSamples16k, sampleRate: targetRate, url: mixPath)
        } else if !micSamples.isEmpty {
            try AudioMixer.saveWAV(samples: micSamples, sampleRate: targetRate, url: mixPath)
        } else {
            throw RecorderError.noAudioData
        }

        return RecordingResult(
            mixPath: mixPath,
            appPath: appPath,
            micPath: micPath,
            micDelay: micDelay,
            recordingStart: recordingStart,
        )
    }

    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return fmt
    }()

    private static func timestamp() -> String {
        "\(timestampFormatter.string(from: Date()))_\(UUID().uuidString.prefix(8))"
    }
}
