import CryptoKit
import Darwin
import Foundation
import SwiftData

struct BenchmarkModelTarget: Identifiable, Equatable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let digest: String
}

enum BenchmarkSessionStatus: String, Codable, CaseIterable, Sendable {
    case completed
    case cancelled
    case failed

    var label: String {
        rawValue.capitalized
    }
}

struct BenchmarkEnvironmentSnapshot: Codable, Equatable, Sendable {
    let operatingSystem: String
    let hardwareModel: String
    let physicalMemoryBytes: Int64
    let thermalState: String
    let ollamaVersion: String

    static func current(ollamaVersion: String) -> BenchmarkEnvironmentSnapshot {
        BenchmarkEnvironmentSnapshot(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: Self.hardwareModelIdentifier,
            physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory),
            thermalState: Self.thermalStateLabel(ProcessInfo.processInfo.thermalState),
            ollamaVersion: ollamaVersion
        )
    }

    private static var hardwareModelIdentifier: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "Unknown Mac"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else {
            return "Unknown Mac"
        }
        return String(cString: value)
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

struct BenchmarkSessionSnapshot: Identifiable, Codable, Equatable, Sendable {
    static let currentProtocolVersion = 1

    let id: UUID
    let createdAt: Date
    let completedAt: Date?
    let status: BenchmarkSessionStatus
    let modelName: String
    let modelDigest: String
    let prompt: String
    let outputTokenLimit: Int
    let iterationsRequested: Int
    let temperature: Double
    let seed: Int
    let protocolVersion: Int
    let environment: BenchmarkEnvironmentSnapshot
    let runs: [BenchmarkSample]
    let errorMessage: String?

    var promptHash: String {
        SHA256.hash(data: Data(prompt.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var summary: BenchmarkSummary? {
        BenchmarkSummary(samples: runs)
    }

    var completedRunCount: Int {
        runs.count
    }
}

@Model
final class BenchmarkSessionRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var completedAt: Date?
    var statusRawValue: String
    var modelName: String
    var modelDigest: String
    var prompt: String
    var promptHash: String
    var outputTokenLimit: Int
    var iterationsRequested: Int
    var temperature: Double
    var seed: Int
    var protocolVersion: Int
    var operatingSystem: String
    var hardwareModel: String
    var physicalMemoryBytes: Int64
    var thermalState: String
    var ollamaVersion: String
    var errorMessage: String?

    @Relationship(deleteRule: .cascade, inverse: \BenchmarkRunRecord.session)
    var runs: [BenchmarkRunRecord]

    init(snapshot: BenchmarkSessionSnapshot) {
        id = snapshot.id
        createdAt = snapshot.createdAt
        completedAt = snapshot.completedAt
        statusRawValue = snapshot.status.rawValue
        modelName = snapshot.modelName
        modelDigest = snapshot.modelDigest
        prompt = snapshot.prompt
        promptHash = snapshot.promptHash
        outputTokenLimit = snapshot.outputTokenLimit
        iterationsRequested = snapshot.iterationsRequested
        temperature = snapshot.temperature
        seed = snapshot.seed
        protocolVersion = snapshot.protocolVersion
        operatingSystem = snapshot.environment.operatingSystem
        hardwareModel = snapshot.environment.hardwareModel
        physicalMemoryBytes = snapshot.environment.physicalMemoryBytes
        thermalState = snapshot.environment.thermalState
        ollamaVersion = snapshot.environment.ollamaVersion
        errorMessage = snapshot.errorMessage
        runs = snapshot.runs.map(BenchmarkRunRecord.init(sample:))
    }

    var status: BenchmarkSessionStatus {
        BenchmarkSessionStatus(rawValue: statusRawValue) ?? .failed
    }

    var snapshot: BenchmarkSessionSnapshot {
        BenchmarkSessionSnapshot(
            id: id,
            createdAt: createdAt,
            completedAt: completedAt,
            status: status,
            modelName: modelName,
            modelDigest: modelDigest,
            prompt: prompt,
            outputTokenLimit: outputTokenLimit,
            iterationsRequested: iterationsRequested,
            temperature: temperature,
            seed: seed,
            protocolVersion: protocolVersion,
            environment: BenchmarkEnvironmentSnapshot(
                operatingSystem: operatingSystem,
                hardwareModel: hardwareModel,
                physicalMemoryBytes: physicalMemoryBytes,
                thermalState: thermalState,
                ollamaVersion: ollamaVersion
            ),
            runs: runs.map(\.sample).sorted { $0.iteration < $1.iteration },
            errorMessage: errorMessage
        )
    }
}

@Model
final class BenchmarkRunRecord {
    @Attribute(.unique) var id: UUID
    var modelName: String
    var iteration: Int
    var runKindRawValue: String
    var startedAt: Date
    var timeToFirstTokenSeconds: Double
    var totalDurationNanoseconds: Int64
    var loadDurationNanoseconds: Int64
    var promptEvaluationCount: Int
    var promptEvaluationDurationNanoseconds: Int64
    var evaluationCount: Int
    var evaluationDurationNanoseconds: Int64
    var session: BenchmarkSessionRecord?

    init(sample: BenchmarkSample) {
        id = sample.id
        modelName = sample.modelName
        iteration = sample.iteration
        runKindRawValue = sample.runKind.rawValue
        startedAt = sample.startedAt
        timeToFirstTokenSeconds = sample.timeToFirstTokenSeconds
        totalDurationNanoseconds = sample.totalDurationNanoseconds
        loadDurationNanoseconds = sample.loadDurationNanoseconds
        promptEvaluationCount = sample.promptEvaluationCount
        promptEvaluationDurationNanoseconds = sample.promptEvaluationDurationNanoseconds
        evaluationCount = sample.evaluationCount
        evaluationDurationNanoseconds = sample.evaluationDurationNanoseconds
    }

    var sample: BenchmarkSample {
        BenchmarkSample(
            id: id,
            modelName: modelName,
            iteration: iteration,
            runKind: BenchmarkRunKind(rawValue: runKindRawValue) ?? .warm,
            startedAt: startedAt,
            timeToFirstTokenSeconds: timeToFirstTokenSeconds,
            totalDurationNanoseconds: totalDurationNanoseconds,
            loadDurationNanoseconds: loadDurationNanoseconds,
            promptEvaluationCount: promptEvaluationCount,
            promptEvaluationDurationNanoseconds: promptEvaluationDurationNanoseconds,
            evaluationCount: evaluationCount,
            evaluationDurationNanoseconds: evaluationDurationNanoseconds
        )
    }
}

@MainActor
struct BenchmarkRepository {
    let context: ModelContext

    func save(_ snapshot: BenchmarkSessionSnapshot) throws {
        let requestedID = snapshot.id
        let descriptor = FetchDescriptor<BenchmarkSessionRecord>(
            predicate: #Predicate { $0.id == requestedID }
        )
        if let existing = try context.fetch(descriptor).first {
            context.delete(existing)
        }
        context.insert(BenchmarkSessionRecord(snapshot: snapshot))
        try context.save()
    }

    func delete(_ records: [BenchmarkSessionRecord]) throws {
        records.forEach(context.delete)
        try context.save()
    }
}
