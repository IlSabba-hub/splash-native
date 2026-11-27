import NativeCore
import NativeUI
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class ChatController {
    let session: ChatSession
    @ObservationIgnored let presets: ChatPresetStore
    private(set) var serverPort: Int?
    private(set) var facts: [Int: Result<ChatServerFacts, Error>] = [:]
    private(set) var defaults: [Int: ChatSamplingDefaults] = [:]
    @ObservationIgnored private var factsOf: [Int: Int32] = [:]
    @ObservationIgnored private var defaultsOf: [Int: Int32] = [:]
    @ObservationIgnored private var seen: Set<Int>?
    var settings = ChatSettings()
    private(set) var savedPresets: [ChatPreset]

    init(session: ChatSession = ChatSession(), presets: ChatPresetStore = ChatPresetStore()) {
        self.session = session
        self.presets = presets
        savedPresets = presets.load()
    }

    func server(in model: NativeModel) -> ChatServer? {
        let servers = model.chatServers
        return servers.first { $0.splashPort == serverPort } ?? servers.first
    }

    func use(port: Int, in model: NativeModel) {
        serverPort = port
        Task { await refresh(model) }
    }

    func refresh(_ model: NativeModel) async {
        let servers = model.chatServers
        if let seen, let newest = servers.last(where: { !seen.contains($0.splashPort) }) {
            serverPort = newest.splashPort
        }
        seen = Set(servers.map(\.splashPort))
        guard let server = server(in: model) else { return }
        if serverPort == nil { serverPort = server.splashPort }
        if factsOf[server.splashPort] == server.pid, case .success? = facts[server.splashPort] { return }
        factsOf[server.splashPort] = server.pid
        do {
            facts[server.splashPort] = .success(try await ChatServerFacts.read(port: server.splashPort, apiKey: apiKey(server, model)))
        } catch {
            facts[server.splashPort] = .failure(error)
        }
        if defaultsOf[server.splashPort] != server.pid {
            defaults[server.splashPort] = await Self.samplingDefaults(of: server, in: model)
            defaultsOf[server.splashPort] = server.pid
        }
    }

    static func samplingDefaults(of server: ChatServer, in model: NativeModel) async -> ChatSamplingDefaults? {
        guard case .owned(let name) = server.origin, let owned = model.supervisor.owned.first(where: { $0.pid == server.pid }) else { return nil }
        var family: (name: String, sampling: [String: Double])?
        let configuration = model.configurations.first(where: { $0.name == name })
        let installation = model.installations.first(where: { $0.root.path == owned.installationRoot })
            ?? configuration?.installation(among: model.installations)
        if let configuration, let installation,
           let familyName = model.family(of: configuration, in: installation),
           let sampling = try? await model.schema(for: installation).families?.families[familyName]?.sampling {
            family = (familyName, sampling)
        }
        return ChatSamplingDefaults.resolve(family: family, flags: Self.flagValues("--sampling-default", in: owned.serveArguments),
                                            version: installation?.version)
    }

    static func flagValues(_ flag: String, in arguments: [String]) -> [String] {
        var values: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == flag, index + 1 < arguments.count {
                values.append(arguments[index + 1])
                index += 2
                continue
            }
            if argument.hasPrefix(flag + "=") { values.append(String(argument.dropFirst(flag.count + 1))) }
            index += 1
        }
        return values
    }

    private func endpoint(in model: NativeModel) -> Result<ChatEndpoint, Blocked> {
        guard let server = server(in: model) else { return .failure(.text(tr("chat.blocked.noServer"))) }
        switch facts[server.splashPort] {
        case .success(let facts)?:
            return .success(ChatEndpoint(port: server.chatPort, apiKey: apiKey(server, model), model: facts.model.id))
        case .failure(let error)?:
            return .failure(.text(tr("chat.blocked.unreadable", NativeFormat.port(server.splashPort), error.localizedDescription)))
        case nil:
            return .failure(.text(tr("chat.blocked.reading", NativeFormat.port(server.splashPort))))
        }
    }

    private enum Blocked: Error { case text(String) }

    private func apiKey(_ server: ChatServer, _ model: NativeModel) -> String? {
        guard case .owned = server.origin, let owned = model.supervisor.owned.first(where: { $0.pid == server.pid }) else { return nil }
        return model.apiKey(for: owned)
    }

    private func blockedReason(in model: NativeModel) -> String? {
        if case .failure(.text(let reason)) = endpoint(in: model) { return reason }
        let problems = settings.fields.problems
        if !problems.isEmpty { return tr("chat.blocked.fields", problems.map(\.rawValue).joined(separator: ", ")) }
        if !Self.toolsAreValid(settings.tools) { return tr("chat.blocked.tools") }
        return nil
    }

    static func toolsAreValid(_ text: String?) -> Bool {
        do {
            _ = try ChatWire.tools(text)
            return true
        } catch {
            return false
        }
    }

    static func toolNames(_ text: String?) -> [String] {
        guard let tools = try? ChatWire.tools(text) else { return [] }
        return tools.compactMap { (($0 as? [String: Any])?["function"] as? [String: Any])?["name"] as? String }
    }

    func chip(_ loaded: LoadedModel, in model: NativeModel) -> LoadedModel {
        let current = server(in: model)?.splashPort
        let use = current == loaded.port || model.chatServers.count < 2 ? nil
            : NativeAction(title: tr("chat.useInChat"), systemImage: "bubble.left") { [weak self] in self?.use(port: loaded.port, in: model) }
        return loaded.forChat(current == loaded.port, use: use)
    }

    func column() -> ChatColumnState {
        let live = session.live
        let rows = session.conversations.map { conversation in
            ChatConversationRow(id: conversation.id, title: conversation.title, updated: conversation.updated,
                                answering: live?.conversation == conversation.id, tokens: Self.contextTokens(conversation))
        }
        return ChatColumnState(conversations: rows, selection: session.selection)
    }

    static func contextTokens(_ conversation: NativeConversation) -> Int? {
        guard let stats = conversation.messages.last(where: { $0.stats?.promptTokens != nil })?.stats,
              let prompt = stats.promptTokens else { return nil }
        return prompt + (stats.completionTokens ?? 0)
    }

    func columnActions() -> ChatColumnActions {
        ChatColumnActions(
            newChat: { [weak self] in self?.session.newChat() },
            select: { [weak self] id in
                guard let self else { return }
                session.selection = id
                if let conversation = session.current {
                    settings.system = conversation.system
                    settings.tools = conversation.tools
                }
            },
            rename: { [weak self] id, title in self?.session.rename(id, to: title) },
            duplicate: { [weak self] id in
                guard let self, let original = session.conversations.first(where: { $0.id == id }) else { return }
                session.duplicate(id, title: tr("chat.duplicate.title", original.title))
            },
            delete: { [weak self] id in self?.session.delete(id) })
    }

    func page(_ model: NativeModel) -> ChatPageState {
        let server = server(in: model)
        let live = session.live
        let blocked = blockedReason(in: model)
        var messages: [ChatBubble] = []
        let conversation = session.current
        if let conversation {
            let answered = Set(conversation.messages.compactMap(\.toolCallID))
            for (index, message) in conversation.messages.enumerated() {
                let isLive = live?.message.id == message.id
                let shown = isLive ? live!.message : message
                let canRetry = index == conversation.messages.count - 1 && shown.role == .assistant && live == nil && blocked == nil
                messages.append(Self.bubble(shown, live: isLive ? live : nil, answered: answered,
                                            actions: canRetry ? [retryAction(model)] : [], delete: live == nil ? deleteAction(message) : nil))
            }
        }
        let state: ChatModelState = if let server {
            if case .success(let facts)? = facts[server.splashPort] {
                .ready(name: Self.title(of: server), model: facts.model.id)
            } else {
                .reading(name: Self.title(of: server))
            }
        } else {
            .none
        }
        return ChatPageState(model: state, title: conversation?.title, messages: messages, answering: live != nil, sendBlocked: blocked,
                             context: context(conversation, server: server), tools: Self.toolNames(settings.tools),
                             presets: savedPresets.map(\.name), preset: settings.preset,
                             metrics: metrics(conversation, live: live, server: server))
    }

    private func metrics(_ conversation: NativeConversation?, live: ChatSession.Live?, server: ChatServer?) -> ReplyMetrics? {
        if let live, live.conversation == conversation?.id {
            let track = server.flatMap { server in ServerBoard.shared.activeServers.first { $0.port == server.splashPort }?.track }
            return Self.liveMetrics(live, track: track)
        }
        guard let stats = conversation?.messages.last(where: { $0.role == .assistant && $0.stats != nil })?.stats else { return nil }
        return .done(Self.numbers(stats))
    }

    static func liveMetrics(_ live: ChatSession.Live, track: LiveTrack?, now: Date = .now) -> ReplyMetrics {
        let ttft: Measured<String> = live.firstVisible.map { .value(NativeFormat.latency(milliseconds: $0.timeIntervalSince(live.asked) * 1000)) }
            ?? .unavailable(reason: tr("metrics.waiting", NativeFormat.duration(seconds: now.timeIntervalSince(live.asked))))
        guard let track else {
            let reason = tr("metrics.noStatus")
            return ReplyMetrics(ttft: ttft, prefill: .unavailable(reason: reason), decode: .unavailable(reason: reason),
                                tokens: .unavailable(reason: reason), live: true, source: tr("metrics.source.live"))
        }
        func latest(_ samples: [LiveSample]) -> Double? { samples.last { $0.at.timeIntervalSince(live.asked) >= 0 && $0.value != nil }?.value }
        let prefill: Measured<String> = latest(track.prefill).map { .value(NativeFormat.tokensPerSecond($0)) }
            ?? .unavailable(reason: tr("metrics.prefill.notYet"))
        let decode: Measured<String> = latest(track.decode).map { .value(NativeFormat.tokensPerSecond($0)) }
            ?? .unavailable(reason: tr(live.firstVisible == nil ? "metrics.decode.notYet" : "metrics.prefill.notYet"))
        let age = now.timeIntervalSince(live.asked) * 1000
        let request = track.reading?.detail.activeRequests.min { abs(($0.ageMilliseconds ?? .infinity) - age) < abs(($1.ageMilliseconds ?? .infinity) - age) }
        let tokens = request.map {
            ReplyMetrics.tokens(prompt: $0.promptTokens, completion: $0.generatedTokens, missing: tr("metrics.noStatus"))
        } ?? .unavailable(reason: tr("metrics.noRequest"))
        return ReplyMetrics(ttft: ttft, prefill: prefill, decode: decode, tokens: tokens, live: true, source: tr("metrics.source.live"))
    }

    private func context(_ conversation: NativeConversation?, server: ChatServer?) -> Measured<ContextUse> {
        guard let server else { return .unavailable(reason: tr("chat.context.noModel")) }
        let facts = try? facts[server.splashPort]?.get()
        guard let limit = facts?.maximumContextTokens ?? facts?.model.contextLength else {
            return .unavailable(reason: tr("chat.context.noLimit"))
        }
        guard let conversation, let used = Self.contextTokens(conversation) else {
            return .unavailable(reason: tr("context.beforeFirstReply"))
        }
        return .value(ContextUse(used: used, limit: limit))
    }

    func pageActions(_ model: NativeModel, loadModel: @escaping @MainActor @Sendable () -> Void,
                     showSettings: @escaping @MainActor @Sendable () -> Void) -> ChatPageActions {
        ChatPageActions(
            send: { [weak self] text in
                guard let self, case .success(let endpoint) = endpoint(in: model) else { return }
                session.send(text, to: endpoint, settings: settings)
            },
            stop: { [weak self] in self?.session.stop() },
            answerTool: { [weak self] id, result in
                guard let self, case .success(let endpoint) = endpoint(in: model),
                      let call = session.current?.messages.flatMap(\.toolCalls).last(where: { $0.id == id }) else { return }
                session.answer(call, with: result, to: endpoint, settings: settings)
            },
            loadModel: loadModel,
            choosePreset: { [weak self] name in self?.choosePreset(name) },
            showSettings: showSettings)
    }

    private func retryAction(_ model: NativeModel) -> NativeAction {
        NativeAction(title: tr("chat.retry"), systemImage: "arrow.clockwise") { [weak self] in
            guard let self, case .success(let endpoint) = endpoint(in: model) else { return }
            session.retry(with: endpoint, settings: settings)
        }
    }

    private func deleteAction(_ message: NativeChatMessage) -> NativeAction {
        let consequence = message.toolCalls.isEmpty ? nil : tr("chat.message.delete.consequence")
        return NativeAction(title: tr("chat.message.delete"), systemImage: "trash",
                          role: .destructive(question: tr("chat.message.delete.question"), consequence: consequence,
                                             confirmTitle: tr("chat.delete"))) { [weak self] in
            self?.session.deleteMessage(message.id)
        }
    }

    private static func title(of server: ChatServer) -> String {
        switch server.origin {
        case .owned(let configuration): configuration
        case .outside(let app): app ? tr("chat.server.splashApp") : tr("chat.server.outside")
        }
    }

    static func bubble(_ message: NativeChatMessage, live: ChatSession.Live?, answered: Set<String>, actions: [NativeAction],
                       delete: NativeAction? = nil) -> ChatBubble {
        let role: ChatBubble.Role = switch message.role {
        case .user: .user
        case .assistant: .assistant
        case .tool: .tool
        }
        var line: ChatReplyLine?
        if message.role == .assistant {
            if let live, message.text.isEmpty, message.toolCalls.isEmpty {
                line = message.reasoning.isEmpty ? .reading(read: live.read, since: live.asked) : .thinking(since: live.thinkingSince ?? live.asked)
            } else if !message.reasoning.isEmpty {
                line = .thought(tokens: message.stats?.reasoningTokens, seconds: message.thinkingTime)
            }
        }
        let calls = message.toolCalls.map { call in
            ChatToolCallItem(id: call.id, name: call.name, arguments: Self.pretty(call.arguments), callID: call.callID,
                             answered: answered.contains(call.id))
        }
        let stats = live == nil ? message.stats : nil
        return ChatBubble(id: message.id, role: role, text: message.text, reasoning: message.reasoning, toolCalls: calls,
                          toolName: message.toolName, error: message.error, stopped: message.stopped, live: live != nil, line: line,
                          model: message.model, numbers: stats.map(Self.numbers),
                          fieldsSent: message.fields.flatMap { $0.isEmpty ? nil : Self.describe($0) }, actions: actions, delete: delete)
    }

    static func pretty(_ arguments: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return arguments }
        return String(decoding: data, as: UTF8.self)
    }

    static func numbers(_ stats: ReplyStats) -> ChatReplyNumbers {
        ChatReplyNumbers(ttftMs: stats.ttftMs, clientTTFTMs: stats.clientTTFTMs, decodeTokensPerSecond: stats.decodeTokensPerSecond,
                         prefillTokensPerSecond: stats.prefillTokensPerSecond, promptTokens: stats.promptTokens,
                         cachedTokens: stats.cachedTokens, stateSource: stats.stateSource, completionTokens: stats.completionTokens,
                         reasoningTokens: stats.reasoningTokens, draftedTokens: stats.draftedTokens,
                         acceptedDraftTokens: stats.acceptedDraftTokens, finishReason: stats.finishReason)
    }

    static func describe(_ fields: ChatFields) -> String {
        ChatField.allCases.compactMap { field -> String? in
            guard let value = fields[field] else { return nil }
            let text = switch value {
            case .number(let x): NativeFormat.number(x, fractionDigits: 2)
            case .integer(let x): String(x)
            case .text(let x): x
            case .texts(let x): x.map { $0.debugDescription }.joined(separator: ", ")
            }
            return "\(field.rawValue) \(text)"
        }.joined(separator: " · ")
    }

    func inspector(_ model: NativeModel) -> SectionState<ChatSettingsState> {
        guard let server = server(in: model) else { return .unavailable(reason: tr("chat.blocked.noServer")) }
        let facts = try? facts[server.splashPort]?.get()
        let version = server.version ?? "?"
        let values = Dictionary(uniqueKeysWithValues: ChatField.allCases.compactMap { field -> (String, NativeUI.ParameterValue)? in
            guard let value = settings.fields[field] else { return nil }
            return switch value {
            case .number(let x): (field.rawValue, .number(x))
            case .integer(let x): (field.rawValue, .integer(x))
            case .text(let x): (field.rawValue, .choice(x))
            case .texts(let x): (field.rawValue, .list(x))
            }
        })
        var unoffered: [ChatUnofferedChoice] = []
        if let facts, facts.model.thinks == true, !facts.model.efforts.isEmpty, !facts.model.efforts.contains("none") {
            unoffered.append(ChatUnofferedChoice(token: "none", reason: facts.promptSwitchesReasoning == false
                ? tr("chat.effort.none.noSwitch") : tr("chat.effort.none.notListed")))
        }
        let input = ChatFieldForm.Input(
            version: version, sources: Dictionary(uniqueKeysWithValues: ChatField.allCases.map { ($0.rawValue, $0.source) }),
            efforts: facts?.model.efforts, defaultEffort: facts?.model.defaultEffort, serverEffort: facts?.serverEffort,
            thinkingBudgetHasNoEffect: facts?.thinkingBudgetHasNoEffect == true, contextLength: facts?.model.contextLength,
            defaults: Self.defaults(defaults[server.splashPort], version: version), values: values,
            problems: Set(settings.fields.problems.map(\.rawValue)), unofferedEfforts: unoffered)
        return .available(ChatSettingsState(
            system: settings.system ?? "", presets: savedPresets.map(\.name), preset: settings.preset,
            sampling: ChatFieldForm.sampling(input), reasoning: ChatFieldForm.reasoning(input), tools: settings.tools ?? "",
            toolNames: Self.toolNames(settings.tools), toolsProblem: Self.toolsAreValid(settings.tools) ? nil : tr("chat.blocked.tools")))
    }

    static func defaults(_ defaults: ChatSamplingDefaults?, version: String) -> [String: ChatFieldForm.Default] {
        guard let defaults else { return [:] }
        return defaults.entries.mapValues { entry in
            let source = switch entry.source {
            case .family(let name): tr("chat.default.family", name)
            case .flag: tr("chat.default.flag")
            case .splash: tr("chat.default.splash", version)
            }
            return ChatFieldForm.Default(value: entry.value, source: source)
        }
    }

    private func choosePreset(_ name: String?) {
        if let name, let preset = savedPresets.first(where: { $0.name == name }) {
            settings = ChatSettings(fields: preset.fields, system: preset.system, tools: preset.tools, preset: name)
        } else {
            settings = ChatSettings()
        }
    }

    func inspectorActions() -> ChatInspectorActions {
        ChatInspectorActions(
            setValue: { [weak self] flag, value in
                guard let self, let field = ChatField(rawValue: flag) else { return }
                settings.fields[field] = switch value {
                case .number(let x): .number(x)
                case .integer(let x): .integer(x)
                case .choice(let x), .word(let x), .text(let x): .text(x)
                case .list(let x): .texts(x)
                default: nil
                }
            },
            setSystem: { [weak self] text in self?.settings.system = text.isEmpty ? nil : text },
            setTools: { [weak self] text in self?.settings.tools = text.isEmpty ? nil : text },
            choosePreset: { [weak self] name in self?.choosePreset(name) },
            savePreset: { [weak self] name in
                guard let self, !name.isEmpty else { return }
                let preset = ChatPreset(name: name, fields: settings.fields, system: settings.system, tools: settings.tools)
                try? presets.save(preset)
                savedPresets = presets.load()
                settings.preset = name
            },
            deletePreset: { [weak self] name in
                guard let self else { return }
                try? presets.remove(name)
                savedPresets = presets.load()
                if settings.preset == name { settings.preset = nil }
            })
    }
}

struct ChatSectionView: View {
    let model: NativeModel
    let chat: ChatController
    let loads: LoadController
    let navigation: NativeNavigation

    var body: some View {
        ChatPage(chat.page(model), actions: chat.pageActions(model, loadModel: { loads.showsPicker = true },
                                                            showSettings: { navigation.showsPanel = true }))
            .task {
                while !Task.isCancelled {
                    await chat.refresh(model)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
    }
}
