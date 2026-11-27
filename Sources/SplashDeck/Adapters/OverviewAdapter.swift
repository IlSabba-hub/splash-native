import DeckCore
import DeckUI
import Foundation
import SwiftUI

@MainActor
struct OverviewAdapter {
    let board: ServerBoard
    var model: DeckModel { board.model }

    var principals: SectionState<[PrincipalSummary]> {
        guard board.prepared else { return .unavailable(reason: tr("reason.reading")) }
        if let error = board.configurationsError { return .unavailable(reason: error) }
        return .available(model.principals.map(principal))
    }

    func principal(_ configuration: Configuration) -> PrincipalSummary {
        let server = board.server(for: configuration)
        let reading = server?.reading
        let status = server?.status ?? (.stopped, ServerActions.waitingReason(configuration) == nil ? nil : tr("files.waiting"))
        let track = server?.track
        return PrincipalSummary(
            id: configuration.name, name: configuration.name, model: Self.modelName(configuration), draft: Self.draftName(configuration),
            port: server?.port ?? configuration.port, status: status.kind, statusDetail: status.detail,
            foundOutside: server.map { !$0.managed } ?? false, readySince: server?.readySince,
            badges: badges(configuration, reading: reading, served: track?.servedModels),
            facts: facts(configuration, reading: reading, server: server),
            memory: reading.map(Self.memoryReading),
            memorySeries: track.map { series($0.memory) },
            decodeSeries: track.map { series($0.decode) },
            lastBench: ServerFacts.lastBench(configuration: configuration.name))
    }

    static func modelTitle(_ configuration: Configuration) -> String {
        let model = modelName(configuration)
        if let draft = draftName(configuration) { return tr("card.modelWithDraft", model, draft) }
        return model
    }

    static func modelName(_ configuration: Configuration) -> String {
        configuration.apiModelID ?? (configuration.isLocal ? URL(filePath: configuration.model).lastPathComponent : configuration.model)
    }

    static func draftName(_ configuration: Configuration) -> String? {
        guard case let .value(draft)? = configuration.parameters["--draft-model"] else { return nil }
        return URL(filePath: draft).lastPathComponent
    }

    func badges(_ configuration: Configuration, reading: ServerReading?, served: [String]?) -> [PrincipalBadge] {
        var badges: [PrincipalBadge] = []
        if let hermes = board.hermes, let port = hermes.localPort, let wanted = hermes.model, port == configuration.port,
           Self.servedNames(configuration, served: served).contains(wanted) {
            badges.append(.usedByHermes)
        }
        if (configuration.apiModelID ?? configuration.model).localizedCaseInsensitiveContains("uncensored") { badges.append(.uncensored) }
        if reading?.detail.vision == true { badges.append(.vision) }
        return badges
    }

    static func servedNames(_ configuration: Configuration, served: [String]?) -> [String] {
        if let served { return served }
        var names = [configuration.apiModelID ?? configuration.model]
        switch configuration.parameters["--served-model-name"] {
        case let .value(name)?: names.append(name)
        case let .values(list)?: names += list
        default: break
        }
        return names
    }

    func facts(_ configuration: Configuration, reading: ServerReading?, server: ServerBoard.Server?) -> [Fact] {
        let sourceName = configuration.name
        let schema = configuration.installation(among: model.installations).flatMap { model.schemas[$0.id] }
        let version = schema?.installation.version ?? configuration.splashVersion ?? ""
        func configured(_ flag: String) -> Fact? {
            let title = FlagLabels.title(for: flag) ?? flag
            if let value = configuration.parameters[flag] {
                return Fact(title: title, value: .value(ServerFacts.text(value, flag: flag)),
                            provenance: Provenance(flag: flag, source: .configuration(name: sourceName)))
            }
            if let word = schema?.serve.parameter(flag).flatMap(ServerFacts.defaultWord) {
                return Fact(title: title, value: .value(word), provenance: Provenance(flag: flag, source: .splashDefault(version: version)))
            }
            return nil
        }
        func live(_ flag: String, field: String, _ value: String?) -> Fact? {
            guard let value else { return configured(flag) }
            return Fact(title: FlagLabels.title(for: flag) ?? flag, value: .value(value),
                        provenance: Provenance(flag: flag, source: .status(field: field)))
        }
        let detail = reading?.detail
        let snapshot = reading?.snapshot
        var facts: [Fact?] = [
            live("--max-context", field: "maximum_context_tokens", detail?.maximumContextTokens.map { DeckFormat.count($0) }),
            live("--kv-format", field: "identity.kv.format", detail?.kvFormat),
            configured("--draft-model"),
            live("--idle-release", field: "weights.idle_release_seconds",
                 snapshot?.weights?.idleReleaseSeconds.map { $0 > 0 ? DeckFormat.duration(seconds: $0) : tr("parameter.word.off") }),
            live("--max-memory", field: "memory_plan.budget.configured_memory_limit_bytes",
                 snapshot?.budget?.configuredMemoryLimitBytes.map { $0 > 0 ? DeckFormat.memory($0) : tr("parameter.word.auto") }),
            configured("--activations"),
            configured("--verify-rows"),
        ]
        if let completed = detail?.requests?.completed {
            facts.append(Fact(title: tr("card.requestsServed"), value: .value(DeckFormat.count(completed)),
                              provenance: Provenance(source: .status(field: "requests.completed"))))
        }
        return facts.compactMap { $0 }
    }

    static func memoryReading(_ reading: ServerReading) -> MemoryReading {
        let actual = reading.snapshot.memoryActual
        let cap = reading.detail.governorLimitBytes ?? reading.snapshot.budget?.hardBudgetBytes
        return MemoryReading(current: ServerFacts.measured(actual?.currentBytes, field: "memory_actual.current_bytes"),
                             peak: ServerFacts.measured(actual?.peakBytes, field: "memory_actual.peak_bytes"),
                             cap: ServerFacts.measured(cap, field: "memory_governor.limit_bytes"))
    }

    func series(_ samples: [LiveSample]) -> TimeSeries {
        TimeSeries(samples: samples.map { .init(time: $0.at, value: $0.value) }, maximumGap: board.live.maximumGap,
                   window: samples.last.map { $0.at.addingTimeInterval(-board.live.window) ... $0.at })
    }

    var memory: SectionState<MemoryBreakdown> {
        guard let budget = model.budget else { return .unavailable(reason: tr("reason.metalBudget")) }
        guard board.prepared else { return .unavailable(reason: tr("reason.reading")) }
        var instances: [MemoryBreakdown.Instance] = []
        var counted: Set<Int32> = []
        for server in board.activeServers {
            guard let reading = server.reading, let measured = reading.snapshot.memoryActual?.currentBytes else { continue }
            let cap = reading.detail.governorLimitBytes ?? reading.snapshot.budget?.hardBudgetBytes ?? measured
            instances.append(.init(id: server.id, name: server.name, measured: measured, reservedUnused: max(0, cap - measured)))
            if let found = server.found { counted.formUnion([found.pid] + found.engines) }
        }
        let others = model.others.filter { !counted.contains($0.pid) && !counted.contains($0.parent) }
        return .available(MemoryBreakdown(
            budget: Int64(budget), budgetTitle: tr("memory.budgetMetal"),
            budgetProvenance: Provenance(source: .system(name: "MTLDevice.recommendedMaxWorkingSetSize")),
            instances: instances, others: .value(others.reduce(0) { $0 + Int64($1.charge) })))
    }

    var activeServers: SectionState<[ActiveServerSummary]> {
        guard board.prepared else { return .unavailable(reason: tr("reason.reading")) }
        return .available(board.activeServers.map(Self.summary))
    }

    static func summary(_ server: ServerBoard.Server) -> ActiveServerSummary {
        let status = server.status
        return ActiveServerSummary(
            id: server.id, name: server.name, port: server.port, status: status.kind, statusDetail: status.detail, managed: server.managed,
            version: server.version.map { .value($0) } ?? .unavailable(reason: tr("reason.noReleaseFile")),
            memory: server.reading.map { ServerFacts.measured($0.snapshot.memoryActual?.currentBytes, field: "memory_actual.current_bytes") }
                ?? .unavailable(reason: server.track?.failure ?? tr("reason.noStatusYet")),
            weightsReleased: server.reading?.snapshot.weights?.released == true)
    }

    var requests: SectionState<RequestsOverview> {
        guard board.prepared else { return .unavailable(reason: tr("reason.reading")) }
        var requests: [ActiveRequestSummary] = []
        var counts: [RequestCounts] = []
        for server in board.activeServers {
            guard let reading = server.reading else {
                let reason = server.track?.failure ?? tr("reason.noStatusYet")
                counts.append(RequestCounts(server: server.name, queued: .unavailable(reason: reason),
                                            completed: .unavailable(reason: reason), failed: .unavailable(reason: reason)))
                continue
            }
            requests += reading.detail.activeRequests.map { ServerFacts.request($0, server: server.name) }
            let notReported = tr("reason.notReported")
            counts.append(RequestCounts(
                server: server.name,
                queued: reading.detail.scheduler?.queued.map { .value($0) } ?? .unavailable(reason: notReported),
                completed: reading.detail.requests?.completed.map { .value($0) } ?? .unavailable(reason: notReported),
                failed: reading.detail.requests?.failed.map { .value($0) } ?? .unavailable(reason: notReported)))
        }
        return .available(RequestsOverview(requests: requests, counts: counts))
    }

    var hermes: SectionState<HermesSummary> {
        guard board.hermesRead else { return .unavailable(reason: tr("reason.reading")) }
        guard let hermes = board.hermes else { return .unavailable(reason: tr("reason.hermesUnreadable")) }
        let file = "~/.hermes/config.yaml"
        let missing = tr("reason.hermesFieldMissing")
        let endpointField = "providers.\(hermes.provider ?? "<provider>").base_url"
        var serving: HermesSummary.Serving?
        if let url = hermes.baseURL, let wanted = hermes.model {
            if let port = hermes.localPort {
                if let server = board.activeServers.first(where: { $0.port == port }) {
                    if let served = server.track?.servedModels {
                        serving = served.contains(wanted) ? .servedBy(server: server.name) : .modelNotServed(server: server.name, served: served)
                    } else {
                        serving = .modelsUnknown(server: server.name, reason: server.track?.failure ?? tr("reason.noStatusYet"))
                    }
                } else {
                    serving = .nobodyOnPort(port: port)
                }
            } else if !url.isEmpty {
                serving = .notLocal
            }
        }
        return .available(HermesSummary(
            model: hermes.model.map { .value($0) } ?? .unavailable(reason: missing),
            endpoint: hermes.baseURL.map { .value($0) } ?? .unavailable(reason: missing),
            serving: serving,
            modelProvenance: Provenance(source: .system(name: "\(file) · model.default")),
            endpointProvenance: Provenance(source: .system(name: "\(file) · \(endpointField)"))))
    }
}

@MainActor
enum ServerFacts {
    static func measured(_ bytes: Int64?, field: String) -> Measured<Int64> {
        bytes.map { .value($0) } ?? .unavailable(reason: tr("reason.notReportedField", field))
    }

    static func text(_ value: DeckCore.ParameterValue, flag: String) -> String {
        switch value {
        case .on: return tr("value.on")
        case let .value(text):
            return text.hasPrefix("/") || text.hasPrefix("~/") ? URL(filePath: text).lastPathComponent : text
        case let .values(list): return list.joined(separator: ", ")
        }
    }

    static func defaultWord(_ parameter: ServeParameter) -> String? {
        if let text = parameter.parserDefault.text, !text.isEmpty { return text }
        guard let help = parameter.helpDefault else { return nil }
        let word = help.split(separator: ",", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return word?.isEmpty == false ? word : nil
    }

    static func request(_ request: StatusDetail.ActiveRequest, server: String) -> ActiveRequestSummary {
        ActiveRequestSummary(server: server, request: request.id, phase: .init(request.phase), promptProcessed: request.promptProcessed,
                             promptTokens: request.promptTokens, generated: request.generatedTokens, maximumNew: request.maxNewTokens,
                             ageSeconds: request.ageMilliseconds.map { $0 / 1000 })
    }

    static func lastBench(configuration: String) -> Measured<String> {
        guard let last = lastBenchResult(configuration) else { return .unavailable(reason: tr("reason.neverBenchmarked")) }
        let decode = last.median.decodeTokensPerSecond.map { DeckFormat.tokensPerSecond($0) } ?? tr("value.unavailable")
        return .value(tr("bench.summary", decode, DeckFormat.latency(milliseconds: last.median.ttftMilliseconds), DeckFormat.moment(last.at)))
    }

    @MainActor private static var benchCache: (revision: Int, last: [String: Bench.Result])?

    static func lastBenchResult(_ configuration: String) -> Bench.Result? {
        let actions = ServerActions.shared
        let revision = actions.benchRevision
        if let cache = benchCache, cache.revision == revision { return cache.last[configuration] }
        var last: [String: Bench.Result] = [:]
        for entry in actions.benchStore.entries() { last[entry.label] = entry }
        benchCache = (revision, last)
        return last[configuration]
    }
}
