import Foundation

public struct CapturedMessage: Sendable, Equatable {
    public let role: String
    public let characters: Int
    public let excerpt: String
    public let media: Int
    public let toolCalls: [String]
    public let toolCallID: String?

    public init(role: String, characters: Int, excerpt: String, media: Int, toolCalls: [String], toolCallID: String?) {
        self.role = role
        self.characters = characters
        self.excerpt = excerpt
        self.media = media
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

public struct CapturedRequest: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable { case running, finished, failed }

    public let id: UInt64
    public let started: Date
    public let method: String
    public let path: String
    public let interpreted: Bool
    public let state: State
    public let status: Int?
    public let userAgent: String?
    public let authorization: String?
    public let requestBytes: UInt64
    public let messages: [CapturedMessage]
    public let tools: [String]
    public let parameters: [(name: String, value: String)]
    public let reasoning: String
    public let content: String
    public let toolCalls: [ChatToolCallItem]
    public let finishReason: String?
    public let ttftMs: Double?
    public let durationMs: Double?
    public let promptTokens: Int?
    public let cachedTokens: Int?
    public let completionTokens: Int?
    public let tokensSource: String?
    public let tokensPerSecond: Double?
    public let engineTokensPerSecond: Double?
    public let error: String?
    public let truncated: Bool
    public let raw: String?

    public init(id: UInt64, started: Date, method: String, path: String, interpreted: Bool, state: State, status: Int?, userAgent: String?,
                authorization: String?, requestBytes: UInt64, messages: [CapturedMessage], tools: [String],
                parameters: [(name: String, value: String)], reasoning: String, content: String, toolCalls: [ChatToolCallItem],
                finishReason: String?, ttftMs: Double?, durationMs: Double?, promptTokens: Int?, cachedTokens: Int?, completionTokens: Int?,
                tokensSource: String?, tokensPerSecond: Double?, engineTokensPerSecond: Double?, error: String?, truncated: Bool, raw: String?) {
        self.id = id
        self.started = started
        self.method = method
        self.path = path
        self.interpreted = interpreted
        self.state = state
        self.status = status
        self.userAgent = userAgent
        self.authorization = authorization
        self.requestBytes = requestBytes
        self.messages = messages
        self.tools = tools
        self.parameters = parameters
        self.reasoning = reasoning
        self.content = content
        self.toolCalls = toolCalls
        self.finishReason = finishReason
        self.ttftMs = ttftMs
        self.durationMs = durationMs
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.completionTokens = completionTokens
        self.tokensSource = tokensSource
        self.tokensPerSecond = tokensPerSecond
        self.engineTokensPerSecond = engineTokensPerSecond
        self.error = error
        self.truncated = truncated
        self.raw = raw
    }

    public static func == (a: CapturedRequest, b: CapturedRequest) -> Bool {
        a.id == b.id && a.state == b.state && a.status == b.status && a.content == b.content && a.reasoning == b.reasoning
            && a.toolCalls == b.toolCalls && a.durationMs == b.durationMs && a.completionTokens == b.completionTokens && a.error == b.error
            && a.messages == b.messages
    }
}

public enum ObservationState: Sendable, Equatable {
    case observed(listen: Int, splash: Int)
    case off(reason: String)
}

public struct CapturedTraffic: Sendable, Equatable {
    public let observation: ObservationState
    public let read: @MainActor @Sendable () -> [CapturedRequest]

    public init(observation: ObservationState, read: @escaping @MainActor @Sendable () -> [CapturedRequest]) {
        self.observation = observation
        self.read = read
    }

    public static func == (a: CapturedTraffic, b: CapturedTraffic) -> Bool { a.observation == b.observation }
}
