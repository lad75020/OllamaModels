# OllamaModels

A small native macOS SwiftUI application for managing models installed in [Ollama](https://ollama.com/).

## Features

- List installed Ollama models with size, family, parameters, quantization, and update date.
- Filter the list by model name or metadata.
- Pull a model by name or tag with live download progress.
- Remove models with an explicit confirmation step.
- Run deterministic local benchmarks with repeated iterations, fixed sampling settings, live progress, and cancellation.
- Compare time to first token, generation and prompt throughput, model-load time, total duration, and output-token count.
- Persist benchmark history with search, status filters, compatibility warnings, side-by-side comparisons, and JSON/CSV/Markdown export.
- Diagnose model fit with Model Doctor: estimated versus observed memory, recommended context, swap and pressure detection, accelerator residency, slow-inference explanations, quantization guidance, and installed-variant recommendations.
- Uses Ollama's local HTTP API; it never shells out to a command containing a model name.

The default endpoint is `http://127.0.0.1:11434`. When launched from a shell, `OLLAMA_HOST` is honored when it contains a valid HTTP(S) URL.

## Requirements

- macOS 15 or later
- Xcode 26 or later
- Ollama installed and running locally
- XcodeGen 2.46 or later

## Build and run

From the project directory:

```bash
xcodegen generate
xcodebuild \
  -project OllamaModels.xcodeproj \
  -scheme OllamaModels \
  -destination 'platform=macOS,arch=arm64' \
  build
```

To run the tests:

```bash
xcodebuild \
  -project OllamaModels.xcodeproj \
  -scheme OllamaModels \
  -destination 'platform=macOS,arch=arm64' \
  test
```

You can also open `OllamaModels.xcodeproj` in Xcode and press Run. The app uses the same local API endpoints documented by the Ollama tooling:

- `GET /api/tags` to list models
- `POST /api/pull` to add a model and stream progress
- `DELETE /api/delete` to remove a model
- `GET /api/ps` to report loaded models and memory use
- `POST /api/show` to inspect architecture, context, attention, and quantization metadata
- `POST /api/generate` with streaming enabled to run benchmarks and capture Ollama's timing counters

The app requires the Ollama process to be running before refreshing or changing models. Existing models are never modified during a normal build or test.
