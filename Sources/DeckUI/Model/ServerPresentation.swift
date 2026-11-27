import Foundation

public struct ServerListItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case managed, foundOutside, configuration }

    public let id: String
    public let name: String
    public let port: Int
    public let status: StatusKind
    public let statusDetail: String?
    public let kind: Kind

    public init(id: String, name: String, port: Int, status: StatusKind, statusDetail: String? = nil, kind: Kind) {
        self.id = id
        self.name = name
        self.port = port
        self.status = status
        self.statusDetail = statusDetail
        self.kind = kind
    }
}

public enum ServerTab: String, Sendable, CaseIterable, Identifiable {
    case log, requests, bench

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .requests: tr("server.tab.requests")
        case .log: tr("server.tab.log")
        case .bench: tr("server.tab.bench")
        }
    }
}

public struct ServerEndpoints: Sendable, Equatable {
    public struct Route: Sendable, Equatable, Identifiable {
        public let method: String
        public let path: String
        public let pattern: String?
        public let open: Bool

        public var id: String { "\(method) \(path)" }

        public init(method: String, path: String, pattern: String? = nil, open: Bool = false) {
            self.method = method
            self.path = path
            self.pattern = pattern
            self.open = open
        }
    }

    public let routes: [Route]
    public let provenance: Provenance

    public init(routes: [Route], provenance: Provenance) {
        self.routes = routes
        self.provenance = provenance
    }
}

public struct ServerControl: Sendable {
    public let status: StatusKind
    public let statusDetail: String?
    public let foundOutside: Bool
    public let endpoint: String
    public let toggle: DeckAction?
    public let copy: DeckAction?
    public let settings: DeckAction?

    public let isOn: Bool
    public let name: String?

    public init(status: StatusKind, statusDetail: String? = nil, foundOutside: Bool = false, endpoint: String, toggle: DeckAction?,
                copy: DeckAction?, settings: DeckAction?, isOn: Bool? = nil, name: String? = nil) {
        self.isOn = isOn ?? (status != .stopped)
        self.name = name
        self.status = status
        self.statusDetail = statusDetail
        self.foundOutside = foundOutside
        self.endpoint = endpoint
        self.toggle = toggle
        self.copy = copy
        self.settings = settings
    }
}

public struct LogRequest: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case started, done }

    public var id: String { "\(index)" }
    public let index: Int
    public let kind: Kind
    public let clock: String
    public let request: Int
    public let input: Int?
    public let cached: Int?
    public let output: Int?
    public let ttftSeconds: Double?
    public let tokensPerSecond: Double?
    public let tokensPerCycle: Double?

    public init(index: Int, kind: Kind, clock: String, request: Int, input: Int?, cached: Int?, output: Int?, ttftSeconds: Double?,
                tokensPerSecond: Double?, tokensPerCycle: Double?) {
        self.index = index
        self.kind = kind
        self.clock = clock
        self.request = request
        self.input = input
        self.cached = cached
        self.output = output
        self.ttftSeconds = ttftSeconds
        self.tokensPerSecond = tokensPerSecond
        self.tokensPerCycle = tokensPerCycle
    }
}

public struct ServerLog: Sendable, Equatable {
    public let lines: [String]
    public let path: String

    public init(lines: [String], path: String) {
        self.lines = lines
        self.path = path
    }
}

public struct BenchRow: Sendable, Equatable, Identifiable {
    public var id: Date { at }
    public let at: Date
    public let ttftMilliseconds: Double
    public let decodeTokensPerSecond: Double?
    public let completionTokens: Int
    public let warmupTTFTMilliseconds: Double
    public let peakFootprintBytes: Int64?
    public let runs: Int

    public init(at: Date, ttftMilliseconds: Double, decodeTokensPerSecond: Double?, completionTokens: Int,
                warmupTTFTMilliseconds: Double, peakFootprintBytes: Int64?, runs: Int) {
        self.at = at
        self.ttftMilliseconds = ttftMilliseconds
        self.decodeTokensPerSecond = decodeTokensPerSecond
        self.completionTokens = completionTokens
        self.warmupTTFTMilliseconds = warmupTTFTMilliseconds
        self.peakFootprintBytes = peakFootprintBytes
        self.runs = runs
    }
}

public struct BenchSummary: Sendable, Equatable {
    public let results: [BenchRow]
    public let running: Bool
    public let failure: String?
    public let method: String

    public init(results: [BenchRow], running: Bool, failure: String?, method: String) {
        self.results = results
        self.running = running
        self.failure = failure
        self.method = method
    }
}

public struct ServerNotice: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case progress, success, warning, failure }

    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct FactSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let facts: [Fact]

    public init(id: String, title: String, facts: [Fact]) {
        self.id = id
        self.title = title
        self.facts = facts
    }
}

public struct ServerStreaming: Sendable, Equatable {
    public let summary: [Fact]
    public let sections: [FactSection]

    public init(summary: [Fact], sections: [FactSection]) {
        self.summary = summary
        self.sections = sections
    }
}

public struct ServerDetail: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let model: String
    public let port: Int
    public let status: StatusKind
    public let statusDetail: String?
    public let foundOutside: Bool
    public let readySince: Date?
    public let identity: [Fact]
    public let memory: MemoryReading?
    public let memorySeries: TimeSeries?
    public let decodeSeries: TimeSeries?
    public let traffic: [Fact]
    public let weights: [Fact]
    public let cache: [Fact]
    public let requests: SectionState<[ActiveRequestSummary]>
    public let history: SectionState<[LogRequest]>
    public let captured: CapturedTraffic?
    public let log: SectionState<ServerLog>
    public let bench: SectionState<BenchSummary>
    public let configuration: [Fact]
    public let configurationSource: String
    public let family: String?
    public let endpoints: ServerEndpoints?
    public let weightsReleased: Bool?
    public let lastRequest: ReplyMetrics?
    public let streaming: ServerStreaming?

    public init(id: String, name: String, model: String, port: Int, status: StatusKind, statusDetail: String?, foundOutside: Bool,
                readySince: Date?, identity: [Fact], memory: MemoryReading?, memorySeries: TimeSeries?, decodeSeries: TimeSeries?,
                traffic: [Fact], weights: [Fact], cache: [Fact], requests: SectionState<[ActiveRequestSummary]>,
                history: SectionState<[LogRequest]>, log: SectionState<ServerLog>, bench: SectionState<BenchSummary>,
                configuration: [Fact], configurationSource: String, captured: CapturedTraffic? = nil, family: String? = nil,
                endpoints: ServerEndpoints? = nil, weightsReleased: Bool? = nil, lastRequest: ReplyMetrics? = nil,
                streaming: ServerStreaming? = nil) {
        self.streaming = streaming
        self.id = id
        self.name = name
        self.model = model
        self.port = port
        self.status = status
        self.statusDetail = statusDetail
        self.foundOutside = foundOutside
        self.readySince = readySince
        self.identity = identity
        self.memory = memory
        self.memorySeries = memorySeries
        self.decodeSeries = decodeSeries
        self.traffic = traffic
        self.weights = weights
        self.cache = cache
        self.requests = requests
        self.history = history
        self.captured = captured
        self.log = log
        self.bench = bench
        self.configuration = configuration
        self.configurationSource = configurationSource
        self.family = family
        self.endpoints = endpoints
        self.weightsReleased = weightsReleased
        self.lastRequest = lastRequest
    }

    public static func == (a: ServerDetail, b: ServerDetail) -> Bool {
        a.id == b.id && a.status == b.status && a.statusDetail == b.statusDetail && a.identity == b.identity && a.memory == b.memory
            && a.memorySeries == b.memorySeries && a.decodeSeries == b.decodeSeries && a.traffic == b.traffic && a.weights == b.weights
            && a.cache == b.cache && a.configuration == b.configuration && a.captured == b.captured
            && a.family == b.family && a.endpoints == b.endpoints && a.weightsReleased == b.weightsReleased
            && a.streaming == b.streaming
    }
}
