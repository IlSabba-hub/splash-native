import Foundation
import Observation

struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    var role: Role
    var text: String
    var reasoning = ""
    var attachments: [Attachment]?
    var images: [Data] = []
    var model: String?
    var tokensPerSecond: Double?
    var thinkingTime: Double?
    var reasoningTokens: Int?
    var error: String?
    var stopped: Bool?

    var isEmpty: Bool { text.isEmpty && reasoning.isEmpty }
}

struct Attachment: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case image, pdf }

    var id = UUID()
    var kind: Kind
    var type: String
    var bytes: Int
    var name: String?
    var pages: Int?

    var file: String {
        let suffix = switch type {
        case "image/png": "png"
        case "application/pdf": "pdf"
        default: "jpg"
        }
        return "\(id.uuidString).\(suffix)"
    }

    func write(_ data: Data, in folder: URL) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? data.write(to: folder.appending(path: file), options: .atomic)) != nil
    }

    static func image(_ data: Data) -> Attachment {
        Attachment(kind: .image, type: ChatClient.mediaType(data), bytes: data.count)
    }

    var details: String {
        [pages.map { $0 == 1 ? "1 page" : "\($0) pages" }, Format.size(Int64(bytes))].compactMap { $0 }.joined(separator: " · ")
    }
}

struct Conversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var updated = Date.now
    var messages: [ChatMessage] = []
    var pinned: Date?

    var attachmentFiles: [String] { messages.flatMap { ($0.attachments ?? []).map(\.file) } }
}

struct ChatTarget: Equatable, Sendable {
    let url: URL
    let model: String
    let acceptsImages: Bool
    let effort: String
    var context: Int?
    var apiKey: String?
}

@MainActor @Observable
final class ChatStore {
    struct Live: Equatable {
        let asked: Date
        var thinking: Date?
        var read: Double?
    }

    @MainActor @Observable
    final class Reply {
        let conversation: UUID
        fileprivate(set) var message: ChatMessage
        fileprivate(set) var live: Live

        fileprivate init(_ message: ChatMessage, in conversation: UUID) {
            self.conversation = conversation
            self.message = message
            live = Live(asked: .now)
        }
    }

    private struct Pending {
        enum Ask { case first, later, again }

        let conversation: Conversation
        let ask: Ask
        let shown: () -> Void
    }

    private(set) var conversations: [Conversation] = []
    var selection: UUID?
    private(set) var reply: Reply?
    private var pending: Pending?

    var streaming: UUID? { reply?.conversation }

    var answering: Bool {
        guard let reply else { return false }
        return pending?.ask == .first ? selection == nil : reply.conversation == selection
    }

    var sendingFirstMessage: Bool { pending?.ask == .first && selection == nil }

    private let folder: URL
    nonisolated let attachments: URL
    nonisolated let drafts: URL
    private var replying: Task<Void, Never>?
    @ObservationIgnored private var titling: [UUID: Task<Void, Never>] = [:]
    private let files = DispatchQueue(label: "ChatStore.files", qos: .utility)
    @ObservationIgnored private(set) var readAll = false

    init(folder: URL) {
        self.folder = folder
        attachments = folder.appending(path: "Attachments")
        drafts = folder.appending(path: "Drafts.plist")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let kept = files.filter { $0.pathExtension == "json" }
        let read = kept.compactMap { try? JSONDecoder().decode(Conversation.self, from: Data(contentsOf: $0)) }
        conversations = read.map(Self.interrupted).sorted { $0.updated > $1.updated }
        readAll = read.count == kept.count
    }

    func adoptFiles(keeping drafted: Set<String>) {
        for index in conversations.indices where conversations[index].messages.contains(where: { !$0.images.isEmpty }) {
            conversations[index] = Self.movingImages(of: conversations[index], to: attachments)
            write(conversations[index])
        }
        guard readAll else { return }
        let named = Set(conversations.flatMap(\.attachmentFiles)).union(drafted)
        let attachments = attachments
        files.async {
            let stray = ((try? FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil)) ?? [])
                .filter { !named.contains($0.lastPathComponent) }
            stray.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    nonisolated static func movingImages(of conversation: Conversation, to folder: URL) -> Conversation {
        var conversation = conversation
        for index in conversation.messages.indices {
            let images = conversation.messages[index].images
            guard !images.isEmpty else { continue }
            var attached = conversation.messages[index].attachments ?? []
            var kept: [Data] = []
            for image in images {
                let attachment = Attachment.image(image)
                if attachment.write(image, in: folder) {
                    attached.append(attachment)
                } else {
                    kept.append(image)
                }
            }
            conversation.messages[index].attachments = attached.isEmpty ? nil : attached
            conversation.messages[index].images = kept
        }
        return conversation
    }

    var current: Conversation? {
        guard var open = conversations.first(where: { $0.id == selection }) else { return nil }
        if let pending, pending.conversation.id == open.id { open.messages = pending.conversation.messages }
        return open
    }

    func matching(_ query: String) -> [Conversation] {
        guard !query.isEmpty else { return conversations }
        return conversations.filter { conversation in
            conversation.title.localizedStandardContains(query)
                || conversation.messages.contains { $0.text.localizedStandardContains(query) }
        }
    }

    func newChat() {
        selection = nil
    }

    func delete(_ ids: Set<UUID>) {
        if let streaming, ids.contains(streaming) { stop() }
        for id in ids { titling.removeValue(forKey: id)?.cancel() }
        let deleted = conversations.filter { ids.contains($0.id) }
        let removed = deleted.map { file($0.id) }
            + deleted.flatMap(\.attachmentFiles).map { attachments.appending(path: $0) }
        conversations.removeAll { ids.contains($0.id) }
        files.async { removed.forEach { try? FileManager.default.removeItem(at: $0) } }
        if let selection, ids.contains(selection) { self.selection = nil }
    }

    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        titling.removeValue(forKey: id)?.cancel()
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = title
        write(conversations[index])
    }

    func pin(_ id: UUID, _ pinned: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].pinned = pinned ? .now : nil
        write(conversations[index])
    }

    struct Refused: Equatable {
        let text: String
        let attachments: [Attachment]
        let reason: String?
        let conversation: UUID?
    }

    func send(_ text: String, attachments: [Attachment], to server: ChatTarget,
              refused: @escaping (Refused) -> Void = { _ in }, shown: @escaping () -> Void = {}) {
        guard streaming == nil else { return }
        let open = current
        var conversation = open ?? Conversation()
        if conversation.title.isEmpty { conversation.title = Self.firstLine(text, attachments: attachments) }
        conversation.messages.append(ChatMessage(role: .user, text: text, attachments: attachments.isEmpty ? nil : attachments))
        stream(conversation, new: open == nil, to: server, shown: shown) { reason in
            if let open {
                refused(Refused(text: text, attachments: attachments, reason: reason, conversation: open.id))
            } else if let reason {
                refused(Refused(text: "", attachments: [], reason: reason, conversation: nil))
            }
        }
    }

    static func firstLine(_ text: String, attachments: [Attachment] = []) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? attachments.lazy.compactMap(\.name).first ?? "Image"
        return String(line.prefix(80))
    }

    private func title(_ id: UUID, question: ChatMessage, answer: String, with server: ChatTarget) {
        guard conversations.first(where: { $0.id == id })?.title == Self.firstLine(question.text, attachments: question.attachments ?? [])
        else { return }
        titling[id]?.cancel()
        titling[id] = Task { [weak self] in
            let title = try? await ChatClient.title(question: question.text, answer: answer, with: server)
            guard let self, !Task.isCancelled else { return }
            titling[id] = nil
            guard let title, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
            conversations[index].title = title
            write(conversations[index])
        }
    }

    func retry(with server: ChatTarget, refused: @escaping (Refused) -> Void = { _ in }) {
        guard streaming == nil, var conversation = current, let previous = conversation.messages.last,
              previous.role == .assistant else { return }
        conversation.messages.removeLast()
        let id = conversation.id
        stream(conversation, new: false, to: server, instead: previous) { reason in
            if let reason { refused(Refused(text: "", attachments: [], reason: reason, conversation: id)) }
        }
    }

    func stop() {
        replying?.cancel()
    }

    func quit() {
        if pending?.ask == .later { keep() }
        stop()
    }

    private func stream(_ conversation: Conversation, new: Bool, to server: ChatTarget, instead previous: ChatMessage? = nil,
                        shown: @escaping () -> Void = {}, back: @escaping (String?) -> Void) {
        var conversation = conversation
        let history = conversation.messages
        var answer = ChatMessage(role: .assistant, text: "", model: server.model)
        conversation.messages.append(answer)
        pending = Pending(conversation: conversation, ask: new ? .first : previous == nil ? .later : .again, shown: shown)
        if !new { shown() }
        let reply = Reply(answer, in: conversation.id)
        self.reply = reply
        let files = attachments
        replying = Task { [weak self] in
            var drawn = ContinuousClock.now
            var thinking: Date?
            var read: Double?
            do {
                let deltas = try await ChatClient.reply(to: history, with: server, files: files)
                if previous == nil, !Task.isCancelled { self?.keep() }
                for try await delta in deltas {
                    if Task.isCancelled { break }
                    if !delta.reasoning.isEmpty, thinking == nil {
                        thinking = .now
                        reply.live.thinking = thinking
                    }
                    if !delta.text.isEmpty, answer.text.isEmpty, let thinking {
                        answer.thinkingTime = Date.now.timeIntervalSince(thinking)
                    }
                    answer.reasoning += delta.reasoning
                    answer.text += delta.text
                    answer.tokensPerSecond = delta.tokensPerSecond ?? answer.tokensPerSecond
                    answer.reasoningTokens = delta.reasoningTokens ?? answer.reasoningTokens
                    read = delta.read ?? read
                    if delta.cut { answer.error = "The reply reached the end of the model’s context." }
                    if !answer.isEmpty { self?.keep() }
                    if ContinuousClock.now - drawn > .milliseconds(50) {
                        drawn = .now
                        reply.live.read = read
                        reply.message = answer
                    }
                }
            } catch {
                if !Task.isCancelled { answer.error = error.localizedDescription }
            }
            if Task.isCancelled { answer.stopped = true }
            guard let self else { return }
            self.reply = nil
            if pending != nil {
                pending = nil
                let listed = conversations.contains { $0.id == conversation.id }
                guard new || listed else { return }
                if previous == nil || answer.error != nil { selection = listed ? conversation.id : nil }
                back(answer.error)
                return
            }
            if let thinking, answer.thinkingTime == nil { answer.thinkingTime = Date.now.timeIntervalSince(thinking) }
            finish(answer, in: conversation.id)
            if history.count == 1, answer.error == nil, answer.stopped == nil, !answer.text.isEmpty {
                title(conversation.id, question: history[0], answer: answer.text, with: server)
            }
        }
    }

    private func keep() {
        guard let pending else { return }
        self.pending = nil
        guard var conversation = pending.ask == .first ? pending.conversation
            : conversations.first(where: { $0.id == pending.conversation.id }) else { return }
        conversation.messages = pending.conversation.messages
        if conversation.title.isEmpty { conversation.title = pending.conversation.title }
        conversation.updated = .now
        put(conversation)
        guard pending.ask == .first else { return }
        if selection == nil { selection = conversation.id }
        pending.shown()
    }

    private func finish(_ message: ChatMessage, in conversation: UUID) {
        guard var updated = conversations.first(where: { $0.id == conversation }),
              let index = updated.messages.firstIndex(where: { $0.id == message.id })
        else { return }
        updated.messages[index] = message
        updated.updated = .now
        put(updated)
    }

    private func put(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
        write(conversation)
    }

    private func write(_ conversation: Conversation) {
        let (folder, file) = (folder, file(conversation.id))
        files.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(conversation).write(to: file, options: .atomic)
        }
    }

    func flush() {
        files.sync {}
    }

    private func file(_ id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).json")
    }

    private static func interrupted(_ conversation: Conversation) -> Conversation {
        var conversation = conversation
        for index in conversation.messages.indices where conversation.messages[index].role == .assistant
            && conversation.messages[index].isEmpty && conversation.messages[index].error == nil
            && conversation.messages[index].stopped != true {
            conversation.messages[index].error = "The reply was interrupted."
        }
        return conversation
    }
}

enum ChatClient {
    struct Delta: Equatable {
        var text = ""
        var reasoning = ""
        var tokensPerSecond: Double?
        var cut = false
        var read: Double?
        var reasoningTokens: Int?
    }

    enum Event: Equatable {
        case delta(Delta)
        case done
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func countTokens(_ messages: [ChatMessage], with server: ChatTarget, files: URL,
                            session: URLSession = .shared) async throws -> Int {
        let request = try countRequest(messages, with: server, files: files)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure(errorDescription: message(of: data, for: messages, server: server)
                ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        struct Count: Decodable { let input_tokens: Int }
        guard let count = try? JSONDecoder().decode(Count.self, from: data), count.input_tokens >= 0 else {
            throw Failure(errorDescription: "The model returned an invalid token count.")
        }
        return count.input_tokens
    }

    static func countRequest(_ messages: [ChatMessage], with server: ChatTarget, files: URL) throws -> URLRequest {
        let json = try JSONSerialization.data(withJSONObject: prompt(messages, effort: server.effort, vision: server.acceptsImages,
                                                                     files: files))
        return request("v1/chat/completions/count_tokens", json, to: server, timeout: 30)
    }

    private static func request(_ path: String, _ body: Data, to server: ChatTarget, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: server.url.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = server.apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        request.timeoutInterval = timeout
        return request
    }

    static func reply(to messages: [ChatMessage], with server: ChatTarget, files: URL) async throws -> AsyncThrowingStream<Delta, Error> {
        let json = try body(messages, effort: server.effort, vision: server.acceptsImages, files: files)
        let (bytes, response) = try await URLSession.shared.bytes(for: request("v1/chat/completions", json, to: server, timeout: 3600))
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw Failure(errorDescription: message(of: data, for: messages, server: server)
                ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        switch try parse(line) {
                        case .delta(let delta): continuation.yield(delta)
                        case .done: return continuation.finish()
                        case nil: continue
                        }
                    }
                    throw Failure(errorDescription: "The connection closed before the reply ended.")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func title(question: String, answer: String, with server: ChatTarget, session: URLSession = .shared) async throws -> String? {
        let ask = try titleBody(question: question, answer: answer)
        let (data, response) = try await session.data(for: request("v1/chat/completions", ask, to: server, timeout: 120))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let choice = (try? JSONDecoder().decode(Completion.self, from: data))?.choices.first,
              choice.finish_reason != "length" else { return nil }
        return choice.message.content.flatMap(title(in:))
    }

    static func titleBody(question: String, answer: String) throws -> Data {
        let ask = "Give the chat below a title of at most six words, in the chat's language. Reply with the title alone."
            + "\n\nUser: \(question.prefix(1000))\n\nAssistant: \(answer.prefix(1000))"
        return try JSONSerialization.data(withJSONObject: [
            "messages": [["role": "user", "content": ask]], "priority": "background", "reasoning_effort": "none",
            "thinking_token_budget": 0, "max_tokens": 32, "temperature": 0.2,
        ] as [String: Any])
    }

    static func title(in reply: String) -> String? {
        func tidy(_ text: some StringProtocol) -> String {
            String(text.drop { $0 == "#" }).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’「」*`").union(.whitespaces))
        }
        var line = tidy(reply.split(whereSeparator: \.isNewline).first { !tidy($0).isEmpty } ?? "")
        if line.lowercased().hasPrefix("title:") { line = tidy(line.dropFirst(6)) }
        while let last = line.last, ".。".contains(last) { line = tidy(line.dropLast()) }
        return line.isEmpty ? nil : String(line.prefix(80))
    }

    static func body(_ messages: [ChatMessage], effort: String, vision: Bool, files: URL) throws -> Data {
        var body = prompt(messages, effort: effort, vision: vision, files: files)
        body["stream"] = true
        body["stream_options"] = ["include_usage": true]
        body["return_progress"] = true
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func prompt(_ messages: [ChatMessage], effort: String, vision: Bool, files: URL) -> [String: Any] {
        let wire: [[String: Any]] = messages.compactMap { message in
            let attachments = message.attachments ?? []
            switch message.role {
            case .user where !attachments.isEmpty && vision:
                let parts: [[String: Any]] = attachments.compactMap { attachment in
                    guard let data = try? Data(contentsOf: files.appending(path: attachment.file)) else { return nil }
                    let url = "data:\(attachment.type);base64,\(data.base64EncodedString())"
                    return switch attachment.kind {
                    case .image: ["type": "image_url", "image_url": ["url": url]]
                    case .pdf: ["type": "file", "file": ["filename": attachment.name ?? "document.pdf", "file_data": url]]
                    }
                }
                return ["role": "user", "content": parts + [["type": "text", "text": message.text]]]
            case .user where !attachments.isEmpty:
                let note = unseen(attachments)
                return ["role": "user", "content": message.text.isEmpty ? note : "\(note)\n\n\(message.text)"]
            case .user:
                return ["role": "user", "content": message.text]
            case .assistant where message.isEmpty:
                return nil
            case .assistant:
                return ["role": "assistant", "content": message.text, "reasoning_content": message.reasoning]
            }
        }
        var body: [String: Any] = ["messages": wire]
        if !effort.isEmpty { body["reasoning_effort"] = effort }
        return body
    }

    static func parse(_ line: String) throws -> Event? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Content: Decodable { let content: String?; let reasoning_content: String? }
                let delta: Content?
                let finish_reason: String?
            }
            struct Metrics: Decodable {
                struct Latency: Decodable { let stream_tokens_per_second: Double? }
                let request_latency: Latency?
            }
            struct Progress: Decodable { let total: Int; let processed: Int }
            struct Usage: Decodable {
                struct Details: Decodable { let reasoning_tokens: Int? }
                let completion_tokens_details: Details?
            }
            struct Problem: Decodable { let message: String }
            let choices: [Choice]?
            let metrics: Metrics?
            let prompt_progress: Progress?
            let usage: Usage?
            let error: Problem?
        }
        let chunk = try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
        if let error = chunk.error { throw Failure(errorDescription: error.message) }
        let choice = chunk.choices?.first
        let progress = chunk.prompt_progress.flatMap { $0.total > 0 ? min(Double($0.processed) / Double($0.total), 1) : nil }
        return .delta(Delta(text: choice?.delta?.content ?? "", reasoning: choice?.delta?.reasoning_content ?? "",
                            tokensPerSecond: chunk.metrics?.request_latency?.stream_tokens_per_second,
                            cut: choice?.finish_reason == "length", read: progress,
                            reasoningTokens: chunk.usage?.completion_tokens_details?.reasoning_tokens))
    }

    static func message(of data: Data, for messages: [ChatMessage], server: ChatTarget) -> String? {
        struct Body: Decodable { struct Problem: Decodable { let message: String; let code: String? }; let error: Problem }
        guard let problem = try? JSONDecoder().decode(Body.self, from: data).error else { return nil }
        guard problem.code == "context_length_exceeded" else { return problem.message }
        let context = server.context.map { "the model’s \(ContextLength.figure($0))-token context" } ?? "the model’s context"
        return messages.count == 1 ? "This message is longer than \(context)."
            : "This chat is longer than \(context). Start a new chat to continue."
    }

    private static func unseen(_ attachments: [Attachment]) -> String {
        let images = attachments.count { $0.kind == .image }, pdfs = attachments.count { $0.kind == .pdf }
        let notes = [images == 1 ? "[An image this model can’t see]" : images > 1 ? "[\(images) images this model can’t see]" : nil,
                     pdfs == 1 ? "[A PDF this model can’t read]" : pdfs > 1 ? "[\(pdfs) PDFs this model can’t read]" : nil]
        return notes.compactMap { $0 }.joined(separator: " ")
    }

    static func mediaType(_ image: Data) -> String {
        image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }
}
