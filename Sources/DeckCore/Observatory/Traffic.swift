import Foundation
import Synchronization

public struct ObservedExchange: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable, Equatable { case running, finished, failed }

    public struct Message: Sendable, Equatable {
        public let role: String
        public let characters: Int
        public let excerpt: String
        public let media: Int
        public let toolCalls: [String]
        public let toolCallID: String?
    }

    public let id: UInt64
    public let port: Int
    public let method: String
    public let path: String
    public let interpreted: Bool
    public let startedAt: Date
    public internal(set) var state: State = .running
    public internal(set) var authorization: String?
    public internal(set) var userAgent: String?
    public internal(set) var requestBytes: UInt64 = 0
    public internal(set) var messages: [Message] = []
    public internal(set) var tools: [String] = []
    public internal(set) var parameters: [String: String] = [:]
    public internal(set) var status: Int?
    public internal(set) var streaming: Bool?
    public internal(set) var reasoning = ""
    public internal(set) var content = ""
    public internal(set) var toolCalls: [ChatToolCall] = []
    public internal(set) var finishReason: String?
    public internal(set) var ttftMs: Double?
    public internal(set) var durationMs: Double?
    public internal(set) var chunks = 0
    public internal(set) var promptTokens: Int?
    public internal(set) var completionTokens: Int?
    public internal(set) var cachedTokens: Int?
    public internal(set) var tokensSource: String?
    public internal(set) var tokensPerSecond: Double?
    public internal(set) var engineTokensPerSecond: Double?
    public internal(set) var error: String?
    public internal(set) var truncated = false
    public internal(set) var raw: String?

    var t0: ContinuousClock.Instant
    var first: ContinuousClock.Instant?
    var last: ContinuousClock.Instant?

    public static func == (a: ObservedExchange, b: ObservedExchange) -> Bool {
        a.id == b.id && a.state == b.state && a.content == b.content && a.reasoning == b.reasoning && a.toolCalls == b.toolCalls
            && a.status == b.status && a.chunks == b.chunks && a.durationMs == b.durationMs && a.error == b.error
            && a.messages == b.messages && a.completionTokens == b.completionTokens
    }
}

public final class TrafficRecorder: Sendable {
    public static let defaultKeep = 50
    static let maxText = 1 << 20
    static let maxBody = 16 << 20
    static let rawLimit = 8 << 10
    static let excerpt = 240

    private struct State {
        var list: [ObservedExchange] = []
        var next: UInt64 = 1
        var revision: UInt64 = 0
    }

    private let state = Mutex(State())
    public let keep: Int

    public init(keep: Int = TrafficRecorder.defaultKeep) {
        self.keep = max(1, min(keep, 1000))
    }

    public func exchanges(port: Int? = nil) -> [ObservedExchange] {
        state.withLock { state in state.list.filter { port == nil || $0.port == port }.reversed() }
    }

    public var revision: UInt64 { state.withLock { $0.revision } }

    public func clear(port: Int? = nil) {
        state.withLock { state in
            state.list.removeAll { port == nil || $0.port == port }
            state.revision += 1
        }
    }

    private func update(_ id: UInt64, _ change: (inout ObservedExchange) -> Void) {
        state.withLock { state in
            guard let index = state.list.lastIndex(where: { $0.id == id }) else { return }
            change(&state.list[index])
            state.revision += 1
        }
    }

    func begin(port: Int, method: String, path: String, authorization: String?, userAgent: String?, at t0: ContinuousClock.Instant) -> UInt64 {
        state.withLock { state in
            let id = state.next
            state.next += 1
            let target = path.split(separator: "?").first.map(String.init) ?? path
            let interpreted = target.hasSuffix("/chat/completions") || target.hasSuffix("/completions")
            var exchange = ObservedExchange(id: id, port: port, method: method, path: path, interpreted: interpreted,
                                            startedAt: Date.now, t0: t0)
            exchange.authorization = authorization.map(HTTPTap.maskAuthorization)
            exchange.userAgent = userAgent
            state.list.append(exchange)
            while state.list.count > keep, let old = state.list.firstIndex(where: { $0.state != .running }) {
                state.list.remove(at: old)
            }
            state.revision += 1
            return id
        }
    }

    func request(_ id: UInt64, body: [UInt8]?, total: UInt64) {
        let summary = body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0)) }.map(Self.summarize)
        update(id) { exchange in
            exchange.requestBytes = total
            if body == nil, total > 0 { exchange.truncated = true }
            if let summary {
                exchange.messages = summary.messages
                exchange.tools = summary.tools
                exchange.parameters = summary.parameters
            }
        }
    }

    func responseHead(_ id: UInt64, status: Int, contentType: String?) {
        update(id) { exchange in
            exchange.status = status
            exchange.streaming = contentType?.contains("text/event-stream") == true
            if status >= 400 { exchange.error = "HTTP \(status)" }
        }
    }

    func interpreted(_ id: UInt64) -> Bool {
        state.withLock { $0.list.last { $0.id == id }?.interpreted ?? false }
    }

    func piece(_ id: UInt64, _ piece: HTTPTap.Piece, at now: ContinuousClock.Instant) {
        update(id) { exchange in
            exchange.chunks += 1
            if piece.visible {
                if exchange.first == nil {
                    exchange.first = now
                    if exchange.streaming == true { exchange.ttftMs = Self.milliseconds(now - exchange.t0) }
                }
                exchange.last = now
            }
            Self.append(&exchange.reasoning, piece.reasoning, &exchange.truncated)
            Self.append(&exchange.content, piece.content, &exchange.truncated)
            Self.merge(&exchange.toolCalls, piece.tools, &exchange.truncated)
            if let reason = piece.finishReason { exchange.finishReason = reason }
            if let tokens = piece.completionTokens, exchange.tokensSource != "usage" || piece.fromUsage {
                exchange.completionTokens = tokens
                exchange.tokensSource = piece.fromUsage ? "usage" : "timings"
            }
            if let tokens = piece.promptTokens { exchange.promptTokens = tokens }
            if let tokens = piece.cachedTokens { exchange.cachedTokens = tokens }
            if let speed = piece.engineTokensPerSecond { exchange.engineTokensPerSecond = speed }
            if let error = piece.error { exchange.error = error }
        }
    }

    func raw(_ id: UInt64, _ bytes: [UInt8]) {
        update(id) { exchange in
            var raw = exchange.raw ?? ""
            guard raw.utf8.count < Self.rawLimit else { return }
            raw += String(decoding: bytes.prefix(Self.rawLimit - raw.utf8.count), as: UTF8.self)
            exchange.raw = raw
        }
    }

    func finish(_ id: UInt64, error: String?, at now: ContinuousClock.Instant) {
        update(id) { exchange in
            exchange.durationMs = Self.milliseconds(now - exchange.t0)
            if let error, exchange.error == nil { exchange.error = error }
            exchange.state = exchange.error == nil ? .finished : .failed
            if let tokens = exchange.completionTokens, tokens > 1, let first = exchange.first, let last = exchange.last, last > first {
                exchange.tokensPerSecond = Double(tokens - 1) / (Self.milliseconds(last - first) / 1000)
            }
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func merge(_ calls: inout [ChatToolCall], _ deltas: [ChatToolCall], _ truncated: inout Bool) {
        for delta in deltas {
            let index: Int
            if let found = calls.firstIndex(where: { $0.index == delta.index }) {
                index = found
                if let id = delta.callID { calls[index].callID = id }
            } else {
                var fresh = delta
                fresh.name = ""
                fresh.arguments = ""
                calls.append(fresh)
                index = calls.count - 1
            }
            append(&calls[index].name, delta.name, &truncated)
            append(&calls[index].arguments, delta.arguments, &truncated)
        }
    }

    private static func append(_ text: inout String, _ add: String, _ truncated: inout Bool) {
        guard !add.isEmpty else { return }
        let room = maxText - text.utf8.count
        if add.utf8.count <= room { text += add; return }
        truncated = true
        var cut = ""
        for character in add {
            if cut.utf8.count + character.utf8.count > room { break }
            cut.append(character)
        }
        text += cut
    }

    static func summarize(_ body: JSONValue) -> (messages: [ObservedExchange.Message], tools: [String], parameters: [String: String]) {
        var messages: [ObservedExchange.Message] = []
        if case .array(let list)? = body["messages"] {
            for message in list {
                var text = ""
                var media = 0
                switch message["content"] {
                case .string(let value)?: text = value
                case .array(let parts)?:
                    for part in parts {
                        if ["text", "input_text"].contains(part["type"]?.string ?? "") {
                            if !text.isEmpty { text += "\n" }
                            text += part["text"]?.string ?? ""
                        } else {
                            media += 1
                        }
                    }
                default: break
                }
                var calls: [String] = []
                if case .array(let toolCalls)? = message["tool_calls"] { calls = toolCalls.compactMap { $0["function"]?["name"]?.string } }
                messages.append(.init(role: message["role"]?.string ?? "?", characters: text.count, excerpt: excerpt(text), media: media,
                                      toolCalls: calls, toolCallID: message["tool_call_id"]?.string))
            }
        } else if let prompt = body["prompt"] {
            let text = prompt.string ?? prompt.text ?? ""
            messages.append(.init(role: "prompt", characters: text.count, excerpt: excerpt(text), media: 0, toolCalls: [], toolCallID: nil))
        }
        var tools: [String] = []
        if case .array(let list)? = body["tools"] { tools = list.compactMap { $0["function"]?["name"]?.string } }
        var parameters: [String: String] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for key in ["model", "stream", "max_tokens", "max_completion_tokens", "temperature", "top_p", "top_k", "min_p", "seed",
                    "presence_penalty", "frequency_penalty", "repetition_penalty", "tool_choice", "reasoning_effort",
                    "thinking_token_budget", "stop", "stream_options", "response_format", "priority"] {
            if let value = body[key], let data = try? encoder.encode(value) { parameters[key] = String(decoding: data, as: UTF8.self) }
        }
        return (messages, tools, parameters)
    }

    static func excerpt(_ text: String) -> String {
        let one = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return one.count <= excerpt ? one : String(one.prefix(excerpt - 1)) + "…"
    }
}
