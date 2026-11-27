import AppKit
import DeckCore
import DeckUI
import SwiftUI

struct SystemSection: View {
    private let services = AppServices.shared
    @State private var folders: [CacheFolder]?
    @State private var stats: StatsAdapter.Pack?

    var body: some View {
        SectionPage(.system, state: .available(SystemAdapter.content(
            inputs: .init(model: services.model, sampler: services.sampler, recorder: services.stats,
                          scanned: services.processesScanned, folders: folders, stats: stats,
                          live: ServerBoard.shared.live)))) { content in
            SystemScreen(content)
        }
        .task {
            let model = services.model
            for installation in model.installations { _ = try? await model.schema(for: installation) }
            while !Task.isCancelled {
                let schemas = Array(model.schemas.values), configurations = model.configurations
                folders = await Task.detached { CacheFolders.scan(schemas: schemas, configurations: configurations) }.value
                if services.stats.loaded { stats = await StatsAdapter.pack(services.stats) }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

@MainActor
enum SystemAdapter {
    struct Inputs {
        let model: DeckModel
        let sampler: ResourceSampler
        let recorder: StatsRecorder
        let scanned: Bool
        let folders: [CacheFolder]?
        let stats: StatsAdapter.Pack?
        var live: LiveServers? = nil
    }

    static func content(inputs: Inputs) -> SystemContent {
        let model = inputs.model, sampler = inputs.sampler
        let samples = sampler.servers.values.sorted { ($0.target.owned ? 0 : 1, $0.target.key) < ($1.target.owned ? 0 : 1, $1.target.key) }
        let schema = linkedSchema(model)
        return SystemContent(
            tiles: tiles(model: model, sampler: sampler, samples: samples),
            stats: StatsAdapter.content(inputs.stats, recorder: inputs.recorder, configurations: model.configurations.map(\.name),
                                      installation: model.installations.first(where: \.linked) ?? model.installations.first),
            memory: memory(model: model, sampler: sampler, samples: samples, scanned: inputs.scanned, schema: schema),
            cache: cache(samples: samples, sampled: sampler.system != nil, folders: inputs.folders, schema: schema,
                         hasSchemas: !model.schemas.isEmpty, summary: inputs.stats?.summary),
            streaming: StreamingAdapter.system(samples: samples, live: inputs.live))
    }

    static func linkedSchema(_ model: DeckModel) -> VersionSchema? {
        let installation = model.installations.first(where: \.linked) ?? model.installations.first
        return installation.flatMap { model.schemas[$0.id] }
    }

    static func versionText(_ schema: VersionSchema) -> String {
        schema.installation.version ?? schema.serve.reportedVersion
    }

    static func tiles(model: DeckModel, sampler: ResourceSampler, samples: [ServerSample]) -> [SystemTile] {
        let first = tr("system.reason.firstReading")
        let system = sampler.system

        let gpuMemory: SystemTile
        if let budget = model.budget, budget > 0, system != nil {
            let readings = samples.map { $0.status?.memoryActual?.currentBytes }
            let measured = readings.compactMap { $0 }.reduce(0, +)
            let missing = readings.filter { $0 == nil }.count
            let caption = missing > 0 ? tr(missing == 1 ? "system.tile.gpuMemory.missing.one" : "system.tile.gpuMemory.missing", DeckFormat.memory(Int64(clamping: budget)), DeckFormat.count(missing))
                : samples.isEmpty ? tr("system.tile.gpuMemory.none", DeckFormat.memory(Int64(clamping: budget)))
                : tr("system.tile.gpuMemory.caption", DeckFormat.memory(Int64(clamping: budget)))
            gpuMemory = SystemTile(id: "gpuMemory", title: tr("system.tile.gpuMemory"), value: .value(DeckFormat.memory(measured)), caption: caption,
                                   fraction: Double(measured) / Double(budget),
                                   provenance: Provenance(source: .status(field: "memory_actual.current_bytes / recommendedMaxWorkingSetSize")))
        } else {
            gpuMemory = SystemTile(id: "gpuMemory", title: tr("system.tile.gpuMemory"),
                                   value: .unavailable(reason: model.budget == nil ? tr("system.reason.noMetal") : first))
        }

        let memory = system?.memory
        let pressure = memory?.pressure?.rawValue
        let swap = memory?.swapUsedBytes.map { DeckFormat.memory(Int64(clamping: $0)) }
        let macCaption: String = switch (pressure, swap) {
        case let (pressure?, swap?): tr("system.tile.mac.caption", pressureWord(pressure), swap)
        case let (pressure?, nil): tr("system.tile.mac.pressure", pressureWord(pressure))
        default: tr("system.tile.mac.pressureNone")
        }
        let mac = SystemTile(id: "mac", title: tr("system.tile.mac"),
                             value: memory?.physicalBytes.map { .value(DeckFormat.memory(Int64(clamping: $0))) } ?? .unavailable(reason: first),
                             caption: system == nil ? nil : macCaption, tone: pressure.map(pressureTone),
                             provenance: Provenance(source: .system(name: "sysctl hw.memsize · kern.memorystatus_vm_pressure_level · vm.swapusage")))

        let reading = system?.gpu.first
        let gap = Double(sampler.interval.components.seconds) * 1.5
        let series = TimeSeries(samples: sampler.gpuHistory.map { .init(time: $0.time, value: $0.utilization.map(Double.init)) }, maximumGap: gap)
        let gpu = SystemTile(id: "gpu", title: tr("system.tile.gpu"),
                             value: reading?.deviceUtilization.map { .value(DeckFormat.percent(Double($0) / 100)) }
                                 ?? .unavailable(reason: system == nil ? first : tr("system.gpu.noAccelerator")),
                             caption: tr("system.tile.gpu.caption"), series: series,
                             provenance: Provenance(source: .system(name: "IOAccelerator · PerformanceStatistics · Device Utilization %")))

        let thermal = system?.thermal?.rawValue
        let heat = SystemTile(id: "thermal", title: tr("system.tile.thermal"),
                              value: thermal.map { .value(thermalWord($0)) } ?? .unavailable(reason: first),
                              tone: thermal.map(thermalTone),
                              provenance: Provenance(source: .system(name: "ProcessInfo.thermalState")))
        return [gpuMemory, mac, gpu, heat]
    }

    static func pressureTone(_ word: String) -> ModelTag.Tone {
        switch word {
        case "normal": .ready
        case "warning", "warn": .warning
        default: .error
        }
    }

    static func thermalTone(_ word: String) -> ModelTag.Tone {
        switch word {
        case "nominal": .ready
        case "fair": .warning
        default: .error
        }
    }

    static func memory(model: DeckModel, sampler: ResourceSampler, samples: [ServerSample], scanned: Bool,
                       schema: VersionSchema?) -> SystemMemorySection {
        let outside = Set(model.found.flatMap { [$0.pid] + $0.engines })
        let others = model.others.filter { !outside.contains($0.pid) }
        let bar: SectionState<MemoryBreakdown>
        var unified: SectionState<MemoryBreakdown>?
        if let budget = model.budget {
            let othersCharge: Measured<Int64> = scanned
                ? .value(Int64(clamping: others.reduce(UInt64(0)) { $0 + $1.charge }))
                : .unavailable(reason: tr("system.reason.scanning"))
            let instances = samples.compactMap { sample -> MemoryBreakdown.Instance? in
                guard let current = sample.status?.memoryActual?.currentBytes else { return nil }
                let peak = sample.status?.peakBytes ?? current
                return .init(id: sample.target.key, name: sample.target.label, measured: current, reservedUnused: max(0, peak - current))
            }
            let room = MemoryRoom(metalBudget: budget, physical: ProcessInfo.processInfo.physicalMemory, splashBytes: 0, othersBytes: 0)
            bar = .available(MemoryBreakdown(budget: Int64(clamping: budget - room.metalMargin), budgetTitle: tr("memory.budgetMetalSplash"),
                                             budgetProvenance: Provenance(source: .system(name: "MTLDevice.recommendedMaxWorkingSetSize − workingSetMarginBytes")),
                                             instances: instances, others: othersCharge, showsOthers: false))
            unified = .available(MemoryBreakdown(budget: Int64(clamping: room.physical), budgetTitle: tr("memory.unified"),
                                                 budgetProvenance: Provenance(source: .system(name: "hw.memsize")),
                                                 instances: instances, others: othersCharge, system: Int64(clamping: room.macOSReserve),
                                                 systemTitle: tr("memory.macOSReserve")))
        } else {
            bar = .unavailable(reason: tr("system.reason.noMetal"))
        }
        let servers: SectionState<[SystemMemoryRow]> = sampler.system == nil
            ? .unavailable(reason: tr("system.reason.firstReading"))
            : .available(samples.map(serverRow))
        return SystemMemorySection(
            bar: bar, unified: unified, servers: servers,
            others: scanned ? .available(others.map(processRow)) : .unavailable(reason: tr("system.reason.scanning")),
            autoCap: autoCap(budget: model.budget, samples: samples, schema: schema))
    }

    static func serverRow(_ sample: ServerSample) -> SystemMemoryRow {
        let status = sample.status
        let reason = failureReason(sample)
        func bytes(_ value: Int64?) -> Measured<Int64> { value.map { .value($0) } ?? .unavailable(reason: reason) }
        let budget = status?.memoryPlan?.budget
        let rule: String? = if let limit = budget?.configuredMemoryLimitBytes, limit > 0 {
            tr("system.rule.maxMemory", DeckFormat.memory(limit))
        } else if let margin = budget?.workingSetMarginBytes {
            tr("system.rule.auto", DeckFormat.memory(margin))
        } else { nil }
        return SystemMemoryRow(
            id: sample.target.key, name: sample.target.label, kind: sample.target.owned ? .managed : .foundOutside,
            detail: DeckFormat.port(sample.target.port),
            memory: bytes(status?.memoryActual?.currentBytes), peak: bytes(status?.memoryActual?.peakBytes),
            cap: bytes(budget?.hardBudgetBytes), rule: rule)
    }

    static func failureReason(_ sample: ServerSample) -> String {
        if case let .failed(message) = sample.reading { return tr("system.reason.statusFailed", message) }
        return tr("reason.notReported")
    }

    static func autoCap(budget: UInt64?, samples: [ServerSample], schema: VersionSchema?) -> SystemAutoCap {
        let withPlan = samples.first { $0.status?.memoryPlan?.budget?.workingSetMarginBytes != nil }
        let plan = withPlan?.status?.memoryPlan?.budget
        let notRunning = tr("system.reason.autoCapNeedsServer")
        func status(_ value: Int64?, _ field: String) -> (Measured<String>, Provenance?) {
            guard let value else { return (.unavailable(reason: notRunning), nil) }
            return (.value(DeckFormat.memory(value)), Provenance(source: .status(field: field)))
        }
        let workingSet = status(plan?.recommendedWorkingSetBytes, "memory_plan.budget.recommended_working_set_bytes")
        let margin = status(plan?.workingSetMarginBytes, "memory_plan.budget.working_set_margin_bytes")
        let cap: Measured<String> = if let ws = plan?.recommendedWorkingSetBytes, let m = plan?.workingSetMarginBytes {
            .value(DeckFormat.memory(ws - m))
        } else { .unavailable(reason: notRunning) }
        var facts = [
            Fact(title: tr("system.autoCap.budget"), value: budget.map { .value(DeckFormat.memory(Int64(clamping: $0))) }
                    ?? .unavailable(reason: tr("system.reason.noMetal")),
                 provenance: Provenance(source: .system(name: "MTLDevice.recommendedMaxWorkingSetSize"))),
            Fact(title: tr("system.autoCap.workingSet"), value: workingSet.0, provenance: workingSet.1),
            Fact(title: tr("system.autoCap.margin"), value: margin.0, provenance: margin.1),
            Fact(title: tr("system.autoCap.cap"), value: cap,
                 provenance: plan == nil ? nil : Provenance(source: .status(field: "recommended_working_set_bytes − working_set_margin_bytes"))),
        ]
        for sample in samples {
            guard let hard = sample.status?.memoryPlan?.budget?.hardBudgetBytes else { continue }
            facts.append(Fact(title: tr("system.autoCap.serverBudget", sample.target.label), value: .value(DeckFormat.memory(hard)),
                              provenance: Provenance(flag: "--max-memory", source: .status(field: "memory_plan.budget.hard_budget_bytes"))))
        }
        return SystemAutoCap(cap: cap, margin: margin.0, facts: facts,
                             help: schema?.serve.parameter("--max-memory")?.help.map(normalized),
                             helpSource: schema.map { tr("system.helpSource", versionText($0)) })
    }

    static func pressureWord(_ word: String) -> String {
        switch word {
        case "normal": tr("system.pressure.normal")
        case "warning", "warn": tr("system.pressure.warning")
        case "critical": tr("system.pressure.critical")
        default: word
        }
    }

    static func thermalWord(_ word: String) -> String {
        switch word {
        case "nominal": tr("system.thermal.nominal")
        case "fair": tr("system.thermal.fair")
        case "serious": tr("system.thermal.serious")
        case "critical": tr("system.thermal.critical")
        default: word
        }
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func processRow(_ process: OtherProcess) -> SystemMemoryRow {
        let weights = process.weights.filter { $0.countedWith == nil }.reduce(UInt64(0)) { $0 + $1.mappedBytes }
        let rule = switch process.rule {
        case .footprint: tr("system.others.rule.footprint")
        case .peak: tr("system.others.rule.peak")
        case .peakAndWeights: tr("system.others.rule.peakAndWeightsValue", DeckFormat.memory(Int64(clamping: weights)))
        case .resident: tr("system.others.rule.resident")
        }
        let ports = process.ports.map(DeckFormat.port).joined(separator: " ")
        return SystemMemoryRow(id: String(process.pid), name: process.engine.map(engineName) ?? process.name,
                               kind: process.engine == nil ? .process : .engine,
                               detail: ports.isEmpty ? tr("system.others.pid", String(process.pid)) : ports,
                               command: process.command, memory: .value(Int64(clamping: process.charge)),
                               peak: .value(Int64(clamping: process.usage.lifetimeMax)), cap: nil, rule: rule)
    }

    static func engineName(_ engine: KnownEngine) -> String {
        switch engine {
        case .splash: "Splash"
        case .inkEngine: "ink-engine"
        case .llamaServer: "llama-server"
        case .omlx: "oMLX"
        case .mlxVLM: "mlx-vlm"
        case .mlxLM: "mlx-lm"
        }
    }

    static func cache(samples: [ServerSample], sampled: Bool, folders: [CacheFolder]?, schema: VersionSchema?,
                      hasSchemas: Bool, summary: StatsSummary?) -> SystemCacheSection {
        let servers: SectionState<[SystemCacheServer]> = sampled
            ? .available(samples.map { cacheServer($0, summary: summary) }) : .unavailable(reason: tr("system.reason.firstReading"))
        let folderState: SectionState<[SystemCacheFolder]>
        if let folders, hasSchemas {
            folderState = .available(folders.map(cacheFolder))
        } else if folders != nil {
            folderState = .unavailable(reason: tr("system.cache.folders.noSchema"))
        } else {
            folderState = .unavailable(reason: tr("system.reason.firstReading"))
        }
        let rules = schema.map { schema in
            ["--max-cache-disk", "--max-cache-disk-writes", "--persistent-cache", "--cache-dir"].compactMap { flag -> SystemHelpRule? in
                guard let parameter = schema.serve.parameter(flag), let help = parameter.help else { return nil }
                return SystemHelpRule(title: FlagLabels.title(for: flag) ?? flag, flag: flag, splashDefault: parameter.helpDefault,
                                      help: normalized(help),
                                      provenance: Provenance(flag: flag, source: .help(version: versionText(schema), group: parameter.group)))
            }
        } ?? []
        return SystemCacheSection(servers: servers, folders: folderState, rules: rules, clearing: tr("system.cache.clearing"))
    }

    static func cacheServer(_ sample: ServerSample, summary: StatsSummary?) -> SystemCacheServer {
        let disk = sample.status?.disk
        let reason = disk == nil ? failureReason(sample) : tr("reason.notReported")
        func bytes(_ value: Int64?) -> Measured<String> { value.map { .value(DeckFormat.disk($0)) } ?? .unavailable(reason: reason) }
        func field(_ title: String, _ value: Measured<String>, _ name: String) -> Fact {
            Fact(title: title, value: value, provenance: Provenance(source: .status(field: "disk.\(name)")))
        }
        let state: Measured<SystemCacheState> = if let disk {
            if let off = disk.offReason { .value(.off(reason: off)) }
            else if disk.capacityBytes == 0 { .value(.off(reason: tr("system.cache.zeroQuota"))) }
            else if let persistent = disk.persistent { .value(.on(persistent: persistent)) }
            else { .unavailable(reason: tr("reason.notReported")) }
        } else { .unavailable(reason: reason) }
        let gated: Measured<String> = disk?.writesGated.map { .value(gatedWord($0)) } ?? .unavailable(reason: reason)
        let takenBack: Measured<String> = if let back = disk?.takenBack, let states = back.states, let bytes = back.bytes {
            states == 0 ? .value(tr("system.cache.takenBack.none"))
                : .value(tr(states == 1 ? "system.cache.takenBack.value.one" : "system.cache.takenBack.value", DeckFormat.count(Int(states)), DeckFormat.disk(bytes)))
        } else { .unavailable(reason: reason) }
        let blocks: Measured<String> = disk?.takenBack?.kvBlocks.map { .value(DeckFormat.count(Int($0))) } ?? .unavailable(reason: reason)
        let behind: Measured<String> = if let wb = disk?.writeBehind, let waiting = wb.waiting, let durable = wb.durable, let refused = wb.refused {
            .value(tr("system.cache.writeBehind.value", DeckFormat.count(Int(waiting)), DeckFormat.count(Int(durable)), DeckFormat.count(Int(refused))))
        } else { .unavailable(reason: reason) }
        let details = [
            field(tr("system.cache.written"), bytes(disk?.writtenBytes), "written_bytes"),
            field(tr("system.cache.writtenHour"), bytes(disk?.writtenLastHourBytes), "written_last_hour_bytes"),
            field(tr("system.cache.gated"), gated, "writes_gated"),
            field(tr("system.cache.writeBudget"), bytes(disk?.writeBudgetBytes), "write_budget_bytes"),
            field(tr("system.cache.read"), bytes(disk?.readBytes), "read_bytes"),
            field(tr("system.cache.takenBackBlocks"), blocks, "taken_back.kv_blocks"),
            field(tr("system.cache.writeBehind"), behind, "write_behind"),
            field(tr("system.cache.limit"), bytes(disk?.limitBytes), "limit_bytes"),
            field(tr("system.cache.volume"), bytes(disk?.volumeAvailableBytes), "volume_available_bytes"),
        ]
        return SystemCacheServer(id: sample.target.key, name: sample.target.label, port: sample.target.port, state: state,
                                 used: disk?.usedBytes.map { .value($0) } ?? .unavailable(reason: reason),
                                 quota: disk?.capacityBytes.map { .value($0) } ?? .unavailable(reason: reason),
                                 writtenDay: bytes(disk?.writtenLastDayBytes),
                                 accumulated: accumulated(sample.target.key, summary), takenBack: takenBack, details: details)
    }

    static func accumulated(_ key: String, _ summary: StatsSummary?) -> Measured<String> {
        guard let summary else { return .unavailable(reason: tr("stats.reason.loading")) }
        guard let totals = summary.lastDay[key], totals.observed > 0 else {
            return .unavailable(reason: tr("system.cache.accumulated.none"))
        }
        return .value(tr("system.cache.accumulated.value", DeckFormat.disk(totals.diskWritten), DeckFormat.duration(seconds: totals.observed)))
    }

    static func gatedWord(_ word: String) -> String {
        switch word {
        case "no": tr("system.cache.gated.no")
        case "budget": tr("system.cache.gated.budget")
        case "closed": tr("system.cache.gated.closed")
        default: word
        }
    }

    static func cacheFolder(_ folder: CacheFolder) -> SystemCacheFolder {
        let origins = folder.origins.map { origin in
            switch origin {
            case let .splashDefault(version): tr("system.cache.origin.default", version)
            case let .configuration(name): tr("system.cache.origin.configuration", name)
            }
        }
        let url = folder.url
        let size: Measured<Int64> = if let bytes = folder.allocatedBytes { .value(Int64(clamping: bytes)) }
            else { .unavailable(reason: tr(folder.exists ? "system.cache.folder.unreadable" : "system.cache.folder.missing")) }
        return SystemCacheFolder(id: folder.id, path: folder.written, origins: origins, size: size, namespaces: folder.namespaces.count,
                                 lastModified: folder.namespaces.compactMap(\.modified).max(),
                                 reveal: folder.exists ? DeckAction(title: tr("action.showInFinder"), systemImage: "folder") {
                                     NSWorkspace.shared.activateFileViewerSelecting([url])
                                 } : nil)
    }
}
