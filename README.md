# yidh26-ai

A Swift package for calling the AI models on the YiDH AI cluster from an iOS app. It handles the HTTP requests, the API key and JSON for you, and works with the same `@Generable` types you use with Apple's Foundation Models.

- iOS 26 and later (Xcode 26 or 27)
- On iOS 27, an AI cluster model plugs straight into `LanguageModelSession`

## Install

Always pin an **exact version**, so every app at the event uses the same code and nothing changes under you until you choose to update.

### In an Xcode project

1. **File ▸ Add Package Dependencies…**
2. Paste the URL into the search field:

    ```
    https://github.com/swiftcodingclubth/yidh26-ai
    ```

3. Set **Dependency Rule** to **Exact Version** and enter `0.0.3`.
4. Click **Add Package**, then tick **HackathonAI** for your app target.

To update later: select the project ▸ **Package Dependencies** tab ▸ double-click `yidh26-ai` ▸ change the exact version.

### In a Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/swiftcodingclubth/yidh26-ai", exact: "0.0.3"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "HackathonAI", package: "yidh26-ai"),
    ]),
]
```

### Releasing a new version (maintainers)

1. Commit and push the change to `main`.
2. Tag it and push the tag. SPM only sees tagged versions.

    ```sh
    git tag 0.0.4
    git push origin 0.0.4
    ```

3. Update the exact version in each app (and in the handbook) when you want them to move.

## Setup

1. Create one client with your team's API key:

    ```swift
    import HackathonAI

    let aiCluster = HackathonAI(apiKey: "team-01-xxxx")
    ```

    This connects to the YiDH AI cluster at `http://10.1.17.156:3949`, and the [model presets](#models) are its models.

    To use another server, pass its address. The presets aren't on that server, so list its models and pass one as `model:`:

    ```swift
    let lab = HackathonAI(baseURL: "http://10.2.0.5:8000", apiKey: "lab-key")
    let models = try await lab.models()             // the IDs this server has
    let answer = try await lab.respond(to: "Hello", model: models[0].id)
    ```

    `http://` and `/v1` are added for you.

2. Add these to your app's Info.plist. The server uses plain `http://` on a local IP address, which iOS blocks by default.

    ```xml
    <key>NSLocalNetworkUsageDescription</key>
    <string>Connects to the AI cluster on the event network.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    ```

    Don't add `NSAllowsLocalNetworking` as well. When it's present, iOS ignores `NSAllowsArbitraryLoads`.

## Usage

```swift
// Text
let answer = try await aiCluster.respond(to: "Explain photosynthesis in one sentence.")

// Streaming: each value is the whole answer so far
for try await partial in aiCluster.streamResponse(to: prompt) {
    text = partial
}

// Structured output with a @Generable type
@Generable struct StudyCard {
    var title: String
    @Guide(.count(3)) var keyPoints: [String]
}
let card = try await aiCluster.respond(to: notes, generating: StudyCard.self)

// Images
let description = try await aiCluster.respond(to: "What does this chart show?", model: .reasoning, images: [cgImage])
let text = try await aiCluster.recognizeText(in: cgImage)          // OCR

// Speech
let audio = try await aiCluster.speak("Hello")                     // returns audio data
let transcript = try await aiCluster.transcribe(recording, language: "th")

// What's on the server
let models = try await aiCluster.models()
let online = await aiCluster.isReachable()
```

### iOS 27: use an AI cluster model in `LanguageModelSession`

```swift
#if compiler(>=6.4)
let session = LanguageModelSession(
    model: aiCluster.languageModel(.chat),
    tools: [MyTool()],
    instructions: Instructions("Reply in Thai."))
let reply = try await session.respond(to: "Summarize my notes")
#endif
```

The session keeps the conversation, and supports `@Generable`, tool calling and Dynamic Profiles, the same as the on-device model.

## Models

Model names are constants on `ModelID`. They are the model IDs on the YiDH AI cluster, and every method uses `.chat` unless you pass `model:`. You can also pass any ID string the server lists, e.g. `model: "some-model-id"`. On another server, always pass `model:`.

| Constant | Use for |
|---|---|
| `.chat` | Default. Chat, summaries, Thai, structured output |
| `.reasoning` | Multi-step reasoning, documents, images, tool calling |
| `.medical` | Medical knowledge (synthetic data only) |
| `.ocr` | Reading Thai and English text from images |
| `.tts` | Text to speech |
| `.asr` | Speech to text |

## Errors and fallback

Every call throws `HackathonAIError` when something goes wrong: `.unreachable`, `.blockedByAppTransportSecurity`, `.unauthorized`, `.rateLimited(retryAfter:)`, `.modelNotFound`, `.server` or `.invalidResponse`. Catch it and fall back to the on-device model so the app keeps working off the event Wi-Fi:

```swift
do {
    summary = try await aiCluster.respond(to: prompt)
} catch {
    summary = try await LanguageModelSession().respond(to: prompt).content
}
```

## Server compatibility

The server must speak the OpenAI-compatible API: `GET /v1/models`, `POST /v1/chat/completions` (streaming), and for speech `POST /v1/audio/speech` and `POST /v1/audio/transcriptions`. Reasoning text, whether in `<think>` tags or a `reasoning_content` field, is removed from answers.
