import Foundation
import SwiftData
import XCTest
@testable import OllamaModels

final class BenchmarkFeatureTests: XCTestCase {
    @MainActor
    func testRepositoryPersistsSessionAndRuns() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: BenchmarkSessionRecord.self,
            BenchmarkRunRecord.self,
            configurations: configuration
        )
        let repository = BenchmarkRepository(context: container.mainContext)
        let snapshot = makeSnapshot(modelName: "qwen3:4b", prompt: "Hello", runCount: 2)

        try repository.save(snapshot)

        let records = try container.mainContext.fetch(FetchDescriptor<BenchmarkSessionRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].modelName, "qwen3:4b")
        XCTAssertEqual(records[0].runs.count, 2)
        XCTAssertEqual(records[0].snapshot.prompt, "Hello")
    }

    @MainActor
    func testRepositoryDeletesSessionsAndCascadeRuns() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: BenchmarkSessionRecord.self,
            BenchmarkRunRecord.self,
            configurations: configuration
        )
        let repository = BenchmarkRepository(context: container.mainContext)
        try repository.save(makeSnapshot(modelName: "phi4:latest", prompt: "Delete me", runCount: 2))
        let records = try container.mainContext.fetch(FetchDescriptor<BenchmarkSessionRecord>())

        try repository.delete(records)

        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<BenchmarkSessionRecord>()).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<BenchmarkRunRecord>()).isEmpty)
    }

    func testCompatibilityDetectsPromptAndConfigurationDifferences() {
        let baseline = makeSnapshot(modelName: "qwen3:4b", prompt: "Prompt A", runCount: 3)
        let different = makeSnapshot(
            modelName: "phi4:latest",
            prompt: "Prompt B",
            outputTokenLimit: 256,
            runCount: 2
        )

        let warnings = BenchmarkCompatibility.warnings(for: [baseline, different])
        let codes = Set(warnings.map(\.code))

        XCTAssertTrue(codes.contains(.differentPrompt))
        XCTAssertTrue(codes.contains(.differentOutputLimit))
        XCTAssertTrue(codes.contains(.differentRunCount))
    }

    func testCompatibilityAcceptsEquivalentSessions() {
        let first = makeSnapshot(modelName: "qwen3:4b", prompt: "Same", runCount: 3)
        let second = makeSnapshot(modelName: "phi4:latest", prompt: "Same", runCount: 3)

        XCTAssertTrue(BenchmarkCompatibility.warnings(for: [first, second]).isEmpty)
    }

    func testExporterProducesJSONCSVAndMarkdown() throws {
        let sessions = [makeSnapshot(modelName: "qwen3:4b", prompt: "Hello", runCount: 2)]

        let json = try BenchmarkExporter.string(for: sessions, format: .json)
        let csv = try BenchmarkExporter.string(for: sessions, format: .csv)
        let markdown = try BenchmarkExporter.string(for: sessions, format: .markdown)

        XCTAssertTrue(json.contains("\"modelName\" : \"qwen3:4b\""))
        XCTAssertTrue(csv.contains("session_id,model_name"))
        XCTAssertTrue(csv.contains("qwen3:4b"))
        XCTAssertTrue(markdown.contains("# Ollama Benchmark Export"))
        XCTAssertTrue(markdown.contains("qwen3:4b"))
    }

    @MainActor
    func testQueueRunsModelsSequentiallyAndPersistsEachResult() async {
        let events = QueueEventLog()
        var persisted: [BenchmarkSessionSnapshot] = []
        let viewModel = BenchmarkViewModel(
            runBenchmark: { configuration, iteration in
                await events.append("run:\(configuration.modelName):\(iteration)")
                return BenchmarkSample(
                    modelName: configuration.modelName,
                    iteration: iteration,
                    startedAt: Date(timeIntervalSince1970: Double(iteration)),
                    timeToFirstTokenSeconds: 0.1,
                    totalDurationNanoseconds: 1_000_000_000,
                    loadDurationNanoseconds: 100_000_000,
                    promptEvaluationCount: 10,
                    promptEvaluationDurationNanoseconds: 500_000_000,
                    evaluationCount: 20,
                    evaluationDurationNanoseconds: 500_000_000
                )
            },
            unloadAllModels: {
                await events.append("unload")
            },
            fetchOllamaVersion: { "0.12.0" },
            captureEnvironment: {
                BenchmarkEnvironmentSnapshot(
                    operatingSystem: "macOS Test",
                    hardwareModel: "MacTest",
                    physicalMemoryBytes: 64_000_000_000,
                    thermalState: "nominal",
                    ollamaVersion: "0.12.0"
                )
            }
        )
        viewModel.prompt = "Hello"
        viewModel.iterations = 2

        await viewModel.runQueue(
            targets: [
                BenchmarkModelTarget(name: "model-a", digest: "digest-a"),
                BenchmarkModelTarget(name: "model-b", digest: "digest-b")
            ]
        ) { snapshot in
            persisted.append(snapshot)
        }

        XCTAssertEqual(persisted.map(\.modelName), ["model-a", "model-b"])
        XCTAssertEqual(persisted.map(\.runs.count), [2, 2])
        XCTAssertEqual(persisted.map(\.status), [.completed, .completed])
        let recordedEvents = await events.values
        XCTAssertEqual(
            recordedEvents,
            [
                "unload",
                "run:model-a:1",
                "run:model-a:2",
                "unload",
                "unload",
                "run:model-b:1",
                "run:model-b:2",
                "unload"
            ]
        )
    }

    private func makeSnapshot(
        modelName: String,
        prompt: String,
        outputTokenLimit: Int = 128,
        runCount: Int
    ) -> BenchmarkSessionSnapshot {
        let runs = (1...runCount).map { iteration in
            BenchmarkSample(
                modelName: modelName,
                iteration: iteration,
                startedAt: Date(timeIntervalSince1970: Double(iteration)),
                timeToFirstTokenSeconds: 0.1 * Double(iteration),
                totalDurationNanoseconds: 1_000_000_000,
                loadDurationNanoseconds: 100_000_000,
                promptEvaluationCount: 10,
                promptEvaluationDurationNanoseconds: 500_000_000,
                evaluationCount: 20,
                evaluationDurationNanoseconds: 500_000_000
            )
        }
        return BenchmarkSessionSnapshot(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_000),
            completedAt: Date(timeIntervalSince1970: 1_100),
            status: .completed,
            modelName: modelName,
            modelDigest: "digest-\(modelName)",
            prompt: prompt,
            outputTokenLimit: outputTokenLimit,
            iterationsRequested: runCount,
            temperature: 0,
            seed: 42,
            protocolVersion: BenchmarkSessionSnapshot.currentProtocolVersion,
            environment: BenchmarkEnvironmentSnapshot(
                operatingSystem: "macOS Test",
                hardwareModel: "MacTest",
                physicalMemoryBytes: 64_000_000_000,
                thermalState: "nominal",
                ollamaVersion: "0.12.0"
            ),
            runs: runs,
            errorMessage: nil
        )
    }
}

private actor QueueEventLog {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
