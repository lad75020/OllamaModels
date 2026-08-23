import Foundation

enum BenchmarkWarningCode: String, Hashable, Sendable {
    case differentPrompt
    case differentOutputLimit
    case differentRunCount
    case differentSampling
    case differentProtocol
    case differentHardware
    case differentMemory
    case differentOperatingSystem
    case differentOllamaVersion
    case changedModelDigest
    case incompleteSession
    case thermalPressure
}

enum BenchmarkWarningSeverity: Int, Comparable, Sendable {
    case information
    case caution
    case critical

    static func < (lhs: BenchmarkWarningSeverity, rhs: BenchmarkWarningSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct BenchmarkCompatibilityWarning: Identifiable, Equatable, Sendable {
    var id: BenchmarkWarningCode { code }
    let code: BenchmarkWarningCode
    let severity: BenchmarkWarningSeverity
    let title: String
    let message: String
}

enum BenchmarkCompatibility {
    static func warnings(for sessions: [BenchmarkSessionSnapshot]) -> [BenchmarkCompatibilityWarning] {
        guard sessions.count >= 2 else { return [] }
        var warnings: [BenchmarkCompatibilityWarning] = []

        appendIfDifferent(
            sessions.map(\.promptHash),
            warning: .init(
                code: .differentPrompt,
                severity: .critical,
                title: "Different prompts",
                message: "Prompt content differs, so throughput and token counts are not directly comparable."
            ),
            to: &warnings
        )
        appendIfDifferent(
            sessions.map(\.outputTokenLimit),
            warning: .init(
                code: .differentOutputLimit,
                severity: .critical,
                title: "Different output limits",
                message: "Use the same maximum output-token count for a fair comparison."
            ),
            to: &warnings
        )
        appendIfDifferent(
            sessions.map(\.iterationsRequested),
            warning: .init(
                code: .differentRunCount,
                severity: .caution,
                title: "Different run counts",
                message: "Averages based on different sample counts have different confidence levels."
            ),
            to: &warnings
        )
        appendIfDifferent(
            sessions.map { "\($0.temperature):\($0.seed)" },
            warning: .init(
                code: .differentSampling,
                severity: .critical,
                title: "Different sampling settings",
                message: "Temperature or seed differs between the selected sessions."
            ),
            to: &warnings
        )
        appendIfDifferent(
            sessions.map(\.protocolVersion),
            warning: .init(
                code: .differentProtocol,
                severity: .critical,
                title: "Different benchmark protocols",
                message: "The app measured these sessions using different protocol versions."
            ),
            to: &warnings
        )
        appendIfDifferent(
            sessions.map(\.environment.hardwareModel),
            warning: .init(
                code: .differentHardware,
                severity: .caution,
                title: "Different hardware",
                message: "The selected sessions were recorded on different Mac models."
            ),
            to: &warnings
        )
        appendIfDifferent(
            sessions.map(\.environment.physicalMemoryBytes),
            warning: .init(
                code: .differentMemory,
                severity: .caution,
                title: "Different memory capacity",
                message: "Available unified memory differs between the benchmark environments."
            ),
            to: &warnings
        )
        appendIfDifferent(
            sessions.map(\.environment.operatingSystem),
            warning: .init(
                code: .differentOperatingSystem,
                severity: .information,
                title: "Different macOS versions",
                message: "Operating-system changes can affect Metal and memory performance."
            ),
            to: &warnings
        )
        appendIfDifferent(
            sessions.map(\.environment.ollamaVersion),
            warning: .init(
                code: .differentOllamaVersion,
                severity: .caution,
                title: "Different Ollama versions",
                message: "Runtime changes can materially affect inference performance."
            ),
            to: &warnings
        )

        let digestGroups = Dictionary(grouping: sessions, by: \.modelName)
        if digestGroups.values.contains(where: { Set($0.map(\.modelDigest)).count > 1 }) {
            warnings.append(
                .init(
                    code: .changedModelDigest,
                    severity: .critical,
                    title: "Model revision changed",
                    message: "At least one model name points to different digests across the selection."
                )
            )
        }

        if sessions.contains(where: { $0.status != .completed || $0.runs.count < $0.iterationsRequested }) {
            warnings.append(
                .init(
                    code: .incompleteSession,
                    severity: .critical,
                    title: "Incomplete session",
                    message: "One or more selected sessions were cancelled, failed, or have missing runs."
                )
            )
        }

        let pressured = Set(["serious", "critical"])
        if sessions.contains(where: { pressured.contains($0.environment.thermalState.lowercased()) }) {
            warnings.append(
                .init(
                    code: .thermalPressure,
                    severity: .caution,
                    title: "Thermal pressure recorded",
                    message: "At least one benchmark ran while the Mac reported serious thermal pressure."
                )
            )
        }

        return warnings.sorted { $0.severity > $1.severity }
    }

    private static func appendIfDifferent<Value: Hashable>(
        _ values: [Value],
        warning: BenchmarkCompatibilityWarning,
        to warnings: inout [BenchmarkCompatibilityWarning]
    ) {
        if Set(values).count > 1 {
            warnings.append(warning)
        }
    }
}

struct BenchmarkComparisonMetric: Identifiable, Sendable {
    let id: String
    let title: String
    let unit: String
    let prefersLowerValues: Bool
    let value: @Sendable (BenchmarkSummary) -> Double

    static let standard: [BenchmarkComparisonMetric] = [
        .init(
            id: "generation",
            title: "Generation",
            unit: "tok/s",
            prefersLowerValues: false,
            value: { $0.averageGenerationTokensPerSecond }
        ),
        .init(
            id: "first-token",
            title: "First token",
            unit: "s",
            prefersLowerValues: true,
            value: { $0.averageTimeToFirstTokenSeconds }
        ),
        .init(
            id: "prompt",
            title: "Prompt processing",
            unit: "tok/s",
            prefersLowerValues: false,
            value: { $0.averagePromptTokensPerSecond }
        ),
        .init(
            id: "load",
            title: "Model load",
            unit: "s",
            prefersLowerValues: true,
            value: { $0.averageLoadDurationSeconds }
        )
    ]
}
