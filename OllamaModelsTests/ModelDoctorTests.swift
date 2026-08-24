import XCTest
@testable import OllamaModels

final class ModelDoctorTests: XCTestCase {
    func testComfortAndContextRecommendationForModelWithHealthyHeadroom() {
        let profile = makeProfile(fileSize: 9_000_000_000, maxContext: 16_384)
        let host = makeHost(physical: 36_000_000_000, available: 24_000_000_000)

        let assessment = ModelDoctorAnalyzer.assess(
            profile: profile,
            hostBefore: host,
            hostAfter: host,
            probe: makeProbe(observed: 10_500_000_000, accelerator: 10_500_000_000)
        )

        XCTAssertEqual(assessment.comfort, .comfortable)
        XCTAssertEqual(assessment.recommendedContextSize, 16_384)
        XCTAssertEqual(assessment.acceleratorMode, .full)
        XCTAssertGreaterThan(assessment.estimatedMemoryBytes, profile.fileSizeBytes)
    }

    func testMemoryPressureAndSwapGrowthProduceWarnings() {
        let profile = makeProfile(fileSize: 20_000_000_000, maxContext: 32_768)
        let before = makeHost(
            physical: 36_000_000_000,
            available: 12_000_000_000,
            swapUsed: 2_000_000_000
        )
        let after = makeHost(
            physical: 36_000_000_000,
            available: 3_000_000_000,
            swapUsed: 5_000_000_000
        )

        let assessment = ModelDoctorAnalyzer.assess(
            profile: profile,
            hostBefore: before,
            hostAfter: after,
            probe: makeProbe(observed: 25_000_000_000, accelerator: 12_000_000_000)
        )

        XCTAssertNotEqual(assessment.comfort, .comfortable)
        XCTAssertTrue(assessment.findings.contains { $0.code == .memoryPressure })
        XCTAssertTrue(assessment.findings.contains { $0.code == .excessiveSwap })
        XCTAssertEqual(assessment.acceleratorMode, .partial)
        XCTAssertLessThan(assessment.recommendedContextSize, profile.maximumContextSize)
    }

    func testDetectsCPUFallbackAndSlowInference() {
        let profile = makeProfile(fileSize: 9_000_000_000, maxContext: 16_384)
        let host = makeHost(physical: 36_000_000_000, available: 20_000_000_000)

        let assessment = ModelDoctorAnalyzer.assess(
            profile: profile,
            hostBefore: host,
            hostAfter: host,
            probe: makeProbe(
                observed: 10_000_000_000,
                accelerator: 0,
                generationTokensPerSecond: 2
            )
        )

        XCTAssertEqual(assessment.acceleratorMode, .cpu)
        XCTAssertTrue(assessment.findings.contains { $0.code == .cpuFallback })
        XCTAssertTrue(assessment.findings.contains { $0.code == .slowInference })
    }

    func testSuggestsSmallerQuantizationWhenModelIsTooLarge() {
        let profile = makeProfile(
            fileSize: 31_000_000_000,
            quantization: "Q8_0",
            maxContext: 32_768
        )
        let host = makeHost(physical: 36_000_000_000, available: 30_000_000_000)

        let assessment = ModelDoctorAnalyzer.assess(
            profile: profile,
            hostBefore: host,
            hostAfter: host,
            probe: makeProbe(observed: 33_000_000_000, accelerator: 20_000_000_000)
        )

        XCTAssertTrue(assessment.findings.contains { $0.code == .quantization })
        XCTAssertTrue(assessment.findings.contains { $0.message.contains("Q4_K_M") })
    }

    func testVariantRecommendationRetainsFasterComfortableVariant() {
        let host = makeHost(physical: 36_000_000_000, available: 28_000_000_000)
        let first = ModelDoctorAnalyzer.assess(
            profile: makeProfile(name: "model:q4", fileSize: 10_000_000_000),
            hostBefore: host,
            hostAfter: host,
            probe: makeProbe(modelName: "model:q4", observed: 11_000_000_000, accelerator: 11_000_000_000, generationTokensPerSecond: 42)
        )
        let second = ModelDoctorAnalyzer.assess(
            profile: makeProfile(name: "model:q8", fileSize: 18_000_000_000, quantization: "Q8_0"),
            hostBefore: host,
            hostAfter: host,
            probe: makeProbe(modelName: "model:q8", observed: 19_000_000_000, accelerator: 19_000_000_000, generationTokensPerSecond: 28)
        )

        let recommendation = ModelDoctorAnalyzer.recommendVariant(between: first, and: second)

        XCTAssertEqual(recommendation.recommendedModelName, "model:q4")
        XCTAssertTrue(recommendation.reason.contains("faster"))
    }

    @MainActor
    func testRemovedTargetDoesNotAbortDiagnosisOfStillInstalledTarget() async {
        let removed = OllamaModel(
            name: "gemma4:31b-qat",
            modifiedAt: nil,
            size: 20_000_000_000,
            digest: "removed",
            details: nil
        )
        let installed = OllamaModel(
            name: "qwen3:4b",
            modifiedAt: nil,
            size: 2_300_000_000,
            digest: "installed",
            details: nil
        )
        let installedProfile = makeProfile(
            name: installed.name,
            fileSize: installed.size
        )
        let host = makeHost(
            physical: 36_000_000_000,
            available: 24_000_000_000
        )
        let viewModel = ModelDoctorViewModel(
            profileProvider: { model in
                guard model.name != removed.name else {
                    throw OllamaClientError.server("model '\(model.name)' not found")
                }
                return installedProfile
            },
            probeRunner: { configuration, iteration in
                BenchmarkSample(
                    modelName: configuration.modelName,
                    iteration: iteration,
                    startedAt: Date(timeIntervalSince1970: 1_000),
                    timeToFirstTokenSeconds: 0.25,
                    totalDurationNanoseconds: 3_000_000_000,
                    loadDurationNanoseconds: 250_000_000,
                    promptEvaluationCount: 12,
                    promptEvaluationDurationNanoseconds: 300_000_000,
                    evaluationCount: 80,
                    evaluationDurationNanoseconds: 2_000_000_000
                )
            },
            runtimeProvider: {
                OllamaRuntimeStatus(
                    models: [
                        OllamaRunningModel(
                            name: installed.name,
                            size: 2_500_000_000,
                            sizeVRAM: 2_500_000_000
                        )
                    ]
                )
            },
            unloader: {},
            hostCapture: { host }
        )

        await viewModel.run(primary: removed, comparison: installed)

        XCTAssertEqual(viewModel.assessments.map(\.profile.name), [installed.name])
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            viewModel.noticeMessage,
            "Diagnosis completed for qwen3:4b. Skipped removed model gemma4:31b-qat."
        )
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertEqual(viewModel.currentModelName, "")
    }

    private func makeProfile(
        name: String = "phi4:latest",
        fileSize: Int64,
        quantization: String = "Q4_K_M",
        maxContext: Int = 16_384
    ) -> ModelDoctorProfile {
        ModelDoctorProfile(
            name: name,
            family: "phi3",
            quantization: quantization,
            fileSizeBytes: fileSize,
            parameterCount: 14_659_507_200,
            maximumContextSize: maxContext,
            blockCount: 40,
            embeddingLength: 5_120,
            attentionHeadCount: 40,
            keyValueHeadCount: 10
        )
    }

    private func makeHost(
        physical: Int64,
        available: Int64,
        swapUsed: Int64 = 0
    ) -> ModelDoctorHostSnapshot {
        ModelDoctorHostSnapshot(
            physicalMemoryBytes: physical,
            availableMemoryBytes: available,
            swapUsedBytes: swapUsed,
            swapTotalBytes: 24_000_000_000,
            thermalState: "nominal"
        )
    }

    private func makeProbe(
        modelName: String = "phi4:latest",
        observed: Int64,
        accelerator: Int64,
        generationTokensPerSecond: Double = 35
    ) -> ModelDoctorProbe {
        ModelDoctorProbe(
            modelName: modelName,
            observedMemoryBytes: observed,
            acceleratorMemoryBytes: accelerator,
            generationTokensPerSecond: generationTokensPerSecond,
            promptTokensPerSecond: 120,
            timeToFirstTokenSeconds: 1.2,
            loadDurationSeconds: 0.8
        )
    }
}
