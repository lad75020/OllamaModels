import Foundation
import Observation

@MainActor
@Observable
final class ModelDoctorViewModel {
    typealias ProfileProvider = @Sendable (OllamaModel) async throws -> ModelDoctorProfile
    typealias ProbeRunner = @Sendable (BenchmarkConfiguration, Int) async throws -> BenchmarkSample
    typealias RuntimeProvider = @Sendable () async throws -> OllamaRuntimeStatus
    typealias Unloader = @Sendable () async throws -> Void
    typealias HostCapture = @Sendable () -> ModelDoctorHostSnapshot

    private var profileProvider: ProfileProvider
    private var probeRunner: ProbeRunner
    private var runtimeProvider: RuntimeProvider
    private var unloader: Unloader
    private let hostCapture: HostCapture
    private var task: Task<Void, Never>?

    private(set) var isRunning = false
    private(set) var currentModelName = ""
    private(set) var assessments: [ModelDoctorAssessment] = []
    private(set) var variantRecommendation: ModelDoctorVariantRecommendation?
    var errorMessage: String?
    var noticeMessage: String?

    convenience init(client: OllamaClient = OllamaClient()) {
        self.init(
            profileProvider: { try await client.modelDoctorProfile(for: $0) },
            probeRunner: { try await client.runBenchmark(configuration: $0, iteration: $1) },
            runtimeProvider: { try await client.runtimeStatus() },
            unloader: { try await client.unloadAllModelsAndWait() },
            hostCapture: ModelDoctorHostSnapshot.current
        )
    }

    init(
        profileProvider: @escaping ProfileProvider,
        probeRunner: @escaping ProbeRunner,
        runtimeProvider: @escaping RuntimeProvider,
        unloader: @escaping Unloader,
        hostCapture: @escaping HostCapture
    ) {
        self.profileProvider = profileProvider
        self.probeRunner = probeRunner
        self.runtimeProvider = runtimeProvider
        self.unloader = unloader
        self.hostCapture = hostCapture
    }

    func start(primary: OllamaModel, comparison: OllamaModel?) {
        guard !isRunning else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(primary: primary, comparison: comparison)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func configure(client: OllamaClient) {
        guard !isRunning else { return }
        profileProvider = { try await client.modelDoctorProfile(for: $0) }
        probeRunner = { try await client.runBenchmark(configuration: $0, iteration: $1) }
        runtimeProvider = { try await client.runtimeStatus() }
        unloader = { try await client.unloadAllModelsAndWait() }
        clear()
    }

    func clear() {
        guard !isRunning else { return }
        assessments = []
        variantRecommendation = nil
        errorMessage = nil
        noticeMessage = nil
    }

    func run(primary: OllamaModel, comparison: OllamaModel?) async {
        guard !isRunning else { return }
        isRunning = true
        assessments = []
        variantRecommendation = nil
        errorMessage = nil
        noticeMessage = nil

        defer {
            isRunning = false
            currentModelName = ""
            task = nil
        }

        var targets = [primary]
        if let comparison, comparison.name != primary.name {
            targets.append(comparison)
        }
        var skippedRemovedModelNames: [String] = []

        do {
            for model in targets {
                do {
                    try Task.checkCancellation()
                    currentModelName = model.name
                    try await unloader()
                    let profile = try await profileProvider(model)
                    let before = hostCapture()
                    let sample = try await probeRunner(
                        BenchmarkConfiguration(
                            modelName: model.name,
                            prompt: "Reply with one concise sentence explaining why local inference is useful.",
                            outputTokenLimit: 32
                        ),
                        1
                    )
                    let runtime = try await runtimeProvider()
                    let loaded = runtime.models.first(where: { $0.name == model.name })
                        ?? runtime.models.first
                    let after = hostCapture()
                    let probe = ModelDoctorProbe(
                        modelName: model.name,
                        observedMemoryBytes: loaded?.size ?? 0,
                        acceleratorMemoryBytes: loaded?.sizeVRAM ?? 0,
                        generationTokensPerSecond: sample.generationTokensPerSecond,
                        promptTokensPerSecond: sample.promptTokensPerSecond,
                        timeToFirstTokenSeconds: sample.timeToFirstTokenSeconds,
                        loadDurationSeconds: sample.loadDurationSeconds
                    )
                    assessments.append(
                        ModelDoctorAnalyzer.assess(
                            profile: profile,
                            hostBefore: before,
                            hostAfter: after,
                            probe: probe
                        )
                    )
                    try await unloader()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard Self.isRemovedModelError(error) else { throw error }
                    skippedRemovedModelNames.append(model.name)
                    try? await unloader()
                }
            }

            if assessments.count == 2 {
                variantRecommendation = ModelDoctorAnalyzer.recommendVariant(
                    between: assessments[0],
                    and: assessments[1]
                )
            }
            noticeMessage = Self.completionNotice(
                assessments: assessments,
                skippedRemovedModelNames: skippedRemovedModelNames
            )
        } catch is CancellationError {
            try? await unloader()
            noticeMessage = "Model Doctor stopped."
        } catch {
            try? await unloader()
            if let clientError = error as? OllamaClientError {
                errorMessage = clientError.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func isRemovedModelError(_ error: Error) -> Bool {
        guard case .server(let message) = error as? OllamaClientError else { return false }
        let normalized = message.lowercased()
        return normalized.contains("model")
            && (normalized.contains("not found") || normalized.contains("does not exist"))
    }

    private static func completionNotice(
        assessments: [ModelDoctorAssessment],
        skippedRemovedModelNames: [String]
    ) -> String? {
        let completed: String?
        switch assessments.count {
        case 1:
            completed = "Diagnosis completed for \(assessments[0].profile.name)."
        case 2:
            completed = "Diagnosis and variant comparison completed."
        default:
            completed = nil
        }

        let skipped: String?
        switch skippedRemovedModelNames.count {
        case 1:
            skipped = "Skipped removed model \(skippedRemovedModelNames[0])."
        case 2...:
            skipped = "Skipped removed models \(skippedRemovedModelNames.joined(separator: ", "))."
        default:
            skipped = nil
        }

        let notices = [completed, skipped].compactMap { $0 }
        return notices.isEmpty ? nil : notices.joined(separator: " ")
    }
}
