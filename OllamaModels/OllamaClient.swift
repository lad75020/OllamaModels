import Foundation

struct OllamaClient: Sendable {
    let baseURL: URL
    let server: InferenceServer
    private let session: URLSession

    init(baseURL: URL = OllamaClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.server = InferenceServer(
            id: InferenceServer.defaultOllamaID,
            name: "Ollama",
            port: baseURL.port ?? 11_434,
            kind: .ollama
        )
        self.session = session
    }

    init(server: InferenceServer, session: URLSession = .shared) {
        self.baseURL = server.baseURL
        self.server = server
        self.session = session
    }

    static var defaultBaseURL: URL {
        InferenceServer.defaultOllama.baseURL
    }

    var supportsNativeModelManagement: Bool {
        server.supportsNativeModelManagement
    }

    func listModels() async throws -> [OllamaModel] {
        switch server.kind {
        case .ollama:
            return try await listOllamaModels()
        case .openAICompatible:
            return try await listOpenAIModels()
        }
    }

    func isAvailable() async -> Bool {
        do {
            _ = try await listModels()
            return true
        } catch {
            return false
        }
    }

    private func listOllamaModels() async throws -> [OllamaModel] {
        do {
            let request = try makeRequest(path: "api/tags")
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, data: data)

            let result = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return result.models.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch let error as OllamaClientError {
            throw error
        } catch let error as DecodingError {
            throw OllamaClientError.decoding(error.localizedDescription)
        } catch {
            throw OllamaClientError.transport(error.localizedDescription)
        }
    }

    private func listOpenAIModels() async throws -> [OllamaModel] {
        do {
            let request = try makeRequest(path: "v1/models")
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, data: data)
            let result = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
            return result.data.map { $0.asOllamaModel() }.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch let error as OllamaClientError {
            throw error
        } catch let error as DecodingError {
            throw OllamaClientError.decoding(error.localizedDescription)
        } catch {
            throw OllamaClientError.transport(error.localizedDescription)
        }
    }

    func modelDoctorProfile(for model: OllamaModel) async throws -> ModelDoctorProfile {
        guard server.kind == .ollama else {
            return ModelDoctorProfile.openAICompatibleFallback(for: model)
        }

        do {
            let body = try JSONEncoder().encode(OllamaShowRequest(model: model.name))
            let request = try makeRequest(path: "api/show", method: "POST", body: body)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, data: data)
            let showResponse = try JSONDecoder().decode(OllamaShowResponse.self, from: data)
            return showResponse.profile(for: model)
        } catch let error as OllamaClientError {
            throw error
        } catch let error as DecodingError {
            throw OllamaClientError.decoding(error.localizedDescription)
        } catch {
            throw OllamaClientError.transport(error.localizedDescription)
        }
    }

    func runtimeStatus() async throws -> OllamaRuntimeStatus {
        guard server.kind == .ollama else {
            return .empty
        }

        do {
            let request = try makeRequest(path: "api/ps")
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, data: data)

            let result = try JSONDecoder().decode(OllamaProcessResponse.self, from: data)
            return OllamaRuntimeStatus(models: result.models)
        } catch let error as OllamaClientError {
            throw error
        } catch let error as DecodingError {
            throw OllamaClientError.decoding(error.localizedDescription)
        } catch {
            throw OllamaClientError.transport(error.localizedDescription)
        }
    }

    func version() async throws -> String {
        guard server.kind == .ollama else {
            _ = try await listOpenAIModels()
            return "OpenAI-compatible"
        }

        do {
            let request = try makeRequest(path: "api/version")
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, data: data)
            return try JSONDecoder().decode(OllamaVersionResponse.self, from: data).version
        } catch let error as OllamaClientError {
            throw error
        } catch let error as DecodingError {
            throw OllamaClientError.decoding(error.localizedDescription)
        } catch {
            throw OllamaClientError.transport(error.localizedDescription)
        }
    }

    func unloadAllModelsAndWait(
        timeout: Duration = .seconds(60),
        pollInterval: Duration = .milliseconds(250)
    ) async throws {
        guard server.kind == .ollama else { return }

        let loadedModels = try await runtimeStatus().loadedModelNames
        for modelName in Set(loadedModels) {
            try Task.checkCancellation()
            let body = try JSONEncoder().encode(OllamaUnloadRequest(model: modelName))
            let request = try makeRequest(path: "api/generate", method: "POST", body: body)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, data: data)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if try await runtimeStatus().models.isEmpty {
                return
            }
            try await Task.sleep(for: pollInterval)
        }
        throw OllamaClientError.server("Timed out while waiting for Ollama to release loaded models.")
    }

    func deleteModel(named name: String) async throws {
        guard server.kind == .ollama else {
            throw OllamaClientError.unsupportedOperation(
                "Removing models is only available through Ollama's native API."
            )
        }

        do {
            let body = try JSONEncoder().encode(OllamaDeleteRequest(name: name))
            let request = try makeRequest(path: "api/delete", method: "DELETE", body: body)
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, data: data)
        } catch let error as OllamaClientError {
            throw error
        } catch {
            throw OllamaClientError.transport(error.localizedDescription)
        }
    }

    func pullModel(named name: String) -> AsyncThrowingStream<OllamaPullEvent, Error> {
        guard server.kind == .ollama else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: OllamaClientError.unsupportedOperation(
                        "Adding models is only available through Ollama's native API."
                    )
                )
            }
        }

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let client = self
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let body = try JSONEncoder().encode(
                        OllamaPullRequest(name: name, stream: true)
                    )
                    let request = try client.makeRequest(path: "api/pull", method: "POST", body: body)
                    let (bytes, response) = try await client.session.bytes(for: request)
                    try await Self.validate(response, bytes: bytes)

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty, let data = line.data(using: .utf8) else {
                            continue
                        }

                        let event = try JSONDecoder().decode(OllamaPullEvent.self, from: data)
                        if let message = event.error, !message.isEmpty {
                            throw OllamaClientError.server(message)
                        }
                        continuation.yield(event)
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as OllamaClientError {
                    continuation.finish(throwing: error)
                } catch let error as DecodingError {
                    continuation.finish(
                        throwing: OllamaClientError.decoding(error.localizedDescription)
                    )
                } catch {
                    continuation.finish(
                        throwing: OllamaClientError.transport(error.localizedDescription)
                    )
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func runBenchmark(
        configuration: BenchmarkConfiguration,
        iteration: Int,
        onOutput: @escaping BenchmarkOutputHandler = { _ in }
    ) async throws -> BenchmarkSample {
        guard server.kind == .ollama else {
            return try await runOpenAIBenchmark(
                configuration: configuration,
                iteration: iteration,
                onOutput: onOutput
            )
        }

        do {
            let body = try JSONEncoder().encode(
                OllamaGenerateRequest(
                    model: configuration.modelName,
                    prompt: configuration.prompt,
                    stream: true,
                    think: false,
                    options: .init(
                        temperature: 0,
                        seed: 42,
                        outputTokenLimit: configuration.outputTokenLimit
                    )
                )
            )
            let request = try makeRequest(
                path: "api/generate",
                method: "POST",
                body: body,
                timeoutSeconds: configuration.inferenceTimeoutSeconds
            )
            let clock = ContinuousClock()
            let startedAt = Date()
            let started = clock.now
            let (bytes, response) = try await session.bytes(for: request)
            try await Self.validate(response, bytes: bytes)

            var firstTokenSeconds: Double?
            var finalEvent: OllamaGenerateEvent?
            var responseText = ""

            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard !line.isEmpty, let data = line.data(using: .utf8) else {
                    continue
                }

                let event = try JSONDecoder().decode(OllamaGenerateEvent.self, from: data)
                if let message = event.error, !message.isEmpty {
                    throw OllamaClientError.server(message)
                }

                let output = event.response ?? ""
                if firstTokenSeconds == nil, !output.isEmpty {
                    firstTokenSeconds = Self.seconds(from: started.duration(to: clock.now))
                }
                responseText += output
                if !output.isEmpty {
                    await onOutput(output)
                }

                if event.done {
                    finalEvent = event
                }
            }

            try Task.checkCancellation()
            guard let finalEvent else {
                throw OllamaClientError.invalidResponse
            }

            let elapsedSeconds = Self.seconds(from: started.duration(to: clock.now))
            return BenchmarkSample(
                modelName: configuration.modelName,
                iteration: max(iteration, 1),
                startedAt: startedAt,
                timeToFirstTokenSeconds: firstTokenSeconds ?? elapsedSeconds,
                totalDurationNanoseconds: finalEvent.totalDurationNanoseconds ?? 0,
                loadDurationNanoseconds: finalEvent.loadDurationNanoseconds ?? 0,
                promptEvaluationCount: finalEvent.promptEvaluationCount ?? 0,
                promptEvaluationDurationNanoseconds: finalEvent.promptEvaluationDurationNanoseconds ?? 0,
                evaluationCount: finalEvent.evaluationCount ?? 0,
                evaluationDurationNanoseconds: finalEvent.evaluationDurationNanoseconds ?? 0,
                prompt: configuration.prompt,
                response: responseText
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OllamaClientError {
            throw error
        } catch let error as DecodingError {
            throw OllamaClientError.decoding(error.localizedDescription)
        } catch {
            throw OllamaClientError.transport(error.localizedDescription)
        }
    }

    private func runOpenAIBenchmark(
        configuration: BenchmarkConfiguration,
        iteration: Int,
        onOutput: @escaping BenchmarkOutputHandler
    ) async throws -> BenchmarkSample {
        do {
            let body = try JSONEncoder().encode(
                OpenAIChatCompletionRequest(
                    model: configuration.modelName,
                    messages: [.init(role: "user", content: configuration.prompt)],
                    maxTokens: configuration.outputTokenLimit,
                    stream: true,
                    enableThinking: false
                )
            )
            let request = try makeRequest(
                path: "v1/chat/completions",
                method: "POST",
                body: body,
                timeoutSeconds: configuration.inferenceTimeoutSeconds
            )
            let clock = ContinuousClock()
            let startedAt = Date()
            let started = clock.now
            let (bytes, response) = try await session.bytes(for: request)
            try await Self.validate(response, bytes: bytes)

            var firstTokenSeconds: Double?
            var responseText = ""
            var usage: OpenAIChatCompletionResponse.Usage?

            for try await line in bytes.lines {
                try Task.checkCancellation()
                let payload = line.hasPrefix("data:")
                    ? String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                    : line
                guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8) else {
                    continue
                }

                if let event = try? JSONDecoder().decode(OpenAIChatCompletionStreamEvent.self, from: data) {
                    usage = event.usage ?? usage
                    let output = event.choices.compactMap(\.delta.content).joined()
                    guard !output.isEmpty else { continue }
                    if firstTokenSeconds == nil {
                        firstTokenSeconds = Self.seconds(from: started.duration(to: clock.now))
                    }
                    responseText += output
                    await onOutput(output)
                    continue
                }

                if let completion = try? JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data),
                   let output = completion.choices.first?.message.content {
                    usage = completion.usage ?? usage
                    if firstTokenSeconds == nil, !output.isEmpty {
                        firstTokenSeconds = Self.seconds(from: started.duration(to: clock.now))
                    }
                    responseText += output
                    if !output.isEmpty {
                        await onOutput(output)
                    }
                    continue
                }

                throw OllamaClientError.decoding("The OpenAI-compatible server returned an invalid streaming event.")
            }

            guard !responseText.isEmpty else {
                throw OllamaClientError.invalidResponse
            }

            let elapsedSeconds = Self.seconds(from: started.duration(to: clock.now))
            let elapsedNanoseconds = Int64(clamping: Int64((elapsedSeconds * 1_000_000_000).rounded()))
            let promptTokens = usage?.promptTokens ?? 0
            let completionTokens = usage?.completionTokens ?? 0
            return BenchmarkSample(
                modelName: configuration.modelName,
                iteration: max(iteration, 1),
                startedAt: startedAt,
                timeToFirstTokenSeconds: firstTokenSeconds ?? elapsedSeconds,
                totalDurationNanoseconds: elapsedNanoseconds,
                loadDurationNanoseconds: 0,
                promptEvaluationCount: promptTokens,
                promptEvaluationDurationNanoseconds: elapsedNanoseconds,
                evaluationCount: completionTokens,
                evaluationDurationNanoseconds: elapsedNanoseconds,
                prompt: configuration.prompt,
                response: responseText
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OllamaClientError {
            throw error
        } catch let error as DecodingError {
            throw OllamaClientError.decoding(error.localizedDescription)
        } catch {
            throw OllamaClientError.transport(error.localizedDescription)
        }
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        timeoutSeconds: Int? = nil
    ) throws -> URLRequest {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        guard url.scheme != nil, url.host != nil else {
            throw OllamaClientError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeoutSeconds {
            request.timeoutInterval = TimeInterval(timeoutSeconds)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw serverError(statusCode: httpResponse.statusCode, data: data)
        }
    }

    private static func validate(
        _ response: URLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaClientError.invalidResponse
        }
        guard !(200..<300).contains(httpResponse.statusCode) else { return }

        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 65_536 { break }
        }
        throw serverError(statusCode: httpResponse.statusCode, data: data)
    }

    private static func serverError(statusCode: Int, data: Data?) -> OllamaClientError {
        if let data,
           let payload = try? JSONDecoder().decode(OllamaErrorPayload.self, from: data),
           !payload.error.isEmpty {
            return .server(payload.error)
        }
        if let data,
           let payload = try? JSONDecoder().decode(OpenAIErrorPayload.self, from: data),
           let message = payload.error?.message,
           !message.isEmpty {
            return .server(message)
        }
        return .server("The local inference server returned HTTP \(statusCode).")
    }
}

private struct OllamaErrorPayload: Decodable {
    let error: String
}

enum OllamaClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case invalidResponse
    case server(String)
    case unsupportedOperation(String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The Ollama endpoint is invalid."
        case .invalidResponse:
            return "Ollama returned an invalid response."
        case .server(let message), .unsupportedOperation(let message), .decoding(let message), .transport(let message):
            return message
        }
    }
}
