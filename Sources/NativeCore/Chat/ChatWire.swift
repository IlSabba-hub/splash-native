import Foundation

public enum ChatFailure: Error, LocalizedError, Sendable, Equatable {
    case refused(status: Int, code: String?, message: String?)
    case server(String)
    case closedEarly
    case unreachable(String)
    case toolsNotAnArray
    case invalidFields([ChatField])

    public var errorDescription: String? { NativeText.chatFailure(self) }
}

public enum ChatWire {
    public static func tools(_ text: String?) throws -> [Any]? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let array = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              array.allSatisfy({ $0 is [String: Any] }) else { throw ChatFailure.toolsNotAnArray }
        return array
    }

    static func messages(_ history: [NativeChatMessage], system: String?) -> [[String: Any]] {
        var wire: [[String: Any]] = []
        if let system, !system.isEmpty { wire.append(["role": "system", "content": system]) }
        for message in history {
            switch message.role {
            case .user:
                wire.append(["role": "user", "content": message.text])
            case .tool:
                wire.append(["role": "tool", "tool_call_id": message.toolCallID ?? "", "content": message.text])
            case .assistant where message.isEmpty:
                continue
            case .assistant:
                var entry: [String: Any] = ["role": "assistant", "content": message.text, "reasoning_content": message.reasoning]
                if !message.toolCalls.isEmpty {
                    entry["tool_calls"] = message.toolCalls.map { call -> [String: Any] in
                        ["id": call.callID ?? String(call.index), "type": "function",
                         "function": ["name": call.name, "arguments": call.arguments]]
                    }
                }
                wire.append(entry)
            }
        }
        return wire
    }

    public static func body(_ history: [NativeChatMessage], system: String?, tools: String?, fields: ChatFields) throws -> Data {
        let problems = fields.problems
        guard problems.isEmpty else { throw ChatFailure.invalidFields(problems) }
        var body = fields.wire
        body["messages"] = messages(history, system: system)
        if let tools = try Self.tools(tools) { body["tools"] = tools }
        body["stream"] = true
        body["stream_options"] = ["include_usage": true]
        body["return_progress"] = true
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func request(_ body: Data, port: Int, path: String = "v1/chat/completions", apiKey: String?, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        request.timeoutInterval = timeout
        return request
    }

    public static func stream(_ body: Data, port: Int, apiKey: String?, session: URLSession = .shared) async throws
        -> AsyncThrowingStream<ChatChunk, Error> {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request(body, port: port, apiKey: apiKey, timeout: 3600))
        } catch let error as URLError {
            throw ChatFailure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw refusal(status: status, body: data)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        switch try ChatChunk.parse(line) {
                        case .chunk(let chunk)?: continuation.yield(chunk)
                        case .done?: return continuation.finish()
                        case nil: continue
                        }
                    }
                    throw ChatFailure.closedEarly
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func refusal(status: Int, body: Data) -> ChatFailure {
        struct Body: Decodable { struct Problem: Decodable { let message: String?; let code: String? }; let error: Problem }
        let problem = try? JSONDecoder().decode(Body.self, from: body).error
        return .refused(status: status, code: problem?.code, message: problem?.message)
    }
}

public struct ChatChunk: Sendable, Equatable {
    public var text = ""
    public var reasoning = ""
    public var read: Double?
    public var tools: [ChatToolCall] = []
    public var finishReason: String?
    public var stats = ReplyStats()

    public var visible: Bool { !text.isEmpty || !reasoning.isEmpty || !tools.isEmpty }

    enum Event: Equatable {
        case chunk(ChatChunk)
        case done
    }

    static func parse(_ line: String) throws -> Event? {
        let delta: ChatClient.Delta
        do {
            switch try ChatClient.parse(line) {
            case nil: return nil
            case .done?: return .done
            case .delta(let value)?: delta = value
            }
        } catch let failure as ChatClient.Failure {
            throw ChatFailure.server(failure.errorDescription ?? "")
        }
        var chunk = ChatChunk(text: delta.text, reasoning: delta.reasoning, read: delta.read)
        chunk.stats.reasoningTokens = delta.reasoningTokens
        chunk.stats.decodeTokensPerSecond = delta.tokensPerSecond
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let extra = try? JSONDecoder().decode(Extra.self, from: Data(payload.utf8)) else { return .chunk(chunk) }
        let choice = extra.choices?.first
        chunk.finishReason = choice?.finish_reason
        chunk.tools = (choice?.delta?.tool_calls ?? []).enumerated().map { offset, tool in
            ChatToolCall(index: tool.index ?? offset, callID: tool.id, name: tool.function?.name ?? "",
                         arguments: tool.function?.arguments.flatMap(Self.argumentText) ?? "")
        }
        if let usage = extra.usage {
            chunk.stats.promptTokens = usage.prompt_tokens
            chunk.stats.completionTokens = usage.completion_tokens
            chunk.stats.cachedTokens = usage.prompt_tokens_details?.cached_tokens
            chunk.stats.stateSource = usage.prompt_tokens_details?.state_source
        }
        if let timings = extra.timings {
            chunk.stats.prefillTokensPerSecond = timings.prompt_per_second
            chunk.stats.draftedTokens = timings.draft_n
            chunk.stats.acceptedDraftTokens = timings.draft_n_accepted
            chunk.stats.decodeTokensPerSecond = chunk.stats.decodeTokensPerSecond ?? timings.predicted_per_second
        }
        chunk.stats.ttftMs = extra.metrics?.request_latency?.ttft_ms
        return .chunk(chunk)
    }

    static func argumentText(_ value: JSONValue) -> String? {
        if case .string(let text) = value { return text }
        if case .null = value { return nil }
        return (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private struct Extra: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let tool_calls: [Tool]? }
            let delta: Delta?
            let finish_reason: String?
        }
        struct Tool: Decodable {
            struct Function: Decodable { let name: String?; let arguments: JSONValue? }
            let index: Int?
            let id: String?
            let function: Function?
        }
        struct Usage: Decodable {
            struct Prompt: Decodable { let cached_tokens: Int?; let state_source: String? }
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let prompt_tokens_details: Prompt?
        }
        struct Timings: Decodable {
            let prompt_per_second: Double?
            let predicted_per_second: Double?
            let draft_n: Int?
            let draft_n_accepted: Int?
        }
        struct Metrics: Decodable {
            struct Latency: Decodable { let ttft_ms: Double? }
            let request_latency: Latency?
        }
        let choices: [Choice]?
        let usage: Usage?
        let timings: Timings?
        let metrics: Metrics?
    }
}

extension [ChatToolCall] {
    mutating func merge(_ deltas: [ChatToolCall]) {
        for delta in deltas {
            if let index = firstIndex(where: { $0.index == delta.index }) {
                if let id = delta.callID { self[index].callID = id }
                self[index].name += delta.name
                self[index].arguments += delta.arguments
            } else {
                append(delta)
            }
        }
    }
}

extension ReplyStats {
    mutating func merge(_ other: ReplyStats) {
        promptTokens = other.promptTokens ?? promptTokens
        completionTokens = other.completionTokens ?? completionTokens
        cachedTokens = other.cachedTokens ?? cachedTokens
        stateSource = other.stateSource ?? stateSource
        reasoningTokens = other.reasoningTokens ?? reasoningTokens
        ttftMs = other.ttftMs ?? ttftMs
        decodeTokensPerSecond = other.decodeTokensPerSecond ?? decodeTokensPerSecond
        prefillTokensPerSecond = other.prefillTokensPerSecond ?? prefillTokensPerSecond
        draftedTokens = other.draftedTokens ?? draftedTokens
        acceptedDraftTokens = other.acceptedDraftTokens ?? acceptedDraftTokens
        finishReason = other.finishReason ?? finishReason
    }
}

public struct ChatModelInfo: Sendable, Equatable {
    public let id: String
    public let contextLength: Int?
    public let vision: Bool?
    public let thinks: Bool?
    public let efforts: [String]
    public let defaultEffort: String?

    public static func decode(_ data: Data) throws -> ChatModelInfo {
        struct List: Decodable {
            struct Model: Decodable {
                struct Reasoning: Decodable { let thinks: Bool?; let efforts: [String]?; let `default`: String? }
                let id: String
                let context_length: Int?
                let vision: Bool?
                let reasoning: Reasoning?
            }
            let data: [Model]
        }
        guard let model = try JSONDecoder().decode(List.self, from: data).data.first else {
            throw NativeError.httpStatus(path: "/v1/models", status: 200)
        }
        return ChatModelInfo(id: model.id, contextLength: model.context_length, vision: model.vision, thinks: model.reasoning?.thinks,
                             efforts: model.reasoning?.efforts ?? [], defaultEffort: model.reasoning?.default)
    }

    public static func read(port: Int, apiKey: String? = nil, session: URLSession = .shared) async throws -> ChatModelInfo {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        request.timeoutInterval = 3
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw NativeError.httpStatus(path: "/v1/models", status: status) }
        return try decode(data)
    }
}
