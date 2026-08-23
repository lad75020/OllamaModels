import SwiftUI

@MainActor
struct ModelDoctorView: View {
    @Bindable var viewModel: ModelDoctorViewModel
    let installedModels: [OllamaModel]
    let loadedModelNames: [String]

    @State private var selectedModelName = ""
    @State private var comparisonModelName = ""

    private var candidates: [OllamaModel] {
        installedModels.filter(\.supportsLocalBenchmark)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let errorMessage = viewModel.errorMessage {
                banner(errorMessage, image: "exclamationmark.triangle.fill", tint: .red) {
                    viewModel.errorMessage = nil
                }
            }
            if let noticeMessage = viewModel.noticeMessage {
                banner(noticeMessage, image: "checkmark.circle.fill", tint: .green) {
                    viewModel.noticeMessage = nil
                }
            }

            if candidates.isEmpty {
                ContentUnavailableView(
                    "No Models to Diagnose",
                    systemImage: "stethoscope",
                    description: Text("Install a local completion model before running Model Doctor.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .frame(minWidth: 840, minHeight: 580)
        .onAppear(perform: synchronizeSelection)
        .onChange(of: candidates.map(\.name)) {
            synchronizeSelection()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model Doctor")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("Measure fit, memory behavior, acceleration, and inference health with one diagnostic probe.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Model Doctor running")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controls

                if viewModel.isRunning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Diagnosing \(viewModel.currentModelName)…")
                            .font(.headline)
                        Spacer()
                        Text("This can briefly load the model and then releases it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                if let recommendation = viewModel.variantRecommendation {
                    variantRecommendation(recommendation)
                }

                ForEach(viewModel.assessments) { assessment in
                    assessmentCard(assessment)
                }

                if viewModel.assessments.isEmpty, !viewModel.isRunning {
                    ContentUnavailableView {
                        Label("Ready for a Check-up", systemImage: "stethoscope")
                    } description: {
                        Text("Choose a model and run a short probe. Model Doctor unloads resident models before and after each diagnosis.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 210)
                }
            }
            .padding(20)
        }
    }

    private var controls: some View {
        GroupBox("Diagnostic Configuration") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    Picker("Model", selection: $selectedModelName) {
                        ForEach(candidates) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                    .frame(minWidth: 260)

                    Picker("Compare variant", selection: $comparisonModelName) {
                        Text("None").tag("")
                        ForEach(candidates.filter { $0.name != selectedModelName }) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                    .frame(minWidth: 260)

                    Spacer()
                }
                .disabled(viewModel.isRunning)

                HStack(spacing: 10) {
                    if viewModel.isRunning {
                        Button("Stop Diagnosis", systemImage: "stop.fill", role: .destructive) {
                            viewModel.cancel()
                        }
                    } else {
                        Button("Run Model Doctor", systemImage: "stethoscope") {
                            guard let primaryModel else { return }
                            viewModel.start(primary: primaryModel, comparison: comparisonModel)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(primaryModel == nil)
                    }

                    Button("Clear Report", systemImage: "trash") {
                        viewModel.clear()
                    }
                    .disabled(viewModel.isRunning || viewModel.assessments.isEmpty)

                    Spacer()
                    Label("32-token deterministic probe", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Label(
                    "The probe temporarily unloads other Ollama models. Select a second installed variant to receive a keep/remove recommendation.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private func assessmentCard(_ assessment: ModelDoctorAssessment) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(assessment.profile.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(assessment.profile.family) · \(assessment.profile.quantization)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(assessment.comfort.title)
                    .font(.headline)
                    .foregroundStyle(comfortColor(assessment.comfort))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(comfortColor(assessment.comfort).opacity(0.12), in: Capsule())
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                DoctorMetric(
                    title: "Estimated memory",
                    value: bytes(assessment.estimatedMemoryBytes),
                    detail: "At recommended context",
                    image: "chart.bar.doc.horizontal"
                )
                DoctorMetric(
                    title: "Observed memory",
                    value: bytes(assessment.observedMemoryBytes),
                    detail: memoryDifference(assessment),
                    image: "memorychip"
                )
                DoctorMetric(
                    title: "Recommended context",
                    value: assessment.recommendedContextSize.formatted(),
                    detail: "Model maximum \(assessment.profile.maximumContextSize.formatted())",
                    image: "text.alignleft"
                )
                DoctorMetric(
                    title: "Acceleration",
                    value: assessment.acceleratorMode.title,
                    detail: "\(acceleratorPercent(assessment)) accelerator-resident",
                    image: "cpu"
                )
                DoctorMetric(
                    title: "Generation",
                    value: assessment.probe.generationTokensPerSecond.formatted(.number.precision(.fractionLength(1))) + " tok/s",
                    detail: "First token \(assessment.probe.timeToFirstTokenSeconds.formatted(.number.precision(.fractionLength(2)))) s",
                    image: "speedometer"
                )
                DoctorMetric(
                    title: "Memory pressure",
                    value: bytes(assessment.hostAfter.availableMemoryBytes) + " free",
                    detail: "Swap \(bytes(assessment.hostAfter.swapUsedBytes))",
                    image: "waveform.path.ecg"
                )
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Findings & Recommendations")
                    .font(.headline)
                ForEach(assessment.findings) { finding in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: findingImage(finding))
                            .foregroundStyle(findingColor(finding))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title).fontWeight(.medium)
                            Text(finding.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.34), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
    }

    private func variantRecommendation(_ recommendation: ModelDoctorVariantRecommendation) -> some View {
        GroupBox("Variant Recommendation") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Keep \(recommendation.recommendedModelName)")
                        .font(.headline)
                    Text("Consider removing \(recommendation.modelToRemoveName). \(recommendation.reason)")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(8)
        }
    }

    private func banner(
        _ text: String,
        image: String,
        tint: Color,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: image).foregroundStyle(tint)
            Text(text)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1))
    }

    private var primaryModel: OllamaModel? {
        candidates.first { $0.name == selectedModelName }
    }

    private var comparisonModel: OllamaModel? {
        candidates.first { $0.name == comparisonModelName }
    }

    private func synchronizeSelection() {
        guard !viewModel.isRunning else { return }
        let names = candidates.map(\.name)
        if !names.contains(selectedModelName) {
            selectedModelName = loadedModelNames.first(where: names.contains)
                ?? candidates.min(by: { $0.size < $1.size })?.name
                ?? ""
        }
        if comparisonModelName == selectedModelName || !names.contains(comparisonModelName) {
            comparisonModelName = ""
        }
    }

    private func comfortColor(_ comfort: ModelDoctorComfort) -> Color {
        switch comfort {
        case .comfortable: .green
        case .constrained: .orange
        case .unsuitable: .red
        }
    }

    private func findingColor(_ finding: ModelDoctorFinding) -> Color {
        switch finding.severity {
        case .information: .secondary
        case .recommendation: .blue
        case .warning: .orange
        case .critical: .red
        }
    }

    private func findingImage(_ finding: ModelDoctorFinding) -> String {
        switch finding.severity {
        case .information: "info.circle.fill"
        case .recommendation: "lightbulb.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .memory)
    }

    private func acceleratorPercent(_ assessment: ModelDoctorAssessment) -> String {
        guard assessment.observedMemoryBytes > 0 else { return "Not observed" }
        return (Double(assessment.probe.acceleratorMemoryBytes) / Double(assessment.observedMemoryBytes))
            .formatted(.percent.precision(.fractionLength(0)))
    }

    private func memoryDifference(_ assessment: ModelDoctorAssessment) -> String {
        let difference = assessment.observedMemoryBytes - assessment.estimatedMemoryBytes
        let prefix = difference >= 0 ? "+" : "−"
        return prefix + bytes(abs(difference)) + " versus estimate"
    }
}

private struct DoctorMetric: View {
    let title: String
    let value: String
    let detail: String
    let image: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: image)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
