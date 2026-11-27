import Foundation
import Observation

@MainActor @Observable
public final class NativeModel {
    public private(set) var installations: [SplashInstallation] = []
    public private(set) var schemas: [String: VersionSchema] = [:]
    public private(set) var configurations: [Configuration] = []
    public private(set) var found: [FoundServer] = []
    public private(set) var others: [OtherProcess] = []
    public private(set) var statuses: [UUID: StatusSnapshot] = [:]
    public private(set) var budget: UInt64?
    @ObservationIgnored let budgetReader: (@MainActor () -> UInt64?)?
    public let supervisor: ServerSupervisor
    public let observatory = Observatory()

    @ObservationIgnored public let locations: InstallationLocations
    @ObservationIgnored public let schemaStore: SchemaStore
    @ObservationIgnored public let store: ConfigurationStore
    @ObservationIgnored public let forcedLog: ForcedStartLog
    @ObservationIgnored public let calibrationStore: MemoryCalibrationStore
    @ObservationIgnored var recordedPlans: Set<UUID> = []
    @ObservationIgnored var calibrationCache: [String: MemoryCalibration]?
    @ObservationIgnored public internal(set) var livePlans: [UUID: SplashPlanReading] = [:]
    @ObservationIgnored var filePartsCache: [String: MemoryParts] = [:]
    public internal(set) var memoryProbe: String?
    @ObservationIgnored var shellSettings: [String: String] = [:]
    @ObservationIgnored private var apiKeys: [UUID: String?] = [:]

    public init(locations: InstallationLocations = InstallationLocations(), schemaStore: SchemaStore = SchemaStore(),
                store: ConfigurationStore = ConfigurationStore(), supervisor: ServerSupervisor = ServerSupervisor(),
                forcedLog: ForcedStartLog = ForcedStartLog(), budget: UInt64? = MemoryGuard.metalBudget(),
                budgetReader: (@MainActor () -> UInt64?)? = nil,
                calibrationStore: MemoryCalibrationStore = MemoryCalibrationStore()) {
        self.budgetReader = budgetReader
        self.locations = locations
        self.schemaStore = schemaStore
        self.store = store
        self.supervisor = supervisor
        self.forcedLog = forcedLog
        self.budget = budget
        self.calibrationStore = calibrationStore
    }

    @discardableResult
    public func refreshBudget() -> Bool {
        guard let budgetReader else { return false }
        let now = budgetReader()
        guard now != budget else { return false }
        budget = now
        return true
    }

    public var principals: [Configuration] { configurations.filter(\.principal) }

    public func prepare() async {
        refreshInstallations()
        try? reloadConfigurations()
        shellSettings = await Runtime.readShellSettings(Shell.login)
        await refreshProcesses()
        await resumeObservation()
    }

    public func resumeObservation() async {
        for server in supervisor.alive {
            guard let listen = server.observedPort, observatory.proxies[listen] == nil, !portInUse(listen) else { continue }
            _ = try? await observatory.open(listen: listen, upstream: server.port)
        }
    }

    public func refreshInstallations() {
        installations = InstallationScanner.scan(locations)
    }

    public func reloadConfigurations() throws {
        configurations = try store.load()
    }

    public func schema(for installation: SplashInstallation) async throws -> VersionSchema {
        if let cached = schemas[installation.id], cached.key == SchemaStore.key(for: installation) { return cached }
        let schema = try await schemaStore.schema(for: installation)
        schemas[installation.id] = schema
        return schema
    }

    public func save(_ configuration: Configuration, message: String) async throws {
        try await store.save(configuration, message: message)
        try reloadConfigurations()
    }

    public func remove(_ configuration: Configuration, message: String) async throws {
        try await store.remove(configuration.name, message: message)
        try reloadConfigurations()
    }

    public func family(of configuration: Configuration, in installation: SplashInstallation) -> String? {
        let runtime = installation.runtime
        if configuration.isLocal {
            let path = URL(filePath: expandTilde(configuration.model)).standardizedFileURL.path
            return runtime.preparedFamilies()[path]
        }
        return runtime.installedModels().first { $0.id == configuration.model }?.family
            ?? runtime.preparedFamilies()[configuration.model]
    }

    public func plan(for configuration: Configuration) async throws -> LaunchPlan {
        guard let installation = configuration.installation(among: installations) else {
            throw LaunchPlan.Problems(list: [.noInstallation(version: configuration.splashVersion)])
        }
        let schema = try await schema(for: installation)
        return try LaunchPlan.make(configuration, schema: schema, family: family(of: configuration, in: installation)).get()
    }

    public func runningReservations() async -> [MemoryGuard.Reservation] {
        guard let budget else { return [] }
        var reservations: [MemoryGuard.Reservation] = []
        for server in supervisor.alive {
            let installation = installations.first { $0.root.path == server.installationRoot }
            var planned = MemoryGuard.Reservation(label: server.configuration, bytes: budget, source: .wholeBudget)
            if livePlans[server.id] == nil, let installation,
               let verdict = try? await ParserVerdict.judge(server.serveArguments, with: installation) {
                planned = .planned(label: server.configuration, parsed: verdict.parsed, budget: budget)
            }
            reservations.append(.running(label: server.configuration, status: statuses[server.id], plan: livePlans[server.id], planned: planned))
        }
        return reservations
    }

    public struct Assessment: Sendable {
        public let plan: LaunchPlan
        public let parser: ParserVerdict
        public let memory: MemoryGuard.Verdict?
        public var neighbours: [StartAdmission.Neighbour] = []
        public var admission: StartAdmission.Decision?
    }

    public func assess(_ configuration: Configuration, apiKey: String? = nil) async throws -> Assessment {
        let plan = try await plan(for: configuration)
        let parser = try await plan.judge(apiKey: apiKey)
        await refreshProcesses()
        var memory: MemoryGuard.Verdict?
        if let budget {
            memory = MemoryGuard.judge(budget: budget, running: await runningReservations(), others: others,
                                       requested: requestedReservation(configuration, parsed: parser.parsed, budget: budget))
        }
        var assessment = Assessment(plan: plan, parser: parser, memory: memory)
        assessment.neighbours = await neighbours()
        assessment.admission = memory.map { StartAdmission.decide($0, neighbours: assessment.neighbours) }
        return assessment
    }

    public func neighbours() async -> [StartAdmission.Neighbour] {
        var list: [StartAdmission.Neighbour] = []
        for server in supervisor.alive {
            if let (limit, source) = StartAdmission.Neighbour.limit(status: statuses[server.id], arguments: server.serveArguments) {
                list.append(.init(name: server.configuration, port: server.port, limitBytes: limit, source: source))
            }
        }
        for server in found {
            let status = try? await StatusClient(port: server.port).status()
            let arguments = ProcessArguments.read(server.pid)?.argv
            if let (limit, source) = StartAdmission.Neighbour.limit(status: status, arguments: arguments) {
                list.append(.init(name: server.model ?? String(server.port), port: server.port, limitBytes: limit, source: source))
            }
        }
        return list
    }

    @discardableResult
    public func start(_ assessment: Assessment, apiKey: String? = nil, force: Bool = false) async throws -> OwnedServer {
        if let probing = memoryProbe { throw NativeError.memoryProbeRunning(configuration: probing) }
        return try await startAdmitted(assessment, apiKey: apiKey, force: force)
    }

    func startAdmitted(_ assessment: Assessment, apiKey: String? = nil, force: Bool = false) async throws -> OwnedServer {
        guard assessment.parser.accepted else { throw NativeError.splash(assessment.parser.message ?? "") }
        guard let memory = assessment.memory else { throw NativeError.budgetUnknown }
        let admission = assessment.admission ?? StartAdmission.decide(memory, neighbours: assessment.neighbours)
        switch admission {
        case .admit:
            break
        case .warn:
            try forcedLog.record(memory, configuration: assessment.plan.configuration.name, decision: .warned(StartAdmission.current))
        case .block(let block):
            guard force else {
                if case .unlimitedNeighbours(let list) = block { throw NativeError.unlimitedNeighbours(names: list.map(\.name)) }
                throw NativeError.overBudget(excess: memory.excess)
            }
            try forcedLog.record(memory, configuration: assessment.plan.configuration.name, decision: .forced)
        }
        let environment = assessment.plan.environment(shellSettings: shellSettings, apiKey: apiKey)
        if let listen = assessment.plan.observedPort {
            closeOrphanedProxies()
            if let holder = ServerSupervisor.holder(of: listen) { throw NativeError.portBusy(port: listen, pid: holder) }
            try await observatory.open(listen: listen, upstream: assessment.plan.port)
        }
        let server: OwnedServer
        do {
            server = try supervisor.start(assessment.plan, environment: environment, admitted: memory, forced: force || admission != .admit)
        } catch {
            if let listen = assessment.plan.observedPort { observatory.close(listen: listen) }
            throw error
        }
        apiKeys[server.id] = .some(assessment.plan.configuration.usesAPIKey ? apiKey : nil)
        await refreshProcesses()
        return server
    }

    public func apiKey(for server: OwnedServer) -> String? {
        if let known = apiKeys[server.id] { return known }
        guard let configuration = configurations.first(where: { $0.name == server.configuration }) else { return nil }
        let key = configuration.usesAPIKey ? (try? APIKeys.read(configuration.name)) ?? nil : nil
        apiKeys[server.id] = .some(key?.isEmpty == false ? key : nil)
        return apiKeys[server.id] ?? nil
    }

    func remember(apiKey: String?, for server: OwnedServer) {
        apiKeys[server.id] = .some(apiKey)
    }

    public func stop(_ server: OwnedServer) async -> StopReport {
        let report = await supervisor.stop(server)
        if let listen = server.observedPort, !report.stillAlive { observatory.close(listen: listen) }
        statuses[server.id] = nil
        if !report.stillAlive { apiKeys[server.id] = nil }
        await refreshProcesses()
        return report
    }

    public func forget(_ server: OwnedServer) {
        supervisor.forget(server)
        apiKeys[server.id] = nil
        closeOrphanedProxies()
    }

    public func closeOrphanedProxies() {
        let alive = supervisor.alive
        let used = Set(alive.compactMap(\.observedPort))
        for server in supervisor.owned where !alive.contains(server) {
            if let listen = server.observedPort, !used.contains(listen) { observatory.close(listen: listen) }
        }
    }

    public func stop(_ server: FoundServer, consent: StopConsent) async throws -> StopReport {
        let report = try await supervisor.stop(server, consent: consent)
        await refreshProcesses()
        return report
    }

    public func refreshProcesses() async {
        let owned = Set(supervisor.owned.map(\.pid))
        let (servers, rows) = await Task.detached {
            let excluded = OtherProcesses.descendants(of: owned)
            return (ServerSupervisor.scan(excluding: excluded), OtherProcesses.scan(excluding: excluded))
        }.value
        found = servers
        others = rows
        closeOrphanedProxies()
    }

    public func record(_ status: StatusSnapshot?, for id: UUID) {
        statuses[id] = status
    }

    public func refreshStatuses() async {
        for server in supervisor.owned {
            statuses[server.id] = try? await StatusClient(port: server.port, apiKey: apiKey(for: server)).status()
        }
    }
}
