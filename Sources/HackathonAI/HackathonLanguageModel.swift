// Plugging a custom model into LanguageModelSession needs the iOS 27 SDK (Xcode 27).
// On Xcode 26 this file compiles to nothing; use the HackathonAI methods instead.
#if compiler(>=6.4)
import Foundation
import FoundationModels

@available(iOS 27.0, macOS 27.0, *)
extension HackathonAI {
    /// An AI cluster model you can pass to `LanguageModelSession`, so `respond`,
    /// streaming, `@Generable` and tools all work exactly as they do on device.
    ///
    /// ```swift
    /// let session = LanguageModelSession(model: aiCluster.languageModel(.chat))
    /// ```
    public func languageModel(
        _ model: ModelID = .chat,
        supportsVision: Bool = false,
        supportsToolCalling: Bool = true
    ) -> HackathonLanguageModel {
        HackathonLanguageModel(
            baseURL: baseURL,
            apiKey: transport.apiKey,
            modelID: model,
            supportsVision: supportsVision,
            supportsToolCalling: supportsToolCalling
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
public struct HackathonLanguageModel: LanguageModel {
    public typealias Executor = HackathonLanguageModelExecutor

    public var baseURL: URL
    public var apiKey: String
    public var modelID: ModelID
    public var supportsVision: Bool
    public var supportsToolCalling: Bool

    public var capabilities: LanguageModelCapabilities {
        var capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration]
        if supportsToolCalling { capabilities.append(.toolCalling) }
        if supportsVision { capabilities.append(.vision) }
        return LanguageModelCapabilities(capabilities)
    }

    public var executorConfiguration: HackathonLanguageModelExecutor.Configuration {
        .init(baseURL: baseURL, apiKey: apiKey, modelID: modelID.rawValue,
              supportsVision: supportsVision, supportsToolCalling: supportsToolCalling)
    }
}

@available(iOS 27.0, macOS 27.0, *)
public struct HackathonLanguageModelExecutor: LanguageModelExecutor {
    public typealias Model = HackathonLanguageModel

    public struct Configuration: Hashable, Sendable {
        var baseURL: URL
        var apiKey: String
        var modelID: String
        var supportsVision: Bool
        var supportsToolCalling: Bool
    }

    private let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: HackathonLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let transport = Transport(baseURL: configuration.baseURL, apiKey: configuration.apiKey)
        let modelID = ModelID(configuration.modelID)
        let body = try makeBody(for: request)

        var splitter = ThinkSplitter()
        var jsonFilter = request.schema == nil ? nil : JSONObjectFilter()
        var hasText = false
        var toolCallIDs: [Int: String] = [:]
        var toolCallNames: [Int: String] = [:]
        var usage = (input: 0, output: 0)

        for try await delta in transport.streamChat(body, model: modelID) {
            if let deltaUsage = delta.usage { usage = deltaUsage }

            let split = splitter.feed(delta.text)
            let reasoning = delta.reasoning + split.reasoning
            if !reasoning.isEmpty {
                await channel.send(.reasoning(action: .appendText(reasoning, tokenCount: 0)))
            }
            var text = jsonFilter?.feed(split.text) ?? split.text
            if !hasText { text = String(text.drop(while: \.isWhitespace)) }
            if !text.isEmpty {
                hasText = true
                await channel.send(.response(action: .appendText(text, tokenCount: 0)))
            }

            guard configuration.supportsToolCalling else { continue }
            for call in delta.toolCalls {
                if let id = call.id { toolCallIDs[call.index] = id }
                if let name = call.name { toolCallNames[call.index] = name }
                guard !call.arguments.isEmpty else { continue }
                await channel.send(.toolCalls(action: .toolCall(
                    id: toolCallIDs[call.index] ?? "call_\(call.index)",
                    name: toolCallNames[call.index] ?? "",
                    action: .appendArguments(call.arguments, tokenCount: 0)
                )))
            }
        }

        let rest = splitter.flush().text
        var restText = jsonFilter?.feed(rest) ?? rest
        if !hasText { restText = String(restText.drop(while: \.isWhitespace)) }
        if !restText.isEmpty {
            await channel.send(.response(action: .appendText(restText, tokenCount: 0)))
        }
        await channel.send(.response(action: .updateUsage(
            input: .init(totalTokenCount: usage.input, cachedTokenCount: 0),
            output: .init(totalTokenCount: usage.output, reasoningTokenCount: 0)
        )))
    }

    // MARK: - Transcript → OpenAI messages

    private func makeBody(for request: LanguageModelExecutorGenerationRequest) throws -> [String: Any] {
        var messages: [[String: Any]] = []
        for entry in request.transcript {
            switch entry {
            case .instructions(let instructions):
                let text = Self.text(in: instructions.segments)
                if !text.isEmpty { messages.append(["role": "system", "content": text]) }
            case .prompt(let prompt):
                messages.append(HackathonAI.wireMessage(userMessage(from: prompt.segments)))
            case .response(let response):
                messages.append(["role": "assistant", "content": Self.text(in: response.segments)])
            case .toolCalls(let toolCalls):
                messages.append([
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": toolCalls.map { call in
                        ["id": call.id, "type": "function",
                         "function": ["name": call.toolName, "arguments": call.arguments.jsonString]]
                    },
                ])
            case .toolOutput(let output):
                messages.append(["role": "tool", "tool_call_id": output.id, "content": Self.text(in: output.segments)])
            default:
                continue
            }
        }

        var body = HackathonAI.chatBody(messages: [], model: ModelID(configuration.modelID), options: .init(
            temperature: request.generationOptions.temperature,
            maximumResponseTokens: request.generationOptions.maximumResponseTokens
        ))
        body["messages"] = messages

        if let schema = request.schema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "response", "schema": try HackathonAI.jsonObject(encoding: schema)],
            ]
        }

        if configuration.supportsToolCalling, !request.enabledToolDefinitions.isEmpty {
            body["tools"] = try request.enabledToolDefinitions.map { definition -> [String: Any] in
                ["type": "function",
                 "function": ["name": definition.name,
                              "description": definition.description,
                              "parameters": try HackathonAI.jsonObject(encoding: definition.parameters)]]
            }
        }
        return body
    }

    private func userMessage(from segments: [Transcript.Segment]) -> HackathonAI.Message {
        var texts: [String] = []
        var images: [Data] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                texts.append(text.content)
            case .structure(let structure):
                texts.append(structure.content.jsonString)
            case .attachment(let attachment):
                if configuration.supportsVision, case .image(let image) = attachment.content,
                   let jpeg = ImageEncoder.jpeg(image.cgImage) {
                    images.append(jpeg)
                }
            @unknown default:
                continue
            }
        }
        return HackathonAI.Message(role: .user, text: texts.joined(separator: "\n"), images: images)
    }

    private static func text(in segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            default: nil
            }
        }.joined(separator: "\n")
    }
}
#endif
