import Foundation

public struct ChatToolCall: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var index: Int
    public var callID: String?
    public var name: String
    public var arguments: String

    public var id: String { callID ?? String(index) }

    public init(index: Int, callID: String? = nil, name: String = "", arguments: String = "") {
        self.index = index
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }

    enum CodingKeys: String, CodingKey { case index, callID = "id", name, arguments }
}

public struct ReplyStats: Codable, Sendable, Equatable, Hashable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var cachedTokens: Int?
    public var stateSource: String?
    public var reasoningTokens: Int?
    public var ttftMs: Double?
    public var decodeTokensPerSecond: Double?
    public var prefillTokensPerSecond: Double?
    public var draftedTokens: Int?
    public var acceptedDraftTokens: Int?
    public var finishReason: String?
    public var clientTTFTMs: Double?

    public init() {}

    public var isEmpty: Bool { self == ReplyStats() }
}

public struct NativeChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable, Equatable { case user, assistant, tool }

    var base: ChatMessage
    public var toolCalls: [ChatToolCall]
    public var toolCallID: String?
    public var toolName: String?
    public var stats: ReplyStats?
    public var fields: ChatFields?

    init(base: ChatMessage, toolCalls: [ChatToolCall] = [], toolCallID: String? = nil, toolName: String? = nil,
         stats: ReplyStats? = nil, fields: ChatFields? = nil) {
        self.base = base
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.stats = stats
        self.fields = fields
    }

    public static func user(_ text: String) -> NativeChatMessage {
        NativeChatMessage(base: ChatMessage(role: .user, text: text))
    }

    public static func toolResult(_ text: String, for call: ChatToolCall) -> NativeChatMessage {
        NativeChatMessage(base: ChatMessage(role: .user, text: text), toolCallID: call.callID ?? String(call.index), toolName: call.name)
    }

    static func assistant(model: String?) -> NativeChatMessage {
        NativeChatMessage(base: ChatMessage(role: .assistant, text: "", model: model))
    }

    public var id: UUID { base.id }
    public var role: Role { toolCallID != nil ? .tool : base.role == .user ? .user : .assistant }
    public var text: String {
        get { base.text }
        set { base.text = newValue }
    }
    public var reasoning: String {
        get { base.reasoning }
        set { base.reasoning = newValue }
    }
    public var model: String? { base.model }
    public var error: String? {
        get { base.error }
        set { base.error = newValue }
    }
    public var stopped: Bool { base.stopped == true }
    public var thinkingTime: Double? { base.thinkingTime }
    public var isEmpty: Bool { base.isEmpty && toolCalls.isEmpty }
}

extension NativeChatMessage: Codable {
    private enum ExtraKeys: String, CodingKey {
        case toolCalls = "tool_calls", toolCallID = "tool_call_id", toolName = "tool_name", stats, fields
    }

    public init(from decoder: Decoder) throws {
        base = try ChatMessage(from: decoder)
        let extra = try decoder.container(keyedBy: ExtraKeys.self)
        toolCalls = try extra.decodeIfPresent([ChatToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try extra.decodeIfPresent(String.self, forKey: .toolCallID)
        toolName = try extra.decodeIfPresent(String.self, forKey: .toolName)
        stats = try extra.decodeIfPresent(ReplyStats.self, forKey: .stats)
        fields = try extra.decodeIfPresent(ChatFields.self, forKey: .fields)
    }

    public func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
        var extra = encoder.container(keyedBy: ExtraKeys.self)
        if !toolCalls.isEmpty { try extra.encode(toolCalls, forKey: .toolCalls) }
        try extra.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try extra.encodeIfPresent(toolName, forKey: .toolName)
        try extra.encodeIfPresent(stats, forKey: .stats)
        try extra.encodeIfPresent(fields, forKey: .fields)
    }
}

public struct NativeConversation: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title = ""
    public var updated = Date.now
    public var messages: [NativeChatMessage] = []
    public var pinned: Date?
    public var system: String?
    public var tools: String?
    public var preset: String?

    public init(id: UUID = UUID(), title: String = "", updated: Date = .now, messages: [NativeChatMessage] = [],
                system: String? = nil, tools: String? = nil, preset: String? = nil) {
        self.id = id
        self.title = title
        self.updated = updated
        self.messages = messages
        self.system = system
        self.tools = tools
        self.preset = preset
    }
}

public final class ChatArchive: Sendable {
    public let folder: URL
    private let queue = DispatchQueue(label: "SplashNative.ChatArchive", qos: .utility)

    public static let defaultFolder = URL.applicationSupportDirectory.appending(path: "SplashNative/Chats")

    public init(folder: URL = ChatArchive.defaultFolder) {
        self.folder = folder
    }

    public func load() -> [NativeConversation] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(NativeConversation.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    public func file(_ id: UUID) -> URL {
        folder.appending(path: "\(id.uuidString).json")
    }

    public func write(_ conversation: NativeConversation) {
        let (folder, file) = (folder, file(conversation.id))
        queue.async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(conversation).write(to: file, options: .atomic)
        }
    }

    public func remove(_ id: UUID) {
        let file = file(id)
        queue.async { try? FileManager.default.removeItem(at: file) }
    }

    public func flush() {
        queue.sync {}
    }
}
