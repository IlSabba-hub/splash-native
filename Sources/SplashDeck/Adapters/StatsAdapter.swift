import DeckCore
import DeckUI
import Foundation

@MainActor
enum StatsAdapter {
    struct Pack: Sendable {
        let summary: StatsSummary
        let hour: [StatsSummary.Bucket]
        let day: [StatsSummary.Bucket]
        let bytesOnDisk: UInt64
    }

    static func pack(_ recorder: StatsRecorder, now: Date = .now) async -> Pack {
        let records = recorder.records, gap = recorder.maximumGap, keep = recorder.store.keepDays, store = recorder.store
        return await Task.detached {
            Pack(summary: StatsSummary.make(records, now: now, keepDays: keep, maximumGap: gap),
                 hour: StatsSummary.buckets(records, now: now, length: StatsRange.hour.bucketLength, count: StatsRange.hour.bucketCount,
                                            maximumGap: gap),
                 day: StatsSummary.buckets(records, now: now, length: StatsRange.day.bucketLength, count: StatsRange.day.bucketCount,
                                           maximumGap: gap),
                 bytesOnDisk: store.bytesOnDisk())
        }.value
    }

    typealias Slot = (start: Date, app: Double, servers: [String: StatsSummary.Totals], groups: [StatsGroup: StatsSummary.Totals])

    static func content(_ pack: Pack?, recorder: StatsRecorder, configurations: [String] = [],
                        installation: SplashInstallation? = nil) -> SectionState<StatsContent> {
        guard let pack else { return .unavailable(reason: tr("stats.reason.loading")) }
        let summary = pack.summary
        let ranges: [StatsRange: [Slot]] = [
            .hour: pack.hour.map { ($0.start, $0.appObserved, $0.servers, $0.groups) },
            .day: pack.day.map { ($0.start, $0.appObserved, $0.servers, $0.groups) },
            .month: summary.days.map { ($0.start, $0.appObserved, $0.servers, $0.groups) },
        ]
        let keys = Set(ranges.values.flatMap { $0.flatMap(\.servers.keys) }).sorted()
        let groups = Set(ranges.values.flatMap { $0.flatMap(\.groups.keys) })
        func series(id: String, title: String, kind: StatsSeries.Kind, detail: String? = nil, help: String? = nil,
                    pick: @escaping (Slot) -> StatsSummary.Totals?) -> StatsSeries {
            StatsSeries(id: id, title: title, windows: ranges.mapValues { buckets in
                var total = StatsSummary.Totals(), any = false
                let rows = buckets.map { bucket -> StatsBucket in
                    let totals = pick(bucket)
                    if let totals { total.add(totals); any = true }
                    return StatsBucket(start: bucket.start, appObserved: bucket.app, values: values(totals))
                }
                return StatsWindow(buckets: rows, total: any ? values(total) : StatsValues(), observed: total.observed)
            }, kind: kind, detail: detail, help: help)
        }
        func sum(_ values: some Sequence<StatsSummary.Totals>) -> StatsSummary.Totals? {
            var total = StatsSummary.Totals(), any = false
            for totals in values { total.add(totals); any = true }
            return any ? total : nil
        }
        let existing = Set(configurations)
        let modelNames = ModelNames.names(of: Set(groups.compactMap(\.model)), installation: installation)
        var list: [StatsSeries] = []
        if !keys.isEmpty {
            list.append(series(id: "", title: tr("stats.allServers"), kind: .all) { sum($0.servers.values) })
            struct ModelVersion: Hashable { let model: String?; let version: String? }
            let pairs = Set(groups.map { ModelVersion(model: $0.model, version: $0.version) }).sorted {
                ($0.model ?? "", $0.version ?? "") < ($1.model ?? "", $1.version ?? "")
            }
            func title(_ pair: ModelVersion, name: String) -> String {
                guard let version = pair.version else { return name }
                let splash = tr("stats.series.version", version)
                return tr("stats.series.model", name, splash)
            }
            func name(_ model: String?) -> String { model.map { modelNames[$0] ?? $0 } ?? tr("value.unavailable") }
            let clashing = Dictionary(grouping: Set(pairs.map(\.model)), by: name).filter { $0.value.count > 1 }.keys
            for pair in pairs {
                let members = groups.filter { $0.model == pair.model && $0.version == pair.version }
                let shown = clashing.contains(name(pair.model)) ? pair.model ?? name(nil) : name(pair.model)
                let detail = modelDetail(members, existing: existing)
                list.append(series(id: "model:\(pair.model ?? "")|\(pair.version ?? "")", title: title(pair, name: shown), kind: .model,
                                   detail: detail.isEmpty ? nil : detail,
                                   help: pair.version == nil ? tr("stats.help.versionUnknown") : nil) { slot in
                    sum(slot.groups.filter { $0.key.model == pair.model && $0.key.version == pair.version }.values)
                })
            }
            for key in keys where existing.contains(key) {
                list.append(series(id: key, title: key, kind: .configuration) { $0.servers[key] })
            }
        }
        let coverage = ranges.mapValues { $0.map { StatsBucket(start: $0.start, appObserved: $0.app, values: StatsValues()) } }
        let none = tr("stats.reason.noneYet")
        let since = summary.since.map { DeckFormat.day($0) } ?? none
        let footer = tr("stats.footer", DeckFormat.disk(Int64(clamping: pack.bytesOnDisk)), since, DeckFormat.duration(seconds: recorder.every))
        return .available(StatsContent(series: list, coverage: coverage, footer: footer, writeError: recorder.writeError))
    }

    static func modelDetail(_ members: Set<StatsGroup>, existing: Set<String>) -> String {
        var parts: [String] = []
        let names = Set(members.compactMap(\.configuration)).sorted()
        if !names.isEmpty {
            let marked = names.map { name in
                guard !existing.contains(name) else { return name }
                return tr("stats.series.removed", name)
            }
            parts.append(tr("stats.detail.configurations", marked.joined(separator: ", ")))
        }
        let outside = Set(members.filter { $0.configuration == nil }.compactMap { group in
            group.key.range(of: "@:", options: .backwards).map { ":" + group.key[$0.upperBound...] }
        }).sorted()
        if !outside.isEmpty { parts.append(tr("stats.detail.outside", outside.joined(separator: ", "))) }
        return parts.joined(separator: " · ")
    }

    static func values(_ totals: StatsSummary.Totals?) -> StatsValues {
        guard let totals else { return StatsValues() }
        return StatsValues(decodeRate: totals.decodeRate, prefillRate: totals.prefillRate,
                           requests: Double(totals.completed + totals.failed), tokens: Double(totals.tokens),
                           ssdWritten: Double(totals.diskWritten), memoryPeak: totals.memoryPeak.map(Double.init))
    }
}
