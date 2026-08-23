import Foundation
import Observation

@MainActor
@Observable
final class ModelsViewModel {
    private let client: OllamaClient
    private var operationTask: Task<Void, Never>?

    private(set) var models: [OllamaModel]
    private(set) var isRefreshing = false
    private(set) var activePull: PullState?
    private(set) var deletingModelName: String?
    private(set) var lastUpdated: Date?
    private(set) var runtimeStatus: OllamaRuntimeStatus

    var errorMessage: String?
    var noticeMessage: String?

    var endpointDescription: String {
        client.baseURL.absoluteString
    }

    var isBusy: Bool {
        isRefreshing || activePull != nil || deletingModelName != nil
    }

    init(
        client: OllamaClient = OllamaClient(),
        initialModels: [OllamaModel] = [],
        initialRuntimeStatus: OllamaRuntimeStatus = .empty
    ) {
        self.client = client
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

        do {
            for try await event in client.pullModel(named: name) {
                try Task.checkCancellation()
                activePull?.status = event.status ?? "Downloading…"
                activePull?.completed = event.completed
                activePull?.total = event.total
            }

            try Task.checkCancellation()
            models = try await client.listModels()
            lastUpdated = Date()
            noticeMessage = "Added \(name)."
        } catch is CancellationError {
            noticeMessage = "Stopped adding \(name)."
        } catch {
            errorMessage = message(for: error)
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
