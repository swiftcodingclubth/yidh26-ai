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

public extension ModelID {
    /// Smart Route (`@route/sccth-gq`, falls back to the Gemma 4 pool). Default for chat, summaries, Thai and structured output.
    static let chat: ModelID = "@route/sccth-gq"
    /// Qwen3.6 35B. Reasoning, document analysis, image input and tool calling.
    static let reasoning: ModelID = "nexus-node-15de3eac23192e67332ee785/mlx/Jundot/Qwen3.6-35B-A3B-oQ4e-mtp"
    /// MedGemma 1.5 4B. Medical knowledge. Synthetic data only.
    static let medical: ModelID = "nexus-node-15de3eac23192e67332ee785/mlx/mlx-community/medgemma-1.5-4b-it-bf16"
    /// Typhoon OCR 1.5 2B. Reads Thai and English text from images.
    static let ocr: ModelID = "nexus-node-15de3eac23192e67332ee785/mlx/mlx-community/typhoon-ocr1.5-2b-8bit"
    /// Qwen3-TTS 1.7B. Text to speech.
    static let tts: ModelID = "nexus-node-15de3eac23192e67332ee785/mlx/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"
    /// Qwen3-ASR 1.7B. Speech to text (Thai/English).
    static let asr: ModelID = "nexus-node-15de3eac23192e67332ee785/mlx/mlx-community/Qwen3-ASR-1.7B-bf16"
}
