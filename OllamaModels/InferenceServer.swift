import Foundation
import Observation
import SwiftData

enum InferenceServerKind: String, CaseIterable, Codable, Sendable {
    case ollama
    case openAICompatible

    var displayName: String {
        switch self {
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-compatible"
        }
    }
}

struct InferenceServer: Identifiable, Equatable, Hashable, Sendable {
    static let defaultOllamaID = UUID(uuidString: "C0A61251-6B7C-487D-94E1-9F79D178D5AC")!

    let id: UUID
    let name: String
    let port: Int
    let kind: InferenceServerKind

    init(id: UUID = UUID(), name: String, port: Int, kind: InferenceServerKind) {
        self.id = id
        self.name = name
        self.port = port
        self.kind = kind
    }

    static var defaultOllama: InferenceServer {
        let port = configuredOllamaPort ?? 11_434
        return InferenceServer(
            id: defaultOllamaID,
            name: "Ollama",
            port: port,
            kind: .ollama
        )
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var endpointDescription: String {
        baseURL.absoluteString
    }

    var supportsNativeModelManagement: Bool {
        kind == .ollama
    }

    private static var configuredOllamaPort: Int? {
        guard let value = ProcessInfo.processInfo.environment["OLLAMA_HOST"],
              let url = URL(string: value),
              url.host != nil,
              let port = url.port,
              InferenceServerValidator.isValid(port: port) else {
            return nil
        }
        return port
    }
}

@Model
final class InferenceServerRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var port: Int
    var kindRawValue: String
    var isActive: Bool = false

    init(server: InferenceServer, isActive: Bool = false) {
        id = server.id
        name = server.name
        port = server.port
        kindRawValue = server.kind.rawValue
        self.isActive = isActive
    }

    var server: InferenceServer {
        InferenceServer(
            id: id,
            name: name,
            port: port,
            kind: InferenceServerKind(rawValue: kindRawValue) ?? .openAICompatible
        )
    }
}

enum InferenceServerValidator {
    static func isValid(port: Int) -> Bool {
        (1...65_535).contains(port)
    }

    static func normalizedName(_ rawValue: String, port: Int) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "OpenAI-compatible :\(port)" : String(trimmed.prefix(80))
    }
}

@MainActor
@Observable
final class ServerHealthMonitor {
    private(set) var reachability: [UUID: Bool] = [:]

    func isReachable(_ server: InferenceServer) -> Bool {
        reachability[server.id] ?? false
    }

    func refresh(servers: [InferenceServer]) async {
        let results = await withTaskGroup(of: (UUID, Bool).self, returning: [(UUID, Bool)].self) { group in
            for server in servers {
                group.addTask {
                    (server.id, await OllamaClient(server: server).isAvailable())
                }
            }

            var results: [(UUID, Bool)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        reachability = Dictionary(uniqueKeysWithValues: results)
    }
}
