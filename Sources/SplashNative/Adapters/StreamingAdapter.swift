import NativeCore
import NativeUI
import Foundation

enum StreamingAdapter {

    static func server(_ reading: ServerReading?, track: LiveTrack?) -> ServerStreaming? {
        guard let streaming = reading?.streaming, !streaming.isEmpty else { return nil }
        var sections: [FactSection] = []
        if let experts = streaming.experts {
            sections.append(FactSection(id: "experts", title: tr("stream.experts"), facts: storeFacts(experts)))
            let uses = [("prefill", experts.prefill, tr("stream.experts.prefill")), ("decode", experts.decode, tr("stream.experts.decode"))]
            for (use, counters, title) in uses {
                guard let counters else { continue }
                sections.append(FactSection(id: "experts.\(use)", title: title, facts: expertUseFacts(counters, use: use)))
            }
        }
        if let table = streaming.table {
            sections.append(FactSection(id: "table", title: tr("stream.table"), facts: tableFacts(table)))
        }
        if let spill = streaming.kvSpill {
            sections.append(FactSection(id: "kv", title: tr("stream.kv"), facts: kvFacts(spill)))
        }
        return ServerStreaming(summary: summary(streaming, track: track), sections: sections)
    }

    static func summary(_ streaming: StreamingStatus, track: LiveTrack?) -> [Fact] {
        var facts: [Fact] = []
        if let decode = streaming.experts?.decode {
            facts.append(Fact(title: tr("stream.summary.expertHit"),
                              value: hitRate(decode.hitRate, samples: decode.routed, field: "streamed_experts.decode.hit_rate"),
                              provenance: status("streamed_experts.decode.hit_rate")))
        } else if let decode = streaming.table?.decode {
            facts.append(Fact(title: tr("stream.summary.pleHit"),
                              value: hitRate(decode.hitRate, samples: decode.uniqueRows, field: "streamed_table.decode.hit_rate"),
                              provenance: status("streamed_table.decode.hit_rate")))
        }
        facts.append(Fact(title: tr("stream.summary.ssdRead"), value: readNow(track), provenance: readProvenance))
        return facts
    }

    static func readNow(_ track: LiveTrack?) -> Measured<String> {
        guard let last = track?.ssdRead.last else { return .unavailable(reason: tr("stream.reason.secondReading")) }
        return last.value.map { .value(NativeFormat.throughput(bytesPerSecond: $0)) } ?? .unavailable(reason: tr("stream.reason.secondReading"))
    }

    static let readProvenance = Provenance(source: .native(what: tr("stream.source.read")))

    static func storeFacts(_ experts: StreamingStatus.Experts) -> [Fact] {
        var facts = [
            memory(tr("stream.fact.store"), "streamed_experts.cap_bytes", experts.capBytes),
            memory(tr("stream.fact.floor"), "streamed_experts.floor_bytes", experts.floorBytes),
            Fact(title: tr("stream.fact.resident"), value: resident(experts), provenance: status("streamed_experts.resident")),
            count(tr("stream.fact.slots"), "streamed_experts.slots", experts.slots.map(Int64.init)),
            Fact(title: tr("stream.fact.chunks"),
                 value: pair(experts.chunks, experts.capChunks, field: "streamed_experts.chunks"),
                 provenance: status("streamed_experts.chunks · cap_chunks")),
            Fact(title: tr("stream.fact.shrinks"),
                 value: pair(experts.shrinks, experts.regrows, field: "streamed_experts.shrinks"),
                 provenance: status("streamed_experts.shrinks · regrows")),
            memory(tr("stream.fact.arena"), "streamed_experts.arena_bytes", experts.arenaBytes),
            memory(tr("stream.fact.staging"), "streamed_experts.staging_bytes", experts.stagingBytes),
        ]
        if let failure = experts.failure, !failure.isEmpty {
            facts.append(Fact(title: tr("stream.fact.failure"), value: .value(failure), provenance: status("streamed_experts.failure")))
        }
        return facts
    }

    static func expertUseFacts(_ use: StreamingStatus.Experts.Use, use name: String) -> [Fact] {
        let base = "streamed_experts.\(name)"
        return [
            Fact(title: tr("stream.fact.hitRate"), value: hitRate(use.hitRate, samples: use.routed, field: "\(base).hit_rate"),
                 provenance: status("\(base).hit_rate")),
            count(tr("stream.fact.routed"), "\(base).routed", use.routed),
            count(tr("stream.fact.read"), "\(base).read", use.read),
            count(tr("stream.fact.prefetched"), "\(base).prefetched", use.prefetched),
            count(tr("stream.fact.readAhead"), "\(base).read_ahead", use.readAhead),
            count(tr("stream.fact.loads"), "\(base).loads", use.loads),
            bytes(tr("stream.fact.readBytes"), "\(base).read_bytes", use.readBytes),
            latency(tr("stream.fact.hostWork"), "\(base).host_steps.work_ms", use.hostSteps?.work),
        ]
    }

    static func tableFacts(_ table: StreamingStatus.Table) -> [Fact] {
        var facts: [Fact] = []
        if let name = table.table { facts.append(Fact(title: tr("stream.fact.tableName"), value: .value(name), provenance: status("streamed_table.table"))) }
        facts += [
            bytes(tr("stream.fact.tableBytes"), "streamed_table.table_bytes", table.tableBytes),
            memory(tr("stream.fact.cacheBytes"), "streamed_table.cache_bytes", table.cacheBytes),
            Fact(title: tr("stream.fact.cachedRows"), value: pair64(table.cachedRows, table.cacheCapacityRows, field: "streamed_table.cached_rows"),
                 provenance: status("streamed_table.cached_rows · cache_capacity_rows")),
            count(tr("stream.fact.evictions"), "streamed_table.evictions", table.evictions),
        ]
        for (name, use, label) in [("prefill", table.prefill, tr("stream.use.prefill")), ("decode", table.decode, tr("stream.use.decode"))] {
            guard let use else { continue }
            let base = "streamed_table.\(name)"
            facts.append(Fact(title: tr("stream.fact.use.hitRate", label), value: hitRate(use.hitRate, samples: use.uniqueRows, field: "\(base).hit_rate"),
                              provenance: status("\(base).hit_rate")))
            facts.append(count(tr("stream.fact.use.readRows", label), "\(base).read_rows", use.readRows))
            facts.append(latency(tr("stream.fact.use.stage", label), "\(base).stage_ms", use.stage))
        }
        facts += [
            bytes(tr("stream.fact.readBytes"), "streamed_table.read_bytes", table.readBytes),
            latency(tr("stream.fact.readLatency"), "streamed_table.read_ms", table.read),
            Fact(title: tr("stream.fact.prefetchRows"),
                 value: pair64(table.prefetchReadRows, table.prefetchRequestedRows, field: "streamed_table.prefetch_read_rows"),
                 provenance: status("streamed_table.prefetch_read_rows · prefetch_requested_rows")),
            count(tr("stream.fact.readErrors"), "streamed_table.read_errors", table.readErrors),
        ]
        if table.poisoned == true || !(table.failure ?? "").isEmpty {
            facts.append(Fact(title: tr("stream.fact.failure"), value: .value(table.failure.flatMap { $0.isEmpty ? nil : $0 } ?? tr("stream.poisoned")),
                              provenance: status("streamed_table.poisoned · failure")))
        }
        return facts
    }

    static func kvFacts(_ spill: StreamingStatus.KVSpill) -> [Fact] {
        var facts = [
            count(tr("stream.fact.spillRequests"), "kv_spill.requests.spill", spill.requests?.spill),
            count(tr("stream.fact.convertedRequests"), "kv_spill.requests.converted", spill.requests?.converted),
            count(tr("stream.fact.spilledPages"), "kv_spill.pages.spilled", spill.pages?.spilled),
            bytes(tr("stream.fact.spilledBytes"), "kv_spill.pages.spilled_bytes", spill.pages?.spilledBytes),
            count(tr("stream.fact.indexPages"), "kv_spill.pages.index", spill.pages?.index),
            bytes(tr("stream.fact.writeThrough"), "kv_spill.write_through.bytes", spill.writeThrough?.bytes),
        ]
        if let cache = spill.blockCache {
            let samples = (cache.hits ?? 0) + (cache.read ?? 0)
            facts += [
                memory(tr("stream.fact.blockCache"), "kv_spill.block_cache.bytes", cache.bytes),
                Fact(title: tr("stream.fact.blockHit"), value: hitRate(cache.hitRate, samples: samples, field: "kv_spill.block_cache.hit_rate"),
                     provenance: status("kv_spill.block_cache.hit_rate")),
                count(tr("stream.fact.blocksRead"), "kv_spill.block_cache.read", cache.read),
                bytes(tr("stream.fact.readBytes"), "kv_spill.block_cache.read_bytes", cache.readBytes),
                latency(tr("stream.fact.readLatency"), "kv_spill.block_cache.read_ms", cache.readLatency),
                count(tr("stream.fact.readErrors"), "kv_spill.block_cache.read_failures", cache.readFailures),
            ]
        }
        if let history = spill.historyStream {
            facts += [
                bytes(tr("stream.fact.historyBytes"), "kv_spill.history_stream.bytes", history.bytes),
                count(tr("stream.fact.historyPages"), "kv_spill.history_stream.pages", history.pages),
            ]
        }
        return facts
    }

    @MainActor
    static func system(samples: [ServerSample], live: LiveServers?) -> [SystemStreamingServer] {
        guard let live else { return [] }
        return samples.compactMap { sample in
            guard let key = sample.target.server, let track = live.track(key) else { return nil }
            return system(id: sample.target.key, name: sample.target.label, port: sample.target.port, track: track,
                          maximumGap: live.maximumGap, window: live.window)
        }
    }

    static func system(id: String, name: String, port: Int?, track: LiveTrack, maximumGap: TimeInterval,
                       window: TimeInterval) -> SystemStreamingServer? {
        guard let streaming = track.reading?.streaming, !streaming.isEmpty else { return nil }
        func series(_ samples: [LiveSample]) -> TimeSeries {
            TimeSeries(samples: samples.map { .init(time: $0.at, value: $0.value) }, maximumGap: maximumGap,
                       window: samples.last.map { $0.at.addingTimeInterval(-window) ... $0.at })
        }
        let hasExperts = streaming.experts != nil
        let hitNow: Measured<String>? = hasExperts
            ? (track.expertHit.last?.value.map { .value(NativeFormat.percent($0)) } ?? .unavailable(reason: tr("stream.reason.noRouting")))
            : nil
        return SystemStreamingServer(
            id: id, name: name, port: port, read: series(track.ssdRead), readNow: readNow(track), readProvenance: readProvenance,
            hit: hasExperts ? series(track.expertHit) : nil, hitNow: hitNow,
            hitProvenance: hasExperts ? Provenance(source: .native(what: tr("stream.source.hit"))) : nil)
    }

    static func status(_ field: String) -> Provenance { Provenance(source: .status(field: field)) }

    static func missing(_ field: String) -> Measured<String> { .unavailable(reason: tr("reason.notReportedField", field)) }

    static func bytes(_ title: String, _ field: String, _ value: Int64?) -> Fact {
        Fact(title: title, value: value.map { .value(NativeFormat.disk($0)) } ?? missing(field), provenance: status(field))
    }

    static func memory(_ title: String, _ field: String, _ value: Int64?) -> Fact {
        Fact(title: title, value: value.map { .value(NativeFormat.memory($0)) } ?? missing(field), provenance: status(field))
    }

    static func count(_ title: String, _ field: String, _ value: Int64?) -> Fact {
        Fact(title: title, value: value.map { .value(NativeFormat.count(Int($0))) } ?? missing(field), provenance: status(field))
    }

    static func latency(_ title: String, _ field: String, _ value: StreamingStatus.Latency?) -> Fact {
        let text: Measured<String>
        if let value, let p50 = value.p50, let p95 = value.p95, (value.samples ?? 0) > 0 {
            text = .value(tr("stream.value.p50p95", NativeFormat.latency(milliseconds: p50), NativeFormat.latency(milliseconds: p95)))
        } else if value != nil {
            text = .unavailable(reason: tr("stream.reason.noSamples"))
        } else {
            text = missing(field)
        }
        return Fact(title: title, value: text, provenance: status(field))
    }

    static func hitRate(_ rate: Double?, samples: Int64?, field: String) -> Measured<String> {
        guard let rate else { return missing(field) }
        guard (samples ?? 0) > 0 else { return .unavailable(reason: tr("stream.reason.noRouting")) }
        return .value(NativeFormat.percent(rate))
    }

    static func resident(_ experts: StreamingStatus.Experts) -> Measured<String> {
        guard let resident = experts.resident else { return missing("streamed_experts.resident") }
        guard let total = experts.experts, total > 0 else { return .value(NativeFormat.count(resident)) }
        return .value(tr("stream.value.ofTotal", NativeFormat.count(resident), NativeFormat.count(total),
                         NativeFormat.percent(Double(resident) / Double(total))))
    }

    static func pair(_ a: Int?, _ b: Int?, field: String) -> Measured<String> {
        pair64(a.map(Int64.init), b.map(Int64.init), field: field)
    }

    static func pair64(_ a: Int64?, _ b: Int64?, field: String) -> Measured<String> {
        guard let a, let b else { return missing(field) }
        return .value(tr("stream.value.pair", NativeFormat.count(Int(a)), NativeFormat.count(Int(b))))
    }
}
