import Foundation

/// One piece of a streamed chat completion.
struct ChatDelta: Sendable {
    var text = ""
    var reasoning = ""
    var toolCalls: [ToolCallDelta] = []
    var usage: (input: Int, output: Int)?
}

struct ToolCallDelta: Sendable {
    var index: Int
    var id: String?
    var name: String?
    var arguments: String
}

/// HTTP plumbing shared by the simple API and the Foundation Models adapter.
struct Transport: Sendable {
    let baseURL: URL
    let apiKey: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json") -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Sends a request and returns the body of a 2xx response.
    func data(for request: URLRequest, model: ModelID? = nil) async throws -> Data {
        let context = Self.context(request, model: model)
        Log.request(request, model: model)
        let start = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw Log.error(Self.connectionError(error), context)
        }
        if let http = response as? HTTPURLResponse { Log.response(request, status: http.statusCode, since: start) }
        do {
            try Self.check(response, body: data, model: model)
        } catch {
            throw Log.error(error, context)
        }
        return data
    }

    /// Streams a `/chat/completions` request (Server-Sent Events).
    func streamChat(_ body: [String: Any], model: ModelID) -> AsyncThrowingStream<ChatDelta, Error> {
        let request: URLRequest
        do {
            request = self.request("chat/completions", method: "POST", body: try JSONSerialization.data(withJSONObject: body))
        } catch {
            Log.error(error, "Encoding chat request for \(model.rawValue)")
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let context = Self.context(request, model: model)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    Log.request(request, model: model)
                    let start = ContinuousClock.now
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await Self.session.bytes(for: request)
                    } catch {
                        throw Self.connectionError(error)
                    }
                    if let http = response as? HTTPURLResponse { Log.response(request, status: http.statusCode, since: start) }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var errorBody = Data()
                        for try await byte in bytes { errorBody.append(byte) }
                        try Self.check(response, body: errorBody, model: model)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard
                            let data = payload.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else {
                            Log.notice("Skipped a stream line that isn't JSON: \(payload.prefix(200))")
                            continue
                        }
                        if let message = Self.streamErrorMessage(in: json) {
                            throw HackathonAIError.server(statusCode: 200, message: message)
                        }
                        if let delta = Self.delta(from: json) {
                            continuation.yield(delta)
                        }
                    }
                    Log.finished(request, since: start)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Log.error(error, context))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func context(_ request: URLRequest, model: ModelID?) -> String {
        let path = request.url?.absoluteString ?? "?"
        let model = model.map { " (model \($0.rawValue))" } ?? ""
        return "\(request.httpMethod ?? "GET") \(path)\(model)"
    }

    /// Some servers report a failure mid-stream as `{"error": …}` inside an SSE event.
    private static func streamErrorMessage(in json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] { return error["message"] as? String ?? "\(error)" }
        return json["error"] as? String
    }

    private static func connectionError(_ error: Error) -> HackathonAIError {
        if (error as? URLError)?.code == .appTransportSecurityRequiresSecureConnection {
            return .blockedByAppTransportSecurity
        }
        return .unreachable(error.localizedDescription)
    }

    private static func delta(from json: [String: Any]) -> ChatDelta? {
        var result = ChatDelta()
        if let usage = json["usage"] as? [String: Any] {
            result.usage = (usage["prompt_tokens"] as? Int ?? 0, usage["completion_tokens"] as? Int ?? 0)
        }
        if let choice = (json["choices"] as? [[String: Any]])?.first,
           let delta = choice["delta"] as? [String: Any] {
            result.text = delta["content"] as? String ?? ""
            result.reasoning = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? ""
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let function = call["function"] as? [String: Any]
                result.toolCalls.append(ToolCallDelta(
                    index: call["index"] as? Int ?? 0,
                    id: call["id"] as? String,
                    name: function?["name"] as? String,
                    arguments: function?["arguments"] as? String ?? ""
                ))
            }
        }
        return result
    }

    private static func check(_ response: URLResponse, body: Data, model: ModelID?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw HackathonAIError.invalidResponse("not an HTTP response")
        }
        guard !(200..<300).contains(http.statusCode) else { return }

        let message = errorMessage(from: body)
        switch http.statusCode {
        case 401, 403:
            throw HackathonAIError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw HackathonAIError.rateLimited(retryAfter: retryAfter)
        case 404 where model != nil && message.localizedCaseInsensitiveContains("model"):
            throw HackathonAIError.modelNotFound(model!)
        default:
            throw HackathonAIError.server(statusCode: http.statusCode, message: message)
        }
    }

    private static func errorMessage(from body: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let error = json["error"] as? String { return error }
            if let message = json["message"] as? String { return message }
            if let detail = json["detail"] as? String { return detail }
        }
        return String(data: body.prefix(300), encoding: .utf8) ?? "no details"
    }
}

/// Splits `<think>…</think>` blocks out of streamed text, even when a tag is
/// cut across two chunks. Reasoning models put their thinking there.
struct ThinkSplitter {
    private var isThinking = false
    private var pending = ""

    mutating func feed(_ chunk: String) -> (text: String, reasoning: String) {
        pending += chunk
        var text = ""
        var reasoning = ""
        while true {
            let tag = isThinking ? "</think>" : "<think>"
            if let range = pending.range(of: tag) {
                let before = String(pending[..<range.lowerBound])
                if isThinking { reasoning += before } else { text += before }
                pending = String(pending[range.upperBound...])
                isThinking.toggle()
            } else {
                let keep = Self.partialTagLength(at: pending, tag: tag)
                let ready = String(pending.dropLast(keep))
                if isThinking { reasoning += ready } else { text += ready }
                pending = String(pending.suffix(keep))
                return (text, reasoning)
            }
        }
    }

    mutating func flush() -> (text: String, reasoning: String) {
        defer { pending = "" }
        return isThinking ? ("", pending) : (pending, "")
    }

    private static func partialTagLength(at text: String, tag: String) -> Int {
        for length in stride(from: min(tag.count - 1, text.count), to: 0, by: -1) {
            if text.hasSuffix(tag.prefix(length)) { return length }
        }
        return 0
    }
}

/// Passes through only the first JSON object in streamed text, dropping code
/// fences or words around it, so structured output still parses.
struct JSONObjectFilter {
    private var depth = 0
    private var started = false
    private var finished = false
    private var inString = false
    private var escaped = false

    mutating func feed(_ chunk: String) -> String {
        var output = ""
        for character in chunk where !finished {
            if !started {
                guard character == "{" else { continue }
                started = true
            }
            output.append(character)
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
                if depth == 0 { finished = true }
            }
        }
        return output
    }
}
