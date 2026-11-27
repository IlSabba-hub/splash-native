import Foundation

public enum Measured<Value: Sendable & Equatable>: Sendable, Equatable {
    case value(Value)
    case unavailable(reason: String)

    public var value: Value? {
        if case let .value(value) = self { value } else { nil }
    }

    public func map<Other: Sendable & Equatable>(_ transform: (Value) -> Other) -> Measured<Other> {
        switch self {
        case let .value(value): .value(transform(value))
        case let .unavailable(reason): .unavailable(reason: reason)
        }
    }
}

public struct Provenance: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case splashDefault(version: String)
        case configuration(name: String)
        case commandLine
        case status(field: String)
        case metrics(name: String)
        case system(name: String)
        case help(version: String, group: String?)
        case response(field: String)
        case requestField(version: String, source: String)
        case deck(what: String)
        case file(name: String)
        case deckDefault(what: String)
    }

    public var flag: String?
    public var source: Source
    public var line: Int?

    public init(flag: String? = nil, source: Source, line: Int? = nil) {
        self.flag = flag
        self.source = source
        self.line = line
    }

    public var sourceDescription: String {
        switch source {
        case let .splashDefault(version): tr("provenance.splashDefault", version)
        case let .configuration(name): tr("provenance.configuration", name)
        case .commandLine: tr("provenance.commandLine")
        case let .status(field): tr("provenance.status", field)
        case let .metrics(name): tr("provenance.metrics", name)
        case let .system(name): tr("provenance.system", name)
        case let .help(version, group?):
            line.map { tr("provenance.helpGroupLine", version, group, DeckFormat.count($0)) } ?? tr("provenance.helpGroup", version, group)
        case let .help(version, nil): line.map { tr("provenance.helpLine", version, DeckFormat.count($0)) } ?? tr("provenance.help", version)
        case let .response(field): tr("provenance.response", field)
        case let .requestField(version, source): tr("provenance.requestField", version, source)
        case let .deck(what): tr("provenance.deck", what)
        case let .file(name): tr("provenance.file", name)
        case let .deckDefault(what): tr("provenance.deckDefault", what)
        }
    }

    public var shortDescription: String {
        switch source {
        case let .help(version, _): line.map { tr("provenance.shortHelpLine", version, DeckFormat.count($0)) } ?? tr("provenance.shortHelp", version)
        default: sourceDescription
        }
    }
}

public enum StatusKind: String, Sendable, Equatable, CaseIterable {
    case stopped
    case starting
    case ready
    case error
    case foundOutside

    public var title: String {
        switch self {
        case .stopped: tr("status.stopped")
        case .starting: tr("status.starting")
        case .ready: tr("status.ready")
        case .error: tr("status.error")
        case .foundOutside: tr("status.foundOutside")
        }
    }

    public var symbol: String {
        switch self {
        case .stopped: "stop.circle"
        case .starting: "hourglass"
        case .ready: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .foundOutside: "arrow.down.right.circle"
        }
    }
}

public struct TimeSeries: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public let time: Date
        public let value: Double?

        public init(time: Date, value: Double?) {
            self.time = time
            self.value = value
        }
    }

    public struct Run: Sendable, Equatable {
        public let samples: [(time: Date, value: Double)]

        public static func == (a: Run, b: Run) -> Bool {
            a.samples.count == b.samples.count && zip(a.samples, b.samples).allSatisfy { $0.time == $1.time && $0.value == $1.value }
        }
    }

    public var samples: [Sample]
    public var maximumGap: TimeInterval
    public var window: ClosedRange<Date>?

    public init(samples: [Sample], maximumGap: TimeInterval, window: ClosedRange<Date>? = nil) {
        self.samples = samples.sorted { $0.time < $1.time }
        self.maximumGap = maximumGap
        self.window = window
    }

    public var runs: [Run] {
        var runs: [Run] = []
        var current: [(time: Date, value: Double)] = []
        var last: Date?
        for sample in samples {
            let tooFar = last.map { sample.time.timeIntervalSince($0) > maximumGap } ?? false
            if sample.value == nil || tooFar, !current.isEmpty {
                runs.append(Run(samples: current))
                current = []
            }
            if let value = sample.value { current.append((sample.time, value)) }
            last = sample.time
        }
        if !current.isEmpty { runs.append(Run(samples: current)) }
        return runs
    }

    public var gaps: Int { max(0, runs.count - 1) }

    public var values: [Double] { samples.compactMap(\.value) }

    public var latest: Double? { samples.last?.value }

    public var domain: ClosedRange<Date>? {
        if let window { return window }
        guard let first = samples.first?.time, let last = samples.last?.time else { return nil }
        return first ... last
    }
}

public struct MemoryBreakdown: Sendable, Equatable {
    public struct Instance: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let measured: Int64
        public let reservedUnused: Int64

        public init(id: String, name: String, measured: Int64, reservedUnused: Int64) {
            self.id = id
            self.name = name
            self.measured = measured
            self.reservedUnused = reservedUnused
        }
    }

    public let budget: Int64
    public let budgetTitle: String
    public let budgetProvenance: Provenance?
    public let instances: [Instance]
    public let others: Measured<Int64>
    public let showsOthers: Bool
    public let system: Int64?
    public let systemTitle: String?

    public init(budget: Int64, budgetTitle: String, budgetProvenance: Provenance? = nil, instances: [Instance], others: Measured<Int64>,
                showsOthers: Bool = true, system: Int64? = nil, systemTitle: String? = nil) {
        self.budget = budget
        self.budgetTitle = budgetTitle
        self.budgetProvenance = budgetProvenance
        self.instances = instances
        self.others = others
        self.showsOthers = showsOthers
        self.system = system
        self.systemTitle = systemTitle
    }

    public var measured: Int64 { instances.reduce(0) { $0 + $1.measured } }
    public var reservedUnused: Int64 { instances.reduce(0) { $0 + $1.reservedUnused } }
    public var committed: Int64 { (system ?? 0) + measured + reservedUnused + (showsOthers ? others.value ?? 0 : 0) }
    public var free: Int64 { max(0, budget - committed) }
    public var overcommitted: Int64 { max(0, committed - budget) }
}

public struct Fact: Sendable, Equatable, Identifiable {
    public var id: String { title }
    public let title: String
    public let value: Measured<String>
    public let provenance: Provenance?

    public init(title: String, value: Measured<String>, provenance: Provenance? = nil) {
        self.title = title
        self.value = value
        self.provenance = provenance
    }
}

public enum PrincipalBadge: Sendable, Equatable, Hashable {
    case usedByHermes
    case uncensored
    case vision

    public var title: String {
        switch self {
        case .usedByHermes: tr("badge.usedByHermes")
        case .uncensored: tr("badge.uncensored")
        case .vision: tr("badge.vision")
        }
    }
}

public struct MemoryReading: Sendable, Equatable {
    public let current: Measured<Int64>
    public let peak: Measured<Int64>
    public let cap: Measured<Int64>

    public init(current: Measured<Int64>, peak: Measured<Int64>, cap: Measured<Int64>) {
        self.current = current
        self.peak = peak
        self.cap = cap
    }
}

public struct PrincipalSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let model: String
    public let draft: String?
    public let port: Int?
    public let status: StatusKind
    public let statusDetail: String?
    public let foundOutside: Bool
    public let readySince: Date?
    public let badges: [PrincipalBadge]
    public let facts: [Fact]
    public let memory: MemoryReading?
    public let memorySeries: TimeSeries?
    public let decodeSeries: TimeSeries?
    public let lastBench: Measured<String>

    public init(id: String, name: String, model: String, draft: String? = nil, port: Int?, status: StatusKind, statusDetail: String? = nil,
                foundOutside: Bool = false, readySince: Date? = nil, badges: [PrincipalBadge] = [], facts: [Fact] = [],
                memory: MemoryReading? = nil, memorySeries: TimeSeries? = nil, decodeSeries: TimeSeries? = nil,
                lastBench: Measured<String>) {
        self.id = id
        self.name = name
        self.model = model
        self.draft = draft
        self.port = port
        self.status = status
        self.statusDetail = statusDetail
        self.foundOutside = foundOutside
        self.readySince = readySince
        self.badges = badges
        self.facts = facts
        self.memory = memory
        self.memorySeries = memorySeries
        self.decodeSeries = decodeSeries
        self.lastBench = lastBench
    }
}

public struct DeckAction: Sendable {
    public enum Role: Sendable, Equatable {
        case primary
        case normal
        case destructive(question: String, consequence: String?, confirmTitle: String)
    }

    public let title: String
    public let systemImage: String?
    public let role: Role
    public let isEnabled: Bool
    public let disabledReason: String?
    public let remember: Remember?
    public let perform: @MainActor @Sendable () -> Void

    public struct Remember: Sendable {
        public let title: String
        public let perform: @MainActor @Sendable () -> Void

        public init(title: String, perform: @escaping @MainActor @Sendable () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    public init(title: String, systemImage: String? = nil, role: Role = .normal, isEnabled: Bool = true,
                disabledReason: String? = nil, remember: Remember? = nil, perform: @escaping @MainActor @Sendable () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.remember = remember
        self.perform = perform
    }
}

public enum SectionState<Content: Sendable>: Sendable {
    case available(Content)
    case unavailable(reason: String)
}
