import Foundation
import os.log

enum Log {
    static let logger = Logger(subsystem: "io.gridpilot", category: "app")
    static var fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/GridPilot.log")
    private static let queue = DispatchQueue(label: "io.gridpilot.log")
    /// Set by the menu bar controller so action failures surface as a badge.
    static var onError: ((String) -> Void)?

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO  \(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR \(message)")
        onError?(message)
    }

    private static func append(_ line: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("\(stamp) \(line)\n".utf8)
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
