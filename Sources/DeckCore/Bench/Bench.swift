import Foundation

public enum Bench {
    public static let prompt = "Spiega in circa 200 parole come funziona una cache KV in un modello transformer."
    public static let maxTokens = 256
    public static let warmupTokens = 8
    public static let runs = 3

    public static func noncePrompt(base: UInt64, sequence: UInt64) -> String {
        let n = 1000 + ((base % 9000) + sequence * 1111) % 9000
        return "#\(n) \(prompt)"
    }

    public struct Stream: Sendable, Equatable {
        public var first: Double?
        public var last: Double?
        public var chunks = 0
        public var completionTokens: Int?
        public var promptTokens: Int?
        public var cachedTokens: Int?
        public var characters = 0

        public init() {}

        public mutating func read(_ line: String, now: Double) -> Bool {
            guard line.hasPrefix("data:") else { return true }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { return false }
            guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return true }
            if let usage = object["usage"] as? [String: Any] {
                if let n = usage["completion_tokens"] as? Int { completionTokens = n }
                if let n = usage["prompt_tokens"] as? Int { promptTokens = n }
                if let n = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int { cachedTokens = n }
            }
            let delta = ((object["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any]
            let piece = ["content", "reasoning_content", "reasoning"].compactMap { delta?[$0] as? String }.joined()
            if !piece.isEmpty {
                if first == nil { first = now }
                last = now
                chunks += 1
                characters += piece.count
            }
            return true
        }
    }

    public struct Run: Codable, Sendable, Equatable {
        public let ttftMilliseconds: Double
        public let decodeTokensPerSecond: Double?
        public let completionTokens: Int
        public let tokensSource: String
        public let promptTokens: Int?
        public let cachedTokens: Int?
        public let totalSeconds: Double
        public let promptHead: String

        static func from(_ stream: Stream, total: Double, prompt: String) -> Run? {
            guard let first = stream.first else { return nil }
            let last = stream.last ?? first
            let tokens = stream.completionTokens ?? stream.chunks
            let decode = last - first
            return Run(ttftMilliseconds: (first * 1000).rounded(),
                       decodeTokensPerSecond: decode > 0 && tokens > 1 ? Double(tokens - 1) / decode : nil,
                       completionTokens: tokens, tokensSource: stream.completionTokens != nil ? "usage.completion_tokens" : "chunks",
                       promptTokens: stream.promptTokens, cachedTokens: stream.cachedTokens, totalSeconds: total,
                       promptHead: String(prompt.prefix(6)))
        }
    }

    public struct Result: Codable, Sendable, Equatable {
        public let at: Date
        public let label: String
        public let port: Int
        public let model: String
        public let splashVersion: String?
        public let arguments: [String]
        public let prompt: String
        public let maxTokens: Int
        public let warmupTTFTMilliseconds: Double
        public let runs: [Run]
        public let median: Run
        public let peakFootprintBytes: UInt64?
    }

    public enum Failure: Error, LocalizedError, Sendable, Equatable {
        case http(status: Int, body: String)
        case noTokens

        public var errorDescription: String? {
            switch self {
            case let .http(status, body): DeckError.httpStatus(path: "/v1/chat/completions \(body.prefix(160))", status: status).localizedDescription
            case .noTokens: DeckError.splash("no token received").localizedDescription
            }
        }
    }

    static func once(port: Int, model: String, prompt: String, maxTokens: Int, apiKey: String?,
                     session: URLSession) async throws -> Run {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": model, "messages": [["role": "user", "content": prompt]], "max_tokens": maxTokens,
            "temperature": 0, "stream": true, "stream_options": ["include_usage": true],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let start = ContinuousClock.now
        func seconds() -> Double {
            let elapsed = ContinuousClock.now - start
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line; if text.count > 400 { break } }
            throw Failure.http(status: status, body: text)
        }
        var stream = Stream()
        for try await line in bytes.lines {
            if !stream.read(line, now: seconds()) { break }
        }
        guard let run = Run.from(stream, total: seconds(), prompt: prompt) else { throw Failure.noTokens }
        return run
    }

    public static func masked(_ arguments: [String]) -> [String] {
        var masked = arguments
        for index in masked.indices {
            if masked[index] == "--api-key", index + 1 < masked.count { masked[index + 1] = "•••" }
            if masked[index].hasPrefix("--api-key=") { masked[index] = "--api-key=•••" }
        }
        return masked
    }

    public static func run(port: Int, model: String, pid: Int32?, label: String, splashVersion: String?, arguments: [String],
                           apiKey: String? = nil, session: URLSession = .shared) async throws -> Result {
        let base = UInt64(Date.now.timeIntervalSince1970 * 1_000_000_000)
        let peak = PeakSampler(pid: pid)
        let sampler = Task.detached { await peak.sample() }
        defer { sampler.cancel() }
        let warmup = try await once(port: port, model: model, prompt: noncePrompt(base: base, sequence: 0), maxTokens: warmupTokens,
                                    apiKey: apiKey, session: session)
        var measured: [Run] = []
        for sequence in 1 ... UInt64(runs) {
            measured.append(try await once(port: port, model: model, prompt: noncePrompt(base: base, sequence: sequence),
                                           maxTokens: maxTokens, apiKey: apiKey, session: session))
        }
        sampler.cancel()
        let sorted = measured.sorted { $0.ttftMilliseconds < $1.ttftMilliseconds }
        return Result(at: .now, label: label, port: port, model: model, splashVersion: splashVersion,
                      arguments: masked(arguments),
                      prompt: prompt, maxTokens: maxTokens, warmupTTFTMilliseconds: warmup.ttftMilliseconds, runs: measured,
                      median: sorted[sorted.count / 2], peakFootprintBytes: await peak.value)
    }
}

actor PeakSampler {
    let pid: Int32?
    private(set) var value: UInt64?

    init(pid: Int32?) {
        self.pid = pid
    }

    func sample() async {
        guard let pid else { return }
        while !Task.isCancelled {
            let tree = OtherProcesses.descendants(of: [pid])
            let usages = tree.compactMap { ProcessFacts.usage($0)?.footprint }
            if !usages.isEmpty { value = max(value ?? 0, usages.reduce(0, +)) }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

public struct BenchStore: Sendable {
    public let file: URL

    public static let defaultFile = URL.applicationSupportDirectory.appending(path: "SplashDeck/bench.jsonl")

    public init(file: URL = BenchStore.defaultFile) {
        self.file = file
    }

    public func append(_ result: Bench.Result) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(result)
        line.append(0x0A)
        try JSONLines.append(line, to: file)
    }

    public func entries() -> [Bench.Result] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Bench.Result.self, from: Data($0)) }
    }

    public func entries(for label: String) -> [Bench.Result] {
        entries().filter { $0.label == label }
    }
}
