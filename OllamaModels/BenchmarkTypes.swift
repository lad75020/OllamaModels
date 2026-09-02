import Foundation

typealias BenchmarkOutputHandler = @MainActor @Sendable (String) -> Void

enum BenchmarkTestSetError: LocalizedError, Equatable {
    case noTests
    case blankPrompt(index: Int)
    case blankCorrectAnswer(index: Int)

    var errorDescription: String? {
        switch self {
        case .noTests:
            "The JSON file must contain at least one test."
        case let .blankPrompt(index):
            "Test \(index) must include a prompt."
        case let .blankCorrectAnswer(index):
            "Test \(index) must include a correctAnswer."
        }
    }
}

struct BenchmarkTestCase: Identifiable, Equatable, Sendable {
    let id: UUID
    let prompt: String
    let correctAnswer: String

    init(id: UUID = UUID(), prompt: String, correctAnswer: String) {
        self.id = id
        self.prompt = prompt
        self.correctAnswer = correctAnswer
    }

    func matches(response: String) -> Bool {
        Self.normalized(response) == Self.normalized(correctAnswer)
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct BenchmarkTestSet: Decodable, Equatable, Sendable {
    let tests: [BenchmarkTestCase]

    static func decode(data: Data) throws -> BenchmarkTestSet {
        try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case tests
    }

    private struct RawTestCase: Decodable {
        let prompt: String
        let correctAnswer: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawTests = try container.decode([RawTestCase].self, forKey: .tests)
        guard !rawTests.isEmpty else {
            throw BenchmarkTestSetError.noTests
        }

        tests = try rawTests.enumerated().map { offset, rawTest in
            let prompt = rawTest.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                throw BenchmarkTestSetError.blankPrompt(index: offset + 1)
            }

            let correctAnswer = rawTest.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !correctAnswer.isEmpty else {
                throw BenchmarkTestSetError.blankCorrectAnswer(index: offset + 1)
            }

            return BenchmarkTestCase(prompt: prompt, correctAnswer: correctAnswer)
        }
    }
}

struct BenchmarkConfiguration: Equatable, Sendable {
    let modelName: String
    let prompt: String
    let outputTokenLimit: Int

    init(modelName: String, prompt: String, outputTokenLimit: Int) {
        self.modelName = modelName
        self.prompt = prompt
        self.outputTokenLimit = min(max(outputTokenLimit, 1), 2_048)
    }
}

struct OllamaGenerateRequest: Encodable, Sendable {
    let model: String
    let prompt: String
    let stream: Bool
    let think: Bool
    let options: Options

    struct Options: Encodable, Sendable {
        let temperature: Double
        let seed: Int
        let outputTokenLimit: Int

        enum CodingKeys: String, CodingKey {
            case temperature
            case seed
            case outputTokenLimit = "num_predict"
        }
    }
}

struct OllamaGenerateEvent: Decodable, Sendable {
    let response: String?
    let thinking: String?
    let done: Bool
    let totalDurationNanoseconds: Int64?
    let loadDurationNanoseconds: Int64?
    let promptEvaluationCount: Int?
    let promptEvaluationDurationNanoseconds: Int64?
    let evaluationCount: Int?
    let evaluationDurationNanoseconds: Int64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case response
        case thinking
        case done
        case totalDurationNanoseconds = "total_duration"
        case loadDurationNanoseconds = "load_duration"
        case promptEvaluationCount = "prompt_eval_count"
        case promptEvaluationDurationNanoseconds = "prompt_eval_duration"
        case evaluationCount = "eval_count"
        case evaluationDurationNanoseconds = "eval_duration"
        case error
    }
}

enum BenchmarkRunKind: String, Codable, Sendable {
    case cold
    case warm

    var label: String {
        rawValue.capitalized
    }
}

struct BenchmarkSample: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let modelName: String
    let iteration: Int
    let runKind: BenchmarkRunKind
    let startedAt: Date
    let timeToFirstTokenSeconds: Double
    let totalDurationNanoseconds: Int64
    let loadDurationNanoseconds: Int64
    let promptEvaluationCount: Int
    let promptEvaluationDurationNanoseconds: Int64
    let evaluationCount: Int
    let evaluationDurationNanoseconds: Int64
    let prompt: String
    let correctAnswer: String?
    let response: String
    let isCorrect: Bool?

    init(
        id: UUID = UUID(),
        modelName: String,
        iteration: Int,
        runKind: BenchmarkRunKind? = nil,
        startedAt: Date,
        timeToFirstTokenSeconds: Double,
        totalDurationNanoseconds: Int64,
        loadDurationNanoseconds: Int64,
        promptEvaluationCount: Int,
        promptEvaluationDurationNanoseconds: Int64,
        evaluationCount: Int,
        evaluationDurationNanoseconds: Int64,
        prompt: String = "",
        correctAnswer: String? = nil,
        response: String = "",
        isCorrect: Bool? = nil
    ) {
        self.id = id
        self.modelName = modelName
        self.iteration = iteration
        self.runKind = runKind ?? (iteration == 1 ? .cold : .warm)
        self.startedAt = startedAt
        self.timeToFirstTokenSeconds = max(timeToFirstTokenSeconds, 0)
        self.totalDurationNanoseconds = max(totalDurationNanoseconds, 0)
        self.loadDurationNanoseconds = max(loadDurationNanoseconds, 0)
        self.promptEvaluationCount = max(promptEvaluationCount, 0)
        self.promptEvaluationDurationNanoseconds = max(promptEvaluationDurationNanoseconds, 0)
        self.evaluationCount = max(evaluationCount, 0)
        self.evaluationDurationNanoseconds = max(evaluationDurationNanoseconds, 0)
        self.prompt = prompt
        self.correctAnswer = correctAnswer
        self.response = response
        self.isCorrect = isCorrect
    }

    func evaluated(using test: BenchmarkTestCase) -> BenchmarkSample {
        BenchmarkSample(
            id: id,
            modelName: modelName,
            iteration: iteration,
            runKind: runKind,
            startedAt: startedAt,
            timeToFirstTokenSeconds: timeToFirstTokenSeconds,
            totalDurationNanoseconds: totalDurationNanoseconds,
            loadDurationNanoseconds: loadDurationNanoseconds,
            promptEvaluationCount: promptEvaluationCount,
            promptEvaluationDurationNanoseconds: promptEvaluationDurationNanoseconds,
            evaluationCount: evaluationCount,
            evaluationDurationNanoseconds: evaluationDurationNanoseconds,
            prompt: test.prompt,
            correctAnswer: test.correctAnswer,
            response: response,
            isCorrect: test.matches(response: response)
        )
    }

    var totalDurationSeconds: Double {
        seconds(fromNanoseconds: totalDurationNanoseconds)
    }

    var loadDurationSeconds: Double {
        seconds(fromNanoseconds: loadDurationNanoseconds)
    }

    var promptTokensPerSecond: Double {
        tokensPerSecond(
            count: promptEvaluationCount,
            durationNanoseconds: promptEvaluationDurationNanoseconds
        )
    }

    var generationTokensPerSecond: Double {
        tokensPerSecond(
            count: evaluationCount,
            durationNanoseconds: evaluationDurationNanoseconds
        )
    }

    private func seconds(fromNanoseconds value: Int64) -> Double {
        Double(value) / 1_000_000_000
    }

    private func tokensPerSecond(count: Int, durationNanoseconds: Int64) -> Double {
        guard count > 0, durationNanoseconds > 0 else { return 0 }
        return Double(count) / seconds(fromNanoseconds: durationNanoseconds)
    }
}

struct BenchmarkSummary: Equatable, Sendable {
    let modelName: String
    let sampleCount: Int
    let averageTimeToFirstTokenSeconds: Double
    let averageGenerationTokensPerSecond: Double
    let averagePromptTokensPerSecond: Double
    let averageLoadDurationSeconds: Double
    let bestGenerationTokensPerSecond: Double

    init?(samples: [BenchmarkSample]) {
        guard let first = samples.first else { return nil }

        modelName = first.modelName
        sampleCount = samples.count
        averageTimeToFirstTokenSeconds = Self.average(
            samples.map(\.timeToFirstTokenSeconds)
        )
        averageGenerationTokensPerSecond = Self.average(
            samples.map(\.generationTokensPerSecond)
        )
        averagePromptTokensPerSecond = Self.average(
            samples.map(\.promptTokensPerSecond)
        )
        averageLoadDurationSeconds = Self.average(
            samples.map(\.loadDurationSeconds)
        )
        bestGenerationTokensPerSecond = samples
            .map(\.generationTokensPerSecond)
            .max() ?? 0
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
