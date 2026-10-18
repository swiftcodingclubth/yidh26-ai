import CoreGraphics
import Foundation
import FoundationModels

/// A client for the AI models running on the AI cluster.
///
/// Create one with the address and your team's API key, then call it from
/// anywhere in the app:
///
/// ```swift
/// let aiCluster = HackathonAI(apiKey: "team-01-xxxx")
///
/// let answer = try await aiCluster.respond(to: "Explain photosynthesis in one sentence")
/// let card = try await aiCluster.respond(to: notes, generating: StudyCard.self)
/// ```
///
/// Works on iOS 26 and later. On iOS 27 you can also plug an AI cluster model
/// straight into `LanguageModelSession` with `languageModel(_:)`.
public struct HackathonAI: Sendable {
    /// The YiDH AI cluster on the event Wi-Fi.
    public static let defaultBaseURL = "http://10.1.17.156:3949"

    public let baseURL: URL
    let transport: Transport

    /// Connects to the YiDH AI cluster. The `ModelID` presets (`.chat`, `.ocr`, …) are its models.
    /// - Parameter apiKey: Your team's API key.
    public init(apiKey: String) {
        self.init(baseURL: Self.defaultBaseURL, apiKey: apiKey)
    }

    /// Connects to another OpenAI-compatible server.
    ///
    /// The `ModelID` presets are the YiDH AI cluster's models, so they won't exist here.
    /// Call `models()` to see this server's model IDs, then pass one as `model:`:
    ///
    /// ```swift
    /// let lab = HackathonAI(baseURL: "http://10.2.0.5:8000", apiKey: "lab-key")
    /// let model = try await lab.models().first!.id
    /// let answer = try await lab.respond(to: "Hello", model: model)
    /// ```
    ///
    /// - Parameters:
    ///   - baseURL: The server address, e.g. `"http://10.2.0.5:8000"`. `http://` and `/v1` are added if missing.
    ///   - apiKey: The API key for that server.
    public init(baseURL: String, apiKey: String) {
        var address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("://") { address = "http://" + address }
        while address.hasSuffix("/") { address.removeLast() }
        if !address.hasSuffix("/v1") { address += "/v1" }
        guard let url = URL(string: address) else {
            preconditionFailure("HackathonAI: \"\(baseURL)\" is not a valid address")
        }
        self.baseURL = url
        self.transport = Transport(baseURL: url, apiKey: apiKey)
    }

    // MARK: - Types

    /// One message in a conversation, for multi-turn chat.
    public struct Message: Sendable {
        public enum Role: String, Sendable { case system, user, assistant }

        public var role: Role
        public var text: String
        /// JPEG data for each attached image.
        public var images: [Data]

        public init(role: Role, text: String, images: [Data] = []) {
            self.role = role
            self.text = text
            self.images = images
        }

        public static func system(_ text: String) -> Message { Message(role: .system, text: text) }
        public static func assistant(_ text: String) -> Message { Message(role: .assistant, text: text) }
        public static func user(_ text: String, images: [CGImage] = []) -> Message {
            Message(role: .user, text: text, images: images.compactMap(ImageEncoder.jpeg))
        }
    }

    /// Settings for one request. Leave a value `nil` to use the server default.
    public struct Options: Sendable {
        /// Higher gives more varied answers, lower gives more consistent ones.
        public var temperature: Double?
        /// Stops the answer after this many tokens.
        public var maximumResponseTokens: Int?

        public init(temperature: Double? = nil, maximumResponseTokens: Int? = nil) {
            self.temperature = temperature
            self.maximumResponseTokens = maximumResponseTokens
        }
    }

    /// A model the server can run.
    public struct ModelInfo: Sendable, Identifiable, Hashable {
        public var id: ModelID
        /// A readable name, when the server provides one.
        public var name: String?
        public var ownedBy: String?
        /// What the model accepts, e.g. `["text", "image"]`, when the server provides it.
        public var inputModalities: [String]

        public var acceptsImages: Bool { inputModalities.contains("image") }
    }

    // MARK: - Server

    /// Lists the models the server has right now.
    public func models() async throws -> [ModelInfo] {
        let data = try await transport.data(for: transport.request("models"))
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = json["data"] as? [[String: Any]]
        else {
            throw Log.error(HackathonAIError.invalidResponse("expected a model list"), "GET models")
        }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return ModelInfo(
                id: ModelID(id),
                name: entry["name"] as? String,
                ownedBy: entry["owned_by"] as? String,
                inputModalities: entry["input_modalities"] as? [String] ?? []
            )
        }
    }

    /// Returns `true` if the server answers within a few seconds.
    /// Use it to decide whether to show a cluster-only feature.
    public func isReachable() async -> Bool {
        var request = transport.request("models")
        request.timeoutInterval = 3
        return (try? await transport.data(for: request)) != nil
    }

    // MARK: - Text

    /// Sends a prompt and waits for the full answer.
    public func respond(
        to prompt: String,
        model: ModelID = .chat,
        instructions: String? = nil,
        images: [CGImage] = [],
        options: Options = Options()
    ) async throws -> String {
        try await respond(to: Self.messages(prompt, instructions: instructions, images: images), model: model, options: options)
    }

    /// Sends a whole conversation and waits for the next answer.
    public func respond(
        to messages: [Message],
        model: ModelID = .chat,
        options: Options = Options()
    ) async throws -> String {
        var answer = ""
        for try await snapshot in streamResponse(to: messages, model: model, options: options) {
            answer = snapshot
        }
        return answer
    }

    /// Streams the answer. Each value is the full answer so far, the same as
    /// `LanguageModelSession.streamResponse`, so you can assign it straight to the UI.
    public func streamResponse(
        to prompt: String,
        model: ModelID = .chat,
        instructions: String? = nil,
        images: [CGImage] = [],
        options: Options = Options()
    ) -> AsyncThrowingStream<String, Error> {
        streamResponse(to: Self.messages(prompt, instructions: instructions, images: images), model: model, options: options)
    }

    /// Streams the answer to a whole conversation.
    public func streamResponse(
        to messages: [Message],
        model: ModelID = .chat,
        options: Options = Options()
    ) -> AsyncThrowingStream<String, Error> {
        let body = Self.chatBody(messages: messages, model: model, options: options)
        let deltas = transport.streamChat(body, model: model)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var splitter = ThinkSplitter()
                    var snapshot = ""
                    for try await delta in deltas {
                        var piece = splitter.feed(delta.text).text
                        if snapshot.isEmpty { piece = String(piece.drop(while: \.isWhitespace)) }
                        guard !piece.isEmpty else { continue }
                        snapshot += piece
                        continuation.yield(snapshot)
                    }
                    var rest = splitter.flush().text
                    if snapshot.isEmpty { rest = String(rest.drop(while: \.isWhitespace)) }
                    if !rest.isEmpty {
                        snapshot += rest
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Structured output

    /// Asks for an answer shaped like a `@Generable` type, the same types you
    /// use with `LanguageModelSession`. Works on iOS 26 and later.
    public func respond<Content: Generable>(
        to prompt: String,
        generating type: Content.Type = Content.self,
        model: ModelID = .chat,
        instructions: String? = nil,
        images: [CGImage] = [],
        options: Options = Options()
    ) async throws -> Content {
        try await respond(
            to: Self.messages(prompt, instructions: instructions, images: images),
            generating: type, model: model, options: options)
    }

    /// Structured output for a whole conversation.
    public func respond<Content: Generable>(
        to messages: [Message],
        generating type: Content.Type = Content.self,
        model: ModelID = .chat,
        options: Options = Options()
    ) async throws -> Content {
        let schema = try Self.jsonObject(encoding: Content.generationSchema)
        let schemaText = String(data: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), encoding: .utf8) ?? ""

        // Repeat the schema in the prompt, so servers that ignore `response_format` still answer in JSON.
        var messages = messages
        messages.insert(.system("Reply with only a JSON object that matches this JSON schema, no other text:\n\(schemaText)"), at: 0)

        var body = Self.chatBody(messages: messages, model: model, options: options)
        body["response_format"] = [
            "type": "json_schema",
            "json_schema": ["name": "response", "schema": schema],
        ]

        let text: String
        do {
            text = try await collect(body, model: model)
        } catch HackathonAIError.server(let status, _) where status == 400 || status == 422 {
            // This model doesn't support `response_format`. The schema in the prompt is enough.
            Log.notice("\(model.rawValue) rejected response_format (\(status)); retrying with the schema in the prompt only")
            body["response_format"] = nil
            text = try await collect(body, model: model)
        }

        let json = Self.extractJSON(from: text)
        do {
            return try Content(GeneratedContent(json: json))
        } catch {
            Log.error(error, "Decoding \(Content.self) from \(model.rawValue); full answer: \(text)")
            throw HackathonAIError.invalidResponse("the answer didn't match \(Content.self): \(text.prefix(200))")
        }
    }

    // MARK: - Images, speech

    /// Reads the text in an image. Uses Typhoon OCR by default, which handles Thai well.
    public func recognizeText(
        in image: CGImage,
        model: ModelID = .ocr,
        prompt: String = "Extract all text from this image. Keep the original language and line breaks. Output only the text."
    ) async throws -> String {
        try await respond(to: prompt, model: model, images: [image])
    }

    /// Turns text into speech. Returns audio data you can play with `AVAudioPlayer(data:)`.
    public func speak(_ text: String, voice: String? = nil, model: ModelID = .tts) async throws -> Data {
        var body: [String: Any] = ["model": model.rawValue, "input": text, "response_format": "wav"]
        if let voice { body["voice"] = voice }
        let request = transport.request("audio/speech", method: "POST", body: try JSONSerialization.data(withJSONObject: body))
        return try await transport.data(for: request, model: model)
    }

    /// Turns recorded speech into text.
    /// - Parameters:
    ///   - audio: The audio file's data, e.g. from `Data(contentsOf: recordingURL)`.
    ///   - fileName: A name with the right extension (`.m4a`, `.wav`, `.mp3`) so the server knows the format.
    ///   - language: Optional language hint, e.g. `"th"` or `"en"`.
    public func transcribe(_ audio: Data, fileName: String = "audio.m4a", language: String? = nil, model: ModelID = .asr) async throws -> String {
        var form = MultipartForm()
        form.addField("model", model.rawValue)
        if let language { form.addField("language", language) }
        form.addFile("file", fileName: fileName, data: audio)
        let request = transport.request("audio/transcriptions", method: "POST", body: form.finished, contentType: form.contentType)
        let data = try await transport.data(for: request, model: model)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = json["text"] as? String else {
            throw Log.error(HackathonAIError.invalidResponse("expected a transcript"), "POST audio/transcriptions (model \(model.rawValue))")
        }
        return text
    }

    // MARK: - Helpers

    private func collect(_ body: [String: Any], model: ModelID) async throws -> String {
        var splitter = ThinkSplitter()
        var text = ""
        for try await delta in transport.streamChat(body, model: model) {
            text += splitter.feed(delta.text).text
        }
        return text + splitter.flush().text
    }

    static func messages(_ prompt: String, instructions: String?, images: [CGImage]) -> [Message] {
        var messages: [Message] = []
        if let instructions, !instructions.isEmpty { messages.append(.system(instructions)) }
        messages.append(.user(prompt, images: images))
        return messages
    }

    static func chatBody(messages: [Message], model: ModelID, options: Options) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "messages": messages.map(wireMessage),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if let temperature = options.temperature { body["temperature"] = temperature }
        if let maximumResponseTokens = options.maximumResponseTokens { body["max_tokens"] = maximumResponseTokens }
        return body
    }

    static func wireMessage(_ message: Message) -> [String: Any] {
        guard !message.images.isEmpty else {
            return ["role": message.role.rawValue, "content": message.text]
        }
        var content: [[String: Any]] = [["type": "text", "text": message.text]]
        for image in message.images {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"],
            ])
        }
        return ["role": message.role.rawValue, "content": content]
    }

    static func jsonObject(encoding schema: GenerationSchema) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema))
    }

    /// Pulls the JSON object out of an answer, skipping code fences or extra words around it.
    static func extractJSON(from text: String) -> String {
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return text }
        let close: Character = text[start] == "{" ? "}" : "]"
        guard let end = text.lastIndex(of: close), end > start else { return String(text[start...]) }
        return String(text[start...end])
    }
}

private struct MultipartForm {
    private let boundary = "HackathonAI-\(UUID().uuidString)"
    private(set) var data = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, fileName: String, data fileData: Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
    }

    var finished: Data { data + Data("--\(boundary)--\r\n".utf8) }
}
