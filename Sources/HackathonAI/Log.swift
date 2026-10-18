import Foundation
import os

/// Logs every request and every error, so problems show up in the Xcode console
/// (and in Console.app under the subsystem `HackathonAI`) even when the app swallows the error.
/// API keys and prompts are never logged.
enum Log {
    static let logger = Logger(subsystem: "HackathonAI", category: "AICluster")

    static func request(_ request: URLRequest, model: ModelID?) {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "?"
        let model = model.map { " model=\($0.rawValue)" } ?? ""
        logger.debug("→ \(method, privacy: .public) \(url, privacy: .public)\(model, privacy: .public)")
    }

    static func response(_ request: URLRequest, status: Int, since start: ContinuousClock.Instant) {
        let url = request.url?.absoluteString ?? "?"
        let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        logger.debug("← \(status) \(url, privacy: .public) in \(elapsed, privacy: .public)")
    }

    /// For streams: `response` logs when the headers arrive, this logs when the last chunk does.
    static func finished(_ request: URLRequest, since start: ContinuousClock.Instant) {
        let url = request.url?.absoluteString ?? "?"
        let elapsed = (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        logger.debug("✓ stream from \(url, privacy: .public) finished in \(elapsed, privacy: .public)")
    }

    /// Logs the error with where it happened, then returns it so it can be thrown.
    @discardableResult
    static func error<E: Error>(_ error: E, _ context: String) -> E {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            logger.debug("Cancelled: \(context, privacy: .public)")
            return error
        }
        let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        logger.error("\(context, privacy: .public): \(description, privacy: .public) [\(String(describing: error), privacy: .public)]")
        return error
    }

    static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
