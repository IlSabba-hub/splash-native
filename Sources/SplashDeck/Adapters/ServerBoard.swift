import DeckCore
import DeckUI
import Foundation
import Observation

@MainActor @Observable
final class ServerBoard {
    static let shared = ServerBoard()

    let model: DeckModel
    let live: LiveServers
    private(set) var hermes: HermesConfig?
    private(set) var hermesRead = false
    private(set) var prepared = false
    private(set) var configurationsError: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(model: DeckModel = DeckModel(budgetReader: MemoryGuard.metalBudget), live: LiveServers = LiveServers()) {
        self.model = model
        self.live = live
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await model.prepare()
            prepareConfigurations()
            Task { [model] in
                let used = Set(model.configurations.compactMap { $0.installation(among: model.installations) })
                for installation in used { _ = try? await model.schema(for: installation) }
            }
            var round = 0
            while !Task.isCancelled {
                await live.poll(model)
                round += 1
                if round % 5 == 0 {
                    readHermes()
                    model.refreshBudget()
                }
                try? await Task.sleep(for: live.interval)
            }
        }
    }

    func prepareConfigurations() {
        do {
            try model.reloadConfigurations()
            configurationsError = nil
        } catch {
            configurationsError = error.localizedDescription
        }
        readHermes()
        prepared = true
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func readHermes() {
        hermes = HermesConfig.read()
        hermesRead = true
    }

    struct Server: Identifiable, Sendable {
        enum Origin: Sendable {
            case owned(OwnedServer)
            case found(FoundServer)
        }

        let origin: Origin
        let key: ServerKey
        let configuration: Configuration?
        let track: LiveTrack?
        let phase: ServerPhase?

        var id: String {
            switch origin {
            case let .owned(server): server.id.uuidString
            case let .found(server): "found-\(server.pid)-\(server.started)"
            }
        }

        var managed: Bool { if case .owned = origin { true } else { false } }
        var owned: OwnedServer? { if case let .owned(server) = origin { server } else { nil } }
        var found: FoundServer? { if case let .found(server) = origin { server } else { nil } }

        var pid: Int32 {
            switch origin {
            case let .owned(server): server.pid
            case let .found(server): server.pid
            }
        }

        var port: Int {
            switch origin {
            case let .owned(server): server.port
            case let .found(server): server.port
            }
        }

        var version: String? {
            switch origin {
            case let .owned(server): server.version
            case let .found(server): server.version
            }
        }

        var root: URL {
            switch origin {
            case let .owned(server): URL(filePath: server.installationRoot)
            case let .found(server): server.root
            }
        }

        var name: String {
            if let configuration { return configuration.name }
            switch origin {
            case let .owned(server): return server.configuration
            case let .found(server): return server.model ?? DeckFormat.port(server.port)
            }
        }

        var alive: Bool {
            if case .exited = phase { return false }
            return true
        }

        var reading: ServerReading? { track?.reading }

        var status: (kind: StatusKind, detail: String?) {
            let ready = reading?.snapshot.ready == true && track?.failure == nil
            switch phase {
            case .preparing?:
                return (.starting, tr("status.preparing"))
            case let .recorded(record, warmup)?:
                switch record {
                case .starting: return (.starting, nil)
                case .loading: return (.starting, tr("status.loading"))
                case .warming:
                    return (.starting, warmup.map { tr("status.warming", DeckFormat.count($0.done), DeckFormat.count($0.steps)) })
                case .ready: return ready ? (.ready, nil) : (.error, tr("status.notResponding"))
                case .recovering: return (.starting, tr("status.recovering"))
                case .failed: return (.error, nil)
                case .unknown: return ready ? (.ready, nil) : (.starting, nil)
                }
            case let .exited(code, failure)?:
                if let failure { return (.error, failure.message) }
                if let code, code != 0 { return (.error, tr("status.exitCode", String(code))) }
                return (.stopped, nil)
            case .running?, nil:
                if ready { return (.ready, nil) }
                if track?.failure != nil, reading != nil { return (.error, tr("status.notResponding")) }
                return (.starting, nil)
            }
        }

        var readySince: Date? {
            guard alive else { return nil }
            let records = SplashInstallation(kind: .keg, root: root, version: version).serveRecords
            return ServeRecordFile.readySince(pid: pid, port: port, records: records)
        }

        var endpoint: String { "http://127.0.0.1:\(owned?.observedPort ?? port)/v1" }
    }

    var servers: [Server] {
        let owned = model.supervisor.owned.map { server in
            Server(origin: .owned(server), key: .owned(server.id),
                   configuration: model.configurations.first { $0.name == server.configuration },
                   track: live.track(.owned(server.id)), phase: model.supervisor.phase(of: server))
        }
        let found = model.found.map { server in
            Server(origin: .found(server), key: .found(pid: server.pid, started: server.started),
                   configuration: matchingConfiguration(server), track: live.track(.found(pid: server.pid, started: server.started)),
                   phase: nil)
        }
        return (owned + found).sorted { $0.port < $1.port }
    }

    var activeServers: [Server] { servers.filter(\.alive) }

    func matchingConfiguration(_ server: FoundServer) -> Configuration? {
        model.configurations.first { configuration in
            configuration.port == server.port && server.model != nil
                && (configuration.apiModelID == server.model || configuration.model == server.model)
        }
    }

    func server(for configuration: Configuration) -> Server? {
        activeServers.first { $0.managed && $0.owned?.configuration == configuration.name }
            ?? activeServers.first { !$0.managed && $0.configuration?.name == configuration.name }
    }
}
