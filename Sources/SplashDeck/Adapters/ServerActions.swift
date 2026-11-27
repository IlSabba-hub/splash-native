import AppKit
import DeckCore
import DeckUI
import Foundation
import Observation

@MainActor @Observable
final class ServerActions {
    static let shared = ServerActions(board: .shared)

    let board: ServerBoard
    var selection: String?
    private(set) var runningAtChoice: Set<String>?

    func choose(_ id: String?) {
        selection = id
        runningAtChoice = Set(board.activeServers.map(\.id))
    }

    func revisit(running: [String]) {
        guard let first = running.first else { return }
        if let selection, running.contains(selection) { return }
        if let runningAtChoice, runningAtChoice == Set(running) { return }
        selection = first
        runningAtChoice = nil
    }
    var tab: ServerTab = .log
    private(set) var notices: [String: ServerNotice] = [:]
    private(set) var pendingStarts: [String: DeckModel.Assessment] = [:]
    private(set) var benchRunning: Set<String> = []
    private(set) var benchFailures: [String: String] = [:]
    private(set) var benchRevision = 0
    @ObservationIgnored let benchStore: BenchStore

    init(board: ServerBoard, benchStore: BenchStore = BenchStore()) {
        self.board = board
        self.benchStore = benchStore
    }

    var model: DeckModel { board.model }

    static func itemID(configuration name: String) -> String { "configuration-\(name)" }

    func notice(for id: String) -> ServerNotice? { notices[id] }

    func clearNotice(_ id: String) {
        guard pendingStarts[id] == nil, notices[id]?.kind != .progress else { return }
        notices[id] = nil
    }

    func start(_ configuration: Configuration) {
        let id = Self.itemID(configuration: configuration.name)
        pendingStarts[id] = nil
        if configuration.usesAPIKey, Self.apiKey(configuration) == nil {
            notices[id] = ServerNotice(.failure, tr("reason.apiKeyNotPassed"))
            return
        }
        if let waiting = Self.waitingReason(configuration) {
            notices[id] = ServerNotice(.failure, waiting)
            return
        }
        notices[id] = ServerNotice(.progress, tr("notice.assessing", configuration.name))
        Task {
            do {
                let assessment = try await model.assess(configuration, apiKey: Self.apiKey(configuration))
                guard assessment.parser.accepted else {
                    notices[id] = ServerNotice(.failure, tr("notice.parserRejected", assessment.parser.message ?? ""))
                    return
                }
                guard let memory = assessment.memory, let admission = assessment.admission else {
                    notices[id] = ServerNotice(.failure, DeckError.budgetUnknown.localizedDescription)
                    return
                }
                switch admission {
                case .admit:
                    try await launch(assessment, id: id, force: false)
                case .warn(let excess):
                    try await launch(assessment, id: id, force: false,
                                     warning: tr("notice.startedOverBudget", DeckFormat.memory(Int64(excess)),
                                                 DeckFormat.memory(Int64(memory.total)), DeckFormat.memory(Int64(memory.budget))))
                case .block(.unlimitedNeighbours(let list)):
                    pendingStarts[id] = assessment
                    notices[id] = ServerNotice(.warning, DeckError.unlimitedNeighbours(
                        names: list.map { "\($0.name) \(DeckFormat.port($0.port))" }).localizedDescription)
                case .block(.overBudget):
                    pendingStarts[id] = assessment
                    notices[id] = ServerNotice(.warning, tr("notice.overBudget", DeckFormat.memory(Int64(memory.excess)),
                                                            DeckFormat.memory(Int64(memory.total)), DeckFormat.memory(Int64(memory.budget))))
                }
            } catch let problems as LaunchPlan.Problems {
                notices[id] = ServerNotice(.failure, problems.list.map(\.message).joined(separator: " "))
            } catch {
                notices[id] = ServerNotice(.failure, error.localizedDescription)
            }
        }
    }

    func confirmPendingStart(_ id: String) {
        guard let assessment = pendingStarts.removeValue(forKey: id) else { return }
        notices[id] = ServerNotice(.progress, tr("notice.starting", assessment.plan.configuration.name))
        Task {
            do {
                try await launch(assessment, id: id, force: true)
            } catch {
                notices[id] = ServerNotice(.failure, error.localizedDescription)
            }
        }
    }

    private func launch(_ assessment: DeckModel.Assessment, id: String, force: Bool, warning: String? = nil) async throws {
        let name = assessment.plan.configuration.name
        let server = try await model.start(assessment, apiKey: Self.apiKey(assessment.plan.configuration), force: force)
        var text = assessment.plan.dropped.isEmpty ? tr("notice.started", name, String(server.pid))
            : tr("notice.startedDropped", name, String(server.pid), assessment.plan.dropped.map(\.flag).joined(separator: ", "))
        if let warning { text += " " + warning }
        notices[id] = nil
        notices[server.id.uuidString] = ServerNotice(warning == nil ? .success : .warning, text)
        if selection == id { selection = server.id.uuidString }
    }

    func pendingAction(for id: String) -> DeckAction? {
        guard let assessment = pendingStarts[id] else { return nil }
        let name = assessment.plan.configuration.name
        return DeckAction(title: tr("action.startAnyway"), systemImage: "play.fill",
                          role: .destructive(question: tr("confirm.startAnywayQuestion", name),
                                             consequence: tr("confirm.startAnywayConsequence"), confirmTitle: tr("action.startAnyway"))) {
            [weak self] in self?.confirmPendingStart(id)
        }
    }

    func stop(_ server: ServerBoard.Server) {
        let id = server.id
        notices[id] = ServerNotice(.progress, tr("notice.stopping", server.name))
        Task {
            do {
                let report: StopReport
                if let owned = server.owned {
                    report = await model.stop(owned)
                } else if let found = server.found {
                    report = try await model.stop(found, consent: StopConsent(confirmedFor: found))
                } else {
                    return
                }
                let seconds = DeckFormat.latency(milliseconds: report.seconds * 1000)
                notices[id] = report.stillAlive ? ServerNotice(.failure, tr("notice.stillAlive", server.name))
                    : report.portFree ? ServerNotice(.success, tr("notice.stopped", server.name, seconds))
                    : ServerNotice(.warning, tr("notice.stoppedPortBusy", server.name, DeckFormat.port(server.port)))
                if let configuration = server.configuration, server.managed {
                    notices[Self.itemID(configuration: configuration.name)] = notices[id]
                    if selection == id { selection = Self.itemID(configuration: configuration.name) }
                }
            } catch {
                notices[id] = ServerNotice(.failure, error.localizedDescription)
            }
        }
    }

    func release(_ server: ServerBoard.Server) {
        let id = server.id
        notices[id] = ServerNotice(.progress, tr("notice.releasing", server.name))
        Task {
            do {
                let client = StatusClient(port: server.port, apiKey: server.owned.flatMap(model.apiKey(for:)))
                let outcome = try await client.releaseMemory()
                switch outcome {
                case .released:
                    let after = try? await client.reading()
                    let memory = after?.snapshot.memoryActual?.currentBytes.map { DeckFormat.memory($0) } ?? tr("value.unavailable")
                    notices[id] = ServerNotice(.success, tr("notice.released", memory, DeckFormat.clause(restoreCostText(server))))
                case let .busy(message):
                    notices[id] = ServerNotice(.warning, tr("notice.releaseBusy", message))
                case let .refused(status, code, message):
                    notices[id] = ServerNotice(.failure, tr("notice.releaseRefused", String(status), code ?? "", message ?? ""))
                }
            } catch {
                notices[id] = ServerNotice(.failure, error.localizedDescription)
            }
        }
    }

    func restoreCost(_ server: ServerBoard.Server) -> Measured<String> {
        if let name = server.configuration?.name ?? server.owned?.configuration,
           let last = SplashLog.lastRestore(in: ServerSupervisor.defaultLogs.appending(path: name)) {
            return .value(tr("restore.fromLog", DeckFormat.latency(milliseconds: last.seconds * 1000), last.clock))
        }
        if let observed = server.track?.observedRestore {
            return .value(tr("restore.observed", DeckFormat.latency(milliseconds: observed.seconds * 1000), DeckFormat.moment(observed.at)))
        }
        return .unavailable(reason: tr("restore.never"))
    }

    private func restoreCostText(_ server: ServerBoard.Server) -> String {
        switch restoreCost(server) {
        case let .value(text): text
        case let .unavailable(reason): reason
        }
    }

    func copyEndpoint(_ server: ServerBoard.Server) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.endpoint, forType: .string)
        notices[server.id] = ServerNotice(.success, tr("notice.copied", server.endpoint))
    }

    func forget(_ server: ServerBoard.Server) {
        guard let owned = server.owned else { return }
        model.forget(owned)
        notices[server.id] = nil
        if selection == server.id { selection = nil }
    }

    static func benchLabel(_ server: ServerBoard.Server) -> String {
        server.configuration?.name ?? server.owned?.configuration ?? server.name
    }

    func bench(_ server: ServerBoard.Server) {
        let label = Self.benchLabel(server)
        guard !benchRunning.contains(label) else { return }
        guard let model = server.track?.servedModels?.first ?? server.reading?.snapshot.instance?.model else {
            benchFailures[label] = tr("bench.noModel")
            return
        }
        benchRunning.insert(label)
        benchFailures[label] = nil
        let arguments = server.owned?.serveArguments ?? (ProcessArguments.read(server.pid)?.argv ?? [])
        let apiKey = server.owned.flatMap(self.model.apiKey(for:))
        let store = benchStore
        Task {
            defer { benchRunning.remove(label) }
            do {
                let result = try await Bench.run(port: server.port, model: model, pid: server.pid, label: label,
                                                 splashVersion: server.version, arguments: arguments, apiKey: apiKey)
                try store.append(result)
                benchRevision += 1
            } catch {
                benchFailures[label] = error.localizedDescription
            }
        }
    }

    func actions(for server: ServerBoard.Server, includeBench: Bool = false) -> [DeckAction] {
        guard server.alive else {
            var list: [DeckAction] = []
            if let configuration = server.configuration { list.append(startAction(configuration)) }
            if server.managed {
                list.append(DeckAction(title: tr("action.forget"), systemImage: "xmark.circle") { [weak self] in self?.forget(server) })
            }
            return list
        }
        let ready = server.status.kind == .ready
        var list = [stopAction(server)]
        let released = server.reading?.snapshot.weights?.released == true
        list.append(DeckAction(title: tr("action.release"), systemImage: "arrow.down.to.line", isEnabled: ready && !released,
                               disabledReason: released ? tr("reason.alreadyReleased") : ready ? nil : tr("reason.notReady")) {
            [weak self] in self?.release(server)
        })
        list.append(DeckAction(title: tr("action.copyEndpoint"), systemImage: "doc.on.doc") { [weak self] in self?.copyEndpoint(server) })
        return list
    }

    func stopAction(_ server: ServerBoard.Server) -> DeckAction {
        if server.managed {
            return DeckAction(title: tr("action.stop"), systemImage: "eject") { [weak self] in self?.stop(server) }
        }
        let hermes = board.hermes?.localPort == server.port
        return DeckAction(title: tr("action.stop"), systemImage: "eject",
                          role: .destructive(question: tr("confirm.stopOutsideQuestion", server.name),
                                             consequence: hermes ? tr("confirm.stopHermesConsequence", DeckFormat.port(server.port), String(server.pid))
                                                 : tr("confirm.stopOutsideConsequence"),
                                             confirmTitle: tr("action.stop"))) { [weak self] in self?.stop(server) }
    }

    static func apiKey(_ configuration: Configuration) -> String? {
        guard configuration.usesAPIKey, let key = (try? APIKeys.read(configuration.name)) ?? nil, !key.isEmpty else { return nil }
        return key
    }

    static func waitingReason(_ configuration: Configuration) -> String? {
        let missing = ConfigurationFiles.missing(configuration)
        guard !missing.isEmpty else { return nil }
        let list = missing.map { file in
            let path = ModelsAdapter.display(file.path)
            return file.partialBytes.map { tr("files.partial", path, DeckFormat.disk($0)) } ?? path
        }
        return tr("files.waiting.reason", list.joined(separator: "; "))
    }

    func startAction(_ configuration: Configuration) -> DeckAction {
        let reason = (configuration.usesAPIKey && Self.apiKey(configuration) == nil ? tr("reason.apiKeyNotPassed") : nil)
            ?? Self.waitingReason(configuration)
        guard let occupant = ModelPort.occupant(of: configuration, board: board) else {
            return DeckAction(title: tr("action.start"), systemImage: "play.fill", role: .primary, isEnabled: reason == nil,
                              disabledReason: reason) { [weak self] in self?.start(configuration) }
        }
        let (role, remember) = swapRole(configuration.name, occupant: occupant)
        return DeckAction(title: tr("action.start"), systemImage: "play.fill", role: role, isEnabled: reason == nil, disabledReason: reason,
                          remember: remember) { [weak self] in self?.swapStart(configuration, ejecting: occupant) }
    }

    func swapRole(_ name: String, occupant: ServerBoard.Server) -> (DeckAction.Role, DeckAction.Remember?) {
        let port = DeckFormat.port(occupant.port)
        let hermes = board.hermes?.localPort == occupant.port
        if occupant.managed {
            guard ModelPort.shared.asks else { return (.primary, nil) }
            return (.destructive(question: tr("swap.question", occupant.name, port, name),
                                 consequence: hermes ? tr("swap.consequence.hermes", port, name) : tr("swap.consequence"),
                                 confirmTitle: tr("swap.confirm")),
                    DeckAction.Remember(title: tr("swap.dontAsk")) { ModelPort.shared.stopAsking() })
        }
        return (.destructive(question: tr("swap.outside.question", port, String(occupant.pid), name),
                             consequence: hermes ? tr("confirm.stopHermesConsequence", port, String(occupant.pid)) : tr("confirm.stopOutsideConsequence"),
                             confirmTitle: tr("swap.confirm")), nil)
    }

    static func swapNote(_ occupant: ServerBoard.Server) -> String {
        tr(occupant.managed ? "swap.note" : "swap.note.outside", occupant.name, DeckFormat.port(occupant.port))
    }

    func swapStart(_ configuration: Configuration, ejecting occupant: ServerBoard.Server) {
        let id = Self.itemID(configuration: configuration.name)
        notices[id] = ServerNotice(.progress, tr("notice.swapping", occupant.name, configuration.name))
        Task {
            if let failure = await eject([occupant]) {
                notices[id] = failure
                return
            }
            start(configuration)
        }
    }

    func eject(_ servers: [ServerBoard.Server]) async -> ServerNotice? {
        for server in servers {
            let report: StopReport
            if let owned = server.owned {
                report = await model.stop(owned)
            } else if let found = server.found {
                do {
                    report = try await model.stop(found, consent: StopConsent(confirmedFor: found))
                } catch {
                    return ServerNotice(.failure, error.localizedDescription)
                }
            } else {
                continue
            }
            if report.stillAlive { return ServerNotice(.failure, tr("notice.stillAlive", server.name)) }
            if !report.portFree { return ServerNotice(.failure, tr("notice.stoppedPortBusy", server.name, DeckFormat.port(server.port))) }
        }
        return nil
    }

    func benchAction(for server: ServerBoard.Server?) -> DeckAction? {
        guard let server else { return nil }
        let label = Self.benchLabel(server)
        let ready = server.alive && server.status.kind == .ready
        let running = benchRunning.contains(label)
        return DeckAction(title: tr("action.bench"), systemImage: "speedometer", role: .primary, isEnabled: ready && !running,
                          disabledReason: running ? tr("bench.running") : ready ? nil : tr("reason.notReady")) {
            [weak self] in self?.bench(server)
        }
    }

}
