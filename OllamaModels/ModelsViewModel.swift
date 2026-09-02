import Foundation
import Observation

struct PullProgressUpdateGate {
    private let minimumInterval: Duration
    private var lastPublishedAt: ContinuousClock.Instant?
    private var lastStatus: String?

    init(minimumInterval: Duration = .milliseconds(125)) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldPublish(
        status: String,
        isTerminal: Bool = false,
        now: ContinuousClock.Instant
    ) -> Bool {
        let statusChanged = status != lastStatus
        let intervalElapsed = lastPublishedAt.map {
            $0.advanced(by: minimumInterval) <= now
        } ?? true
        guard statusChanged || isTerminal || intervalElapsed else { return false }

        lastPublishedAt = now
        lastStatus = status
        return true
    }
}

enum PullCancellationNotice {
    static func message(for modelName: String) -> String {
        "Stopped this app's request for \(modelName). Ollama may retain partial data and resume it later."
    }
}

@MainActor
@Observable
final class ModelsViewModel {
    typealias Unloader = @Sendable () async throws -> Void

    private var client: OllamaClient
    private var unloader: Unloader
    private var operationTask: Task<Void, Never>?

    private(set) var models: [OllamaModel]
    private(set) var isRefreshing = false
    private(set) var activePull: PullState?
    private(set) var deletingModelName: String?
    private(set) var isUnloadingModels = false
    private(set) var lastUpdated: Date?
    private(set) var runtimeStatus: OllamaRuntimeStatus

    var errorMessage: String?
    var noticeMessage: String?

    var endpointDescription: String {
        client.baseURL.absoluteString
    }

    var supportsNativeModelManagement: Bool {
        client.supportsNativeModelManagement
    }

    var isBusy: Bool {
        isRefreshing || activePull != nil || deletingModelName != nil || isUnloadingModels
    }

    init(
        client: OllamaClient = OllamaClient(),
        initialModels: [OllamaModel] = [],
        initialRuntimeStatus: OllamaRuntimeStatus = .empty,
        unloader: Unloader? = nil
    ) {
        self.client = client
        self.unloader = unloader ?? { try await client.unloadAllModelsAndWait() }
        self.models = initialModels.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        self.runtimeStatus = initialRuntimeStatus
    }

    func filteredModels(for query: String) -> [OllamaModel] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter { model in
            model.name.localizedCaseInsensitiveContains(query)
                || model.family.localizedCaseInsensitiveContains(query)
                || model.parameterSize.localizedCaseInsensitiveContains(query)
        }
    }

    func refresh() async {
        guard !isBusy else { return }
        isRefreshing = true
        errorMessage = nil
        noticeMessage = nil
        defer { isRefreshing = false }

        do {
            models = try await client.listModels()
            lastUpdated = Date()
        } catch {
            errorMessage = message(for: error)
        }

        await refreshRuntimeStatus()
    }

    func refreshRuntimeStatus() async {
        do {
            runtimeStatus = try await client.runtimeStatus()
        } catch {
            // Runtime status is best-effort. Preserve the last successful value
            // and avoid repeating banners when background polling is unavailable.
        }
    }

    func configure(client: OllamaClient) {
        guard self.client.server != client.server, !isBusy else { return }
        operationTask?.cancel()
        self.client = client
        unloader = { try await client.unloadAllModelsAndWait() }
        models = []
        runtimeStatus = .empty
        lastUpdated = nil
        errorMessage = nil
        noticeMessage = nil
    }

    func startPull(named rawName: String) {
        guard !isBusy else { return }
        guard let name = ModelNameValidator.normalized(rawName) else {
            errorMessage = "Enter a model name without spaces, such as qwen3:4b."
            noticeMessage = nil
            return
        }

        operationTask?.cancel()
        errorMessage = nil
        noticeMessage = nil
        activePull = PullState(name: name, status: "Starting…")
        operationTask = Task { [weak self] in
            await self?.performPull(named: name)
        }
    }

    func cancelPull() {
        guard activePull != nil else { return }
        activePull?.status = "Stopping request…"
        operationTask?.cancel()
    }

    func remove(_ model: OllamaModel) async {
        guard !isBusy else { return }
        deletingModelName = model.name
        errorMessage = nil
        noticeMessage = nil
        defer { deletingModelName = nil }

        do {
            try await client.deleteModel(named: model.name)
            models.removeAll { $0.id == model.id }
            noticeMessage = "Removed \(model.name)."
            lastUpdated = Date()
        } catch {
            errorMessage = message(for: error)
        }
    }

    func unloadAllModels() async {
        guard !isBusy, !runtimeStatus.models.isEmpty else { return }
        isUnloadingModels = true
        errorMessage = nil
        noticeMessage = nil
        defer { isUnloadingModels = false }

        do {
            try await unloader()
            runtimeStatus = .empty
            noticeMessage = "Unloaded all models."
        } catch {
            errorMessage = message(for: error)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func dismissNotice() {
        noticeMessage = nil
    }

    private func performPull(named name: String) async {
        defer {
            activePull = nil
            operationTask = nil
        }

        let clock = ContinuousClock()
        var progressGate = PullProgressUpdateGate()

        do {
            for try await event in client.pullModel(named: name) {
                try Task.checkCancellation()
                let status = event.status ?? "Downloading…"
                let isTerminal = if let completed = event.completed,
                                    let total = event.total {
                    total > 0 && completed >= total
                } else {
                    false
                }

                if progressGate.shouldPublish(
                    status: status,
                    isTerminal: isTerminal,
                    now: clock.now
                ) {
                    updateActivePull(with: event, fallbackStatus: status)
                }
            }

            try Task.checkCancellation()
            models = try await client.listModels()
            lastUpdated = Date()
            noticeMessage = "Added \(name)."
        } catch is CancellationError {
            noticeMessage = PullCancellationNotice.message(for: name)
        } catch where Task.isCancelled {
            // listModels() normalizes URLSession cancellation into OllamaClientError,
            // so preserve cancellation semantics when a stop races this refresh.
            noticeMessage = PullCancellationNotice.message(for: name)
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func updateActivePull(with event: OllamaPullEvent, fallbackStatus: String) {
        guard var nextPull = activePull else { return }
        nextPull.status = fallbackStatus
        nextPull.completed = event.completed
        nextPull.total = event.total

        if nextPull != activePull {
            activePull = nextPull
        }
    }

    private func message(for error: Error) -> String {
        if let clientError = error as? OllamaClientError {
            return clientError.localizedDescription
        }
        return error.localizedDescription
    }

    struct PullState: Equatable, Sendable {
        let name: String
        var status: String
        var completed: Int64?
        var total: Int64?

        init(name: String, status: String, completed: Int64? = nil, total: Int64? = nil) {
            self.name = name
            self.status = status
            self.completed = completed
            self.total = total
        }

        var progress: Double? {
            guard let completed, let total, total > 0 else { return nil }
            return min(max(Double(completed) / Double(total), 0), 1)
        }

        var progressLabel: String? {
            guard let completed, let total, total > 0 else { return nil }
            let completedText = ByteCountFormatter.string(
                fromByteCount: completed,
                countStyle: .file
            )
            let totalText = ByteCountFormatter.string(
                fromByteCount: total,
                countStyle: .file
            )
            return "\(completedText) / \(totalText)"
        }
    }
}
