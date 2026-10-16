import Foundation

/// Everything that can go wrong when calling the venue server.
/// Catch any of these and fall back to the on-device model.
public enum HackathonAIError: LocalizedError, Sendable {
    /// Not on the venue Wi-Fi, wrong address, or the server is down.
    case unreachable(String)
    /// iOS blocked the plain `http://` connection. Add `NSAllowsArbitraryLoads` to Info.plist.
    case blockedByAppTransportSecurity
    /// The API key is missing or wrong.
    case unauthorized
    /// Your team sent too many requests. Wait, then try again.
    case rateLimited(retryAfter: TimeInterval?)
    /// The server doesn't know this model ID.
    case modelNotFound(ModelID)
    /// The server answered with an error.
    case server(statusCode: Int, message: String)
    /// The server answered, but not in the shape we expected.
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let reason):
            "Can't reach the venue AI server. Are you on the venue Wi-Fi? (\(reason))"
        case .blockedByAppTransportSecurity:
            "iOS blocked the http:// connection. In Info.plist, add NSAppTransportSecurity > NSAllowsArbitraryLoads = YES."
        case .unauthorized:
            "The API key was rejected. Check the key in your config."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "Too many requests. Try again in \(Int(retryAfter)) seconds."
            } else {
                "Too many requests. Wait a moment and try again."
            }
        case .modelNotFound(let model):
            "The server has no model called \"\(model)\". Call models() to see what's available."
        case .server(let statusCode, let message):
            "The server returned \(statusCode): \(message)"
        case .invalidResponse(let reason):
            "Unexpected response from the server: \(reason)"
        }
    }
}
