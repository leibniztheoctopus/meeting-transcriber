import Foundation
import os.log

final class AppFileLogger {
    static let shared = AppFileLogger()

    private let queue = DispatchQueue(label: "com.meetingtranscriber.filelogger", qos: .utility)
    private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "FileLogger")

    var logURL: URL {
        AppPaths.dataDir.appendingPathComponent("meetingtranscriber-debug.log")
    }

    private init() {
        try? FileManager.default.createDirectory(at: AppPaths.dataDir, withIntermediateDirectories: true)
    }

    func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        queue.async { [logURL, logger] in
            do {
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                logger.error("Failed writing debug log: \(error.localizedDescription)")
            }
        }
    }
}
