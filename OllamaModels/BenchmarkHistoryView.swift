import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum BenchmarkHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case completed
    case failed
    case cancelled

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

@MainActor
struct BenchmarkHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BenchmarkSessionRecord.createdAt, order: .reverse)
    private var records: [BenchmarkSessionRecord]

    @State private var searchText = ""
    @State private var filter: BenchmarkHistoryFilter = .all
    @State private var selectedIDs: Set<UUID> = []
    @State private var showingDeleteConfirmation = false
    @State private var exportDocument: BenchmarkExportDocument?
    @State private var showingExporter = false
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()

            if records.isEmpty {
                ContentUnavailableView(
                    "No Benchmark History",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    description: Text("Completed, failed, and cancelled benchmark sessions will appear here automatically.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    historyList
                        .frame(minWidth: 320, idealWidth: 370, maxWidth: 470)
                    detail
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search models or prompts")
        .confirmationDialog(
            "Delete Benchmark History",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(deleteButtonLabel, role: .destructive) {
                deleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the selected benchmark sessions and their individual runs.")
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: exportDocument?.contentType ?? .data,
            defaultFilename: exportDocument?.filename ?? "ollama-benchmarks"
        ) { result in
            if case .failure(let error) = result {
                exportError = error.localizedDescription
            }
            exportDocument = nil
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "Unknown export error")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Benchmark History")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("Search prior runs, compare compatible sessions, and export reproducible results.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(records.count) session\(records.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Status", selection: $filter) {
                ForEach(BenchmarkHistoryFilter.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 410)

            Spacer()

            Menu("Export", systemImage: "square.and.arrow.up") {
                ForEach(BenchmarkExportFormat.allCases) { format in
                    Button("Selected as \(format.label)") {
                        export(selectedSnapshots, format: format)
                    }
                    .disabled(selectedSnapshots.isEmpty)

                    Button("Filtered as \(format.label)") {
                        export(filteredRecords.map(\.snapshot), format: format)
                    }
                    .disabled(filteredRecords.isEmpty)
                }
            }

            Button("Delete", systemImage: "trash", role: .destructive) {
                showingDeleteConfirmation = true
            }
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var historyList: some View {
        List(selection: $selectedIDs) {
            ForEach(filteredRecords) { record in
                BenchmarkHistoryRow(snapshot: record.snapshot)
                    .tag(record.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if filteredRecords.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        let selected = selectedSnapshots
        if selected.isEmpty {
            ContentUnavailableView(
                "Select Benchmark Sessions",
                systemImage: "checklist",
                description: Text("Select one session for details or Command-click two or more sessions to compare them.")
            )
        } else if selected.count == 1, let session = selected.first {
            BenchmarkSessionDetailView(session: session)
        } else {
            BenchmarkComparisonView(sessions: selected)
        }
    }

    private var filteredRecords: [BenchmarkSessionRecord] {
        records.filter { record in
            let statusMatches = filter == .all || record.statusRawValue == filter.rawValue
            guard statusMatches else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return record.modelName.localizedCaseInsensitiveContains(query)
                || record.prompt.localizedCaseInsensitiveContains(query)
                || record.modelDigest.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedSnapshots: [BenchmarkSessionSnapshot] {
        records
            .filter { selectedIDs.contains($0.id) }
            .map(\.snapshot)
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var deleteButtonLabel: String {
        selectedIDs.count == 1 ? "Delete Session" : "Delete \(selectedIDs.count) Sessions"
    }

    private func deleteSelected() {
        do {
            let selected = records.filter { selectedIDs.contains($0.id) }
            try BenchmarkRepository(context: modelContext).delete(selected)
            selectedIDs.removeAll()
        } catch {
            exportError = "Could not delete benchmark history: \(error.localizedDescription)"
        }
    }

    private func export(_ sessions: [BenchmarkSessionSnapshot], format: BenchmarkExportFormat) {
        do {
            let value = try BenchmarkExporter.string(for: sessions, format: format)
            exportDocument = BenchmarkExportDocument(value: value, format: format)
            showingExporter = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct BenchmarkHistoryRow: View {
    let snapshot: BenchmarkSessionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(snapshot.modelName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                statusLabel
            }
            HStack(spacing: 12) {
                Text(snapshot.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("\(snapshot.completedRunCount)/\(snapshot.iterationsRequested) runs")
                if let summary = snapshot.summary {
                    Text(summary.averageGenerationTokensPerSecond, format: .number.precision(.fractionLength(1)))
                        + Text(" tok/s")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(snapshot.prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var statusLabel: some View {
        Text(snapshot.status.label)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.14), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .completed: .green
        case .cancelled: .orange
        case .failed: .red
        }
    }
}

private struct BenchmarkSessionDetailView: View {
    let session: BenchmarkSessionSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.modelName)
                        .font(.title)
                        .fontWeight(.semibold)
                    Text(session.createdAt.formatted(date: .long, time: .standard))
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = session.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .padding(10)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                if let summary = session.summary {
                    summaryGrid(summary)
                }

                GroupBox("Configuration") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        detailRow("Prompt", session.prompt)
                        detailRow("Output limit", "\(session.outputTokenLimit) tokens")
                        detailRow("Runs", "\(session.completedRunCount) of \(session.iterationsRequested)")
                        detailRow("Sampling", "Temperature \(session.temperature.formatted()) · Seed \(session.seed)")
                        detailRow("Model digest", session.modelDigest.isEmpty ? "Unknown" : session.modelDigest)
                        detailRow("Protocol", "Version \(session.protocolVersion)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Environment") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        detailRow("Mac", session.environment.hardwareModel)
                        detailRow("Memory", ByteCountFormatter.string(fromByteCount: session.environment.physicalMemoryBytes, countStyle: .memory))
                        detailRow("macOS", session.environment.operatingSystem)
                        detailRow("Ollama", session.environment.ollamaVersion)
                        detailRow("Thermal state", session.environment.thermalState.capitalized)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                Text("Individual Runs")
                    .font(.title2)
                    .fontWeight(.semibold)
                runTable
            }
            .padding(20)
        }
    }

    private func summaryGrid(_ summary: BenchmarkSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
            HistoryMetricCard(title: "Generation", value: metric(summary.averageGenerationTokensPerSecond, "tok/s"))
            HistoryMetricCard(title: "First token", value: metric(summary.averageTimeToFirstTokenSeconds, "s"))
            HistoryMetricCard(title: "Prompt", value: metric(summary.averagePromptTokensPerSecond, "tok/s"))
            HistoryMetricCard(title: "Load", value: metric(summary.averageLoadDurationSeconds, "s"))
        }
    }

    private var runTable: some View {
        Table(session.runs.sorted(by: { $0.iteration < $1.iteration })) {
            TableColumn("Run") { run in Text(run.iteration, format: .number) }
            TableColumn("Kind") { run in Text(run.runKind.label) }
            TableColumn("First token") { run in Text(metric(run.timeToFirstTokenSeconds, "s")) }
            TableColumn("Generation") { run in Text(metric(run.generationTokensPerSecond, "tok/s")) }
            TableColumn("Prompt") { run in Text(metric(run.promptTokensPerSecond, "tok/s")) }
        }
        .frame(minHeight: 170)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func metric(_ value: Double, _ unit: String) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))) + " " + unit
    }
}

private struct BenchmarkComparisonView: View {
    let sessions: [BenchmarkSessionSnapshot]

    private var warnings: [BenchmarkCompatibilityWarning] {
        BenchmarkCompatibility.warnings(for: sessions)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Historical Comparison")
                            .font(.title)
                            .fontWeight(.semibold)
                        Text("\(sessions.count) persisted sessions · models are not loaded for comparison")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                if warnings.isEmpty {
                    Label("Configuration and environment metadata are compatible.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Comparison Warnings")
                            .font(.headline)
                        ForEach(warnings) { warning in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(warning.title).fontWeight(.medium)
                                    Text(warning.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: warning.severity == .critical ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                    .foregroundStyle(warning.severity == .critical ? .red : .orange)
                            }
                        }
                    }
                    .padding(12)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                ScrollView(.horizontal) {
                    comparisonGrid
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var comparisonGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                Text("Metric").fontWeight(.semibold)
                ForEach(sessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.modelName).fontWeight(.semibold)
                        Text(session.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 150, alignment: .leading)
                }
            }
            Divider()
            ForEach(BenchmarkComparisonMetric.standard) { metric in
                GridRow {
                    Text(metric.title).foregroundStyle(.secondary)
                    ForEach(sessions) { session in
                        if let summary = session.summary {
                            comparisonValue(
                                metric.value(summary),
                                baseline: sessions.first?.summary.map(metric.value),
                                unit: metric.unit
                            )
                        } else {
                            Text("—")
                        }
                    }
                }
                Divider()
            }
            GridRow {
                Text("Runs").foregroundStyle(.secondary)
                ForEach(sessions) { session in
                    Text("\(session.completedRunCount)/\(session.iterationsRequested)")
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func comparisonValue(_ value: Double, baseline: Double?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))) + " " + unit)
                .font(.headline)
                .monospacedDigit()
            if let baseline, baseline != 0 {
                let delta = ((value - baseline) / baseline) * 100
                Text(delta, format: .percent.scale(1).precision(.fractionLength(1)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct HistoryMetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).fontWeight(.semibold).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct BenchmarkExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .plainText] }

    let data: Data
    let contentType: UTType
    let filename: String

    init(value: String, format: BenchmarkExportFormat) {
        data = Data(value.utf8)
        switch format {
        case .json: contentType = .json
        case .csv: contentType = .commaSeparatedText
        case .markdown: contentType = .plainText
        }
        filename = "ollama-benchmarks.\(format.fileExtension)"
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = configuration.contentType
        filename = "ollama-benchmarks"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
