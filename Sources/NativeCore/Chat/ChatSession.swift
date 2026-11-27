import Foundation
import Observation

public struct ChatEndpoint: Sendable, Equatable, Hashable {
    public let port: Int
    public let apiKey: String?
    public let model: String

    public init(port: Int, apiKey: String? = nil, model: String) {
        self.port = port
        self.apiKey = apiKey
        self.model = model
    }

    var target: ChatTarget {
        ChatTarget(url: URL(string: "http://127.0.0.1:\(port)")!, model: model, acceptsImages: false, effort: "", apiKey: apiKey)
    }
}

public struct ChatSettings: Sendable, Equatable, Hashable {
    public var fields: ChatFields
    public var system: String?
    public var tools: String?
    public var preset: String?

    public init(fields: ChatFields = ChatFields(), system: String? = nil, tools: String? = nil, preset: String? = nil) {
        self.fields = fields
        self.system = system
        self.tools = tools
        self.preset = preset
    }
}

@MainActor @Observable
public final class ChatSession {
    public struct Live: Equatable, Sendable {
        public let conversation: UUID
        public var message: NativeChatMessage
        public let asked: Date
        public var read: Double?
        public var thinkingSince: Date?
        public var firstVisible: Date?
    }

    public private(set) var conversations: [NativeConversation]
    public var selection: UUID?
    public private(set) var live: Live?

    @ObservationIgnored public let archive: ChatArchive
    @ObservationIgnored private var replying: Task<Void, Never>?
    @ObservationIgnored private var titling: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored var asksTitles = true

    public init(archive: ChatArchive = ChatArchive(), session: URLSession = .shared) {
        self.archive = archive
        self.session = session
        conversations = archive.load()
    }

    public var current: NativeConversation? { conversations.first { $0.id == selection } }

    public var answering: Bool { live != nil }

    public func newChat() {
        selection = nil
    }

    public func matching(_ query: String) -> [NativeConversation] {
        guard !query.isEmpty else { return conversations }
        return conversations.filter { conversation in
            conversation.title.localizedStandardContains(query) || conversation.messages.contains { $0.text.localizedStandardContains(query) }
        }
    }

    public func delete(_ id: UUID) {
        if live?.conversation == id { stop() }
        titling.removeValue(forKey: id)?.cancel()
        conversations.removeAll { $0.id == id }
        archive.remove(id)
        if selection == id { selection = nil }
    }

    public func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        titling.removeValue(forKey: id)?.cancel()
        conversations[index].title = title
        archive.write(conversations[index])
    }

    @discardableResult
    public func duplicate(_ id: UUID, title: String) -> UUID? {
        guard var copy = conversations.first(where: { $0.id == id }) else { return nil }
        if let live, live.conversation == id { copy.messages.removeAll { $0.id == live.message.id } }
        copy.id = UUID()
        copy.title = title
        copy.updated = .now
        copy.messages = copy.messages.map { message in
            var message = message
            message.base.id = UUID()
            return message
        }
        put(copy)
        selection = copy.id
        return copy.id
    }

    public func deleteMessage(_ id: UUID) {
        guard live == nil, var conversation = current, let message = conversation.messages.first(where: { $0.id == id }) else { return }
        let answers = Set(message.toolCalls.map(\.id))
        conversation.messages.removeAll { $0.id == id || ($0.toolCallID.map(answers.contains) ?? false) }
        conversation.updated = .now
        put(conversation)
    }

    public func send(_ text: String, to endpoint: ChatEndpoint, settings: ChatSettings) {
        guard live == nil else { return }
        var conversation = current ?? NativeConversation(system: settings.system, tools: settings.tools, preset: settings.preset)
        if conversation.title.isEmpty { conversation.title = ChatStore.firstLine(text) }
        conversation.messages.append(.user(text))
        ask(conversation, to: endpoint, settings: settings)
    }

    public func answer(_ call: ChatToolCall, with result: String, to endpoint: ChatEndpoint, settings: ChatSettings) {
        guard live == nil, var conversation = current else { return }
        conversation.messages.append(.toolResult(result, for: call))
        ask(conversation, to: endpoint, settings: settings)
    }

    public func retry(with endpoint: ChatEndpoint, settings: ChatSettings) {
        guard live == nil, var conversation = current, conversation.messages.last?.role == .assistant else { return }
        conversation.messages.removeLast()
        ask(conversation, to: endpoint, settings: settings)
    }

    public func stop() {
        replying?.cancel()
    }

    private func ask(_ conversation: NativeConversation, to endpoint: ChatEndpoint, settings: ChatSettings) {
        var conversation = conversation
        conversation.system = settings.system
        conversation.tools = settings.tools
        conversation.updated = .now
        var answer = NativeChatMessage.assistant(model: endpoint.model)
        answer.fields = settings.fields
        let history = conversation.messages
        conversation.messages.append(answer)
        put(conversation)
        selection = conversation.id
        let body: Data
        do {
            body = try ChatWire.body(history, system: settings.system, tools: settings.tools, fields: settings.fields)
        } catch {
            answer.error = error.localizedDescription
            finish(answer, in: conversation.id)
            return
        }
        let asked = Date.now
        live = Live(conversation: conversation.id, message: answer, asked: asked)
        let id = conversation.id
        let first = history.count == 1 ? history[0] : nil
        let session = session
        replying = Task { [weak self] in
            var drawn = ContinuousClock.now
            var stats = ReplyStats()
            var thinkingSince: Date?
            var firstVisible: Date?
            var read: Double?
            do {
                let chunks = try await ChatWire.stream(body, port: endpoint.port, apiKey: endpoint.apiKey, session: session)
                for try await chunk in chunks {
                    if Task.isCancelled { break }
                    if chunk.visible, firstVisible == nil {
                        firstVisible = .now
                        stats.clientTTFTMs = Date.now.timeIntervalSince(asked) * 1000
                    }
                    if !chunk.reasoning.isEmpty, thinkingSince == nil { thinkingSince = .now }
                    if !chunk.text.isEmpty || !chunk.tools.isEmpty, answer.base.thinkingTime == nil, let since = thinkingSince {
                        answer.base.thinkingTime = Date.now.timeIntervalSince(since)
                    }
                    answer.base.reasoning += chunk.reasoning
                    answer.base.text += chunk.text
                    answer.toolCalls.merge(chunk.tools)
                    var update = chunk.stats
                    update.finishReason = chunk.finishReason
                    stats.merge(update)
                    read = chunk.read ?? read
                    if ContinuousClock.now - drawn > .milliseconds(50) {
                        drawn = .now
                        self?.live?.message = answer
                        self?.live?.read = read
                        self?.live?.thinkingSince = thinkingSince
                        self?.live?.firstVisible = firstVisible
                    }
                }
            } catch {
                if !Task.isCancelled { answer.base.error = error.localizedDescription }
            }
            if Task.isCancelled { answer.base.stopped = true }
            if let since = thinkingSince, answer.base.thinkingTime == nil { answer.base.thinkingTime = Date.now.timeIntervalSince(since) }
            if stats.finishReason == "length", answer.base.error == nil { answer.base.error = NativeText.chatCut }
            answer.base.reasoningTokens = stats.reasoningTokens
            answer.base.tokensPerSecond = stats.decodeTokensPerSecond
            answer.stats = stats.isEmpty ? nil : stats
            guard let self else { return }
            live = nil
            finish(answer, in: id)
            if let first, answer.error == nil, !answer.stopped, !answer.text.isEmpty, asksTitles {
                title(id, question: first, answer: answer.text, with: endpoint)
            }
        }
    }

    private func title(_ id: UUID, question: NativeChatMessage, answer: String, with endpoint: ChatEndpoint) {
        guard conversations.first(where: { $0.id == id })?.title == ChatStore.firstLine(question.text) else { return }
        titling[id]?.cancel()
        let session = session
        titling[id] = Task { [weak self] in
            let title = try? await ChatClient.title(question: question.text, answer: answer, with: endpoint.target, session: session)
            guard let self, !Task.isCancelled else { return }
            titling[id] = nil
            guard let title, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
            conversations[index].title = title
            archive.write(conversations[index])
        }
    }

    private func finish(_ message: NativeChatMessage, in conversation: UUID) {
        guard var updated = conversations.first(where: { $0.id == conversation }),
              let index = updated.messages.firstIndex(where: { $0.id == message.id }) else { return }
        updated.messages[index] = message
        updated.updated = .now
        put(updated)
    }

    private func put(_ conversation: NativeConversation) {
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
        archive.write(conversation)
    }
}
