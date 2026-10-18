# CLAUDE.md

Orientation for working on this repo.

## What this is

`yidh26-ai`, published at https://github.com/swiftcodingclubth/yidh26-ai. It's a Swift package whose library **`HackathonAI`** lets students' iOS apps call the AI models on the **YiDH AI cluster**: an OpenAI-compatible HTTP API on the event Wi-Fi, reached with a per-team API key.

Call it the "AI cluster" in code and docs (`let aiCluster = HackathonAI(...)`). Don't name the server software behind it.

Used by:
- the handbook (`yidh26-swift-handbook/docs/workshop-2/hackathon-ai.md` is the reference page, `exam-coach.md` the in-class exercise)
- `study-notes` (the in-class app; Exam Coach)
- `test-local-ai` (the app for testing the server)

## Design rules

- **Must build with Xcode 26 and 27.** `swift-tools-version: 6.2`, iOS 26 minimum. Anything that needs the iOS 27 SDK (the `LanguageModel` adapter) is wrapped in `#if compiler(>=6.4)` plus `@available(iOS 27.0, *)`.
- **Simple for students**: one line to set up (`HackathonAI(apiKey:)` for the YiDH cluster, `HackathonAI(baseURL:apiKey:)` for any other server), and errors in plain English.
- **Model names are only in `ModelID.swift`.** Any string also works as a `ModelID`. Changing which model runs behind a name should need no code change.
- Public API mirrors Foundation Models: `respond`, `streamResponse` (yields the whole answer so far), `respond(generating:)` with `@Generable` types.

## Files

| File | What it does |
|---|---|
| `HackathonAI.swift` | Public client: `models()`, `isReachable()`, `respond`/`streamResponse` (prompt or `[Message]`), `respond(generating:)` (sends the JSON schema as `response_format`, and also in the system prompt; retries without `response_format` on 400/422), `recognizeText`, `speak`, `transcribe`. |
| `HackathonLanguageModel.swift` | iOS 27 `LanguageModel` + `LanguageModelExecutor`: turns the transcript into OpenAI messages, sends tools and the schema, streams text, reasoning and tool-call deltas back to the channel. |
| `Transport.swift` | HTTP + SSE parsing, error mapping (401/403, 429 with Retry-After, 404 model, ATS), `ThinkSplitter` (removes `<think>` even when a tag is split across chunks), `JSONObjectFilter` (keeps only the first JSON object while streaming). |
| `HackathonAIError.swift` | All errors students might catch. |
| `Log.swift` | `os.Logger` (subsystem `HackathonAI`): every request and response status at debug level, every error at error level with where it happened. Never logs the API key or prompts. |
| `ImageEncoder.swift` | CGImage → JPEG, longest side scaled down to 1600. |
| `ModelID.swift` | Model name constants: `.chat` is the `@route/sccth-gq` route, the rest are pinned to models on the SCCTH5 node. |

## Server behaviour (seen on a real Qwen3.8 27B deployment)

- `GET /v1/models` returns `name` and sometimes `input_modalities` per model. `ModelInfo` exposes them.
- Reasoning arrives in `delta.reasoning_content`, separate from `content`. Answers start with `\n\n`, which the package trims.
- Several tokens arrive per SSE chunk, so expect few, large snapshots.
- `response_format: json_schema` worked. Tool calling and image input worked through both the simple API and `LanguageModelSession`.

## Build, test, release

```sh
swift test                      # unit tests (address normalising, think splitting, JSON extraction)
xcodebuild -scheme yidh26-ai -destination 'generic/platform=iOS' build
```

To try it against a server without an app, make a small executable package that depends on this one by path, then call `respond`, `streamResponse`, `respond(generating:)` and `LanguageModelSession(model: ai.languageModel(...))`. `test-local-ai/Tools/mock-server.py` is a mock server you can use.

Releasing: commit to `main`, `git tag X.Y.Z && git push origin X.Y.Z`, `gh release create X.Y.Z`. Apps pin an **exact version**, so bump it in each app and in the handbook (`hackathon-ai.md`, README Install section) when they should move.

## To do

- [ ] Tag a new version now that `ModelID.swift` has the real model IDs.
- [ ] Rate limit numbers for the handbook once known.
- [ ] Decide on a LICENSE (none yet).
- [ ] Maybe: streaming `@Generable` partials for the simple API (only the iOS 27 session path streams partials today).
