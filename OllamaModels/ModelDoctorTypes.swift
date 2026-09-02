import Darwin
import Foundation

enum ModelDoctorComfort: Int, Comparable, Sendable {
    case unsuitable
    case constrained
    case comfortable

    static func < (lhs: ModelDoctorComfort, rhs: ModelDoctorComfort) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .comfortable: "Runs comfortably"
        case .constrained: "Runs with constraints"
        case .unsuitable: "Not recommended"
        }
    }
}

enum ModelDoctorAcceleratorMode: String, Sendable {
    case full
    case partial
    case cpu
    case unknown

    var title: String {
        switch self {
        case .full: "Full accelerator use"
        case .partial: "Partial accelerator use"
        case .cpu: "CPU fallback"
        case .unknown: "Not observed"
        }
    }
}

enum ModelDoctorFindingSeverity: Int, Comparable, Sendable {
    case information
    case recommendation
    case warning
    case critical

    static func < (lhs: ModelDoctorFindingSeverity, rhs: ModelDoctorFindingSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ModelDoctorFindingCode: String, Sendable {
    case memoryPressure
    case excessiveSwap
    case cpuFallback
    case partialAccelerator
    case slowInference
    case thermalPressure
    case quantization
    case observedMemory
    case context
}

struct ModelDoctorFinding: Identifiable, Equatable, Sendable {
    var id: ModelDoctorFindingCode { code }
    let code: ModelDoctorFindingCode
    let severity: ModelDoctorFindingSeverity
    let title: String
    let message: String
}

struct ModelDoctorProfile: Equatable, Sendable {
    let name: String
    let family: String
    let quantization: String
    let fileSizeBytes: Int64
    let parameterCount: Int64
    let maximumContextSize: Int
    let blockCount: Int
    let embeddingLength: Int
    let attentionHeadCount: Int
    let keyValueHeadCount: Int

    var estimatedKeyValueBytesPerToken: Int64 {
        guard blockCount > 0, embeddingLength > 0 else { return 256 * 1_024 }
        let heads = max(attentionHeadCount, 1)
        let keyValueHeads = max(keyValueHeadCount, 1)
        let headDimension = max(embeddingLength / heads, 1)
        let bytes = Int64(blockCount) * Int64(keyValueHeads) * Int64(headDimension) * 4
        return max(bytes, 64 * 1_024)
    }

    func estimatedMemoryBytes(contextSize: Int) -> Int64 {
        let modelOverhead = Int64(Double(fileSizeBytes) * 1.08)
        let runtimeOverhead: Int64 = 512 * 1_024 * 1_024
        let contextBytes = estimatedKeyValueBytesPerToken.multipliedReportingOverflow(
            by: Int64(max(contextSize, 1))
        )
        let keyValueBytes = contextBytes.overflow ? Int64.max : contextBytes.partialValue
        return Self.clampedAdd(Self.clampedAdd(modelOverhead, runtimeOverhead), keyValueBytes)
    }

    private static func clampedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }

    static func openAICompatibleFallback(for model: OllamaModel) -> ModelDoctorProfile {
        ModelDoctorProfile(
            name: model.name,
            family: model.family == "—" ? "Unknown" : model.family,
            quantization: model.quantization == "—" ? "Unknown" : model.quantization,
            fileSizeBytes: max(model.size, 0),
            parameterCount: 0,
            maximumContextSize: 4_096,
            blockCount: 0,
            embeddingLength: 0,
            attentionHeadCount: 1,
            keyValueHeadCount: 1
        )
    }
}

struct ModelDoctorHostSnapshot: Equatable, Sendable {
    let physicalMemoryBytes: Int64
    let availableMemoryBytes: Int64
    let swapUsedBytes: Int64
    let swapTotalBytes: Int64
    let thermalState: String

    static func current() -> ModelDoctorHostSnapshot {
        ModelDoctorHostSnapshot(
            physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory),
            availableMemoryBytes: availableMemoryBytes(),
            swapUsedBytes: swapUsage().used,
            swapTotalBytes: swapUsage().total,
            thermalState: thermalStateLabel(ProcessInfo.processInfo.thermalState)
        )
    }

    private static func availableMemoryBytes() -> Int64 {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return 0 }
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.speculative_count)
            + UInt64(statistics.purgeable_count)
        return Int64(clamping: pages.multipliedReportingOverflow(by: UInt64(pageSize)).partialValue)
    }

    private static func swapUsage() -> (used: Int64, total: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return (0, 0)
        }
        return (Int64(clamping: usage.xsu_used), Int64(clamping: usage.xsu_total))
    }

    private static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

struct ModelDoctorProbe: Equatable, Sendable {
    let modelName: String
    let observedMemoryBytes: Int64
    let acceleratorMemoryBytes: Int64
    let generationTokensPerSecond: Double
    let promptTokensPerSecond: Double
    let timeToFirstTokenSeconds: Double
    let loadDurationSeconds: Double
}

struct ModelDoctorAssessment: Identifiable, Equatable, Sendable {
    var id: String { profile.name }
    let profile: ModelDoctorProfile
    let hostBefore: ModelDoctorHostSnapshot
    let hostAfter: ModelDoctorHostSnapshot
    let probe: ModelDoctorProbe
    let comfort: ModelDoctorComfort
    let estimatedMemoryBytes: Int64
    let recommendedContextSize: Int
    let acceleratorMode: ModelDoctorAcceleratorMode
    let findings: [ModelDoctorFinding]

    var observedMemoryBytes: Int64 { probe.observedMemoryBytes }
}

struct ModelDoctorVariantRecommendation: Equatable, Sendable {
    let recommendedModelName: String
    let modelToRemoveName: String
    let reason: String
}

enum ModelDoctorAnalyzer {
    private static let contextCandidates = [131_072, 65_536, 32_768, 16_384, 8_192, 4_096, 2_048, 1_024]

    static func assess(
        profile: ModelDoctorProfile,
        hostBefore: ModelDoctorHostSnapshot,
        hostAfter: ModelDoctorHostSnapshot,
        probe: ModelDoctorProbe
    ) -> ModelDoctorAssessment {
        let recommendedContext = recommendedContextSize(profile: profile, host: hostBefore)
        let estimatedMemory = profile.estimatedMemoryBytes(contextSize: recommendedContext)
        let physical = max(hostBefore.physicalMemoryBytes, 1)
        let observedRatio = Double(probe.observedMemoryBytes) / Double(physical)
        let estimateRatio = Double(estimatedMemory) / Double(physical)
        let availableRatio = Double(hostAfter.availableMemoryBytes) / Double(physical)
        let swapGrowth = max(hostAfter.swapUsedBytes - hostBefore.swapUsedBytes, 0)

        let comfort: ModelDoctorComfort
        if observedRatio > 0.85 || estimateRatio > 0.85 || availableRatio < 0.06 {
            comfort = .unsuitable
        } else if observedRatio > 0.65 || estimateRatio > 0.65 || availableRatio < 0.15 || swapGrowth > 1_024 * 1_024 * 1_024 {
            comfort = .constrained
        } else {
            comfort = .comfortable
        }

        let acceleratorMode = acceleratorMode(for: probe)
        var findings: [ModelDoctorFinding] = []

        if availableRatio < 0.15 {
            findings.append(.init(
                code: .memoryPressure,
                severity: availableRatio < 0.08 ? .critical : .warning,
                title: "Memory pressure detected",
                message: "Available memory fell to \(formatBytes(hostAfter.availableMemoryBytes)). Close memory-heavy apps or use a smaller model/context."
            ))
        }

        if swapGrowth > 512 * 1_024 * 1_024 || hostAfter.swapUsedBytes > physical / 2 {
            let swapMessage: String
            if swapGrowth > 0 {
                swapMessage = "Swap usage is \(formatBytes(hostAfter.swapUsedBytes)) and grew by \(formatBytes(swapGrowth)) during the probe."
            } else {
                swapMessage = "macOS has \(formatBytes(hostAfter.swapUsedBytes)) of accumulated swap allocated, although it did not grow during this probe."
            }
            findings.append(.init(
                code: .excessiveSwap,
                severity: swapGrowth > 2 * 1_024 * 1_024 * 1_024 ? .critical : .warning,
                title: "Excessive swapping",
                message: "\(swapMessage) Disk paging can sharply reduce inference speed."
            ))
        }

        switch acceleratorMode {
        case .cpu:
            findings.append(.init(
                code: .cpuFallback,
                severity: .critical,
                title: "CPU fallback detected",
                message: "Ollama reported no accelerator-resident model memory. Performance will be substantially lower than Metal acceleration."
            ))
        case .partial:
            findings.append(.init(
                code: .partialAccelerator,
                severity: .warning,
                title: "Partial accelerator use",
                message: "Only \(formatPercent(probe.acceleratorMemoryBytes, of: probe.observedMemoryBytes)) of observed model memory is accelerator-resident. Reduce context size or quantization."
            ))
        case .full, .unknown:
            break
        }

        let expectedFloor = expectedGenerationFloor(parameterCount: profile.parameterCount)
        if probe.generationTokensPerSecond > 0, probe.generationTokensPerSecond < expectedFloor {
            let likelyCause: String
            if acceleratorMode == .cpu {
                likelyCause = "The CPU fallback is the most likely cause."
            } else if acceleratorMode == .partial {
                likelyCause = "Partial accelerator residency is the most likely cause."
            } else if findings.contains(where: { $0.code == .excessiveSwap || $0.code == .memoryPressure }) {
                likelyCause = "Memory pressure and swapping are the most likely causes."
            } else {
                likelyCause = "Check thermal pressure, background workloads, and context size."
            }
            findings.append(.init(
                code: .slowInference,
                severity: .warning,
                title: "Inference is unexpectedly slow",
                message: "The probe measured \(probe.generationTokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s. \(likelyCause)"
            ))
        }

        if ["serious", "critical"].contains(hostAfter.thermalState.lowercased()) {
            findings.append(.init(
                code: .thermalPressure,
                severity: .warning,
                title: "Thermal throttling is possible",
                message: "macOS reported \(hostAfter.thermalState) thermal pressure during the probe. Let the Mac cool and repeat the diagnosis."
            ))
        }

        if probe.observedMemoryBytes > Int64(Double(estimatedMemory) * 1.25) {
            findings.append(.init(
                code: .observedMemory,
                severity: .information,
                title: "Observed memory exceeded the estimate",
                message: "Ollama reported \(formatBytes(probe.observedMemoryBytes)) versus an estimated \(formatBytes(estimatedMemory)). Runtime buffers or a larger effective context may explain the difference."
            ))
        }

        if comfort != .comfortable {
            let suggestedQuantization = quantizationSuggestion(current: profile.quantization, comfort: comfort)
            findings.append(.init(
                code: .quantization,
                severity: comfort == .unsuitable ? .critical : .recommendation,
                title: "Use a lighter quantization",
                message: "The installed \(profile.quantization) variant is memory-heavy for this Mac. Prefer \(suggestedQuantization) for a better speed and headroom balance."
            ))
        }

        findings.append(.init(
            code: .context,
            severity: .recommendation,
            title: "Recommended context: \(recommendedContext.formatted()) tokens",
            message: "This recommendation reserves operating-system headroom and includes an estimated KV-cache cost of \(formatBytes(profile.estimatedKeyValueBytesPerToken)) per token."
        ))

        return ModelDoctorAssessment(
            profile: profile,
            hostBefore: hostBefore,
            hostAfter: hostAfter,
            probe: probe,
            comfort: comfort,
            estimatedMemoryBytes: estimatedMemory,
            recommendedContextSize: recommendedContext,
            acceleratorMode: acceleratorMode,
            findings: findings.sorted { $0.severity > $1.severity }
        )
    }

    static func recommendVariant(
        between first: ModelDoctorAssessment,
        and second: ModelDoctorAssessment
    ) -> ModelDoctorVariantRecommendation {
        let winner: ModelDoctorAssessment
        let loser: ModelDoctorAssessment
        let reason: String

        if first.comfort != second.comfort {
            (winner, loser) = first.comfort > second.comfort ? (first, second) : (second, first)
            reason = "It has the safer memory profile on this Mac."
        } else {
            let firstSpeed = first.probe.generationTokensPerSecond
            let secondSpeed = second.probe.generationTokensPerSecond
            if max(firstSpeed, secondSpeed) > 0,
               abs(firstSpeed - secondSpeed) / max(firstSpeed, secondSpeed) >= 0.10 {
                (winner, loser) = firstSpeed >= secondSpeed ? (first, second) : (second, first)
                reason = "It was faster in the same diagnostic probe while remaining equally comfortable."
            } else {
                (winner, loser) = first.observedMemoryBytes <= second.observedMemoryBytes ? (first, second) : (second, first)
                reason = "Performance was similar, but it used less observed memory."
            }
        }

        return ModelDoctorVariantRecommendation(
            recommendedModelName: winner.profile.name,
            modelToRemoveName: loser.profile.name,
            reason: reason
        )
    }

    private static func recommendedContextSize(
        profile: ModelDoctorProfile,
        host: ModelDoctorHostSnapshot
    ) -> Int {
        let physicalBudget = Int64(Double(host.physicalMemoryBytes) * 0.70)
        let availableBudget = Int64(Double(host.availableMemoryBytes) * 0.85)
        let budget = max(min(physicalBudget, availableBudget), 0)
        return contextCandidates.first {
            $0 <= profile.maximumContextSize && profile.estimatedMemoryBytes(contextSize: $0) <= budget
        } ?? min(max(profile.maximumContextSize, 1), 1_024)
    }

    private static func acceleratorMode(for probe: ModelDoctorProbe) -> ModelDoctorAcceleratorMode {
        guard probe.observedMemoryBytes > 0 else { return .unknown }
        let ratio = Double(probe.acceleratorMemoryBytes) / Double(probe.observedMemoryBytes)
        if ratio < 0.05 { return .cpu }
        if ratio < 0.90 { return .partial }
        return .full
    }

    private static func expectedGenerationFloor(parameterCount: Int64) -> Double {
        switch parameterCount {
        case 30_000_000_000...: 4
        case 13_000_000_000...: 8
        case 7_000_000_000...: 12
        default: 18
        }
    }

    private static func quantizationSuggestion(
        current: String,
        comfort: ModelDoctorComfort
    ) -> String {
        let normalized = current.uppercased()
        if comfort == .unsuitable, normalized.contains("Q4") {
            return "Q3_K_M"
        }
        return "Q4_K_M"
    }

    private static func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .memory)
    }

    private static func formatPercent(_ part: Int64, of total: Int64) -> String {
        guard total > 0 else { return "0%" }
        return (Double(part) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
    }
}
