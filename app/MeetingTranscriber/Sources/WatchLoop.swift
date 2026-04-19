import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// Info about a manually started recording session.
struct ManualRecordingInfo {
    let pid: pid_t
    let appName: String
    let title: String
}

/// Native Swift watch loop that replaces the Python watcher.
///
/// Orchestrates: meeting detection → recording → enqueue to PipelineQueue.
@MainActor
@Observable
class WatchLoop {
    enum Mode {
        case meetingTriggered
        case continuous
    }

    enum State: String {
        case idle
        case watching
        case recording
        case paused
        case error
    }

    private(set) var state: State = .idle
    private(set) var currentMeeting: DetectedMeeting?
    private(set) var lastError: String?
    private(set) var detail: String = ""
    private(set) var mode: Mode

    // Manual recording
    private(set) var manualRecordingInfo: ManualRecordingInfo?
    private var activeRecorder: RecordingProvider?
    private var manualRecordingTask: Task<Void, Never>?
    private var continuousTask: Task<Void, Never>?
    private var activeContinuousRecorder: RecordingProvider?
    private var activeContinuousTitle: String?

    var isManualRecording: Bool {
        manualRecordingInfo != nil
    }

    // Dependencies
    let detector: MeetingDetecting
    let recorderFactory: @MainActor () -> RecordingProvider
    var pipelineQueue: PipelineQueue?
    var permissionChecker: () async -> HealthCheckResult = { await PermissionHealthCheck.runLive() }

    // Settings
    let pollInterval: TimeInterval
    let endGracePeriod: TimeInterval
    let maxDuration: TimeInterval
    let noMic: Bool
    let micDeviceUID: String?
    let continuousChunkDuration: TimeInterval
    let continuousCaptureMode: ContinuousCaptureMode

    private var watchTask: Task<Void, Never>?

    /// Hook called when state changes (for UI updates, notifications, etc.)
    var onStateChange: ((State, State) -> Void)?

    init(
        detector: MeetingDetecting = WatchLoop.defaultDetector(),
        recorderFactory: @MainActor @escaping () -> RecordingProvider = { DualSourceRecorder() },
        pipelineQueue: PipelineQueue? = nil,
        pollInterval: TimeInterval = 3.0,
        endGracePeriod: TimeInterval = 15.0,
        maxDuration: TimeInterval = 14400,
        noMic: Bool = false,
        micDeviceUID: String? = nil,
        mode: Mode = .meetingTriggered,
        continuousChunkDuration: TimeInterval = 300,
        continuousCaptureMode: ContinuousCaptureMode = .global,
    ) {
        self.detector = detector
        self.recorderFactory = recorderFactory
        self.pipelineQueue = pipelineQueue
        self.pollInterval = pollInterval
        self.endGracePeriod = endGracePeriod
        self.maxDuration = maxDuration
        self.noMic = noMic
        self.micDeviceUID = micDeviceUID
        self.mode = mode
        self.continuousChunkDuration = continuousChunkDuration
        self.continuousCaptureMode = continuousCaptureMode
    }

    nonisolated static var defaultOutputDir: URL {
        AppPaths.downloadsProtocolsDir
    }

    nonisolated static func defaultDetector() -> MeetingDetecting {
        PowerAssertionDetector()
    }

    var isActive: Bool {
        state != .idle
    }

    // MARK: - Start / Stop

    func start() {
        guard watchTask == nil, continuousTask == nil else { return }

        transition(to: .watching)
        detail = mode == .continuous ? "Listening continuously..." : "Listening for conversations..."
        logger.info("Listen mode started (mode: \(self.mode == .continuous ? "continuous" : "meeting"), poll: \(self.pollInterval)s, grace: \(self.endGracePeriod)s)")

        if mode == .continuous {
            continuousTask = Task { [weak self] in
                guard let self else { return }
                await self.continuousLoop()
            }
        } else {
            watchTask = Task { [weak self] in
                guard let self else { return }
                await self.watchLoop()
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        continuousTask?.cancel()
        continuousTask = nil
        currentMeeting = nil

        if mode == .continuous {
            finalizeActiveContinuousRecorderIfNeeded(reason: "stop")
        }

        cleanupManualRecording()
        transition(to: .idle)
        detail = ""
        logger.info("Listen mode stopped")
    }

    func pause() {
        guard mode == .continuous, state != .paused else { return }
        continuousTask?.cancel()
        continuousTask = nil
        finalizeActiveContinuousRecorderIfNeeded(reason: "pause")
        activeRecorder = nil
        transition(to: .paused)
        detail = "Listening paused"
        logger.info("Continuous listening paused")
    }

    func resume() {
        guard mode == .continuous, state == .paused, continuousTask == nil else { return }
        transition(to: .watching)
        detail = "Listening continuously..."
        continuousTask = Task { [weak self] in
            guard let self else { return }
            await self.continuousLoop()
        }
        logger.info("Continuous listening resumed")
    }

    // MARK: - Manual Recording

    func startManualRecording(pid: pid_t, appName: String, title: String) async throws {
        guard state != .recording else {
            logger.warning("Cannot start manual recording — already recording")
            return
        }

        let health = await permissionChecker()
        if !health.isHealthy {
            throw RecorderError.permissionDenied(health.notificationBody)
        }

        // Stop auto-watch if active
        watchTask?.cancel()
        watchTask = nil

        let recorder = recorderFactory()
        try recorder.start(appPID: pid, noMic: noMic, micDeviceUID: micDeviceUID)

        activeRecorder = recorder
        manualRecordingInfo = ManualRecordingInfo(pid: pid, appName: appName, title: title)
        transition(to: .recording)
        detail = "Recording: \(title)"

        manualRecordingTask = Task { [weak self] in
            guard let self else { return }
            await self.monitorManualRecording(pid: pid)
        }

        logger.info("Manual recording started for \(appName) (PID \(pid)): \(title)")
    }

    func stopManualRecording() {
        guard let recorder = activeRecorder, let info = manualRecordingInfo else { return }

        manualRecordingTask?.cancel()
        manualRecordingTask = nil

        do {
            let recording = try recorder.stop()
            enqueueRecording(title: info.title, appName: info.appName, recording: recording)
        } catch {
            logger.error("Failed to stop manual recording: \(error)")
            lastError = error.localizedDescription
        }

        activeRecorder = nil
        manualRecordingInfo = nil
        transition(to: .idle)
        detail = ""
    }

    private func monitorManualRecording(pid: pid_t) async {
        let startTime = Date()
        while !Task.isCancelled {
            // Check if process is still alive
            if kill(pid, 0) != 0 {
                logger.info("Monitored app (PID \(pid)) exited — stopping manual recording")
                stopManualRecording()
                return
            }

            // Enforce max duration
            if Date().timeIntervalSince(startTime) > maxDuration {
                logger.info("Max recording duration reached — stopping manual recording")
                stopManualRecording()
                return
            }

            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

    private func cleanupManualRecording() {
        manualRecordingTask?.cancel()
        manualRecordingTask = nil
        activeRecorder = nil
        manualRecordingInfo = nil
    }

    // MARK: - Continuous Listening

    private func continuousLoop() async {
        while !Task.isCancelled {
            do {
                try await runContinuousChunk()
            } catch {
                if error is CancellationError { return }
                let msg = "Continuous capture error: \(error)"
                logger.error("\(msg)")
                lastError = error.localizedDescription
                transition(to: .error)
                detail = msg
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled {
                    transition(to: .watching)
                    detail = "Listening continuously..."
                }
            }
        }
    }

    private func runContinuousChunk() async throws {
        let recorder = recorderFactory()
        let title = Self.continuousChunkTitle()

        currentMeeting = nil
        transition(to: .recording)
        detail = "Recording: \(title)"
        activeContinuousRecorder = recorder
        activeContinuousTitle = title

        logger.info("Continuous chunk start: \(title), duration=\(self.continuousChunkDuration)s")
        AppFileLogger.shared.log("continuous chunk start: title=\(title) duration=\(self.continuousChunkDuration)s mode=\(String(describing: self.continuousCaptureMode))")

        try recorder.startSystemAudio(
            noMic: noMic,
            micDeviceUID: micDeviceUID,
            captureMode: continuousCaptureMode,
        )

        let startedAt = Date()
        while !Task.isCancelled {
            if Date().timeIntervalSince(startedAt) >= continuousChunkDuration {
                break
            }
            try await Task.sleep(for: .seconds(min(pollInterval, 1.0)))
        }

        guard !Task.isCancelled else {
            logger.info("Continuous chunk cancelled before rollover: \(title)")
            return
        }

        logger.info("Continuous chunk rollover: stopping recorder for \(title)")
        AppFileLogger.shared.log("continuous chunk rollover stop: \(title)")
        let recording = try recorder.stop()
        activeContinuousRecorder = nil
        activeContinuousTitle = nil

        enqueueRecording(
            title: title,
            appName: "Continuous Listening",
            recording: recording,
            participants: [],
            isContinuousCapture: true,
        )

        logger.info("Continuous chunk rollover complete: enqueued \(title)")
        AppFileLogger.shared.log("continuous chunk rollover complete: enqueued \(title)")

        if !Task.isCancelled {
            transition(to: .watching)
            detail = "Listening continuously..."
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    // MARK: - Watch Loop

    private func watchLoop() async {
        while !Task.isCancelled {
            if let meeting = detector.checkOnce() {
                do {
                    try await handleMeeting(meeting)
                } catch {
                    if error is CancellationError { return }
                    let msg = "Recording error: \(error)"
                    logger.error("\(msg)")
                    lastError = error.localizedDescription
                    transition(to: .error)
                    detail = "Recording error: \(error.localizedDescription)"
                    try? await Task.sleep(for: .seconds(10))
                }

                detector.reset(appName: meeting.pattern.appName)

                if !Task.isCancelled {
                    transition(to: .watching)
                    detail = "Listening for conversations..."
                }
            }

            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

    // MARK: - Meeting Handling

    func handleMeeting(_ meeting: DetectedMeeting) async throws {
        currentMeeting = meeting
        let title = Self.cleanTitle(meeting.windowTitle)

        // --- Recording ---
        transition(to: .recording)
        detail = "Recording: \(title)"

        let recorder = recorderFactory()
        try recorder.start(
            appPID: meeting.windowPID,
            noMic: noMic,
            micDeviceUID: micDeviceUID,
        )

        // Read participants (Teams)
        var participants: [String] = []
        if meeting.pattern.appName == "Microsoft Teams",
           let names = ParticipantReader.readParticipants(pid: meeting.windowPID),
           !names.isEmpty {
            logger.info("Detected \(names.count) participants")
            participants = names
        }

        // Wait for meeting to end
        try await waitForMeetingEnd(meeting)

        // Stop recording
        let recording = try recorder.stop()

        // --- Enqueue for background processing ---
        enqueueRecording(
            title: title,
            appName: meeting.pattern.appName,
            recording: recording,
            participants: participants,
        )
    }

    // MARK: - Meeting End Detection

    func waitForMeetingEnd(_ meeting: DetectedMeeting) async throws {
        var graceStart: Date?
        let startTime = Date()

        while !Task.isCancelled {
            // Enforce max duration
            if Date().timeIntervalSince(startTime) > maxDuration {
                logger.info("Max recording duration reached (\(Int(self.maxDuration))s)")
                return
            }

            let active = detector.isMeetingActive(meeting)

            if active {
                if graceStart != nil {
                    graceStart = nil
                }
            } else {
                if graceStart == nil {
                    graceStart = Date()
                } else if let start = graceStart, Date().timeIntervalSince(start) >= endGracePeriod {
                    return
                }
            }

            try await Task.sleep(for: .seconds(pollInterval))
        }
    }

    // MARK: - Helpers

    private func enqueueRecording(
        title: String,
        appName: String,
        recording: RecordingResult,
        participants: [String] = [],
        isContinuousCapture: Bool = false,
    ) {
        let job = PipelineJob(
            meetingTitle: title,
            appName: appName,
            mixPath: recording.mixPath,
            appPath: recording.appPath,
            micPath: recording.micPath,
            micDelay: recording.micDelay,
            participants: participants,
            isContinuousCapture: isContinuousCapture,
        )
        pipelineQueue?.enqueue(job)
        logger.info("Enqueued pipeline job for: \(title)")
    }

    private func finalizeActiveContinuousRecorderIfNeeded(reason: String) {
        guard let recorder = activeContinuousRecorder else { return }
        let title = activeContinuousTitle ?? Self.continuousChunkTitle()
        logger.info("Finalizing active continuous recorder due to \(reason): \(title)")
        AppFileLogger.shared.log("finalizing active continuous recorder due to \(reason): \(title)")
        do {
            let recording = try recorder.stop()
            enqueueRecording(
                title: title,
                appName: "Continuous Listening",
                recording: recording,
                participants: [],
                isContinuousCapture: true,
            )
            logger.info("Finalized active continuous recorder: \(title)")
            AppFileLogger.shared.log("finalized active continuous recorder: \(title)")
        } catch {
            logger.error("Failed to finalize active continuous recorder (\(reason)): \(error.localizedDescription)")
            AppFileLogger.shared.log("failed to finalize active continuous recorder (\(reason)): \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
        activeContinuousRecorder = nil
        activeContinuousTitle = nil
    }

    private func transition(to newState: State) {
        let old = state
        state = newState
        if old != newState {
            onStateChange?(old, newState)
        }
    }

    /// Strip app suffixes from meeting titles for cleaner display.
    static func cleanTitle(_ title: String) -> String {
        let suffixes = [" | Microsoft Teams", " - Zoom", " - Webex"]
        for suffix in suffixes where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count))
        }
        return title
    }

    private static func continuousChunkTitle(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Continuous Capture \(formatter.string(from: now))"
    }

    /// Map WatchLoop state to TranscriberState for compatibility with existing UI.
    var transcriberState: TranscriberState {
        switch state {
        case .idle: .idle
        case .watching: .watching
        case .recording: .recording
        case .paused: .paused
        case .error: .error
        }
    }
}
