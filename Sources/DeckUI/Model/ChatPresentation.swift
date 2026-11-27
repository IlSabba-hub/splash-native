import Foundation

public struct ChatConversationRow: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let updated: Date
    public let answering: Bool
    public let tokens: Int?

    public init(id: UUID, title: String, updated: Date, answering: Bool = false, tokens: Int? = nil) {
        self.id = id
        self.title = title
        self.updated = updated
        self.answering = answering
        self.tokens = tokens
    }
}

public struct ChatToolCallItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let arguments: String
    public let callID: String?
    public let answered: Bool

    public init(id: String, name: String, arguments: String, callID: String?, answered: Bool) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.callID = callID
        self.answered = answered
    }
}

public enum ChatReplyLine: Sendable, Equatable {
    case reading(read: Double?, since: Date)
    case thinking(since: Date)
    case thought(tokens: Int?, seconds: Double?)
}

public struct ChatBubble: Sendable, Equatable, Identifiable {
    public enum Role: Sendable, Equatable { case user, assistant, tool }

    public let id: UUID
    public let role: Role
    public let text: String
    public let reasoning: String
    public let toolCalls: [ChatToolCallItem]
    public let toolName: String?
    public let error: String?
    public let stopped: Bool
    public let live: Bool
    public let line: ChatReplyLine?
    public let model: String?
    public let numbers: ChatReplyNumbers?
    public let fieldsSent: String?
    public let actions: [DeckAction]
    public let delete: DeckAction?

    public init(id: UUID, role: Role, text: String, reasoning: String = "", toolCalls: [ChatToolCallItem] = [], toolName: String? = nil,
                error: String? = nil, stopped: Bool = false, live: Bool = false, line: ChatReplyLine? = nil, model: String? = nil,
                numbers: ChatReplyNumbers? = nil, fieldsSent: String? = nil, actions: [DeckAction] = [], delete: DeckAction? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.error = error
        self.stopped = stopped
        self.live = live
        self.line = line
        self.model = model
        self.numbers = numbers
        self.fieldsSent = fieldsSent
        self.actions = actions
        self.delete = delete
    }

    public var summary: [String] { numbers?.summary ?? [] }

    public var facts: [Fact] {
        guard let numbers else { return [] }
        var facts = numbers.facts
        if let fieldsSent { facts.append(Fact(title: tr("chat.fact.fields"), value: .value(fieldsSent))) }
        return facts
    }

    public static func == (a: ChatBubble, b: ChatBubble) -> Bool {
        a.id == b.id && a.role == b.role && a.text == b.text && a.reasoning == b.reasoning && a.toolCalls == b.toolCalls
            && a.toolName == b.toolName && a.error == b.error && a.stopped == b.stopped && a.live == b.live && a.line == b.line
            && a.model == b.model && a.numbers == b.numbers && a.fieldsSent == b.fieldsSent && a.actions.map(\.title) == b.actions.map(\.title)
            && a.delete?.title == b.delete?.title
    }
}

public struct ChatReplyNumbers: Sendable, Equatable {
    public var ttftMs: Double?
    public var clientTTFTMs: Double?
    public var decodeTokensPerSecond: Double?
    public var prefillTokensPerSecond: Double?
    public var promptTokens: Int?
    public var cachedTokens: Int?
    public var stateSource: String?
    public var completionTokens: Int?
    public var reasoningTokens: Int?
    public var draftedTokens: Int?
    public var acceptedDraftTokens: Int?
    public var finishReason: String?

    public init(ttftMs: Double? = nil, clientTTFTMs: Double? = nil, decodeTokensPerSecond: Double? = nil, prefillTokensPerSecond: Double? = nil,
                promptTokens: Int? = nil, cachedTokens: Int? = nil, stateSource: String? = nil, completionTokens: Int? = nil,
                reasoningTokens: Int? = nil, draftedTokens: Int? = nil, acceptedDraftTokens: Int? = nil, finishReason: String? = nil) {
        self.ttftMs = ttftMs
        self.clientTTFTMs = clientTTFTMs
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.stateSource = stateSource
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.draftedTokens = draftedTokens
        self.acceptedDraftTokens = acceptedDraftTokens
        self.finishReason = finishReason
    }

    public var summary: [String] {
        [ttftMs.map { tr("chat.summary.ttft", DeckFormat.latency(milliseconds: $0)) },
         decodeTokensPerSecond.map { DeckFormat.tokensPerSecond($0) },
         completionTokens.map { tr($0 == 1 ? "chat.summary.tokens.one" : "chat.summary.tokens", DeckFormat.count($0)) }].compactMap { $0 }
    }

    public var facts: [Fact] {
        let missing = tr("chat.fact.notSent")
        func value<T>(_ x: T?, _ format: (T) -> String) -> Measured<String> { x.map { .value(format($0)) } ?? .unavailable(reason: missing) }
        func response(_ field: String) -> Provenance { Provenance(source: .response(field: field)) }
        let draft: Measured<String> = if let drafted = draftedTokens, let accepted = acceptedDraftTokens {
            .value(tr("chat.fact.draftValue", DeckFormat.count(accepted), DeckFormat.count(drafted),
                      DeckFormat.percent(drafted > 0 ? Double(accepted) / Double(drafted) : 0)))
        } else {
            .unavailable(reason: missing)
        }
        return [
            Fact(title: tr("chat.fact.ttft"), value: value(ttftMs) { DeckFormat.latency(milliseconds: $0) },
                 provenance: response("metrics.request_latency.ttft_ms")),
            Fact(title: tr("chat.fact.clientTTFT"), value: value(clientTTFTMs) { DeckFormat.latency(milliseconds: $0) },
                 provenance: Provenance(source: .deck(what: tr("chat.fact.clientTTFT.source")))),
            Fact(title: tr("chat.fact.decode"), value: value(decodeTokensPerSecond) { DeckFormat.tokensPerSecond($0) },
                 provenance: response("metrics.request_latency.stream_tokens_per_second")),
            Fact(title: tr("chat.fact.prefill"), value: value(prefillTokensPerSecond) { DeckFormat.tokensPerSecond($0) },
                 provenance: response("timings.prompt_per_second")),
            Fact(title: tr("chat.fact.prompt"), value: value(promptTokens) { DeckFormat.count($0) }, provenance: response("usage.prompt_tokens")),
            Fact(title: tr("chat.fact.cached"), value: value(cachedTokens) { cached in
                stateSource.map { tr("chat.fact.cachedFrom", DeckFormat.count(cached), $0) } ?? DeckFormat.count(cached)
            }, provenance: response("usage.prompt_tokens_details.cached_tokens")),
            Fact(title: tr("chat.fact.completion"), value: value(completionTokens) { DeckFormat.count($0) },
                 provenance: response("usage.completion_tokens")),
            Fact(title: tr("chat.fact.reasoning"), value: value(reasoningTokens) { DeckFormat.count($0) },
                 provenance: response("usage.completion_tokens_details.reasoning_tokens")),
            Fact(title: tr("chat.fact.draft"), value: draft, provenance: response("timings.draft_n_accepted / draft_n")),
            Fact(title: tr("chat.fact.finish"), value: value(finishReason) { $0 }, provenance: response("choices[0].finish_reason")),
        ]
    }
}

public struct ChatColumnState: Sendable, Equatable {
    public let conversations: [ChatConversationRow]
    public let selection: UUID?

    public init(conversations: [ChatConversationRow], selection: UUID?) {
        self.conversations = conversations
        self.selection = selection
    }
}

public struct ChatColumnActions: Sendable {
    public let newChat: @MainActor @Sendable () -> Void
    public let select: @MainActor @Sendable (UUID) -> Void
    public let rename: @MainActor @Sendable (UUID, String) -> Void
    public let duplicate: @MainActor @Sendable (UUID) -> Void
    public let delete: @MainActor @Sendable (UUID) -> Void

    public init(newChat: @escaping @MainActor @Sendable () -> Void, select: @escaping @MainActor @Sendable (UUID) -> Void,
                rename: @escaping @MainActor @Sendable (UUID, String) -> Void, duplicate: @escaping @MainActor @Sendable (UUID) -> Void,
                delete: @escaping @MainActor @Sendable (UUID) -> Void) {
        self.newChat = newChat
        self.select = select
        self.rename = rename
        self.duplicate = duplicate
        self.delete = delete
    }
}

public enum ChatModelState: Sendable, Equatable {
    case none
    case reading(name: String)
    case ready(name: String, model: String)
}

public struct ChatPageState: Sendable, Equatable {
    public let model: ChatModelState
    public let title: String?
    public let messages: [ChatBubble]
    public let answering: Bool
    public let sendBlocked: String?
    public let context: Measured<ContextUse>
    public let tools: [String]
    public let presets: [String]
    public let preset: String?
    public let metrics: ReplyMetrics?

    public init(model: ChatModelState, title: String?, messages: [ChatBubble], answering: Bool, sendBlocked: String?,
                context: Measured<ContextUse>, tools: [String] = [], presets: [String] = [], preset: String? = nil,
                metrics: ReplyMetrics? = nil) {
        self.model = model
        self.title = title
        self.messages = messages
        self.answering = answering
        self.sendBlocked = sendBlocked
        self.context = context
        self.tools = tools
        self.presets = presets
        self.preset = preset
        self.metrics = metrics
    }
}

public struct ChatPageActions: Sendable {
    public let send: @MainActor @Sendable (String) -> Void
    public let stop: @MainActor @Sendable () -> Void
    public let answerTool: @MainActor @Sendable (String, String) -> Void
    public let loadModel: @MainActor @Sendable () -> Void
    public let choosePreset: @MainActor @Sendable (String?) -> Void
    public let showSettings: @MainActor @Sendable () -> Void

    public init(send: @escaping @MainActor @Sendable (String) -> Void, stop: @escaping @MainActor @Sendable () -> Void,
                answerTool: @escaping @MainActor @Sendable (String, String) -> Void, loadModel: @escaping @MainActor @Sendable () -> Void,
                choosePreset: @escaping @MainActor @Sendable (String?) -> Void, showSettings: @escaping @MainActor @Sendable () -> Void) {
        self.send = send
        self.stop = stop
        self.answerTool = answerTool
        self.loadModel = loadModel
        self.choosePreset = choosePreset
        self.showSettings = showSettings
    }
}

public struct ChatSetting: Sendable, Equatable, Identifiable {
    public enum Control: Sendable, Equatable {
        case slider(ClosedRange<Double>, step: Double, digits: Int)
        case stepper(minimum: Int64, maximum: Int64?)
        case number(minimum: Double, openBelow: Bool)
        case choice([String], unoffered: [ChatUnofferedChoice])
        case lines(limit: Int)
    }

    public let id: String
    public let title: String
    public let control: Control
    public let value: ParameterValue
    public let defaultValue: Double?
    public let placeholder: String
    public let defaultSource: String
    public let rule: String
    public let provenance: Provenance
    public let problem: String?
    public let disabledReason: String?

    public init(id: String, title: String, control: Control, value: ParameterValue, defaultValue: Double?, placeholder: String,
                defaultSource: String, rule: String, provenance: Provenance, problem: String? = nil, disabledReason: String? = nil) {
        self.id = id
        self.title = title
        self.control = control
        self.value = value
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.defaultSource = defaultSource
        self.rule = rule
        self.provenance = provenance
        self.problem = problem
        self.disabledReason = disabledReason
    }

    public var isChanged: Bool { value != .unset }
}

public struct ChatUnofferedChoice: Sendable, Equatable, Identifiable {
    public let token: String
    public let reason: String
    public var id: String { token }

    public init(token: String, reason: String) {
        self.token = token
        self.reason = reason
    }
}

public struct ChatSettingsState: Sendable, Equatable {
    public let system: String
    public let presets: [String]
    public let preset: String?
    public let sampling: [ChatSetting]
    public let reasoning: [ChatSetting]
    public let tools: String
    public let toolNames: [String]
    public let toolsProblem: String?

    public init(system: String, presets: [String], preset: String?, sampling: [ChatSetting], reasoning: [ChatSetting], tools: String,
                toolNames: [String], toolsProblem: String?) {
        self.system = system
        self.presets = presets
        self.preset = preset
        self.sampling = sampling
        self.reasoning = reasoning
        self.tools = tools
        self.toolNames = toolNames
        self.toolsProblem = toolsProblem
    }
}

public struct ChatInspectorActions: Sendable {
    public let setValue: @MainActor @Sendable (String, ParameterValue) -> Void
    public let setSystem: @MainActor @Sendable (String) -> Void
    public let setTools: @MainActor @Sendable (String) -> Void
    public let choosePreset: @MainActor @Sendable (String?) -> Void
    public let savePreset: @MainActor @Sendable (String) -> Void
    public let deletePreset: @MainActor @Sendable (String) -> Void

    public init(setValue: @escaping @MainActor @Sendable (String, ParameterValue) -> Void,
                setSystem: @escaping @MainActor @Sendable (String) -> Void, setTools: @escaping @MainActor @Sendable (String) -> Void,
                choosePreset: @escaping @MainActor @Sendable (String?) -> Void, savePreset: @escaping @MainActor @Sendable (String) -> Void,
                deletePreset: @escaping @MainActor @Sendable (String) -> Void) {
        self.setValue = setValue
        self.setSystem = setSystem
        self.setTools = setTools
        self.choosePreset = choosePreset
        self.savePreset = savePreset
        self.deletePreset = deletePreset
    }
}
