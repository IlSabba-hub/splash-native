import Foundation
import Observation

public struct StatsSummary: Sendable, Equatable {
    public struct Totals: Sendable, Equatable {
        public var observed: Double = 0
        public var prefillTokens: Int64 = 0
        public var prefillMs: Double = 0
        public var decodeTokens: Int64 = 0
        public var decodeMs: Double = 0
        public var completed: Int64 = 0
        public var failed: Int64 = 0
        public var diskWritten: Int64 = 0
        public var memoryPeak: Int64?

        public var decodeRate: Double? { decodeMs > 0 ? Double(decodeTokens) / decodeMs * 1000 : nil }
        public var prefillRate: Double? { prefillMs > 0 ? Double(prefillTokens) / prefillMs * 1000 : nil }
        public var tokens: Int64 { prefillTokens + decodeTokens }

        public init() {}

        public mutating func add(_ other: Totals) {
            observed += other.observed
            prefillTokens += other.prefillTokens
            prefillMs += other.prefillMs
            decodeTokens += other.decodeTokens
            decodeMs += other.decodeMs
            completed += other.completed
            failed += other.failed
            diskWritten += other.diskWritten
            memoryPeak = [memoryPeak, other.memoryPeak].compactMap { $0 }.max()
        }
    }

    public struct Day: Sendable, Equatable, Identifiable {
        public let start: Date
        public let appObserved: Double
        public let servers: [String: Totals]
        public var groups: [StatsGroup: Totals] = [:]
        public var id: Date { start }

        public var all: Totals? {
            guard !servers.isEmpty else { return nil }
            var total = Totals()
            for totals in servers.values { total.add(totals) }
            return total
        }
    }

    public let days: [Day]
    public let lastDay: [String: Totals]
    public let lastDayAppObserved: Double
    public let labels: [String: String]
    public let since: Date?

    public static func make(_ records: [StatsRecord], now: Date = .now, keepDays: Int = 30, maximumGap: TimeInterval,
                            calendar: Calendar = .current) -> StatsSummary {
        let today = calendar.startOfDay(for: now)
        let starts = (0 ..< keepDays).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        var perDay: [Date: [String: Totals]] = [:]
        var groupsPerDay: [Date: [StatsGroup: Totals]] = [:]
        var appPerDay: [Date: Double] = [:]
        var lastDay: [String: Totals] = [:]
        var lastDayApp = 0.0
        var labels: [String: String] = [:]
        let dayAgo = now.addingTimeInterval(-86_400).timeIntervalSince1970

        let beats = records.filter { $0.key == nil }
        for (a, b) in zip(beats, beats.dropFirst()) where b.t - a.t <= maximumGap && b.t > a.t {
            appPerDay[calendar.startOfDay(for: b.time), default: 0] += b.t - a.t
            if b.t > dayAgo { lastDayApp += b.t - max(a.t, dayAgo) }
        }

        let byServer = Dictionary(grouping: records.filter { $0.key != nil }) { $0.key! }
        for (key, rows) in byServer {
            let rows = rows.sorted { $0.t < $1.t }
            if let label = rows.last?.label { labels[key] = label }
            for (a, b) in zip(rows, rows.dropFirst()) {
                guard let interval = Self.interval(a, b, maximumGap: maximumGap) else { continue }
                let day = calendar.startOfDay(for: b.time)
                perDay[day, default: [:]][key, default: Totals()].add(interval)
                if let group = b.group { groupsPerDay[day, default: [:]][group, default: Totals()].add(interval) }
                if b.t > dayAgo { lastDay[key, default: Totals()].add(interval) }
            }
        }
        let days = starts.map { Day(start: $0, appObserved: appPerDay[$0] ?? 0, servers: perDay[$0] ?? [:], groups: groupsPerDay[$0] ?? [:]) }
        return StatsSummary(days: days, lastDay: lastDay, lastDayAppObserved: lastDayApp, labels: labels,
                            since: records.first.map(\.time))
    }

    static func interval(_ a: StatsRecord, _ b: StatsRecord, maximumGap: TimeInterval) -> Totals? {
        guard b.t > a.t, b.t - a.t <= maximumGap, let instance = a.instance, instance == b.instance else { return nil }
        func delta<T: Numeric & Comparable>(_ x: T?, _ y: T?) -> T?? {
            guard let x, let y else { return .some(nil) }
            return y < x ? nil : .some(y - x)
        }
        guard let prefillTokens = delta(a.prefillTokens, b.prefillTokens), let prefillMs = delta(a.prefillMs, b.prefillMs),
              let decodeTokens = delta(a.decodeTokens, b.decodeTokens), let decodeMs = delta(a.decodeMs, b.decodeMs),
              let completed = delta(a.completed, b.completed), let failed = delta(a.failed, b.failed),
              let written = delta(a.diskWritten, b.diskWritten)
        else { return nil }
        var totals = Totals()
        totals.observed = b.t - a.t
        totals.prefillTokens = prefillTokens ?? 0
        totals.prefillMs = prefillMs ?? 0
        totals.decodeTokens = decodeTokens ?? 0
        totals.decodeMs = decodeMs ?? 0
        totals.completed = completed ?? 0
        totals.failed = failed ?? 0
        totals.diskWritten = written ?? 0
        totals.memoryPeak = [a.memory, b.memory].compactMap { $0 }.max()
        return totals
    }
}

@MainActor @Observable
public final class StatsRecorder {
    public let store: StatsStore
    public let every: TimeInterval
    public var maximumGap: TimeInterval { every * 2.5 }
    public private(set) var records: [StatsRecord] = []
    public private(set) var loaded = false
    public private(set) var writeError: String?
    @ObservationIgnored private var lastWrite: Double = 0
    @ObservationIgnored private var lastRotationDay: String = ""

    public init(store: StatsStore = StatsStore(), every: TimeInterval = 60) {
        self.store = store
        self.every = every
    }

    public func attach(to sampler: ResourceSampler) async {
        let store = store
        records = await Task.detached {
            store.rotate()
            return store.load()
        }.value
        lastRotationDay = StatsStore.dayName(.now)
        loaded = true
        sampler.onSample = { [weak self] system, servers in self?.record(system: system, servers: servers) }
    }

    public func record(system: SystemReading, servers: [ServerSample]) {
        let now = system.time.timeIntervalSince1970
        guard now - lastWrite >= every - 0.5 || now < lastWrite else { return }
        lastWrite = now
        let new = [StatsRecord.heartbeat(system)] + servers.compactMap(StatsRecord.server)
        records.append(contentsOf: new)
        do {
            try store.append(new)
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
        let day = StatsStore.dayName(system.time)
        if day != lastRotationDay {
            lastRotationDay = day
            store.rotate(now: system.time)
            let first = store.firstKeptDay(now: system.time).timeIntervalSince1970
            records.removeAll { $0.t < first }
        }
    }

    public func summary(now: Date = .now) -> StatsSummary {
        StatsSummary.make(records, now: now, keepDays: store.keepDays, maximumGap: maximumGap)
    }
}
