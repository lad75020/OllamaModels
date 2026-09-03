import Foundation
import SwiftData
import XCTest
@testable import OllamaModels

final class OllamaModelsTests: XCTestCase {
    func testDecodesOllamaProcessResponse() throws {
        let data = Data(
            """
            {
              "models": [
                {
                  "name": "muse-glimmer:30b-mlx",
                  "model": "muse-glimmer:30b-mlx",
                  "size": 21667251880,
                  "size_vram": 21667251880
                },
                {
                  "model": "qwen3:4b",
                  "size": 2300000000,
                  "size_vram": 1800000000
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(OllamaProcessResponse.self, from: data)

        XCTAssertEqual(response.models.map(\.name), ["muse-glimmer:30b-mlx", "qwen3:4b"])
        XCTAssertEqual(response.models[0].size, 21_667_251_880)
        XCTAssertEqual(response.models[1].sizeVRAM, 1_800_000_000)
    }

    func testRuntimeStatusShowsAllLoadedModelNames() {
        let status = OllamaRuntimeStatus(
            models: [
                OllamaRunningModel(name: "muse-glimmer:30b-mlx", size: 10, sizeVRAM: 8),
                OllamaRunningModel(name: "qwen3:4b", size: 20, sizeVRAM: 12)
            ]
        )

        XCTAssertEqual(status.loadedModelNames, ["muse-glimmer:30b-mlx", "qwen3:4b"])
        XCTAssertEqual(status.loadedModelNamesLabel, "muse-glimmer:30b-mlx, qwen3:4b")
    }

    func testRuntimeStatusAggregatesAndFormatsTotalLoadedMemory() {
        let status = OllamaRuntimeStatus(
            models: [
                OllamaRunningModel(name: "first", size: 1_000_000_000, sizeVRAM: 800_000_000),
                OllamaRunningModel(name: "second", size: 2_500_000_000, sizeVRAM: 2_000_000_000)
            ]
        )

        XCTAssertEqual(status.totalMemoryBytes, 3_500_000_000)
        XCTAssertEqual(
            status.formattedTotalMemory,
            ByteCountFormatter.string(fromByteCount: 3_500_000_000, countStyle: .file)
        )
    }

    func testRuntimeStatusMemoryAggregationClampsOnOverflow() {
        let status = OllamaRuntimeStatus(
            models: [
                OllamaRunningModel(name: "very-large", size: .max, sizeVRAM: 0),
                OllamaRunningModel(name: "also-loaded", size: 1, sizeVRAM: 0)
            ]
        )

        XCTAssertEqual(status.totalMemoryBytes, .max)
    }

    func testRuntimeStatusHasHonestEmptyState() {
        let status = OllamaRuntimeStatus.empty

        XCTAssertTrue(status.loadedModelNames.isEmpty)
        XCTAssertEqual(status.loadedModelNamesLabel, "None")
        XCTAssertEqual(status.totalMemoryBytes, 0)
        XCTAssertEqual(status.formattedTotalMemory, "0 bytes")
    }

    func testClientRequestsNativeProcessEndpoint() async throws {
        let client = OllamaClient(
            baseURL: URL(string: "http://success.test")!,
            session: makeStubbedSession()
        )

        let status = try await client.runtimeStatus()

        XCTAssertEqual(status.loadedModelNames, ["muse-glimmer:30b-mlx"])
        XCTAssertEqual(status.totalMemoryBytes, 21_667_251_880)
    }

    @MainActor
    func testManualRefreshLoadsInstalledModelsAndRuntimeStatus() async {
        let client = OllamaClient(
            baseURL: URL(string: "http://success.test")!,
            session: makeStubbedSession()
        )
        let viewModel = ModelsViewModel(client: client)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.models.map(\.name), ["qwen3:4b"])
        XCTAssertEqual(viewModel.runtimeStatus.loadedModelNames, ["muse-glimmer:30b-mlx"])
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testRuntimePollingFailurePreservesLastGoodStatusWithoutBanner() async {
        let lastGoodStatus = OllamaRuntimeStatus(
            models: [
                OllamaRunningModel(name: "muse-glimmer:30b-mlx", size: 42, sizeVRAM: 21)
            ]
        )
        let client = OllamaClient(
            baseURL: URL(string: "http://failure.test")!,
            session: makeStubbedSession()
        )
        let viewModel = ModelsViewModel(
            client: client,
            initialRuntimeStatus: lastGoodStatus
        )

        await viewModel.refreshRuntimeStatus()

        XCTAssertEqual(viewModel.runtimeStatus, lastGoodStatus)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testUnloadClearsLoadedRuntimeStatusAndShowsNotice() async {
        let loadedStatus = OllamaRuntimeStatus(
            models: [OllamaRunningModel(name: "qwen3:4b", size: 2_300_000_000, sizeVRAM: 1_800_000_000)]
        )
        let viewModel = ModelsViewModel(
            initialRuntimeStatus: loadedStatus,
            unloader: {}
        )

        await viewModel.unloadAllModels()

        XCTAssertEqual(viewModel.runtimeStatus, .empty)
        XCTAssertEqual(viewModel.noticeMessage, "Unloaded all models.")
        XCTAssertFalse(viewModel.isUnloadingModels)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testDecodesOllamaTagsResponse() throws {
        let data = Data(
            """
            {
              "models": [
                {
                  "name": "qwen3:4b",
                  "modified_at": "2026-08-15T12:00:00Z",
                  "size": 2300000000,
                  "digest": "abc123",
                  "capabilities": ["completion", "tools"],
                  "details": {
                    "format": "gguf",
                    "family": "qwen3",
                    "families": ["qwen3"],
                    "parameter_size": "4.0B",
                    "quantization_level": "Q4_K_M"
                  }
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)

        XCTAssertEqual(response.models.count, 1)
        XCTAssertEqual(response.models[0].name, "qwen3:4b")
        XCTAssertEqual(response.models[0].parameterSize, "4.0B")
        XCTAssertEqual(response.models[0].quantization, "Q4_K_M")
        XCTAssertEqual(response.models[0].capabilities, ["completion", "tools"])
        XCTAssertTrue(response.models[0].supportsCompletion)
    }

    func testDecodesLegacyModelKeyWhenNameIsMissing() throws {
        let data = Data(
            """
            {
              "models": [
                {
                  "model": "llama3.1:8b",
                  "size": 10
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)

        XCTAssertEqual(response.models.first?.name, "llama3.1:8b")
    }

    func testNormalizesValidModelNames() {
        XCTAssertEqual(ModelNameValidator.normalized("  qwen3:4b  "), "qwen3:4b")
        XCTAssertEqual(ModelNameValidator.normalized("hf.co/example/model:Q4_K_M"), "hf.co/example/model:Q4_K_M")
    }

    func testRejectsInvalidModelNames() {
        XCTAssertNil(ModelNameValidator.normalized(""))
        XCTAssertNil(ModelNameValidator.normalized("model name"))
        XCTAssertNil(ModelNameValidator.normalized(String(repeating: "m", count: 201)))
    }

    func testPullProgressUpdateGateThrottlesUnchangedStatus() {
        let clock = ContinuousClock()
        let start = clock.now
        var gate = PullProgressUpdateGate(minimumInterval: .milliseconds(125))

        XCTAssertTrue(gate.shouldPublish(status: "downloading", now: start))
        XCTAssertFalse(
            gate.shouldPublish(
                status: "downloading",
                now: start.advanced(by: .milliseconds(124))
            )
        )
        XCTAssertTrue(
            gate.shouldPublish(
                status: "downloading",
                now: start.advanced(by: .milliseconds(125))
            )
        )
    }

    func testPullProgressUpdateGatePublishesStatusTransitionsImmediately() {
        let clock = ContinuousClock()
        let start = clock.now
        var gate = PullProgressUpdateGate(minimumInterval: .seconds(1))

        XCTAssertTrue(gate.shouldPublish(status: "downloading", now: start))
        XCTAssertTrue(
            gate.shouldPublish(
                status: "verifying sha256 digest",
                now: start.advanced(by: .milliseconds(1))
            )
        )
    }

    func testPullProgressUpdateGatePublishesCompletionImmediately() {
        let clock = ContinuousClock()
        let start = clock.now
        var gate = PullProgressUpdateGate(minimumInterval: .seconds(1))

        XCTAssertTrue(gate.shouldPublish(status: "downloading", now: start))
        XCTAssertTrue(
            gate.shouldPublish(
                status: "downloading",
                isTerminal: true,
                now: start.advanced(by: .milliseconds(1))
            )
        )
    }

    func testPullCancellationNoticeDoesNotPromiseDaemonCancellation() {
        XCTAssertEqual(
            PullCancellationNotice.message(for: "gemma4:12b-mlx"),
            "Stopped this app's request for gemma4:12b-mlx. Ollama may retain partial data and resume it later."
        )
    }

    func testLocalBenchmarkCandidateRejectsCloudAndEmbeddingModels() {
        let completionModel = OllamaModel(
            name: "qwen3:4b",
            modifiedAt: nil,
            size: 2_300_000_000,
            digest: "completion",
            details: nil
        )
        let cloudModel = OllamaModel(
            name: "large-model:cloud",
            modifiedAt: nil,
            size: 382,
            digest: "cloud",
            details: nil
        )
        let embeddingModel = OllamaModel(
            name: "embeddinggemma:latest",
            modifiedAt: nil,
            size: 621_000_000,
            digest: "embedding",
            details: nil
        )

        XCTAssertTrue(completionModel.supportsLocalBenchmark)
        XCTAssertFalse(cloudModel.supportsLocalBenchmark)
        XCTAssertFalse(embeddingModel.supportsLocalBenchmark)
    }

    func testBenchmarkSampleComputesDurationsAndThroughput() {
        let sample = BenchmarkSample(
            modelName: "qwen3:4b",
            iteration: 1,
            startedAt: Date(timeIntervalSince1970: 1_000),
            timeToFirstTokenSeconds: 0.25,
            totalDurationNanoseconds: 3_000_000_000,
            loadDurationNanoseconds: 250_000_000,
            promptEvaluationCount: 20,
            promptEvaluationDurationNanoseconds: 500_000_000,
            evaluationCount: 80,
            evaluationDurationNanoseconds: 2_000_000_000
        )

        XCTAssertEqual(sample.totalDurationSeconds, 3, accuracy: 0.000_001)
        XCTAssertEqual(sample.loadDurationSeconds, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(sample.promptTokensPerSecond, 40, accuracy: 0.000_001)
        XCTAssertEqual(sample.generationTokensPerSecond, 40, accuracy: 0.000_001)
    }

    func testBenchmarkConfigurationClampsInferenceTimeout() {
        let minimum = BenchmarkConfiguration(
            modelName: "qwen3:4b",
            prompt: "Say hello.",
            outputTokenLimit: 32,
            inferenceTimeoutSeconds: 0
        )
        let maximum = BenchmarkConfiguration(
            modelName: "qwen3:4b",
            prompt: "Say hello.",
            outputTokenLimit: 32,
            inferenceTimeoutSeconds: 9_999
        )

        XCTAssertEqual(minimum.inferenceTimeoutSeconds, 1)
        XCTAssertEqual(maximum.inferenceTimeoutSeconds, 3_600)
    }

    func testBenchmarkSummaryAggregatesMultipleIterations() {
        let samples = [
            BenchmarkSample(
                modelName: "qwen3:4b",
                iteration: 1,
                startedAt: Date(timeIntervalSince1970: 1_000),
                timeToFirstTokenSeconds: 0.2,
                totalDurationNanoseconds: 2_000_000_000,
                loadDurationNanoseconds: 100_000_000,
                promptEvaluationCount: 10,
                promptEvaluationDurationNanoseconds: 500_000_000,
                evaluationCount: 40,
                evaluationDurationNanoseconds: 1_000_000_000
            ),
            BenchmarkSample(
                modelName: "qwen3:4b",
                iteration: 2,
                startedAt: Date(timeIntervalSince1970: 2_000),
                timeToFirstTokenSeconds: 0.4,
                totalDurationNanoseconds: 4_000_000_000,
                loadDurationNanoseconds: 300_000_000,
                promptEvaluationCount: 20,
                promptEvaluationDurationNanoseconds: 500_000_000,
                evaluationCount: 60,
                evaluationDurationNanoseconds: 1_000_000_000
            )
        ]

        let summary = BenchmarkSummary(samples: samples)

        XCTAssertEqual(summary?.modelName, "qwen3:4b")
        XCTAssertEqual(summary?.averageTimeToFirstTokenSeconds ?? 0, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(summary?.averageGenerationTokensPerSecond ?? 0, 50, accuracy: 0.000_001)
        XCTAssertEqual(summary?.averagePromptTokensPerSecond ?? 0, 30, accuracy: 0.000_001)
        XCTAssertEqual(summary?.bestGenerationTokensPerSecond ?? 0, 60, accuracy: 0.000_001)
    }

    @MainActor
    func testClientRunsDeterministicStreamingBenchmark() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BenchmarkStubURLProtocol.self]
        let client = OllamaClient(
            baseURL: URL(string: "http://benchmark.test")!,
            session: URLSession(configuration: configuration)
        )

        var streamedOutput: [String] = []
        let sample = try await client.runBenchmark(
            configuration: BenchmarkConfiguration(
                modelName: "qwen3:4b",
                prompt: "Count from one to five.",
                outputTokenLimit: 32,
                inferenceTimeoutSeconds: 75
            ),
            iteration: 2,
            onOutput: { streamedOutput.append($0) }
        )

        XCTAssertEqual(sample.modelName, "qwen3:4b")
        XCTAssertEqual(sample.iteration, 2)
        XCTAssertEqual(sample.totalDurationNanoseconds, 3_000_000_000)
        XCTAssertEqual(sample.loadDurationNanoseconds, 250_000_000)
        XCTAssertEqual(sample.promptEvaluationCount, 12)
        XCTAssertEqual(sample.evaluationCount, 80)
        XCTAssertEqual(streamedOutput, ["One"])
        XCTAssertEqual(sample.generationTokensPerSecond, 40, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(sample.timeToFirstTokenSeconds, 0)
    }

    @MainActor
    func testClientBenchmarksOnlyFinalAnswerAfterReasoningStream() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReasoningBenchmarkStubURLProtocol.self]
        let client = OllamaClient(
            baseURL: URL(string: "http://reasoning-benchmark.test")!,
            session: URLSession(configuration: configuration)
        )

        var streamedOutput: [String] = []
        let sample = try await client.runBenchmark(
            configuration: BenchmarkConfiguration(
                modelName: "qwen3:4b",
                prompt: "What is 2 + 2?",
                outputTokenLimit: 32
            ),
            iteration: 1,
            onOutput: { streamedOutput.append($0) }
        )

        XCTAssertEqual(sample.response, "4")
        XCTAssertEqual(streamedOutput, ["4"])
        XCTAssertGreaterThanOrEqual(sample.timeToFirstTokenSeconds, 0.05)
    }

    func testClientSurfacesBenchmarkServerErrorBody() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BenchmarkStubURLProtocol.self]
        let client = OllamaClient(
            baseURL: URL(string: "http://benchmark-failure.test")!,
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.runBenchmark(
                configuration: BenchmarkConfiguration(
                    modelName: "qwen3:4b",
                    prompt: "Count from one to five.",
                    outputTokenLimit: 32
                ),
                iteration: 1
            )
            XCTFail("Expected Ollama's server error.")
        } catch let error as OllamaClientError {
            XCTAssertEqual(error, .server("model runner failed to load"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testBenchmarkViewModelRunsConfiguredIterationsSequentially() async {
        let viewModel = BenchmarkViewModel { configuration, iteration in
            BenchmarkSample(
                modelName: configuration.modelName,
                iteration: iteration,
                startedAt: Date(timeIntervalSince1970: Double(iteration)),
                timeToFirstTokenSeconds: Double(iteration) / 10,
                totalDurationNanoseconds: 1_000_000_000,
                loadDurationNanoseconds: 0,
                promptEvaluationCount: 10,
                promptEvaluationDurationNanoseconds: 500_000_000,
                evaluationCount: iteration * 10,
                evaluationDurationNanoseconds: 1_000_000_000
            )
        }
        viewModel.selectedModelName = "qwen3:4b"
        viewModel.prompt = "Write a short greeting."
        viewModel.iterations = 3
        viewModel.outputTokenLimit = 64

        await viewModel.run()

        XCTAssertEqual(viewModel.samples.map(\.iteration), [1, 2, 3])
        XCTAssertEqual(viewModel.completedIterations, 3)
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.summary?.averageGenerationTokensPerSecond ?? 0, 20, accuracy: 0.000_001)
    }

    @MainActor
    func testBenchmarkViewModelPublishesStreamingOutput() async {
        let viewModel = BenchmarkViewModel(
            runStreamingBenchmark: { configuration, iteration, onOutput in
                await onOutput("Hello")
                await onOutput(" world")
                return BenchmarkSample(
                    modelName: configuration.modelName,
                    iteration: iteration,
                    startedAt: .now,
                    timeToFirstTokenSeconds: 0.1,
                    totalDurationNanoseconds: 1_000_000_000,
                    loadDurationNanoseconds: 0,
                    promptEvaluationCount: 4,
                    promptEvaluationDurationNanoseconds: 100_000_000,
                    evaluationCount: 2,
                    evaluationDurationNanoseconds: 500_000_000,
                    response: "Hello world"
                )
            },
            unloadAllModels: {},
            fetchOllamaVersion: { "Test" },
            captureEnvironment: { BenchmarkEnvironmentSnapshot.current(ollamaVersion: "Test") }
        )
        viewModel.selectedModelName = "qwen3:4b"
        viewModel.prompt = "Say hello."
        viewModel.iterations = 1

        await viewModel.run()

        XCTAssertEqual(viewModel.liveOutput, "Hello world")
        XCTAssertEqual(viewModel.samples.map(\.response), ["Hello world"])
    }

    func testBenchmarkCanStartWithoutJSONTestSet() {
        XCTAssertTrue(
            BenchmarkRunReadiness.canStart(
                selectedModelNames: ["gemma4:12b-mlx"],
                isRunning: false
            )
        )
        XCTAssertFalse(BenchmarkRunReadiness.canStart(selectedModelNames: [], isRunning: false))
        XCTAssertFalse(
            BenchmarkRunReadiness.canStart(
                selectedModelNames: ["gemma4:12b-mlx"],
                isRunning: true
            )
        )
    }

    @MainActor
    func testBenchmarkViewModelRejectsBlankPromptBeforeExecution() async {
        let viewModel = BenchmarkViewModel { _, _ in
            XCTFail("The executor must not run for invalid input.")
            throw CancellationError()
        }
        viewModel.selectedModelName = "qwen3:4b"
        viewModel.prompt = "   \n"

        await viewModel.run()

        XCTAssertEqual(viewModel.errorMessage, "Enter a benchmark prompt.")
        XCTAssertTrue(viewModel.samples.isEmpty)
        XCTAssertFalse(viewModel.isRunning)
    }

    func testLiveOllamaListEndpoint() async throws {
        do {
            let models = try await OllamaClient().listModels()
            XCTAssertFalse(models.isEmpty, "The live Ollama service returned no installed models.")
        } catch {
            throw XCTSkip("Ollama is unavailable for the live integration check: \(error)")
        }
    }

    @MainActor
    func testInferenceServerRecordsPersistLocally() throws {
        let container = try ModelContainer(
            for: InferenceServerRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let server = InferenceServer(
            name: "MLX Server",
            port: 8_080,
            kind: .openAICompatible
        )
        container.mainContext.insert(InferenceServerRecord(server: server, isActive: true))
        try container.mainContext.save()

        let records = try container.mainContext.fetch(FetchDescriptor<InferenceServerRecord>())

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].server, server)
        XCTAssertTrue(records[0].isActive)
        XCTAssertEqual(records[0].server.endpointDescription, "http://127.0.0.1:8080")
    }

    @MainActor
    func testOpenAICompatibleServerListsModelsAndRunsBenchmark() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAICompatibleStubURLProtocol.self]
        let server = InferenceServer(
            name: "Local MLX",
            port: 8_080,
            kind: .openAICompatible
        )
        let client = OllamaClient(server: server, session: URLSession(configuration: configuration))

        let models = try await client.listModels()
        let profile = try await client.modelDoctorProfile(for: try XCTUnwrap(models.first))
        var streamedOutput: [String] = []
        let sample = try await client.runBenchmark(
            configuration: BenchmarkConfiguration(
                modelName: "mlx-community/Qwen3-4B-MLX-4bit",
                prompt: "Say hello.",
                outputTokenLimit: 32,
                inferenceTimeoutSeconds: 90
            ),
            iteration: 1,
            onOutput: { streamedOutput.append($0) }
        )

        XCTAssertEqual(models.map(\.name), ["mlx-community/Qwen3-4B-MLX-4bit"])
        XCTAssertTrue(models[0].supportsLocalBenchmark)
        XCTAssertEqual(profile.name, "mlx-community/Qwen3-4B-MLX-4bit")
        XCTAssertEqual(sample.response, "Hello from a local OpenAI-compatible server.")
        XCTAssertEqual(streamedOutput, ["Hello ", "from a local OpenAI-compatible server."])
        XCTAssertEqual(sample.promptEvaluationCount, 4)
        XCTAssertEqual(sample.evaluationCount, 8)
        let isAvailable = await client.isAvailable()
        XCTAssertTrue(isAvailable)
    }

    private func makeStubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class OllamaStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let response: (statusCode: Int, body: String)
        if url.host == "failure.test" {
            response = (503, #"{"error":"unavailable"}"#)
        } else if url.path == "/api/ps" {
            response = (
                200,
                #"{"models":[{"name":"muse-glimmer:30b-mlx","size":21667251880,"size_vram":21667251880}]}"#
            )
        } else if url.path == "/api/tags" {
            response = (
                200,
                #"{"models":[{"name":"qwen3:4b","size":2300000000,"digest":"stub"}]}"#
            )
        } else {
            response = (404, #"{"error":"unexpected path"}"#)
        }

        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class OpenAICompatibleStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body: String
        switch (url.path, request.httpMethod) {
        case ("/v1/models", "GET"):
            body = #"{"data":[{"id":"mlx-community/Qwen3-4B-MLX-4bit","created":1770000000}]}"#
        case ("/v1/chat/completions", "POST") where request.timeoutInterval == 90:
            body = """
            data: {"choices":[{"delta":{"content":"Hello "}}]}

            data: {"choices":[{"delta":{"content":"from a local OpenAI-compatible server."}}],"usage":{"prompt_tokens":4,"completion_tokens":8}}

            data: [DONE]

            """
        default:
            finish(statusCode: 404, body: #"{"error":{"message":"unexpected path"}}"#)
            return
        }

        finish(statusCode: 200, body: body)
    }

    override func stopLoading() {}

    private func finish(statusCode: Int, body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class BenchmarkStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if request.url?.host == "benchmark-failure.test" {
            finish(statusCode: 500, body: #"{"error":"model runner failed to load"}"#)
            return
        }

        guard let url = request.url,
              url.path == "/api/generate",
              request.httpMethod == "POST",
              let requestBody = Self.bodyData(from: request),
              let payload = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              payload["model"] as? String == "qwen3:4b",
              payload["prompt"] as? String == "Count from one to five.",
              payload["stream"] as? Bool == true,
              request.timeoutInterval == 75,
              let options = payload["options"] as? [String: Any],
              (options["num_predict"] as? NSNumber)?.intValue == 32,
              (options["temperature"] as? NSNumber)?.doubleValue == 0 else {
            finish(statusCode: 400, body: #"{"error":"invalid benchmark request"}"#)
            return
        }

        let body = """
        {"model":"qwen3:4b","response":"One","done":false}
        {"model":"qwen3:4b","response":"","done":true,"total_duration":3000000000,"load_duration":250000000,"prompt_eval_count":12,"prompt_eval_duration":600000000,"eval_count":80,"eval_duration":2000000000}

        """
        finish(statusCode: 200, body: body)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func finish(statusCode: Int, body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/x-ndjson"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class ReasoningBenchmarkStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/x-ndjson"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data((#"{"model":"qwen3:4b","thinking":"I need to calculate this.","done":false}"# + "\n").utf8)
        )

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(
                self,
                didLoad: Data(
                    #"{"model":"qwen3:4b","response":"4","done":true,"total_duration":100000000,"eval_count":1,"eval_duration":100000000}"#
                        .utf8
                )
            )
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
