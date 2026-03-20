import Foundation
import os.log

/// A logger that writes to both Apple's Unified Logging (os.log) and stdout.
///
/// Drop-in replacement for `os.log.Logger`. All log messages go to the system
/// log (viewable via Console.app / `log stream`) AND are printed to stdout
/// (viewable in the terminal where the process was launched).
///
/// Usage: replace `Logger(subsystem:category:)` with `DualLogger(subsystem:category:)`.
/// The call-site API is identical: `logger.info("message")`, `logger.error("message")`, etc.
struct DualLogger: Sendable {
    private let logger: Logger
    private let category: String

    private static let subsystem = "com.contextd.app"

    /// Thread-safe timestamp format for stdout. Uses Date.FormatStyle instead of DateFormatter.
    private static let timestampStyle: Date.FormatStyle = .dateTime
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .second(.twoDigits)
        .secondFraction(.fractional(3))

    init(subsystem: String = DualLogger.subsystem, category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    func debug(_ message: String) {
        printToStdout(level: "DEBUG", message: message)
        logger.debug("\(message, privacy: .public)")
    }

    func info(_ message: String) {
        printToStdout(level: "INFO", message: message)
        logger.info("\(message, privacy: .public)")
    }

    func notice(_ message: String) {
        printToStdout(level: "NOTICE", message: message)
        logger.notice("\(message, privacy: .public)")
    }

    func warning(_ message: String) {
        printToStdout(level: "WARN", message: message)
        logger.warning("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        printToStdout(level: "ERROR", message: message)
        logger.error("\(message, privacy: .public)")
    }

    private func printToStdout(level: String, message: String) {
        let ts = Date.now.formatted(DualLogger.timestampStyle)
        print("[\(ts)] [\(level)] [\(category)] \(message)")
    }
}
