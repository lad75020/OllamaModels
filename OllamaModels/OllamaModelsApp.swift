import SwiftUI
import SwiftData

@main
struct OllamaModelsApp: App {
    var body: some Scene {
        WindowGroup("OllamaModels") {
            ContentView()
        }
        .modelContainer(for: [BenchmarkSessionRecord.self, BenchmarkRunRecord.self])
        .defaultSize(width: 1_060, height: 700)
    }
}
