import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum BenchmarkRunReadiness {
    static func canStart(selectedModelNames: Set<String>, isRunning: Bool) -> Bool {
        !selectedModelNames.isEmpty && !isRunning
    }
}

@MainActor
struct BenchmarkView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var viewModel: BenchmarkViewModel
    @State private var selectedModelNames: Set<String> = []
    @State private var isImportingTestSet = false
    let installedModels: [OllamaModel]
    let loadedModelNames: [String]

    init(
        viewModel: BenchmarkViewModel,
        installedModels: [OllamaModel],
        loadedModelNames: [String] = []
    ) {
        self.viewModel = viewModel
        self.installedModels = installedModels
        self.loadedModelNames = loadedModelNames
    }

    private var completionModels: [OllamaModel] {
        installedModels.filter(\.supportsLocalBenchmark)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let errorMessage = viewModel.errorMessage {
                messageBanner(
                    text: errorMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                ) {
                    viewModel.errorMessage = nil
                }
            }

            if let noticeMessage = viewModel.noticeMessage {
                messageBanner(
                    text: noticeMessage,
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                ) {
                    viewModel.noticeMessage = nil
                }
            }

            if completionModels.isEmpty {
                ContentUnavailableView(
                    "No Completion Models",
                    systemImage: "gauge.with.dots.needle.67percent",
                    description: Text("Install a text-generation model before running a benchmark.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                benchmarkContent
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear(perform: synchronizeModelSelection)
        .onChange(of: completionModels.map(\.name)) {
            synchronizeModelSelection()
        }
        .fileImporter(
            isPresented: $isImportingTestSet,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case let .success(url):
                loadTestSet(from: url)
            case let .failure(error):
                viewModel.errorMessage = "Could not choose the JSON test file: \(error.localizedDescription)"
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Benchmark Lab")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("Measure deterministic local inference performance through the selected local server.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Benchmark running")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var benchmarkContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                configurationCard

                if viewModel.isRunning {
                    runningProgress
                    liveOutput
                }

                if let summary = viewModel.summary {
                    summarySection(summary)
                    resultsSection
                } else {
                    benchmarkEmptyState
                }
            }
            .padding(20)
        }
    }

    private var configurationCard: some View {
        GroupBox("Configuration") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Menu {
                            ForEach(completionModels) { model in
                                Button {
                                    toggleModel(model.name)
                                } label: {
                                    if selectedModelNames.contains(model.name) {
                                        Label(model.name, systemImage: "checkmark")
                                    } else {
                                        Text(model.name)
                                    }
                                }
                            }
                            Divider()
                            Button("Select All") {
                                selectedModelNames = Set(completionModels.map(\.name))
                            }
                            Button("Clear Selection") {
                                selectedModelNames.removeAll()
                            }
                        } label: {
                            Text(modelSelectionLabel)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 260)
                        .disabled(viewModel.isRunning)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cycles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Stepper(
                            "\(viewModel.iterations)",
                            value: $viewModel.iterations,
                            in: 1...10
                        )
                        .frame(width: 100)
                        .disabled(viewModel.isRunning)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Maximum output")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Stepper(
                            "\(viewModel.outputTokenLimit) tokens",
                            value: $viewModel.outputTokenLimit,
                            in: 16...2_048,
                            step: 16
                        )
                        .frame(width: 170)
                        .disabled(viewModel.isRunning)
                    }

                    Spacer()
                }

                testSetSection

                HStack(spacing: 10) {
                    if viewModel.isRunning {
                        Button("Stop", systemImage: "stop.fill", role: .destructive) {
                            viewModel.cancel()
                        }
                    } else {
                        Button("Run Benchmark", systemImage: "play.fill") {
                            let repository = BenchmarkRepository(context: modelContext)
                            viewModel.startQueue(targets: selectedTargets) { snapshot in
                                try repository.save(snapshot)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart)
                    }

                    Button("Clear Results", systemImage: "trash") {
                        viewModel.clearResults()
                    }
                    .disabled(viewModel.isRunning || viewModel.samples.isEmpty)

                    Spacer()

                    Label("Temperature 0 · Seed 42", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Fixed sampling settings make repeated runs comparable.")
                }

                Label(
                    "Selected models run sequentially. Ollama unloads resident models; OpenAI-compatible servers manage residency themselves.",
                    systemImage: "memorychip"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var testSetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Load Test JSON…", systemImage: "doc.badge.plus") {
                    isImportingTestSet = true
                }
                .disabled(viewModel.isRunning)
                if viewModel.testSet != nil {
                    Button("Remove", systemImage: "xmark") {
                        viewModel.testSet = nil
                    }
                    .disabled(viewModel.isRunning)
                }
            }

            if let testSet = viewModel.testSet {
                BenchmarkTestSetTree(testSet: testSet)
            } else {
                ContentUnavailableView(
                    "No JSON Test Set",
                    systemImage: "curlybraces.square",
                    description: Text("Load a file containing a tests array with prompt and correctAnswer values.")
                )
                .frame(maxWidth: .infinity, minHeight: 92)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator, lineWidth: 1)
                }
            }
        }
    }

    private var runningProgress: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(runningLabel)
                    .font(.headline)
                Spacer()
                Text(viewModel.progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: viewModel.progress)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(runningLabel)
        .accessibilityValue(viewModel.progress.formatted(.percent))
    }

    private var liveOutput: some View {
        GroupBox("Live Model Output") {
            ScrollView {
                Text(viewModel.liveOutput.isEmpty ? "Waiting for model output…" : viewModel.liveOutput)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }
            .frame(minHeight: 90, maxHeight: 180)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live model output")
        .accessibilityValue(viewModel.liveOutput.isEmpty ? "Waiting for model output" : viewModel.liveOutput)
    }

    private func summarySection(_ summary: BenchmarkSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Summary")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("\(summary.sampleCount) run\(summary.sampleCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(summary.modelName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 155), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                MetricCard(
                    title: "Generation",
                    value: metric(summary.averageGenerationTokensPerSecond, suffix: " tok/s"),
                    detail: "Best \(metric(summary.bestGenerationTokensPerSecond, suffix: " tok/s"))",
                    systemImage: "text.line.first.and.arrowtriangle.forward"
                )
                MetricCard(
                    title: "Time to first token",
                    value: metric(summary.averageTimeToFirstTokenSeconds, suffix: " s"),
                    detail: "Includes load time when cold",
                    systemImage: "bolt.fill"
                )
                MetricCard(
                    title: "Prompt processing",
                    value: metric(summary.averagePromptTokensPerSecond, suffix: " tok/s"),
                    detail: "Average input throughput",
                    systemImage: "arrow.down.doc.fill"
                )
                MetricCard(
                    title: "Model load",
                    value: metric(summary.averageLoadDurationSeconds, suffix: " s"),
                    detail: "Average reported duration",
                    systemImage: "memorychip.fill"
                )
            }
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Runs")
                .font(.title2)
                .fontWeight(.semibold)

            Table(viewModel.samples) {
                TableColumn("Run") { sample in
                    Text(sample.iteration, format: .number)
                        .monospacedDigit()
                }
                .width(min: 40, ideal: 48, max: 60)

                TableColumn("Correct") { sample in
                    correctnessIndicator(for: sample)
                }
                .width(min: 58, ideal: 64, max: 72)

                TableColumn("Kind") { sample in
                    Text(sample.runKind.label)
                        .foregroundStyle(sample.runKind == .cold ? .primary : .secondary)
                }
                .width(min: 55)

                TableColumn("First token") { sample in
                    Text(metric(sample.timeToFirstTokenSeconds, suffix: " s"))
                        .monospacedDigit()
                }
                .width(min: 90)

                TableColumn("Generation") { sample in
                    Text(metric(sample.generationTokensPerSecond, suffix: " tok/s"))
                        .monospacedDigit()
                }
                .width(min: 105)

                TableColumn("Prompt") { sample in
                    Text(metric(sample.promptTokensPerSecond, suffix: " tok/s"))
                        .monospacedDigit()
                }
                .width(min: 95)

                TableColumn("Load") { sample in
                    Text(metric(sample.loadDurationSeconds, suffix: " s"))
                        .monospacedDigit()
                }
                .width(min: 75)

                TableColumn("Total") { sample in
                    Text(metric(sample.totalDurationSeconds, suffix: " s"))
                        .monospacedDigit()
                }
                .width(min: 75)

                TableColumn("Output") { sample in
                    Text("\(sample.evaluationCount) tokens")
                        .monospacedDigit()
                }
                .width(min: 85)
            }
            .frame(minHeight: 170, idealHeight: 220)
            .tableStyle(.inset)
        }
    }

    private var benchmarkEmptyState: some View {
        ContentUnavailableView {
            Label("Ready to Benchmark", systemImage: "gauge.open.with.lines.needle.33percent")
        } description: {
            Text("Load a JSON test set to measure each prompt and validate its response.")
        }
        .frame(maxWidth: .infinity, minHeight: 190)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1))
        .accessibilityElement(children: .combine)
    }

    private var canStart: Bool {
        BenchmarkRunReadiness.canStart(
            selectedModelNames: selectedModelNames,
            isRunning: viewModel.isRunning
        )
    }

    private var runningLabel: String {
        "Model \(viewModel.currentModelIndex) of \(viewModel.totalModels) · Test \(viewModel.currentTestIndex) of \(viewModel.testCount) · Run \(viewModel.currentIteration) · \(viewModel.currentModelName)"
    }

    @ViewBuilder
    private func correctnessIndicator(for sample: BenchmarkSample) -> some View {
        if let isCorrect = sample.isCorrect {
            Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isCorrect ? .green : .red)
                .accessibilityLabel(isCorrect ? "Correct" : "Incorrect")
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("No expected answer")
        }
    }

    private func synchronizeModelSelection() {
        guard !viewModel.isRunning else { return }
        let names = completionModels.map(\.name)
        selectedModelNames.formIntersection(names)
        guard selectedModelNames.isEmpty else { return }
        if let preferred = loadedModelNames.first(where: names.contains)
            ?? completionModels.min(by: { $0.size < $1.size })?.name {
            selectedModelNames.insert(preferred)
            viewModel.selectedModelName = preferred
        }
    }

    private var selectedTargets: [BenchmarkModelTarget] {
        completionModels
            .filter { selectedModelNames.contains($0.name) }
            .map { BenchmarkModelTarget(name: $0.name, digest: $0.digest) }
    }

    private var modelSelectionLabel: String {
        switch selectedModelNames.count {
        case 0: "Choose models"
        case 1: selectedModelNames.first ?? "1 model"
        default: "\(selectedModelNames.count) models selected"
        }
    }

    private func toggleModel(_ modelName: String) {
        if selectedModelNames.contains(modelName) {
            selectedModelNames.remove(modelName)
        } else {
            selectedModelNames.insert(modelName)
        }
    }

    private func loadTestSet(from url: URL) {
        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            viewModel.testSet = try BenchmarkTestSet.decode(data: Data(contentsOf: url))
            viewModel.errorMessage = nil
        } catch {
            viewModel.errorMessage = "Could not load the JSON test file: \(error.localizedDescription)"
        }
    }

    private func metric(_ value: Double, suffix: String) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))) + suffix
    }
}

private struct BenchmarkTestSetTree: View {
    let testSet: BenchmarkTestSet
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(testSet.tests.enumerated()), id: \.element.id) { index, test in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("tests[\(index)]")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            jsonField(key: "prompt", value: test.prompt)
                            jsonField(key: "correctAnswer", value: test.correctAnswer)
                        }
                        .padding(.leading, 12)
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 130)
        } label: {
            Label("{ \"tests\": [\(testSet.tests.count)] }", systemImage: "curlybraces.square")
                .font(.callout.monospaced())
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.separator, lineWidth: 1)
        }
    }

    private func jsonField(key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\"\(key)\":")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("\"\(value)\"")
                .font(.caption)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    BenchmarkView(
        viewModel: BenchmarkViewModel { configuration, iteration in
            BenchmarkSample(
                modelName: configuration.modelName,
                iteration: iteration,
                startedAt: .now,
                timeToFirstTokenSeconds: 0.18 + Double(iteration) * 0.02,
                totalDurationNanoseconds: 2_900_000_000,
                loadDurationNanoseconds: iteration == 1 ? 420_000_000 : 20_000_000,
                promptEvaluationCount: 24,
                promptEvaluationDurationNanoseconds: 360_000_000,
                evaluationCount: 128,
                evaluationDurationNanoseconds: 2_200_000_000
            )
        },
        installedModels: [
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
                ),
                capabilities: ["completion"]
            )
        ]
    )
    .frame(width: 980, height: 720)
}
