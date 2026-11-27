import Foundation

public enum ChatFieldForm {
    public struct Default: Sendable, Equatable {
        public let value: Double
        public let source: String

        public init(value: Double, source: String) {
            self.value = value
            self.source = source
        }
    }

    public struct Input: Sendable, Equatable {
        public let version: String
        public let sources: [String: String]
        public let efforts: [String]?
        public let defaultEffort: String?
        public let serverEffort: String?
        public let thinkingBudgetHasNoEffect: Bool
        public let contextLength: Int?
        public let defaults: [String: Default]
        public let values: [String: ParameterValue]
        public let problems: Set<String>
        public let unofferedEfforts: [ChatUnofferedChoice]

        public init(version: String, sources: [String: String], efforts: [String]?, defaultEffort: String?, serverEffort: String?,
                    thinkingBudgetHasNoEffect: Bool, contextLength: Int?, defaults: [String: Default] = [:],
                    values: [String: ParameterValue] = [:], problems: Set<String> = [], unofferedEfforts: [ChatUnofferedChoice] = []) {
            self.version = version
            self.sources = sources
            self.efforts = efforts
            self.defaultEffort = defaultEffort
            self.serverEffort = serverEffort
            self.thinkingBudgetHasNoEffect = thinkingBudgetHasNoEffect
            self.contextLength = contextLength
            self.defaults = defaults
            self.values = values
            self.problems = problems
            self.unofferedEfforts = unofferedEfforts
        }
    }

    public static let samplingOrder = ["temperature", "top_p", "min_p", "top_k", "presence_penalty", "frequency_penalty", "repetition_penalty",
                                       "seed", "max_tokens", "stop"]
    public static let reasoningOrder = ["reasoning_effort", "thinking_token_budget"]

    public static func sampling(_ input: Input) -> [ChatSetting] { samplingOrder.map { setting($0, input) } }
    public static func reasoning(_ input: Input) -> [ChatSetting] { reasoningOrder.map { setting($0, input) } }

    static func setting(_ name: String, _ input: Input) -> ChatSetting {
        let provenance = Provenance(flag: name, source: .requestField(version: input.version, source: input.sources[name] ?? ""))
        let value = input.values[name] ?? .unset
        let known = input.defaults[name]
        func make(_ title: String, _ control: ChatSetting.Control, placeholder: String, source: String, rule: String,
                  defaultValue: Double? = nil, disabled: String? = nil) -> ChatSetting {
            ChatSetting(id: name, title: title, control: control, value: value, defaultValue: defaultValue ?? known?.value,
                        placeholder: placeholder, defaultSource: source, rule: rule, provenance: provenance,
                        problem: input.problems.contains(name) ? tr("chat.setting.problem", rule) : nil, disabledReason: disabled)
        }
        func sampled(_ title: String, _ control: ChatSetting.Control, rule: String) -> ChatSetting {
            make(title, control, placeholder: known.map { DeckFormat.number($0.value, fractionDigits: 2) } ?? tr("chat.default.server"),
                 source: known?.source ?? tr("chat.default.unknown"), rule: rule)
        }
        switch name {
        case "temperature":
            return sampled(tr("chat.field.temperature"), .slider(0 ... 2, step: 0.01, digits: 2), rule: "temperature must be a number in [0, 2]")
        case "top_p":
            return sampled(tr("chat.field.topP"), .slider(0.01 ... 1, step: 0.01, digits: 2), rule: "top_p must be a number in (0, 1]")
        case "min_p":
            return sampled(tr("chat.field.minP"), .slider(0 ... 1, step: 0.01, digits: 2), rule: "min_p must be a number in [0, 1]")
        case "top_k":
            return make(tr("chat.field.topK"), .stepper(minimum: -1, maximum: nil),
                        placeholder: known.map { DeckFormat.count(Int($0.value)) } ?? tr("chat.default.server"),
                        source: known?.source ?? tr("chat.default.unknown"), rule: "top_k must be 0 or -1 (disabled) or a positive integer")
        case "presence_penalty":
            return sampled(tr("chat.field.presencePenalty"), .slider(-2 ... 2, step: 0.01, digits: 2),
                           rule: "presence_penalty must be a number in [-2, 2]")
        case "frequency_penalty":
            return sampled(tr("chat.field.frequencyPenalty"), .slider(-2 ... 2, step: 0.01, digits: 2),
                           rule: "frequency_penalty must be a number in [-2, 2]")
        case "repetition_penalty":
            return sampled(tr("chat.field.repetitionPenalty"), .number(minimum: 0, openBelow: true), rule: "repetition_penalty must be a positive number")
        case "seed":
            return make(tr("chat.field.seed"), .stepper(minimum: -1, maximum: nil), placeholder: tr("chat.default.random"),
                        source: tr("chat.default.splashRule", input.version), rule: "seed must be a 64-bit integer; -1 asks for a random seed",
                        defaultValue: -1)
        case "max_tokens":
            return make(tr("chat.field.maxTokens"), .stepper(minimum: 1, maximum: input.contextLength.map(Int64.init)),
                        placeholder: tr("chat.default.toContextEnd"), source: tr("chat.default.splashRule", input.version),
                        rule: "max_tokens must be a positive integer; a request generates up to the end of the context window its prompt leaves")
        case "stop":
            return make(tr("chat.field.stop"), .lines(limit: 4), placeholder: tr("chat.default.none"),
                        source: tr("chat.default.splashRule", input.version), rule: "stop must be a string or up to four strings")
        case "reasoning_effort":
            let efforts = input.efforts ?? []
            let reason: String? = if let effort = input.serverEffort {
                tr("chat.reason.serverEffort", effort)
            } else if input.efforts == nil {
                tr("chat.reason.effortsUnread")
            } else if efforts.isEmpty {
                tr("chat.reason.noEfforts")
            } else {
                nil
            }
            return make(tr("chat.field.reasoningEffort"), .choice(efforts, unoffered: input.unofferedEfforts),
                        placeholder: input.defaultEffort ?? tr("chat.default.server"),
                        source: input.defaultEffort != nil ? tr("chat.default.modelEffort") : tr("chat.default.unknown"),
                        rule: "reasoning_effort: none, minimal, low, medium, high, xhigh, max", disabled: reason)
        default:
            return make(tr("chat.field.thinkingTokenBudget"), .stepper(minimum: -1, maximum: nil), placeholder: tr("chat.default.noCap"),
                        source: tr("chat.default.serverFlag"), rule: "thinking_token_budget must be a non-negative integer or -1 for no cap",
                        disabled: input.thinkingBudgetHasNoEffect ? tr("chat.reason.thinkingBudget") : nil)
        }
    }

    static func help(_ setting: ChatSetting) -> String {
        tr("chat.setting.help", setting.placeholder, setting.defaultSource, setting.rule)
    }
}
