import Foundation

/// The name of a model on the AI cluster.
///
/// The constants below are the only place model names live. If the cluster
/// changes which model sits behind a name, nothing here needs to change.
/// You can also pass any string: `model: "some-new-model"`.
public struct ModelID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }
}

// TBC: replace with the real model IDs once the AI cluster is set up.
public extension ModelID {
    /// Smart Route (Gemma 4 26B / Qwen3.6 35B). Default for chat, summaries, Thai and structured output.
    static let chat: ModelID = "sccth-gq"
    /// Qwen3.8 27B. Reasoning, document analysis, image input and tool calling.
    static let reasoning: ModelID = "sccth-reasoning"
    /// MedGemma 1.5 4B. Medical knowledge. Synthetic data only.
    static let medical: ModelID = "sccth-medical"
    /// Typhoon OCR 1.5 2B. Reads Thai and English text from images.
    static let ocr: ModelID = "sccth-ocr"
    /// Qwen3-TTS 1.7B. Text to speech.
    static let tts: ModelID = "sccth-tts"
    /// Qwen3-ASR 1.7B. Speech to text (Thai/English).
    static let asr: ModelID = "sccth-asr"
}
