import Foundation
import Observation

@MainActor
@Observable
final class BenchmarkViewModel {
    typealias Executor = @Sendable (BenchmarkConfiguration, Int) async throws -> BenchmarkSample
    typealias Unloader = @Sendable () async throws -> Void
    typealias VersionProvider = @Sendable () async throws -> String
    typealias EnvironmentCapture = @Sendable () -> BenchmarkEnvironmentSnapshot
    typealias PersistenceHandler = @MainActor (BenchmarkSessionSnapshot) throws -> Void

    private let executor: Executor
    private let unloadAllModels: Unloader
    private let fetchOllamaVersion: VersionProvider
    private let captureEnvironment: EnvironmentCapture
    private var benchmarkTask: Task<Void, Never>?

    var selectedModelName = ""
    var prompt = "Explain why deterministic benchmarks are useful in three concise sentences."
    var iterations = 3
    var outputTokenLimit = 128

    private(set) var samples: [BenchmarkSample] = []
    private(set) var completedSessions: [BenchmarkSessionSnapshot] = []
    private(set) var isRunning = false
    private(set) var completedIterations = 0
    private(set) var totalIterations = 0
    private(set) var currentIteration = 0
    private(set) var currentModelName = ""
    private(set) var currentModelIndex = 0
    private(set) var totalModels = 0
    var errorMessage: String?
    var noticeMessage: String?

    var summary: BenchmarkSummary? {
        BenchmarkSummary(samples: samples)
    }

    var progress: Double {
        guard totalIterations > 0 else { return 0 }
        return min(Double(completedIterations) / Double(totalIterations), 1)
    }

    convenience init(client: OllamaClient = OllamaClient()) {
        self.init(
            runBenchmark: { configuration, iteration in
                try await client.runBenchmark(configuration: configuration, iteration: iteration)
            },
            unloadAllModels: {
                try await client.unloadAllModelsAndWait()
            },
            fetchOllamaVersion: {
                try await client.version()
            },
            captureEnvironment: {
                BenchmarkEnvironmentSnapshot.current(ollamaVersion: "Unknown")
            }
        )
    }

    convenience init(runBenchmark: @escaping Executor) {
        self.init(
            runBenchmark: runBenchmark,
            unloadAllModels: {},
            fetchOllamaVersion: { "Unknown" },
            captureEnvironment: {
                BenchmarkEnvironmentSnapshot.current(ollamaVersion: "Unknown")
            }
        )
    }

    init(
        runBenchmark: @escaping Executor,
        unloadAllModels: @escaping Unloader,
        fetchOllamaVersion: @escaping VersionProvider,
        captureEnvironment: @escaping EnvironmentCapture
    ) {
        executor = runBenchmark
        self.unloadAllModels = unloadAllModels
        self.fetchOllamaVersion = fetchOllamaVersion
        self.captureEnvironment = captureEnvironment
    }

    func start() {
        guard let modelName = ModelNameValidator.normalized(selectedModelName) else {
            errorMessage = "Choose an installed completion model."
            return
        }
        startQueue(targets: [BenchmarkModelTarget(name: modelName, digest: "")]) { _ in }
    }

    func startQueue(
        targets: [BenchmarkModelTarget],
        persist: @escaping PersistenceHandler
    ) {
        guard let prepared = prepareQueue(targets: targets) else { return }
        benchmarkTask = Task { [weak self] in
            guard let self else { return }
            await self.performQueue(prepared: prepared, persist: persist)
        }
    }

    func run() async {
        guard let modelName = ModelNameValidator.normalized(selectedModelName) else {
            errorMessage = "Choose an installed completion model."
            return
        }
        await runQueue(targets: [BenchmarkModelTarget(name: modelName, digest: "")]) { _ in }
    }

    func runQueue(
        targets: [BenchmarkModelTarget],
        persist: @escaping PersistenceHandler
    ) async {
        guard let prepared = prepareQueue(targets: targets) else { return }
        await performQueue(prepared: prepared, persist: persist)
    }

    func cancel() {
        benchmarkTask?.cancel()
    }

    func clearResults() {
        guard !isRunning else { return }
        samples = []
        completedSessions = []
        completedIterations = 0
        totalIterations = 0
        currentIteration = 0
        currentModelName = ""
        currentModelIndex = 0
        totalModels = 0
        errorMessage = nil
        noticeMessage = nil
    }

    private struct PreparedQueue {
        let targets: [BenchmarkModelTarget]
        let prompt: String
        let iterations: Int
        let outputTokenLimit: Int
    }

    private func prepareQueue(targets: [BenchmarkModelTarget]) -> PreparedQueue? {
        guard !isRunning else { return nil }

        var seen = Set<String>()
        let normalizedTargets = targets.compactMap { target -> BenchmarkModelTarget? in
            guard let name = ModelNameValidator.normalized(target.name), seen.insert(name).inserted else {
                return nil
            }
            return BenchmarkModelTarget(name: name, digest: target.digest)
        }
        guard !normalizedTargets.isEmpty else {
            errorMessage = "Choose at least one installed completion model."
            return nil
        }

        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            errorMessage = "Enter a benchmark prompt."
            return nil
        }

        let iterationCount = min(max(iterations, 1), 10)
        iterations = iterationCount
        outputTokenLimit = min(max(outputTokenLimit, 1), 2_048)
        samples = []
        completedSessions = []
        completedIterations = 0
        totalIterations = normalizedTargets.count * iterationCount
        currentIteration = 0
        currentModelName = ""
        currentModelIndex = 0
        totalModels = normalizedTargets.count
        errorMessage = nil
        noticeMessage = nil
        isRunning = true

        return PreparedQueue(
            targets: normalizedTargets,
            prompt: normalizedPrompt,
            iterations: iterationCount,
            outputTokenLimit: outputTokenLimit
        )
    }

    private func performQueue(
        prepared: PreparedQueue,
        persist: PersistenceHandler
    ) async {
        defer {
            isRunning = false
            benchmarkTask = nil
            currentIteration = 0
        }

        let ollamaVersion = (try? await fetchOllamaVersion()) ?? "Unknown"
        let capturedEnvironment = captureEnvironment()
        let environment = BenchmarkEnvironmentSnapshot(
            operatingSystem: capturedEnvironment.operatingSystem,
            hardwareModel: capturedEnvironment.hardwareModel,
            physicalMemoryBytes: capturedEnvironment.physicalMemoryBytes,
            thermalState: capturedEnvironment.thermalState,
            ollamaVersion: ollamaVersion
        )

        for (targetOffset, target) in prepared.targets.enumerated() {
            currentModelIndex = targetOffset + 1
            currentModelName = target.name
            selectedModelName = target.name
            samples = []
            let createdAt = Date()

            do {
                try Task.checkCancellation()
                try await unloadAllModels()

                for iteration in 1...prepared.iterations {
                    try Task.checkCancellation()
                    currentIteration = iteration
                    let configuration = BenchmarkConfiguration(
                        modelName: target.name,
                        prompt: prepared.prompt,
                        outputTokenLimit: prepared.outputTokenLimit
                    )
                    let sample = try await executor(configuration, iteration)
                    samples.append(sample)
                    completedIterations += 1
                }

                let snapshot = makeSnapshot(
                    target: target,
                    prepared: prepared,
                    environment: environment,
                    createdAt: createdAt,
                    status: .completed,
                    errorMessage: nil
                )
                save(snapshot, using: persist)
                completedSessions.append(snapshot)
                try await unloadAllModels()
            } catch is CancellationError {
                let snapshot = makeSnapshot(
                    target: target,
                    prepared: prepared,
                    environment: environment,
                    createdAt: createdAt,
                    status: .cancelled,
                    errorMessage: "Benchmark cancelled."
                )
                save(snapshot, using: persist)
                completedSessions.append(snapshot)
                try? await unloadAllModels()
                noticeMessage = completedIterations == 0
                    ? "Benchmark queue cancelled."
                    : "Benchmark queue stopped after \(completedIterations) completed run\(completedIterations == 1 ? "" : "s")."
                return
            } catch {
                let message = message(for: error)
                let snapshot = makeSnapshot(
                    target: target,
                    prepared: prepared,
                    environment: environment,
                    createdAt: createdAt,
                    status: .failed,
                    errorMessage: message
                )
                save(snapshot, using: persist)
                completedSessions.append(snapshot)
                errorMessage = "\(target.name): \(message)"
                try? await unloadAllModels()
            }
        }

        let completedModels = completedSessions.filter { $0.status == .completed }.count
        noticeMessage = "Completed \(completedModels) of \(prepared.targets.count) model benchmark\(prepared.targets.count == 1 ? "" : "s")."
    }

    private func makeSnapshot(
        target: BenchmarkModelTarget,
        prepared: PreparedQueue,
        environment: BenchmarkEnvironmentSnapshot,
        createdAt: Date,
        status: BenchmarkSessionStatus,
        errorMessage: String?
    ) -> BenchmarkSessionSnapshot {
        BenchmarkSessionSnapshot(
            id: UUID(),
            createdAt: createdAt,
            completedAt: Date(),
            status: status,
            modelName: target.name,
            modelDigest: target.digest,
            prompt: prepared.prompt,
            outputTokenLimit: prepared.outputTokenLimit,
            iterationsRequested: prepared.iterations,
            temperature: 0,
            seed: 42,
            protocolVersion: BenchmarkSessionSnapshot.currentProtocolVersion,
            environment: environment,
            runs: samples,
            errorMessage: errorMessage
        )
    }

    private func save(_ snapshot: BenchmarkSessionSnapshot, using persist: PersistenceHandler) {
        do {
            try persist(snapshot)
        } catch {
            errorMessage = "Could not save benchmark history: \(error.localizedDescription)"
        }
    }

    private func message(for error: Error) -> String {
        if let clientError = error as? OllamaClientError {
            return clientError.localizedDescription
        }
        return error.localizedDescription
    }
}
