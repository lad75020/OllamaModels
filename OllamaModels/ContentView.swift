import SwiftUI

private enum SidebarDestination: Hashable {
    case models
    case benchmarks
    case doctor
    case history
}

@MainActor
struct ContentView: View {
    @State private var viewModel: ModelsViewModel
    @State private var benchmarkViewModel: BenchmarkViewModel
    @State private var modelDoctorViewModel: ModelDoctorViewModel
    @State private var selectedDestination: SidebarDestination = .models
    @State private var filterText = ""
    @State private var showingAddModel = false
    @State private var showingRemoveConfirmation = false
    @State private var modelToRemove: OllamaModel?

    private let loadsOnAppear: Bool
    private let runtimePollInterval: Duration = .seconds(5)

    init(
        viewModel: ModelsViewModel = ModelsViewModel(),
        benchmarkViewModel: BenchmarkViewModel = BenchmarkViewModel(),
        modelDoctorViewModel: ModelDoctorViewModel = ModelDoctorViewModel(),
        loadsOnAppear: Bool = true
    ) {
        _viewModel = State(initialValue: viewModel)
        _benchmarkViewModel = State(initialValue: benchmarkViewModel)
        _modelDoctorViewModel = State(initialValue: modelDoctorViewModel)
        self.loadsOnAppear = loadsOnAppear
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task {
            guard loadsOnAppear else { return }
            await viewModel.refresh()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: runtimePollInterval)
                } catch {
                    break
                }
                await viewModel.refreshRuntimeStatus()
            }
        }
        .sheet(isPresented: $showingAddModel) {
            AddModelView { name in
                showingAddModel = false
                viewModel.startPull(named: name)
            }
        }
        .confirmationDialog(
            "Remove Model",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            if let modelToRemove {
                Button("Remove \(modelToRemove.name)", role: .destructive) {
                    let model = modelToRemove
                    self.modelToRemove = nil
                    Task {
                        await viewModel.remove(model)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                modelToRemove = nil
            }
        } message: {
            if let modelToRemove {
                Text("This removes \(modelToRemove.name) from Ollama. The action cannot be undone.")
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedDestination) {
            Section("Workspace") {
                Label("Installed Models", systemImage: "shippingbox")
                    .tag(SidebarDestination.models)
                Label("Benchmark Lab", systemImage: "gauge.with.dots.needle.67percent")
                    .tag(SidebarDestination.benchmarks)
                Label("Model Doctor", systemImage: "stethoscope")
                    .tag(SidebarDestination.doctor)
                Label("History & Compare", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .tag(SidebarDestination.history)
            }

            Section("Connection") {
                Label {
                    Text("Ollama API")
                } icon: {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 8))
                }

                Text(viewModel.endpointDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Runtime") {
                SidebarRuntimeIndicator(
                    title: "Loaded Models",
                    value: viewModel.runtimeStatus.loadedModelNamesLabel,
                    systemImage: "cpu",
                    accessibilityLabel: "Loaded Ollama models"
                )

                SidebarRuntimeIndicator(
                    title: "Memory Used",
                    value: viewModel.runtimeStatus.formattedTotalMemory,
                    systemImage: "memorychip",
                    accessibilityLabel: "Ollama memory usage"
                )
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        .navigationTitle("OllamaModels")
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedDestination {
        case .models:
            modelLibraryDetail
        case .benchmarks:
            BenchmarkView(
                viewModel: benchmarkViewModel,
                installedModels: viewModel.models,
                loadedModelNames: viewModel.runtimeStatus.loadedModelNames
            )
        case .doctor:
            ModelDoctorView(
                viewModel: modelDoctorViewModel,
                installedModels: viewModel.models,
                loadedModelNames: viewModel.runtimeStatus.loadedModelNames
            )
        case .history:
            BenchmarkHistoryView()
        }
    }

    private var modelLibraryDetail: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let errorMessage = viewModel.errorMessage {
                messageBanner(
                    text: errorMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red,
                    dismiss: viewModel.dismissError
                )
            }

            if let noticeMessage = viewModel.noticeMessage {
                messageBanner(
                    text: noticeMessage,
                    systemImage: "checkmark.circle.fill",
                    tint: .green,
                    dismiss: viewModel.dismissNotice
                )
            }

            modelContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .searchable(text: $filterText, placement: .toolbar, prompt: "Filter models")
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await viewModel.refresh() }
                }
                .disabled(viewModel.isBusy)
                .help("Refresh installed models")
            }

            ToolbarItem {
                Button("Unload", systemImage: "eject") {
                    Task { await viewModel.unloadAllModels() }
                }
                .disabled(viewModel.isBusy || viewModel.runtimeStatus.models.isEmpty)
                .help("Unload all models currently loaded in Ollama")
            }

            ToolbarItem {
                Button("Add Model", systemImage: "plus") {
                    showingAddModel = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
                .help("Pull a model into Ollama")
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Installed Models")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text(modelCountLabel)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing models")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var modelContent: some View {
        if viewModel.isRefreshing && viewModel.models.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Loading models…")
                    .foregroundStyle(.secondary)
            }
        } else if viewModel.models.isEmpty {
            emptyState
        } else if viewModel.filteredModels(for: filterText).isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No matching models")
                    .font(.headline)
                Text("Try a different filter.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Table(viewModel.filteredModels(for: filterText)) {
                TableColumn("Model") { model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .lineLimit(1)
                        Text(model.family)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 220)

                TableColumn("Parameters") { model in
                    Text(model.parameterSize)
                        .foregroundStyle(.secondary)
                }
                .width(min: 100)

                TableColumn("Size") { model in
                    Text(model.formattedSize)
                        .monospacedDigit()
                }
                .width(min: 90)

                TableColumn("Quantization") { model in
                    Text(model.quantization)
                        .foregroundStyle(.secondary)
                }
                .width(min: 110)

                TableColumn("Updated") { model in
                    Text(model.modifiedLabel)
                        .foregroundStyle(.secondary)
                }
                .width(min: 90)

                TableColumn("Actions") { model in
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        modelToRemove = model
                        showingRemoveConfirmation = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isBusy)
                    .help("Remove \(model.name)")
                }
                .width(min: 60)
            }
            .tableStyle(.inset)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No models installed")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Pull a model from Ollama to see it here.")
                .foregroundStyle(.secondary)
            Button("Add Model", systemImage: "plus") {
                showingAddModel = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isBusy)
        }
        .padding()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let pull = viewModel.activePull {
                ProgressView(value: pull.progress)
                    .frame(width: 110)
                Text("Adding \(pull.name): \(pull.status)")
                    .lineLimit(1)
                if let progressLabel = pull.progressLabel {
                    Text(progressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Stop Request") {
                    viewModel.cancelPull()
                }
                .buttonStyle(.borderless)
                .help("Stops this app's request. Ollama may retain partial data and resume it later.")
            } else if let deletingModelName = viewModel.deletingModelName {
                ProgressView()
                    .controlSize(.small)
                Text("Removing \(deletingModelName)…")
            } else if viewModel.isUnloadingModels {
                ProgressView()
                    .controlSize(.small)
                Text("Unloading models…")
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.green)
                Text("Ready")
            }

            Spacer()

            if let lastUpdated = viewModel.lastUpdated {
                Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func messageBanner(
        text: String,
        systemImage: String,
        tint: Color,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", systemImage: "xmark") {
                dismiss()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Dismiss message")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1))
        .accessibilityElement(children: .combine)
    }

    private var modelCountLabel: String {
        let count = viewModel.models.count
        return count == 1 ? "1 model available" : "\(count) models available"
    }
}

private struct SidebarRuntimeIndicator: View {
    let title: String
    let value: String
    let systemImage: String
    let accessibilityLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(value)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(value)
    }
}

@MainActor
private struct AddModelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var modelName = ""

    let onAdd: (String) -> Void

    private let suggestedModels = [
        "qwen3:4b",
        "llama3.1:8b",
        "qwen2.5-coder:7b"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Add Ollama Model")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Enter a model name or name:tag. Ollama will download it and make it available locally.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Model name", text: $modelName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit(submit)

            VStack(alignment: .leading, spacing: 8) {
                Text("Suggestions")
                    .font(.headline)
                ForEach(suggestedModels, id: \.self) { model in
                    Button(model) {
                        modelName = model
                    }
                    .buttonStyle(.link)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Add Model") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 430)
    }

    private var isValid: Bool {
        ModelNameValidator.normalized(modelName) != nil
    }

    private func submit() {
        guard isValid else { return }
        onAdd(modelName)
    }
}

#Preview {
    ContentView(
        viewModel: ModelsViewModel(
            initialModels: [
                OllamaModel(
                    name: "llama3.1:8b",
                    modifiedAt: "2026-08-15T12:00:00Z",
                    size: 4_600_000_000,
                    digest: "preview",
                    details: .init(
                        parentModel: nil,
                        format: "gguf",
                        family: "llama",
                        families: ["llama"],
                        parameterSize: "8.0B",
                        quantizationLevel: "Q4_K_M"
                    )
                ),
                OllamaModel(
                    name: "qwen3:4b",
                    modifiedAt: "2026-08-14T12:00:00Z",
                    size: 2_300_000_000,
                    digest: "preview",
                    details: .init(
                        parentModel: nil,
                        format: "gguf",
                        family: "qwen3",
                        families: ["qwen3"],
                        parameterSize: "4.0B",
                        quantizationLevel: "Q4_K_M"
                    )
                )
            ]
        ),
        loadsOnAppear: false
    )
}
