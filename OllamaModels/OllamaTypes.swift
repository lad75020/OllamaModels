import Foundation

struct OllamaModel: Decodable, Identifiable, Hashable, Sendable {
    let name: String
    let modifiedAt: String?
    let size: Int64
    let digest: String
    let details: Details?
    let capabilities: [String]

    var id: String { name }

    var supportsCompletion: Bool {
        capabilities.isEmpty || capabilities.contains("completion")
    }

    var supportsLocalBenchmark: Bool {
        let normalizedName = name.lowercased()
        return supportsCompletion
            && size >= 1_000_000
            && !normalizedName.contains("embed")
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var parameterSize: String {
        details?.parameterSize ?? "—"
    }

    var family: String {
        details?.family ?? "—"
    }

    var quantization: String {
        details?.quantizationLevel ?? "—"
    }

    var modifiedLabel: String {
        guard let modifiedAt, !modifiedAt.isEmpty else { return "—" }
        return String(modifiedAt.prefix(10))
    }

    struct Details: Codable, Hashable, Sendable {
        let parentModel: String?
        let format: String?
        let family: String?
        let families: [String]?
        let parameterSize: String?
        let quantizationLevel: String?

        enum CodingKeys: String, CodingKey {
            case parentModel = "parent_model"
            case format
            case family
            case families
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case model
        case modifiedAt = "modified_at"
        case size
        case digest
        case details
        case capabilities
    }

    init(
        name: String,
        modifiedAt: String?,
        size: Int64,
        digest: String,
        details: Details?,
        capabilities: [String] = []
    ) {
        self.name = name
        self.modifiedAt = modifiedAt
        self.size = size
        self.digest = digest
        self.details = details
        self.capabilities = capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = try container.decodeIfPresent(String.self, forKey: .name)
                ?? container.decodeIfPresent(String.self, forKey: .model) else {
            throw DecodingError.keyNotFound(
                CodingKeys.name,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "The Ollama model response did not include a name."
                )
            )
        }

        self.init(
            name: name,
            modifiedAt: try container.decodeIfPresent(String.self, forKey: .modifiedAt),
            size: try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0,
            digest: try container.decodeIfPresent(String.self, forKey: .digest) ?? "",
            details: try container.decodeIfPresent(Details.self, forKey: .details),
            capabilities: try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        )
    }
}

struct OllamaTagsResponse: Decodable, Sendable {
    let models: [OllamaModel]
}

struct OllamaShowRequest: Encodable, Sendable {
    let model: String
    let verbose = false
}

private indirect enum OllamaJSONValue: Decodable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case array([OllamaJSONValue])
    case object([String: OllamaJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([OllamaJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: OllamaJSONValue].self))
        }
    }

    var integerValue: Int64? {
        guard case .number(let value) = self, value.isFinite else { return nil }
        return Int64(exactly: value)
    }
}

struct OllamaShowResponse: Decodable, Sendable {
    let details: OllamaModel.Details?
    private let modelInfo: [String: OllamaJSONValue]

    private enum CodingKeys: String, CodingKey {
        case details
        case modelInfo = "model_info"
    }

    func profile(for model: OllamaModel) -> ModelDoctorProfile {
        let architecture = stringValue(for: "general.architecture")
            ?? details?.family
            ?? model.family
        return ModelDoctorProfile(
            name: model.name,
            family: architecture,
            quantization: details?.quantizationLevel ?? model.quantization,
            fileSizeBytes: model.size,
            parameterCount: integerValue(exactKey: "general.parameter_count"),
            maximumContextSize: integerValue(suffix: ".context_length", fallback: 4_096),
            blockCount: integerValue(suffix: ".block_count", fallback: 0),
            embeddingLength: integerValue(suffix: ".embedding_length", fallback: 0),
            attentionHeadCount: integerValue(suffix: ".attention.head_count", fallback: 1),
            keyValueHeadCount: integerValue(suffix: ".attention.head_count_kv", fallback: 1)
        )
    }

    private func integerValue(exactKey: String) -> Int64 {
        modelInfo[exactKey]?.integerValue ?? 0
    }

    private func integerValue(suffix: String, fallback: Int) -> Int {
        guard let value = modelInfo.first(where: { $0.key.hasSuffix(suffix) })?.value.integerValue else {
            return fallback
        }
        return Int(clamping: value)
    }

    private func stringValue(for key: String) -> String? {
        guard case .string(let value) = modelInfo[key] else { return nil }
        return value
    }
}

struct OllamaRunningModel: Decodable, Equatable, Sendable {
    let name: String
    let size: Int64
    let sizeVRAM: Int64

    init(name: String, size: Int64, sizeVRAM: Int64) {
        self.name = name
        self.size = size
        self.sizeVRAM = sizeVRAM
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case model
        case size
        case sizeVRAM = "size_vram"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = try container.decodeIfPresent(String.self, forKey: .name)
                ?? container.decodeIfPresent(String.self, forKey: .model) else {
            throw DecodingError.keyNotFound(
                CodingKeys.name,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "The Ollama process response did not include a model name."
                )
            )
        }

        self.init(
            name: name,
            size: try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0,
            sizeVRAM: try container.decodeIfPresent(Int64.self, forKey: .sizeVRAM) ?? 0
        )
    }
}

struct OllamaProcessResponse: Decodable, Sendable {
    let models: [OllamaRunningModel]
}

struct OllamaRuntimeStatus: Equatable, Sendable {
    static let empty = OllamaRuntimeStatus(models: [])

    let models: [OllamaRunningModel]

    var loadedModelNames: [String] {
        models.map(\.name)
    }

    var loadedModelNamesLabel: String {
        loadedModelNames.isEmpty ? "None" : loadedModelNames.joined(separator: ", ")
    }

    var totalMemoryBytes: Int64 {
        var total: Int64 = 0
        for model in models {
            let size = max(model.size, 0)
            let (sum, overflowed) = total.addingReportingOverflow(size)
            guard !overflowed else { return .max }
            total = sum
        }
        return total
    }

    var formattedTotalMemory: String {
        guard totalMemoryBytes > 0 else { return "0 bytes" }
        return ByteCountFormatter.string(fromByteCount: totalMemoryBytes, countStyle: .file)
    }
}

struct OllamaPullRequest: Encodable, Sendable {
    let name: String
    let stream: Bool
}

struct OllamaDeleteRequest: Encodable, Sendable {
    let name: String
}

struct OllamaUnloadRequest: Encodable, Sendable {
    let model: String
    let keepAlive = 0
    let stream = false

    enum CodingKeys: String, CodingKey {
        case model
        case keepAlive = "keep_alive"
        case stream
    }
}

struct OllamaVersionResponse: Decodable, Sendable {
    let version: String
}

struct OllamaPullEvent: Decodable, Sendable {
    let status: String?
    let digest: String?
    let total: Int64?
    let completed: Int64?
    let error: String?
}

enum ModelNameValidator {
    static func normalized(_ rawValue: String) -> String? {
        let name = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { return nil }
        guard !name.unicodeScalars.contains(where: { scalar in
            scalar.properties.isWhitespace || scalar.value < 0x20 || scalar.value == 0x7F
        }) else {
            return nil
        }
        return name
    }
}
