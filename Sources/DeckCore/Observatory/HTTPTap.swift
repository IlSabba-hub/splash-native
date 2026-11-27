import Foundation

enum HTTPTap {
    static let maxHead = 64 << 10

    struct Head: Equatable, Sendable {
        let start: [String]
        let headers: [(String, String)]

        static func == (a: Head, b: Head) -> Bool {
            a.start == b.start && a.headers.map(\.0) == b.headers.map(\.0) && a.headers.map(\.1) == b.headers.map(\.1)
        }

        func value(_ name: String) -> String? { headers.first { $0.0 == name }?.1 }
        var chunked: Bool { value("transfer-encoding")?.lowercased().contains("chunked") == true }
        var length: UInt64? { value("content-length").flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) } }
        var status: Int? { start.count > 1 ? Int(start[1]) : nil }

        static func parse(_ bytes: [UInt8]) -> Head? {
            var lines = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { line -> Substring in
                let trimmed = line.last == UInt8(ascii: "\r") ? line.dropLast() : line
                return Substring(String(decoding: trimmed, as: UTF8.self))
            }
            guard !lines.isEmpty, String(bytes: bytes, encoding: .utf8) != nil else { return nil }
            let first = lines.removeFirst()
            let start = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard start.count >= 2 else { return nil }
            let headers = lines.filter { !$0.isEmpty }.compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(),
                        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            return Head(start: start, headers: headers)
        }
    }

    enum Framing: Equatable {
        case none
        case length(UInt64)
        case chunked
        case untilClose
        case interim
        case stop
    }

    static func requestFraming(_ head: Head) -> Framing {
        if head.start[0].uppercased() == "CONNECT" || head.value("upgrade") != nil { return .stop }
        if head.chunked { return .chunked }
        guard let length = head.length, length > 0 else { return .none }
        return .length(length)
    }

    static func responseFraming(_ head: Head, method: String) -> Framing {
        guard let status = head.status, status != 101 else { return .stop }
        if (100...199).contains(status) { return .interim }
        if status == 204 || status == 304 || method.uppercased() == "HEAD" { return .none }
        if head.chunked { return .chunked }
        guard let length = head.length else { return .untilClose }
        return length == 0 ? .none : .length(length)
    }

    enum Event: Equatable {
        case head(Head)
        case body([UInt8])
        case end
    }

    struct Framer {
        private enum State: Equatable {
            case head, length(UInt64), chunkSize, chunkData(UInt64), chunkCRLF(seen: Bool), trailer, untilClose, stopped
        }
        private var state = State.head
        private var buffer: [UInt8] = []

        var stopped: Bool { state == .stopped }
        var inHead: Bool { state == .head && buffer.isEmpty }

        mutating func close(_ on: (Event) -> Void) -> Bool {
            let complete: Bool
            switch state {
            case .untilClose: on(.end); complete = true
            case .head: complete = buffer.isEmpty
            case .stopped: complete = true
            default: complete = false
            }
            state = .stopped
            buffer = []
            return complete
        }

        mutating func feed(_ input: [UInt8], decide: (Head) -> Framing, on: (Event) -> Void) {
            var data = input[...]
            while !data.isEmpty {
                switch state {
                case .stopped:
                    return
                case .head:
                    let from = max(0, buffer.count - 3)
                    buffer.append(contentsOf: data)
                    data = []
                    guard let end = Self.headEnd(buffer, from: from) else {
                        if buffer.count > HTTPTap.maxHead { state = .stopped; buffer = [] }
                        return
                    }
                    let rest = Array(buffer[end...])
                    let headBytes = Array(buffer[..<end])
                    buffer = []
                    guard let head = Head.parse(headBytes) else { state = .stopped; return }
                    let framing = decide(head)
                    on(.head(head))
                    switch framing {
                    case .none: on(.end); state = .head
                    case .interim: state = .head
                    case .length(let n): state = .length(n)
                    case .chunked: state = .chunkSize
                    case .untilClose: state = .untilClose
                    case .stop: state = .stopped
                    }
                    data = rest[...]
                case .length(let n):
                    let take = Int(min(n, UInt64(data.count)))
                    on(.body(Array(data.prefix(take))))
                    data = data.dropFirst(take)
                    let left = n - UInt64(take)
                    if left == 0 { on(.end); state = .head } else { state = .length(left) }
                case .untilClose:
                    on(.body(Array(data)))
                    return
                case .chunkSize, .trailer:
                    guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
                        buffer.append(contentsOf: data)
                        if buffer.count > HTTPTap.maxHead { state = .stopped }
                        return
                    }
                    buffer.append(contentsOf: data[..<newline])
                    data = data[(newline + 1)...]
                    var line = buffer
                    buffer = []
                    if line.last == UInt8(ascii: "\r") { line.removeLast() }
                    if state == .trailer {
                        if line.isEmpty { on(.end); state = .head }
                        continue
                    }
                    let hex = String(bytes: line, encoding: .ascii)?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
                    switch hex.flatMap({ UInt64($0, radix: 16) }) {
                    case 0?: state = .trailer
                    case let n?: state = .chunkData(n)
                    case nil: state = .stopped; return
                    }
                case .chunkData(let n):
                    let take = Int(min(n, UInt64(data.count)))
                    on(.body(Array(data.prefix(take))))
                    data = data.dropFirst(take)
                    let left = n - UInt64(take)
                    state = left == 0 ? .chunkCRLF(seen: false) : .chunkData(left)
                case .chunkCRLF(let seen):
                    let byte = data.first!
                    data = data.dropFirst()
                    if !seen, byte == UInt8(ascii: "\r") { state = .chunkCRLF(seen: true) }
                    else if byte == UInt8(ascii: "\n") { state = .chunkSize }
                    else { state = .stopped }
                }
            }
        }

        static func headEnd(_ buffer: [UInt8], from: Int) -> Int? {
            var index = from
            while index < buffer.count {
                if buffer[index] == UInt8(ascii: "\n") {
                    if index + 2 < buffer.count, buffer[index + 1] == UInt8(ascii: "\r"), buffer[index + 2] == UInt8(ascii: "\n") {
                        return index + 3
                    }
                    if index + 1 < buffer.count, buffer[index + 1] == UInt8(ascii: "\n") { return index + 2 }
                }
                index += 1
            }
            return nil
        }
    }

    struct SSEParser {
        private var line: [UInt8] = []
        private var data: String?
        private var lastCR = false

        mutating func feed(_ bytes: [UInt8], into out: inout [String]) {
            for byte in bytes {
                if lastCR, byte == UInt8(ascii: "\n") { lastCR = false; continue }
                lastCR = byte == UInt8(ascii: "\r")
                if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                    let done = line
                    line = []
                    lineDone(done, into: &out)
                } else if line.count < TrafficRecorder.maxBody {
                    line.append(byte)
                }
            }
        }

        mutating func finish(into out: inout [String]) {
            if !line.isEmpty {
                let done = line
                line = []
                lineDone(done, into: &out)
            }
            if let data { out.append(data) }
            data = nil
        }

        private mutating func lineDone(_ bytes: [UInt8], into out: inout [String]) {
            if bytes.isEmpty {
                if let data { out.append(data) }
                data = nil
                return
            }
            let text = String(decoding: bytes, as: UTF8.self)
            let field: Substring
            var value: Substring
            if let colon = text.firstIndex(of: ":") {
                field = text[..<colon]
                value = text[text.index(after: colon)...]
                if value.first == " " { value = value.dropFirst() }
            } else {
                field = text[...]
                value = ""
            }
            guard field == "data", (data?.utf8.count ?? 0) < TrafficRecorder.maxBody else { return }
            data = data.map { $0 + "\n" + value } ?? String(value)
        }
    }

    struct Piece: Equatable, Sendable {
        var reasoning = ""
        var content = ""
        var tools: [ChatToolCall] = []
        var finishReason: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedTokens: Int?
        var fromUsage = false
        var engineTokensPerSecond: Double?
        var error: String?

        var visible: Bool { !reasoning.isEmpty || !content.isEmpty || !tools.isEmpty }

        static func from(_ value: JSONValue) -> Piece {
            var piece = Piece()
            if let error = value["error"], error != .null {
                piece.error = error["message"]?.string ?? error.string ?? error.text ?? ""
            }
            if case .array(let choices)? = value["choices"], let choice = choices.first {
                if let message = choice["delta"] ?? choice["message"], case .object = message {
                    piece.content = message["content"]?.string ?? ""
                    let reasoning = message["reasoning_content"]?.string ?? ""
                    piece.reasoning = reasoning.isEmpty ? message["reasoning"]?.string ?? "" : reasoning
                    if case .array(let calls)? = message["tool_calls"] {
                        piece.tools = calls.enumerated().map { offset, call in
                            ChatToolCall(index: call["index"]?.int.map(Int.init) ?? offset, callID: call["id"]?.string,
                                         name: call["function"]?["name"]?.string ?? "",
                                         arguments: call["function"]?["arguments"].flatMap(ChatChunk.argumentText) ?? "")
                        }
                    }
                } else {
                    piece.content = choice["text"]?.string ?? ""
                }
                piece.finishReason = choice["finish_reason"]?.string
            }
            if let usage = value["usage"], case .object = usage {
                piece.promptTokens = usage["prompt_tokens"]?.int.map(Int.init)
                piece.completionTokens = usage["completion_tokens"]?.int.map(Int.init)
                piece.cachedTokens = usage["prompt_tokens_details"]?["cached_tokens"]?.int.map(Int.init)
                piece.fromUsage = piece.completionTokens != nil
            }
            if let timings = value["timings"], case .object = timings {
                piece.completionTokens = piece.completionTokens ?? timings["predicted_n"]?.int.map(Int.init)
                piece.promptTokens = piece.promptTokens ?? timings["prompt_n"]?.int.map(Int.init)
                piece.cachedTokens = piece.cachedTokens ?? timings["cache_n"]?.int.map(Int.init)
                if let speed = timings["predicted_per_second"]?.number, speed.isFinite, speed > 0 { piece.engineTokensPerSecond = speed }
            }
            return piece
        }
    }

    static func maskAuthorization(_ value: String) -> String {
        let parts = value.split(separator: " ", maxSplits: 1)
        if parts.count == 2 { return "\(parts[0]) •••• (\(parts[1].trimmingCharacters(in: .whitespaces).count))" }
        return "•••• (\(value.count))"
    }
}

extension JSONValue {
    var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}
