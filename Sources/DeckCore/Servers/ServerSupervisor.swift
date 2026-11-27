import Darwin
import Foundation
import Observation

public struct OwnedServer: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let pid: Int32
    public let started: Int
    public let port: Int
    public let configuration: String
    public let installationRoot: String
    public let version: String?
    public let serveArguments: [String]
    public let log: String
    public let launched: Date
    public var observedPort: Int? = nil
}

public struct FoundServer: Sendable, Equatable, Identifiable {
    public let pid: Int32
    public let started: Int
    public let group: Int32
    public let root: URL
    public let version: String?
    public let port: Int
    public let model: String?
    public let startedBySplashApp: Bool
    public let engines: [Int32]

    public var id: Int32 { pid }
}

public enum RecordPhase: String, Sendable, Equatable {
    case starting, loading, warming, ready, recovering, failed, unknown

    init(_ phase: ServeRecord.Phase) { self = RecordPhase(rawValue: phase.rawValue) ?? .unknown }
}

public struct StartFailure: Sendable, Equatable {
    public let kind: String
    public let message: String
    public let bound: String?
    public let requiredBytes: Int64?
    public let budgetBytes: Int64?
    public let planContextTokens: Int?

    init(_ failure: ServeRecord.Failure) {
        kind = failure.kind
        message = failure.message
        bound = failure.bound
        requiredBytes = failure.required_bytes
        budgetBytes = failure.budget_bytes
        planContextTokens = failure.plan_context_tokens
    }
}

public enum ServerPhase: Sendable, Equatable {
    case preparing
    case recorded(RecordPhase, warmup: (done: Int, steps: Int)?)
    case running
    case exited(code: Int32?, failure: StartFailure?)

    public static func == (a: ServerPhase, b: ServerPhase) -> Bool {
        switch (a, b) {
        case (.preparing, .preparing), (.running, .running): true
        case let (.recorded(x, w), .recorded(y, v)): x == y && w?.done == v?.done && w?.steps == v?.steps
        case let (.exited(c, f), .exited(d, g)): c == d && f == g
        default: false
        }
    }
}

public struct ServerRegistry: Sendable {
    public let file: URL

    public static let defaultFile = URL.applicationSupportDirectory.appending(path: "SplashDeck/servers.json")

    public init(file: URL = ServerRegistry.defaultFile) {
        self.file = file
    }

    public func load() -> [OwnedServer] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([OwnedServer].self, from: data)) ?? []
    }

    public func save(_ servers: [OwnedServer]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(servers).write(to: file, options: .atomic)
        let handle = try FileHandle(forUpdating: file)
        try handle.synchronize()
        try handle.close()
    }
}

public struct StopConsent: Sendable, Equatable {
    public let pid: Int32
    public let started: Int

    public init(confirmedFor server: FoundServer) {
        pid = server.pid
        started = server.started
    }
}

public struct StopReport: Sendable, Equatable {
    public let signal: Int32?
    public let stillAlive: Bool
    public let portFree: Bool
    public let seconds: Double
}

@MainActor @Observable
public final class ServerSupervisor {
    public private(set) var owned: [OwnedServer]
    public var alive: [OwnedServer] { owned.filter { processStart($0.pid) == $0.started } }
    public private(set) var exits: [UUID: Int32] = [:]
    @ObservationIgnored private let registry: ServerRegistry
    @ObservationIgnored private let logs: URL
    @ObservationIgnored private var watchers: [UUID: DispatchSourceProcess] = [:]

    public static let defaultLogs = URL.libraryDirectory.appending(path: "Logs/SplashDeck")

    public init(registry: ServerRegistry = ServerRegistry(), logs: URL = ServerSupervisor.defaultLogs) {
        self.registry = registry
        self.logs = logs
        owned = registry.load().filter { processStart($0.pid) == $0.started }
        for server in owned { watch(server) }
    }

    public func start(_ plan: LaunchPlan, environment: [String: String], admitted verdict: MemoryGuard.Verdict,
                      forced: Bool = false) throws -> OwnedServer {
        let port = plan.port
        if let holder = Self.holder(of: port) { throw DeckError.portBusy(port: port, pid: holder) }
        if portInUse(port) { throw DeckError.portBusy(port: port, pid: nil) }
        guard verdict.fits || forced else { throw DeckError.overBudget(excess: verdict.excess) }
        let stamp = ISO8601DateFormatter().string(from: .now).replacing(":", with: "-")
        let log = logs.appending(path: "\(plan.configuration.name)/\(stamp).log")
        let pid = try Spawn.start(plan.argv, environment: environment, log: log)
        guard let started = processStart(pid) else {
            Self.discard(pid)
            throw DeckError.vanished(pid: pid)
        }
        let server = OwnedServer(id: UUID(), pid: pid, started: started, port: port, configuration: plan.configuration.name,
                                 installationRoot: plan.installation.root.path, version: plan.installation.version,
                                 serveArguments: plan.serveArguments, log: log.path, launched: .now, observedPort: plan.observedPort)
        do {
            try registry.save(owned + [server])
        } catch {
            Self.discard(pid)
            throw error
        }
        owned.append(server)
        watch(server)
        return server
    }

    nonisolated static func discard(_ pid: pid_t) {
        kill(-pid, SIGKILL)
        DispatchQueue.global().async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
    }

    public func phase(of server: OwnedServer) -> ServerPhase {
        let installation = SplashInstallation(kind: .keg, root: URL(filePath: server.installationRoot), version: server.version)
        let record = installation.runtime.serveRecord(port: server.port)
        let own = record?.pid == server.pid ? record : nil
        guard processStart(server.pid) == server.started else {
            return .exited(code: exits[server.id], failure: own?.failure.map(StartFailure.init))
        }
        if let arguments = ProcessArguments.read(server.pid), case .launcher? = SplashRole.recognize(arguments) {
            return .preparing
        }
        guard let own else { return .running }
        return .recorded(RecordPhase(own.phase), warmup: own.warmup.map { ($0.steps_done, $0.steps) })
    }

    public func stop(_ server: OwnedServer) async -> StopReport {
        let report = await Self.stopGroup(pid: server.pid, started: server.started, leadsGroup: true, port: server.port)
        if !report.stillAlive {
            watchers[server.id]?.cancel()
            watchers[server.id] = nil
            owned.removeAll { $0.id == server.id }
            try? registry.save(owned)
        }
        return report
    }

    public func forget(_ server: OwnedServer) {
        guard processStart(server.pid) != server.started else { return }
        owned.removeAll { $0.id == server.id }
        exits[server.id] = nil
        try? registry.save(owned)
    }

    public func stop(_ server: FoundServer, consent: StopConsent) async throws -> StopReport {
        guard consent.pid == server.pid, consent.started == server.started else { throw DeckError.consentMismatch }
        return await Self.stopGroup(pid: server.pid, started: server.started, leadsGroup: server.group == server.pid, port: server.port)
    }

    nonisolated static func stopGroup(pid: Int32, started: Int, leadsGroup: Bool, port: Int) async -> StopReport {
        let begin = ContinuousClock.now
        guard processStart(pid) == started else {
            return StopReport(signal: nil, stillAlive: false, portFree: !portInUse(port), seconds: 0)
        }
        if leadsGroup {
            await stopProcessGroup(pid, with: SIGINT, killAfter: Supervision.stop * 2)
        } else {
            kill(pid, SIGINT)
            let deadline = ContinuousClock.now + Supervision.stop * 2
            while processStart(pid) == started, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if processStart(pid) == started { kill(pid, SIGKILL) }
        }
        let portDeadline = ContinuousClock.now + .seconds(5)
        while portInUse(port), ContinuousClock.now < portDeadline { try? await Task.sleep(for: .milliseconds(100)) }
        let elapsed = ContinuousClock.now - begin
        return StopReport(signal: SIGINT, stillAlive: processStart(pid) == started, portFree: !portInUse(port),
                          seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    nonisolated public static func holder(of port: Int) -> Int32? {
        ProcessFacts.allPIDs().first { pid in
            ProcessFacts.identity(pid)?.user == getuid() && ProcessFacts.listeningPorts(pid).contains(port)
        }
    }

    nonisolated public static func scan(excluding excluded: Set<Int32> = []) -> [FoundServer] {
        var servers: [(ProcessFacts.Identity, URL, Int, String?, Bool)] = []
        var engines: [(pid: Int32, parent: Int32)] = []
        for pid in ProcessFacts.allPIDs() where !excluded.contains(pid) {
            guard let identity = ProcessFacts.identity(pid), identity.user == getuid(),
                  let arguments = ProcessArguments.read(pid), let role = SplashRole.recognize(arguments) else { continue }
            switch role {
            case .server(let root, let port, let model, _):
                servers.append((identity, root, port, model, arguments.environmentNames.contains("SPLASH_APP_PID")))
            case .engine: engines.append((pid, identity.parent))
            case .launcher: break
            }
        }
        return servers.map { identity, root, port, model, app in
            FoundServer(pid: identity.pid, started: identity.started, group: identity.group, root: root,
                        version: ReleaseFile.version(in: root), port: port, model: model, startedBySplashApp: app,
                        engines: engines.filter { $0.parent == identity.pid }.map(\.pid))
        }.sorted { $0.port < $1.port }
    }

    private func watch(_ server: OwnedServer) {
        let source = DispatchSource.makeProcessSource(identifier: server.pid, eventMask: .exit, queue: .main)
        let id = server.id, pid = server.pid
        source.setEventHandler { [weak self] in
            source.cancel()
            var status: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, 0) } while reaped == -1 && errno == EINTR
            let code: Int32 = reaped != pid ? -1 : (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            MainActor.assumeIsolated {
                if reaped == pid { self?.exits[id] = code }
                self?.watchers[id] = nil
            }
        }
        watchers[server.id] = source
        source.resume()
    }
}
