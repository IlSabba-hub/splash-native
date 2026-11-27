import Foundation

extension StatsSummary {
    public struct Bucket: Sendable, Equatable, Identifiable {
        public let start: Date
        public let length: TimeInterval
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

    public static func buckets(_ records: [StatsRecord], now: Date = .now, length: TimeInterval, count: Int,
                               maximumGap: TimeInterval) -> [Bucket] {
        guard length > 0, count > 0 else { return [] }
        let lastStart = (now.timeIntervalSince1970 / length).rounded(.down) * length
        let firstStart = lastStart - Double(count - 1) * length
        func index(_ t: Double) -> Int? {
            let i = Int(((t - firstStart) / length).rounded(.down))
            return (0 ..< count).contains(i) ? i : nil
        }
        var app = [Double](repeating: 0, count: count)
        var servers = [[String: Totals]](repeating: [:], count: count)
        var groups = [[StatsGroup: Totals]](repeating: [:], count: count)

        let beats = records.filter { $0.key == nil }
        for (a, b) in zip(beats, beats.dropFirst()) where b.t - a.t <= maximumGap && b.t > a.t {
            if let i = index(b.t) { app[i] += b.t - a.t }
        }
        let byServer = Dictionary(grouping: records.filter { $0.key != nil }) { $0.key! }
        for (key, rows) in byServer {
            let rows = rows.sorted { $0.t < $1.t }
            for (a, b) in zip(rows, rows.dropFirst()) {
                guard let i = index(b.t), let interval = interval(a, b, maximumGap: maximumGap) else { continue }
                servers[i][key, default: Totals()].add(interval)
                if let group = b.group { groups[i][group, default: Totals()].add(interval) }
            }
        }
        return (0 ..< count).map { i in
            Bucket(start: Date(timeIntervalSince1970: firstStart + Double(i) * length), length: length,
                   appObserved: min(app[i], length), servers: servers[i], groups: groups[i])
        }
    }
}
