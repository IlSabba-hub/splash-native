import Foundation

public enum ChatField: String, CaseIterable, Sendable, Hashable, Identifiable {
    case temperature
    case topP = "top_p"
    case topK = "top_k"
    case minP = "min_p"
    case presencePenalty = "presence_penalty"
    case frequencyPenalty = "frequency_penalty"
    case repetitionPenalty = "repetition_penalty"
    case seed
    case maxTokens = "max_tokens"
    case reasoningEffort = "reasoning_effort"
    case thinkingTokenBudget = "thinking_token_budget"
    case stop

    public var id: String { rawValue }

    public enum Rule: Sendable, Equatable {
        case number(ClosedRange<Double>, openBelow: Bool)
        case integer(minimum: Int64)
        case effort
        case stops
    }

    public var rule: Rule {
        switch self {
        case .temperature: .number(0 ... 2, openBelow: false)
        case .topP: .number(0 ... 1, openBelow: true)
        case .topK: .integer(minimum: -1)
        case .minP: .number(0 ... 1, openBelow: false)
        case .presencePenalty, .frequencyPenalty: .number(-2 ... 2, openBelow: false)
        case .repetitionPenalty: .number(0 ... 3.4028234663852886e38, openBelow: true)
        case .seed: .integer(minimum: -1)
        case .maxTokens: .integer(minimum: 1)
        case .reasoningEffort: .effort
        case .thinkingTokenBudget: .integer(minimum: -1)
        case .stop: .stops
        }
    }

    public var source: String {
        switch self {
        case .temperature, .topP, .minP, .presencePenalty, .frequencyPenalty, .repetitionPenalty:
            "server/request_fields.py SAMPLING_NUMBERS"
        case .topK: "server/request_fields.py sampling_refusal"
        case .seed: "server/frontend.py _generation_options (seed)"
        case .maxTokens: "server/frontend.py _output_budget"
        case .reasoningEffort: "server/frontend.py:631-638, chat_format.py:26"
        case .thinkingTokenBudget: "server/frontend.py _generation_options (thinking_token_budget)"
        case .stop: "server/frontend.py:975-995"
        }
    }

    public static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
}

public struct ChatFields: Codable, Sendable, Equatable, Hashable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int64?
    public var minP: Double?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    public var repetitionPenalty: Double?
    public var seed: Int64?
    public var maxTokens: Int64?
    public var reasoningEffort: String?
    public var thinkingTokenBudget: Int64?
    public var stop: [String]?

    public init(temperature: Double? = nil, topP: Double? = nil, topK: Int64? = nil, minP: Double? = nil,
                presencePenalty: Double? = nil, frequencyPenalty: Double? = nil, repetitionPenalty: Double? = nil,
                seed: Int64? = nil, maxTokens: Int64? = nil, reasoningEffort: String? = nil,
                thinkingTokenBudget: Int64? = nil, stop: [String]? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
        self.maxTokens = maxTokens
        self.reasoningEffort = reasoningEffort
        self.thinkingTokenBudget = thinkingTokenBudget
        self.stop = stop
    }

    enum CodingKeys: String, CodingKey {
        case temperature, topP = "top_p", topK = "top_k", minP = "min_p", presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty", repetitionPenalty = "repetition_penalty", seed
        case maxTokens = "max_tokens", reasoningEffort = "reasoning_effort", thinkingTokenBudget = "thinking_token_budget", stop
    }

    public var isEmpty: Bool { self == ChatFields() }

    public enum Value: Sendable, Equatable, Hashable {
        case number(Double)
        case integer(Int64)
        case text(String)
        case texts([String])
    }

    public subscript(field: ChatField) -> Value? {
        get {
            switch field {
            case .temperature: temperature.map(Value.number)
            case .topP: topP.map(Value.number)
            case .topK: topK.map(Value.integer)
            case .minP: minP.map(Value.number)
            case .presencePenalty: presencePenalty.map(Value.number)
            case .frequencyPenalty: frequencyPenalty.map(Value.number)
            case .repetitionPenalty: repetitionPenalty.map(Value.number)
            case .seed: seed.map(Value.integer)
            case .maxTokens: maxTokens.map(Value.integer)
            case .reasoningEffort: reasoningEffort.map(Value.text)
            case .thinkingTokenBudget: thinkingTokenBudget.map(Value.integer)
            case .stop: stop.map(Value.texts)
            }
        }
        set {
            func number() -> Double? { if case .number(let x) = newValue { x } else if case .integer(let x) = newValue { Double(x) } else { nil } }
            func integer() -> Int64? { if case .integer(let x) = newValue { x } else { nil } }
            switch field {
            case .temperature: temperature = number()
            case .topP: topP = number()
            case .topK: topK = integer()
            case .minP: minP = number()
            case .presencePenalty: presencePenalty = number()
            case .frequencyPenalty: frequencyPenalty = number()
            case .repetitionPenalty: repetitionPenalty = number()
            case .seed: seed = integer()
            case .maxTokens: maxTokens = integer()
            case .reasoningEffort: if case .text(let x) = newValue { reasoningEffort = x } else { reasoningEffort = nil }
            case .thinkingTokenBudget: thinkingTokenBudget = integer()
            case .stop: if case .texts(let x) = newValue { stop = x } else { stop = nil }
            }
        }
    }

    public var problems: [ChatField] {
        ChatField.allCases.filter { field in
            guard let value = self[field] else { return false }
            switch (field.rule, value) {
            case let (.number(range, openBelow), .number(x)):
                return !(x.isFinite && range.contains(x) && !(openBelow && x == range.lowerBound))
            case let (.integer(minimum), .integer(x)):
                return x < minimum
            case let (.effort, .text(x)):
                return !ChatField.efforts.contains(x)
            case let (.stops, .texts(list)):
                return list.isEmpty || list.count > 4 || list.contains { $0.isEmpty || $0.count > 16_384 }
            default:
                return true
            }
        }
    }

    var wire: [String: Any] {
        var body: [String: Any] = [:]
        for field in ChatField.allCases {
            switch self[field] {
            case .number(let x)?: body[field.rawValue] = x
            case .integer(let x)?: body[field.rawValue] = x
            case .text(let x)?: body[field.rawValue] = x
            case .texts(let x)?: body[field.rawValue] = x
            case nil: break
            }
        }
        return body
    }
}

public struct ChatPreset: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var fields: ChatFields
    public var system: String?
    public var tools: String?

    public var id: String { name }

    public init(name: String, fields: ChatFields = ChatFields(), system: String? = nil, tools: String? = nil) {
        self.name = name
        self.fields = fields
        self.system = system
        self.tools = tools
    }
}

public struct ChatPresetStore: Sendable {
    public let file: URL

    public static let defaultFile = URL.applicationSupportDirectory.appending(path: "SplashNative/ChatPresets.json")

    public init(file: URL = ChatPresetStore.defaultFile) {
        self.file = file
    }

    public func load() -> [ChatPreset] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return ((try? JSONDecoder().decode([ChatPreset].self, from: data)) ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ preset: ChatPreset) throws {
        var presets = load().filter { $0.name != preset.name }
        presets.append(preset)
        try write(presets)
    }

    public func remove(_ name: String) throws {
        try write(load().filter { $0.name != name })
    }

    private func write(_ presets: [ChatPreset]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets.sorted { $0.name < $1.name }).write(to: file, options: .atomic)
    }
}
