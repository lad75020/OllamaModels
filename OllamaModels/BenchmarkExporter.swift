import Foundation

enum BenchmarkExportFormat: String, CaseIterable, Identifiable, Sendable {
    case json
    case csv
    case markdown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .json: "JSON"
        case .csv: "CSV"
        case .markdown: "Markdown"
        }
    }

    var fileExtension: String {
        switch self {
        case .json: "json"
        case .csv: "csv"
        case .markdown: "md"
        }
    }
}

enum BenchmarkExporter {
    static func string(
        for sessions: [BenchmarkSessionSnapshot],
        format: BenchmarkExportFormat
    ) throws -> String {
        switch format {
        case .json:
            try json(sessions)
        case .csv:
            csv(sessions)
        case .markdown:
            markdown(sessions)
        }
    }

    private static func json(_ sessions: [BenchmarkSessionSnapshot]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sessions)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return value
    }

    private static func csv(_ sessions: [BenchmarkSessionSnapshot]) -> String {
        var rows = [
            [
                "session_id", "model_name", "model_digest", "status", "created_at",
                "prompt_hash", "output_token_limit", "iterations_requested", "run",
                "run_kind", "first_token_seconds", "generation_tokens_per_second",
                "prompt_tokens_per_second", "load_seconds", "total_seconds",
                "prompt_tokens", "output_tokens", "ollama_version", "hardware_model",
                "physical_memory_bytes", "thermal_state", "protocol_version", "error"
            ].joined(separator: ",")
        ]

        let dateFormatter = ISO8601DateFormatter()
        for session in sessions {
            let runs: [BenchmarkSample?] = session.runs.isEmpty ? [nil] : session.runs.map(Optional.some)
            for run in runs {
                rows.append(
                    csvColumns(session: session, run: run, dateFormatter: dateFormatter)
                        .map(escapeCSV)
                        .joined(separator: ",")
                )
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func csvColumns(
        session: BenchmarkSessionSnapshot,
        run: BenchmarkSample?,
        dateFormatter: ISO8601DateFormatter
    ) -> [String] {
        var columns: [String] = []
        columns.append(session.id.uuidString)
        columns.append(session.modelName)
        columns.append(session.modelDigest)
        columns.append(session.status.rawValue)
        columns.append(dateFormatter.string(from: session.createdAt))
        columns.append(session.promptHash)
        columns.append(String(session.outputTokenLimit))
        columns.append(String(session.iterationsRequested))
        columns.append(run.map { String($0.iteration) } ?? "")
        columns.append(run?.runKind.rawValue ?? "")
        columns.append(run.map { number($0.timeToFirstTokenSeconds) } ?? "")
        columns.append(run.map { number($0.generationTokensPerSecond) } ?? "")
        columns.append(run.map { number($0.promptTokensPerSecond) } ?? "")
        columns.append(run.map { number($0.loadDurationSeconds) } ?? "")
        columns.append(run.map { number($0.totalDurationSeconds) } ?? "")
        columns.append(run.map { String($0.promptEvaluationCount) } ?? "")
        columns.append(run.map { String($0.evaluationCount) } ?? "")
        columns.append(session.environment.ollamaVersion)
        columns.append(session.environment.hardwareModel)
        columns.append(String(session.environment.physicalMemoryBytes))
        columns.append(session.environment.thermalState)
        columns.append(String(session.protocolVersion))
        columns.append(session.errorMessage ?? "")
        return columns
    }

    private static func markdown(_ sessions: [BenchmarkSessionSnapshot]) -> String {
        var output = "# Ollama Benchmark Export\n\n"
        output += "Generated \(Date().formatted(date: .abbreviated, time: .shortened))\n\n"

        for session in sessions {
            output += "## \(escapeMarkdown(session.modelName))\n\n"
            output += "- **Date:** \(session.createdAt.formatted(date: .abbreviated, time: .standard))\n"
            output += "- **Status:** \(session.status.label)\n"
            output += "- **Model digest:** `\(session.modelDigest)`\n"
            output += "- **Prompt hash:** `\(session.promptHash)`\n"
            output += "- **Configuration:** \(session.iterationsRequested) runs, \(session.outputTokenLimit) output tokens, temperature \(number(session.temperature)), seed \(session.seed)\n"
            output += "- **Environment:** \(escapeMarkdown(session.environment.hardwareModel)), \(escapeMarkdown(session.environment.operatingSystem)), Ollama \(escapeMarkdown(session.environment.ollamaVersion))\n\n"

            if let summary = session.summary {
                output += "| Generation | First token | Prompt processing | Model load |\n"
                output += "|---:|---:|---:|---:|\n"
                output += "| \(number(summary.averageGenerationTokensPerSecond)) tok/s | \(number(summary.averageTimeToFirstTokenSeconds)) s | \(number(summary.averagePromptTokensPerSecond)) tok/s | \(number(summary.averageLoadDurationSeconds)) s |\n\n"
            }

            output += "| Run | Kind | First token | Generation | Prompt | Load | Total | Output |\n"
            output += "|---:|:---|---:|---:|---:|---:|---:|---:|\n"
            for run in session.runs.sorted(by: { $0.iteration < $1.iteration }) {
                output += "| \(run.iteration) | \(run.runKind.label) | \(number(run.timeToFirstTokenSeconds)) s | \(number(run.generationTokensPerSecond)) tok/s | \(number(run.promptTokensPerSecond)) tok/s | \(number(run.loadDurationSeconds)) s | \(number(run.totalDurationSeconds)) s | \(run.evaluationCount) |\n"
            }
            output += "\n"
        }
        return output
    }

    private static func escapeCSV(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func escapeMarkdown(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }

    private static func number(_ value: Double) -> String {
        value.formatted(
            .number
                .locale(Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(3))
        )
    }
}
