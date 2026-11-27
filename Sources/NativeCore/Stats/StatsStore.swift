import Foundation

public struct StatsRecord: Codable, Sendable, Equatable {
    public var t: Double
    public var key: String?
    public var label: String?
    public var port: Int?
    public var model: String?
    public var instance: String?
    public var startedAt: Double?
    public var prefillTokens: Int64?
    public var prefillMs: Double?
    public var decodeTokens: Int64?
    public var decodeMs: Double?
    public var completed: Int64?
    public var failed: Int64?
    public var cancelled: Int64?
    public var memory: Int64?
    public var memoryPeak: Int64?
    public var diskWritten: Int64?
    public var gpu: Int?
    public var swapUsed: UInt64?
    public var version: String?
    public var configuration: String?

    public var time: Date { Date(timeIntervalSince1970: t) }

    public var configurationName: String? {
        if let configuration { return configuration }
        guard let key, !key.contains("@:") else { return nil }
        return key
    }

    public var group: StatsGroup? {
        guard let key else { return nil }
        return StatsGroup(model: model, version: version, configuration: configurationName, key: key)
    }

    public init(t: Double, key: String? = nil, label: String? = nil, port: Int? = nil, model: String? = nil, instance: String? = nil,
                startedAt: Double? = nil, prefillTokens: Int64? = nil, prefillMs: Double? = nil, decodeTokens: Int64? = nil,
                decodeMs: Double? = nil, completed: Int64? = nil, failed: Int64? = nil, cancelled: Int64? = nil, memory: Int64? = nil,
                memoryPeak: Int64? = nil, diskWritten: Int64? = nil, gpu: Int? = nil, swapUsed: UInt64? = nil,
                version: String? = nil, configuration: String? = nil) {
        self.version = version
        self.configuration = configuration
        self.t = t
        self.key = key
        self.label = label
        self.port = port
        self.model = model
        self.instance = instance
        self.startedAt = startedAt
        self.prefillTokens = prefillTokens
        self.prefillMs = prefillMs
        self.decodeTokens = decodeTokens
        self.decodeMs = decodeMs
        self.completed = completed
        self.failed = failed
        self.cancelled = cancelled
        self.memory = memory
        self.memoryPeak = memoryPeak
        self.diskWritten = diskWritten
        self.gpu = gpu
        self.swapUsed = swapUsed
    }

    public static func heartbeat(_ system: SystemReading) -> StatsRecord {
        StatsRecord(t: system.time.timeIntervalSince1970, gpu: system.gpu.first?.deviceUtilization, swapUsed: system.memory.swapUsedBytes)
    }

    public static func server(_ sample: ServerSample) -> StatsRecord? {
        guard let status = sample.status else { return nil }
        return StatsRecord(
            t: sample.time.timeIntervalSince1970, key: sample.target.key, label: sample.target.label, port: sample.target.port,
            model: status.instance?.model, instance: status.instance?.id, startedAt: status.instance?.startedAt,
            prefillTokens: status.metrics?.prefillInputTokens, prefillMs: status.metrics?.prefillWallMs,
            decodeTokens: status.metrics?.decodeOutputTokens, decodeMs: status.metrics?.decodeWallMs,
            completed: status.requests?.completed, failed: status.requests?.failed, cancelled: status.requests?.cancelled,
            memory: status.memoryActual?.currentBytes, memoryPeak: status.memoryActual?.peakBytes, diskWritten: status.disk?.writtenBytes,
            version: sample.target.version, configuration: sample.target.configuration)
    }
}

public struct StatsGroup: Sendable, Hashable {
    public let model: String?
    public let version: String?
    public let configuration: String?
    public let key: String

    public init(model: String?, version: String?, configuration: String?, key: String) {
        self.model = model
        self.version = version
        self.configuration = configuration
        self.key = key
    }
}

public struct StatsStore: Sendable {
    public let folder: URL
    public let keepDays: Int

    public static let defaultFolder = URL.applicationSupportDirectory.appending(path: "SplashNative/stats")

    public init(folder: URL = StatsStore.defaultFolder, keepDays: Int = 30) {
        self.folder = folder
        self.keepDays = keepDays
    }

    static func dayName(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let pad = { (value: Int?, width: Int) in
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
    }

    func file(for date: Date) -> URL { folder.appending(path: "\(Self.dayName(date)).jsonl") }

    public func append(_ records: [StatsRecord]) throws {
        guard !records.isEmpty else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (day, group) in Dictionary(grouping: records, by: { file(for: $0.time) }) {
            var data = Data()
            for record in group {
                data.append(try encoder.encode(record))
                data.append(0x0A)
            }
            try JSONLines.append(data, to: day)
        }
    }

    public func firstKeptDay(now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -(keepDays - 1), to: calendar.startOfDay(for: now)) ?? now
    }

    @discardableResult
    public func rotate(now: Date = .now, calendar: Calendar = .current) -> [String] {
        let limit = Self.dayName(firstKeptDay(now: now, calendar: calendar), calendar: calendar)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var removed: [String] = []
        for file in files where file.pathExtension == "jsonl" {
            let name = file.deletingPathExtension().lastPathComponent
            if name.count == 10, name < limit, (try? FileManager.default.removeItem(at: file)) != nil { removed.append(file.lastPathComponent) }
        }
        return removed.sorted()
    }

    public func load(now: Date = .now, calendar: Calendar = .current) -> [StatsRecord] {
        let first = firstKeptDay(now: now, calendar: calendar).timeIntervalSince1970
        let decoder = JSONDecoder()
        var records: [StatsRecord] = []
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: 0x0A) {
                if let record = try? decoder.decode(StatsRecord.self, from: Data(line)), record.t >= first { records.append(record) }
            }
        }
        return records.sorted { $0.t < $1.t }
    }

    public func bytesOnDisk() -> UInt64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
        return files.reduce(0) { $0 + UInt64((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
    }
}
