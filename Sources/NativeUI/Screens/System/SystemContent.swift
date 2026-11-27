import Foundation

public struct SystemContent: Sendable {
    public var tiles: [SystemTile]
    public var stats: SectionState<StatsContent>
    public var memory: SystemMemorySection
    public var cache: SystemCacheSection
    public var streaming: [SystemStreamingServer]

    public init(tiles: [SystemTile], stats: SectionState<StatsContent>, memory: SystemMemorySection, cache: SystemCacheSection,
                streaming: [SystemStreamingServer] = []) {
        self.streaming = streaming
        self.tiles = tiles
        self.stats = stats
        self.memory = memory
        self.cache = cache
    }
}

public struct SystemTile: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let value: Measured<String>
    public let caption: String?
    public let fraction: Double?
    public let series: TimeSeries?
    public let tone: ModelTag.Tone?
    public let provenance: Provenance?

    public init(id: String, title: String, value: Measured<String>, caption: String? = nil, fraction: Double? = nil, series: TimeSeries? = nil,
                tone: ModelTag.Tone? = nil, provenance: Provenance? = nil) {
        self.id = id
        self.title = title
        self.value = value
        self.caption = caption
        self.fraction = fraction
        self.series = series
        self.tone = tone
        self.provenance = provenance
    }
}

public struct SystemMemorySection: Sendable {
    public var bar: SectionState<MemoryBreakdown>
    public var unified: SectionState<MemoryBreakdown>?
    public var servers: SectionState<[SystemMemoryRow]>
    public var others: SectionState<[SystemMemoryRow]>
    public var autoCap: SystemAutoCap

    public init(bar: SectionState<MemoryBreakdown>, unified: SectionState<MemoryBreakdown>? = nil, servers: SectionState<[SystemMemoryRow]>,
                others: SectionState<[SystemMemoryRow]>, autoCap: SystemAutoCap) {
        self.bar = bar
        self.unified = unified
        self.servers = servers
        self.others = others
        self.autoCap = autoCap
    }
}

public struct SystemStreamingServer: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let port: Int?
    public let read: TimeSeries
    public let readNow: Measured<String>
    public let readProvenance: Provenance
    public let hit: TimeSeries?
    public let hitNow: Measured<String>?
    public let hitProvenance: Provenance?

    public init(id: String, name: String, port: Int?, read: TimeSeries, readNow: Measured<String>, readProvenance: Provenance,
                hit: TimeSeries? = nil, hitNow: Measured<String>? = nil, hitProvenance: Provenance? = nil) {
        self.id = id
        self.name = name
        self.port = port
        self.read = read
        self.readNow = readNow
        self.readProvenance = readProvenance
        self.hit = hit
        self.hitNow = hitNow
        self.hitProvenance = hitProvenance
    }
}

public struct SystemMemoryRow: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case managed
        case foundOutside
        case engine
        case process
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let detail: String?
    public let command: String?
    public let memory: Measured<Int64>
    public let peak: Measured<Int64>
    public let cap: Measured<Int64>?
    public let rule: String?

    public init(id: String, name: String, kind: Kind, detail: String?, command: String? = nil, memory: Measured<Int64>, peak: Measured<Int64>,
                cap: Measured<Int64>?, rule: String?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.detail = detail
        self.command = command
        self.memory = memory
        self.peak = peak
        self.cap = cap
        self.rule = rule
    }
}

public struct SystemAutoCap: Sendable {
    public var cap: Measured<String>
    public var margin: Measured<String>
    public var facts: [Fact]
    public var help: String?
    public var helpSource: String?

    public init(cap: Measured<String>, margin: Measured<String>, facts: [Fact], help: String?, helpSource: String?) {
        self.cap = cap
        self.margin = margin
        self.facts = facts
        self.help = help
        self.helpSource = helpSource
    }
}

public struct SystemCacheSection: Sendable {
    public var servers: SectionState<[SystemCacheServer]>
    public var folders: SectionState<[SystemCacheFolder]>
    public var rules: [SystemHelpRule]
    public var clearing: String

    public init(servers: SectionState<[SystemCacheServer]>, folders: SectionState<[SystemCacheFolder]>, rules: [SystemHelpRule],
                clearing: String) {
        self.servers = servers
        self.folders = folders
        self.rules = rules
        self.clearing = clearing
    }
}

public enum SystemCacheState: Sendable, Equatable {
    case on(persistent: Bool)
    case off(reason: String)
}

public struct SystemCacheServer: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let port: Int?
    public let state: Measured<SystemCacheState>
    public let used: Measured<Int64>
    public let quota: Measured<Int64>
    public let writtenDay: Measured<String>
    public let accumulated: Measured<String>
    public let takenBack: Measured<String>
    public let details: [Fact]

    public init(id: String, name: String, port: Int?, state: Measured<SystemCacheState>, used: Measured<Int64>, quota: Measured<Int64>,
                writtenDay: Measured<String>, accumulated: Measured<String>, takenBack: Measured<String>, details: [Fact]) {
        self.id = id
        self.name = name
        self.port = port
        self.state = state
        self.used = used
        self.quota = quota
        self.writtenDay = writtenDay
        self.accumulated = accumulated
        self.takenBack = takenBack
        self.details = details
    }
}

public struct SystemCacheFolder: Sendable, Identifiable {
    public let id: String
    public let path: String
    public let origins: [String]
    public let size: Measured<Int64>
    public let namespaces: Int
    public let lastModified: Date?
    public let reveal: NativeAction?

    public init(id: String, path: String, origins: [String], size: Measured<Int64>, namespaces: Int, lastModified: Date?,
                reveal: NativeAction?) {
        self.id = id
        self.path = path
        self.origins = origins
        self.size = size
        self.namespaces = namespaces
        self.lastModified = lastModified
        self.reveal = reveal
    }
}

public struct SystemHelpRule: Sendable, Equatable, Identifiable {
    public let title: String
    public let flag: String
    public let splashDefault: String?
    public let help: String
    public let provenance: Provenance

    public var id: String { flag }

    public init(title: String, flag: String, splashDefault: String?, help: String, provenance: Provenance) {
        self.title = title
        self.flag = flag
        self.splashDefault = splashDefault
        self.help = help
        self.provenance = provenance
    }
}
