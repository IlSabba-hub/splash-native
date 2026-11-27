import AppKit
import DeckCore
import DeckUI
import Foundation
import SwiftUI

struct ServersSection: View {
    @Bindable var actions: ServerActions
    let loads: LoadController

    var body: some View {
        let board = actions.board
        if board.prepared {
            let adapter = ServersAdapter(board: board, actions: actions)
            let overview = OverviewAdapter(board: board)
            let selected = adapter.selectedID(in: adapter.items)
            ServersScreen(control: selected.flatMap { adapter.control($0, loads: loads) }, detail: selected.flatMap(adapter.detail),
                          principals: overview.principals,
                          principalAction: { LoadAdapter.principalAction($0, board: board, controller: loads) },
                          principalMenu: { LoadAdapter.principalMenu($0, board: board, controller: loads) },
                          picker: LoadAdapter.picker(board: board, controller: loads, shelf: AppServices.shared.library.shelf),
                          openPicker: { loads.showsPicker = true }, tab: $actions.tab, notice: selected.flatMap(actions.notice), pending: selected.flatMap(actions.pendingAction),
                          loadedActions: selected.map(adapter.loadedActions) ?? [], benchAction: selected.flatMap(adapter.benchAction))
        } else {
            SectionPage(.servers, unavailable: tr("reason.reading"))
        }
    }

    private var running: [String] {
        guard actions.board.prepared else { return [] }
        let adapter = ServersAdapter(board: actions.board, actions: actions)
        let active = Set(actions.board.activeServers.map(\.id))
        return adapter.items.map(\.id).filter(active.contains)
    }
}

extension ServersSection {
    func openingOnARunningServer() -> some View {
        onAppear { actions.revisit(running: running) }
            .onChange(of: running) { _, now in actions.revisit(running: now) }
    }
}

@MainActor
struct ServersAdapter {
    let board: ServerBoard
    let actions: ServerActions
    var model: DeckModel { board.model }

    var items: [ServerListItem] {
        let servers = board.servers
        let running = Set(servers.filter(\.alive).compactMap { $0.configuration?.name })
        let serverItems = servers.map { server in
            let status = server.status
            return ServerListItem(id: server.id, name: server.name, port: server.port, status: status.kind, statusDetail: status.detail,
                                  kind: server.managed ? .managed : .foundOutside)
        }
        let stopped = model.configurations.filter { !running.contains($0.name) }.map { configuration in
            ServerListItem(id: ServerActions.itemID(configuration: configuration.name), name: configuration.name, port: configuration.port,
                           status: .stopped, kind: .configuration)
        }
        return serverItems + stopped
    }

    func selectedID(in items: [ServerListItem]) -> String? {
        if let selection = actions.selection, items.contains(where: { $0.id == selection }) { return selection }
        return items.first { $0.kind != .configuration }?.id ?? items.first?.id
    }

    func server(_ id: String) -> ServerBoard.Server? { board.servers.first { $0.id == id } }

    func configuration(_ id: String) -> Configuration? {
        model.configurations.first { ServerActions.itemID(configuration: $0.name) == id }
    }

    func control(_ id: String, loads: LoadController) -> ServerControl? {
        if let server = server(id) {
            let status = server.status
            let configuration = server.configuration
            let toggle: DeckAction? = server.alive ? LoadAdapter.ejectAction(server, actions: actions, board: board)
                : configuration.map { load($0, loads: loads) }
            return ServerControl(status: status.kind, statusDetail: status.detail, foundOutside: !server.managed, endpoint: server.endpoint,
                                 toggle: toggle,
                                 copy: server.alive ? DeckAction(title: tr("action.copyEndpoint"), systemImage: "doc.on.doc") { [actions] in
                                     actions.copyEndpoint(server)
                                 } : nil,
                                 settings: settings(configuration, outside: !server.managed, loads: loads), isOn: server.alive,
                                 name: server.name)
        }
        if let configuration = configuration(id) {
            return ServerControl(status: .stopped, statusDetail: ServerActions.waitingReason(configuration) == nil ? nil : tr("files.waiting"),
                                 endpoint: "http://127.0.0.1:\(configuration.port)/v1", toggle: load(configuration, loads: loads),
                                 copy: nil, settings: settings(configuration, outside: false, loads: loads), name: configuration.name)
        }
        return nil
    }

    func load(_ configuration: Configuration, loads: LoadController) -> DeckAction {
        let start = actions.startAction(configuration)
        return DeckAction(title: start.title, systemImage: start.systemImage, role: .primary, isEnabled: start.isEnabled,
                          disabledReason: start.disabledReason) { loads.open(configuration) }
    }

    func settings(_ configuration: Configuration?, outside: Bool, loads: LoadController) -> DeckAction {
        guard let configuration else {
            return DeckAction(title: tr("server.control.settings"), systemImage: "gearshape", isEnabled: false,
                              disabledReason: tr("reason.outsideNoConfiguration")) {}
        }
        return DeckAction(title: tr("server.control.settings"), systemImage: "gearshape", isEnabled: !outside,
                          disabledReason: outside ? tr("reason.outsideSettings") : nil) { loads.edit(configuration) }
    }

    func loadedActions(_ id: String) -> [DeckAction] {
        guard let server = server(id) else { return [] }
        guard server.alive else { return actions.actions(for: server).filter { $0.title == tr("action.forget") } }
        var list = Array(actions.actions(for: server).dropFirst())
        if let model = server.track?.servedModels?.first ?? server.reading?.snapshot.instance?.model {
            list.append(DeckAction(title: tr("server.copyModelID"), systemImage: "textformat") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model, forType: .string)
            })
        }
        return list
    }

    func benchAction(_ id: String) -> DeckAction? {
        server(id).flatMap { actions.benchAction(for: $0) }
    }

    func detail(_ id: String) -> ServerDetail? {
        if let server = server(id) { return detail(server) }
        if let configuration = configuration(id) { return detail(configuration) }
        return nil
    }

    func detail(_ server: ServerBoard.Server) -> ServerDetail {
        let reading = server.reading
        let status = server.status
        let overview = OverviewAdapter(board: board)
        let noReading = server.track?.failure ?? (server.alive ? tr("reason.noStatusYet") : tr("reason.serverStopped"))
        let logState = log(server)
        return ServerDetail(
            id: server.id, name: server.name,
            model: reading?.snapshot.instance?.model ?? server.found?.model ?? server.configuration.map(OverviewAdapter.modelTitle) ?? "",
            port: server.port, status: status.kind, statusDetail: status.detail, foundOutside: !server.managed,
            readySince: server.readySince, identity: identity(server),
            memory: reading.map(OverviewAdapter.memoryReading),
            memorySeries: server.track.map { overview.series($0.memory) }, decodeSeries: server.track.map { overview.series($0.decode) },
            traffic: traffic(reading), weights: weights(server), cache: cache(reading),
            requests: reading.map { reading in .available(reading.detail.activeRequests.map { ServerFacts.request($0, server: server.name) }) }
                ?? .unavailable(reason: noReading),
            history: history(logState), log: logState,
            bench: bench(ServerActions.benchLabel(server)),
            configuration: configurationFacts(server), configurationSource: configurationSource(server),
            captured: ObservatoryAdapter.traffic(of: server, in: model),
            family: server.configuration.flatMap { LoadAdapter.family(of: $0, shelf: AppServices.shared.library.shelf) },
            endpoints: Self.endpoints(root: server.root, version: server.version),
            weightsReleased: reading?.snapshot.weights?.released, lastRequest: Self.lastRequest(logState),
            streaming: StreamingAdapter.server(reading, track: server.track))
    }

    static func lastRequest(_ log: SectionState<ServerLog>) -> ReplyMetrics? {
        guard case let .available(log) = log else { return nil }
        guard let done = log.lines.reversed().lazy.compactMap(SplashLog.request).first(where: { $0.kind == .done }) else { return nil }
        let pattern = /TTFT of request (\d+): ([0-9.]+) ms: own prefill ([0-9.]+)/
        let timing = log.lines.reversed().lazy.compactMap { line -> (ttft: Double, prefill: Double)? in
            guard let match = line.firstMatch(of: pattern), Int(match.1) == done.request,
                  let ttft = Double(match.2), let prefill = Double(match.3) else { return nil }
            return (ttft, prefill)
        }.first
        let noLine = tr("metrics.log.noTiming")
        let ttft: Measured<String> = timing.map { .value(DeckFormat.latency(milliseconds: $0.ttft)) }
            ?? done.ttftSeconds.map { .value(DeckFormat.latency(milliseconds: $0 * 1000)) } ?? .unavailable(reason: noLine)
        var prefill: Measured<String> = .unavailable(reason: noLine)
        if let timing, timing.prefill > 0, let input = done.input {
            let fresh = input - (done.cached ?? 0)
            prefill = fresh > 0 ? .value(DeckFormat.tokensPerSecond(Double(fresh) * 1000 / timing.prefill))
                : .unavailable(reason: tr("metrics.log.allCached"))
        }
        return ReplyMetrics(ttft: ttft, prefill: prefill,
                            decode: done.tokensPerSecond.map { .value(DeckFormat.tokensPerSecond($0)) } ?? .unavailable(reason: noLine),
                            tokens: ReplyMetrics.tokens(prompt: done.input, completion: done.output, missing: noLine),
                            live: false, source: tr("metrics.source.log", String(done.request), done.clock))
    }

    func identity(_ server: ServerBoard.Server) -> [Fact] {
        let proc = Provenance(source: .system(name: "proc_pidinfo"))
        var facts = [
            Fact(title: tr("server.fact.pid"), value: .value(String(server.pid)), provenance: proc),
            Fact(title: tr("server.fact.version"), value: server.version.map { .value($0) } ?? .unavailable(reason: tr("reason.noReleaseFile")),
                 provenance: Provenance(source: .system(name: "release.json"))),
        ]
        if let found = server.found {
            facts.append(Fact(title: tr("server.fact.group"),
                              value: .value(found.group == found.pid ? tr("server.group.own") : tr("server.group.other", String(found.group))),
                              provenance: proc))
            facts.append(Fact(title: tr("server.fact.startedBy"), value: .value(found.startedBySplashApp ? tr("server.startedBy.splashApp")
                                                                                 : tr("server.startedBy.unknown")),
                              provenance: Provenance(source: .system(name: "KERN_PROCARGS2 · SPLASH_APP_PID"))))
        }
        if let owned = server.owned {
            facts.append(Fact(title: tr("server.fact.group"), value: .value(tr("server.group.own")), provenance: proc))
            facts.append(Fact(title: tr("server.fact.launched"), value: .value(DeckFormat.moment(owned.launched)),
                              provenance: Provenance(source: .system(name: "servers.json"))))
            if let ready = server.readySince {
                facts.append(Fact(title: tr("server.fact.loadedIn"),
                                  value: .value(DeckFormat.latency(milliseconds: ready.timeIntervalSince(owned.launched) * 1000)),
                                  provenance: Provenance(source: .system(name: "serve-\(server.port).json"))))
            }
        }
        if let detail = server.reading?.detail {
            if let served = server.track?.servedModels {
                facts.append(Fact(title: tr("server.fact.served"), value: .value(served.joined(separator: ", ")),
                                  provenance: Provenance(flag: "--served-model-name", source: .system(name: "GET /v1/models"))))
            }
            facts.append(Fact(title: tr("server.fact.pressure"), value: text(detail.memoryPressure.map(SystemAdapter.pressureWord), field: "memory_pressure"),
                              provenance: Provenance(source: .status(field: "memory_pressure"))))
            facts.append(Fact(title: tr("server.fact.thermal"), value: text(detail.thermalState.map(SystemAdapter.thermalWord), field: "thermal_state"),
                              provenance: Provenance(source: .status(field: "thermal_state"))))
        }
        return facts
    }

    func traffic(_ reading: ServerReading?) -> [Fact] {
        guard let detail = reading?.detail else { return [] }
        func fact(_ title: String, _ field: String, _ value: String?) -> Fact {
            Fact(title: title, value: value.map { .value($0) } ?? .unavailable(reason: tr("reason.notReportedField", field)),
                 provenance: Provenance(source: .status(field: field)))
        }
        let sampled = (detail.requests?.completed ?? 0) > 0
        let metrics = sampled ? detail.metrics : nil
        func mean(_ title: String, _ field: String, _ value: String?) -> Fact {
            sampled ? fact(title, field, value)
                : Fact(title: title, value: .unavailable(reason: tr("reason.noCompletedRequest")), provenance: Provenance(source: .status(field: field)))
        }
        return [
            mean(tr("server.fact.decodeMean"), "metrics.decode_tokens_per_second", metrics?.decodeTokensPerSecond.map { DeckFormat.tokensPerSecond($0) }),
            mean(tr("server.fact.prefillMean"), "metrics.prefill_tokens_per_second", metrics?.prefillTokensPerSecond.map { DeckFormat.tokensPerSecond($0) }),
            mean(tr("figure.ttftMedian"), "metrics.ttft_ms.p50", metrics?.ttftMedianMilliseconds.map { DeckFormat.latency(milliseconds: $0) }),
            mean(tr("server.fact.draftAccepted"), "metrics.draft_acceptance_rate", metrics?.draftAcceptanceRate.map { DeckFormat.percent($0) }),
            fact(tr("card.requestsServed"), "requests.completed", detail.requests?.completed.map { DeckFormat.count($0) }),
            fact(tr("server.fact.failed"), "requests.failed", detail.requests?.failed.map { DeckFormat.count($0) }),
        ]
    }

    func weights(_ server: ServerBoard.Server) -> [Fact] {
        guard let weights = server.reading?.snapshot.weights else {
            return server.alive ? [] : [Fact(title: tr("server.fact.restoreCost"), value: actions.restoreCost(server))]
        }
        let state = weights.restoring == true ? tr("server.weights.restoring")
            : weights.released == true ? tr("server.weights.released") : tr("server.weights.loaded")
        var facts = [
            Fact(title: tr("server.fact.weights"), value: .value(state), provenance: Provenance(source: .status(field: "weights.released"))),
            Fact(title: FlagLabels.title(for: "--idle-release") ?? "--idle-release",
                 value: weights.idleReleaseSeconds.map { .value($0 > 0 ? DeckFormat.duration(seconds: $0) : tr("parameter.word.off")) }
                    ?? .unavailable(reason: tr("reason.notReportedField", "weights.idle_release_seconds")),
                 provenance: Provenance(flag: "--idle-release", source: .status(field: "weights.idle_release_seconds"))),
            Fact(title: tr("server.fact.restores"), value: weights.restores.map { .value(DeckFormat.count($0)) }
                    ?? .unavailable(reason: tr("reason.notReportedField", "weights.restores")),
                 provenance: Provenance(source: .status(field: "weights.restores"))),
        ]
        if let failures = server.reading?.detail.restoreFailures {
            facts.append(Fact(title: tr("server.fact.restoreFailures"), value: .value(DeckFormat.count(failures)),
                              provenance: Provenance(source: .status(field: "weights.restore_failures"))))
        }
        facts.append(Fact(title: tr("server.fact.restoreCost"), value: actions.restoreCost(server)))
        return facts
    }

    func cache(_ reading: ServerReading?) -> [Fact] {
        guard let disk = reading?.detail.disk else { return [] }
        func bytes(_ title: String, _ field: String, _ value: Int64?) -> Fact {
            Fact(title: title, value: value.map { .value(DeckFormat.disk($0)) } ?? .unavailable(reason: tr("reason.notReportedField", field)),
                 provenance: Provenance(source: .status(field: field)))
        }
        var facts = [
            bytes(tr("server.fact.cacheLimit"), "disk.limit_bytes", disk.limitBytes),
            bytes(tr("server.fact.cacheUsed"), "disk.used_bytes", disk.usedBytes),
            bytes(tr("server.fact.cacheWritten"), "disk.written_last_day_bytes", disk.writtenLastDayBytes),
            bytes(tr("server.fact.cacheTakenBack"), "disk.taken_back.bytes", disk.takenBackBytes),
            Fact(title: FlagLabels.title(for: "--persistent-cache") ?? "--persistent-cache",
                 value: disk.persistent.map { .value($0 ? tr("value.on") : tr("value.off")) }
                    ?? .unavailable(reason: tr("reason.notReportedField", "disk.persistent")),
                 provenance: Provenance(flag: "--persistent-cache", source: .status(field: "disk.persistent"))),
        ]
        if let reason = disk.offReason {
            facts.append(Fact(title: tr("server.fact.cacheOff"), value: .value(reason), provenance: Provenance(source: .status(field: "disk.off_reason"))))
        }
        return facts
    }

    func text(_ value: String?, field: String) -> Measured<String> {
        value.map { .value($0) } ?? .unavailable(reason: tr("reason.notReportedField", field))
    }

    func log(_ server: ServerBoard.Server) -> SectionState<ServerLog> {
        guard let owned = server.owned else { return .unavailable(reason: tr("reason.logOutside")) }
        guard let lines = SplashLog.tail(URL(filePath: owned.log)) else { return .unavailable(reason: tr("reason.logUnreadable", owned.log)) }
        return .available(ServerLog(lines: lines, path: owned.log))
    }

    func history(_ log: SectionState<ServerLog>) -> SectionState<[LogRequest]> {
        switch log {
        case let .unavailable(reason): return .unavailable(reason: reason)
        case let .available(log):
            return .available(log.lines.enumerated().compactMap { index, line in
                SplashLog.request(line).map { request in
                    LogRequest(index: index, kind: request.kind == .done ? .done : .started, clock: request.clock, request: request.request,
                               input: request.input, cached: request.cached, output: request.output, ttftSeconds: request.ttftSeconds,
                               tokensPerSecond: request.tokensPerSecond, tokensPerCycle: request.tokensPerCycle)
                }
            })
        }
    }

    func bench(_ label: String) -> SectionState<BenchSummary> {
        _ = actions.benchRevision
        let rows = actions.benchStore.entries(for: label).map { result in
            BenchRow(at: result.at, ttftMilliseconds: result.median.ttftMilliseconds, decodeTokensPerSecond: result.median.decodeTokensPerSecond,
                     completionTokens: result.median.completionTokens, warmupTTFTMilliseconds: result.warmupTTFTMilliseconds,
                     peakFootprintBytes: result.peakFootprintBytes.map { Int64($0) }, runs: result.runs.count)
        }
        return .available(BenchSummary(results: rows, running: actions.benchRunning.contains(label), failure: actions.benchFailures[label],
                                       method: tr("bench.method", DeckFormat.count(Bench.warmupTokens), DeckFormat.count(Bench.runs),
                                                  DeckFormat.count(Bench.maxTokens))))
    }

    private static var routes: [String: [ServerRoute]?] = [:]

    static func endpoints(root: URL, version: String?) -> ServerEndpoints? {
        let key = root.standardizedFileURL.path
        if routes[key] == nil { routes[key] = .some(ServerRoutes.read(root: root)) }
        guard let list = routes[key] ?? nil else { return nil }
        let source = "\(ServerRoutes.file) · ROUTES" + (version.map { " · Splash \($0)" } ?? "")
        return ServerEndpoints(routes: list.map { .init(method: $0.method, path: $0.path, pattern: $0.pattern, open: $0.open) },
                               provenance: Provenance(source: .file(name: source)))
    }

    func configurationFacts(_ server: ServerBoard.Server) -> [Fact] {
        if let owned = server.owned {
            return Self.flagFacts(owned.serveArguments, provenance: { Provenance(flag: $0, source: .configuration(name: owned.configuration)) })
        }
        guard let arguments = ProcessArguments.read(server.pid)?.argv else { return [] }
        let start = arguments.firstIndex(of: "server.server").map { $0 + 2 } ?? arguments.count
        let launcherOwned: Set<String> = ["--binary", "--serve-record"]
        let flags = Array(arguments.dropFirst(min(start, arguments.count)))
        return Self.flagFacts(flags, provenance: { Provenance(flag: $0, source: .commandLine) }).filter { !launcherOwned.contains($0.provenance?.flag ?? "") }
    }

    func configurationSource(_ server: ServerBoard.Server) -> String {
        if let owned = server.owned { return tr("inspector.sourceOwned", owned.configuration, server.version ?? tr("value.unavailable")) }
        return tr("inspector.sourceOutside", String(server.pid), server.version ?? tr("value.unavailable"))
    }

    static func flagFacts(_ arguments: [String], provenance: (String) -> Provenance) -> [Fact] {
        var order: [String] = []
        var values: [String: [String]] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { index += 1; continue }
            var flag = argument
            var value: String?
            if let equals = argument.firstIndex(of: "=") {
                flag = String(argument[..<equals])
                value = String(argument[argument.index(after: equals)...])
            } else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                value = arguments[index + 1]
                index += 1
            }
            if flag == "--api-key" { value = "•••" }
            if values[flag] == nil { order.append(flag) }
            values[flag, default: []].append(value ?? tr("value.on"))
            index += 1
        }
        return order.map { flag in
            Fact(title: FlagLabels.title(for: flag) ?? flag, value: .value(values[flag, default: []].joined(separator: ", ")),
                 provenance: provenance(flag))
        }
    }

    func detail(_ configuration: Configuration) -> ServerDetail {
        let stopped = tr("reason.serverStopped")
        let folder = ServerSupervisor.defaultLogs.appending(path: configuration.name)
        let last = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }.max { $0.lastPathComponent < $1.lastPathComponent }
        let logState: SectionState<ServerLog> = last.flatMap { file in SplashLog.tail(file).map { .available(ServerLog(lines: $0, path: file.path)) } }
            ?? .unavailable(reason: tr("reason.neverStarted"))
        var parameters: [String] = []
        for (flag, value) in configuration.parameters.sorted(by: { $0.key < $1.key }) {
            switch value {
            case .on: parameters.append(flag)
            case let .value(text): parameters += [flag, text]
            case let .values(list): for item in list { parameters += [flag, item] }
            }
        }
        let modelFlag = configuration.isLocal ? ["--model-dir", configuration.model] + (configuration.apiModelID.map { ["--model", $0] } ?? [])
            : ["--model", configuration.model]
        let facts = Self.flagFacts(modelFlag + ["--port", String(configuration.port)] + parameters,
                                   provenance: { Provenance(flag: $0, source: .configuration(name: configuration.name)) })
        let restore = SplashLog.lastRestore(in: folder).map {
            Measured<String>.value(tr("restore.fromLog", DeckFormat.latency(milliseconds: $0.seconds * 1000), $0.clock))
        } ?? .unavailable(reason: tr("restore.never"))
        return ServerDetail(
            id: ServerActions.itemID(configuration: configuration.name), name: configuration.name,
            model: OverviewAdapter.modelTitle(configuration), port: configuration.port, status: .stopped,
            statusDetail: ServerActions.waitingReason(configuration),
            foundOutside: false, readySince: nil,
            identity: [Fact(title: tr("server.fact.version"), value: configuration.splashVersion.map { .value($0) } ?? .unavailable(reason: tr("reason.noVersion")),
                            provenance: Provenance(source: .configuration(name: configuration.name)))],
            memory: nil, memorySeries: nil, decodeSeries: nil, traffic: [],
            weights: [Fact(title: tr("server.fact.restoreCost"), value: restore)], cache: [],
            requests: .unavailable(reason: stopped), history: history(logState), log: logState,
            bench: bench(configuration.name), configuration: facts,
            configurationSource: tr("inspector.sourceConfiguration", configuration.name),
            family: LoadAdapter.family(of: configuration, shelf: AppServices.shared.library.shelf),
            endpoints: configuration.installation(among: model.installations).flatMap { Self.endpoints(root: $0.root, version: $0.version) })
    }
}
