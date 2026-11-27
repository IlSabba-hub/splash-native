import Foundation

extension DeckModel {
    public func memoryFingerprint(_ configuration: Configuration) -> String? {
        guard let installation = configuration.installation(among: installations), let schema = schemas[installation.id],
              case .success(let plan) = LaunchPlan.make(configuration, schema: schema, family: family(of: configuration, in: installation))
        else { return nil }
        return MemoryCalibration.fingerprint(version: installation.version, arguments: plan.serveArguments)
    }

    func recordMemoryPlan(_ reading: ServerReading?, for server: OwnedServer) {
        if let plan = reading?.plan { livePlans[server.id] = plan }
        guard let reading, reading.snapshot.ready == true, let plan = reading.plan, !reading.expertsStreamed,
              !recordedPlans.contains(server.id) else { return }
        recordedPlans.insert(server.id)
        let log = (try? String(contentsOfFile: server.log, encoding: .utf8)).map(SplashStartLog.init(text:))
        let fingerprint = MemoryCalibration.fingerprint(version: server.version, arguments: server.serveArguments)
        _ = try? calibrationStore.record(fingerprint: fingerprint, reading: plan, log: log, streamed: false, port: server.port)
        calibrationCache = nil
    }

    func recordRefusedMemoryPlan(_ server: OwnedServer) {
        guard !recordedPlans.contains(server.id), processStart(server.pid) != server.started else { return }
        recordedPlans.insert(server.id)
        guard let text = try? String(contentsOfFile: server.log, encoding: .utf8) else { return }
        let log = SplashStartLog(text: text)
        guard log.refusalMaximum != nil, let plan = log.breakdown else { return }
        let fingerprint = MemoryCalibration.fingerprint(version: server.version, arguments: server.serveArguments)
        _ = try? calibrationStore.record(fingerprint: fingerprint, reading: plan, log: log, streamed: log.expertStoreMiB != nil,
                                         port: server.port)
        calibrationCache = nil
    }

    public var uncalibratedConfigurations: [Configuration] {
        configurations.filter { configuration in
            guard configuration.isLocal, FileManager.default.fileExists(atPath: expandTilde(configuration.model)),
                  let forecast = forecast(configuration) else { return false }
            return !forecast.parts.measured
        }
    }

    nonisolated static func freeProbePort() -> Int? {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard named == 0 else { return nil }
        let port = Int(UInt16(bigEndian: address.sin_port))
        return (1024...65535).contains(port) && !Configuration.reservedPorts.contains(port) ? port : nil
    }

    public func measureMemory(_ configuration: Configuration, port: Int? = nil, timeout: Duration = .seconds(240)) async throws -> MemoryCalibration {
        guard memoryProbe == nil else { throw DeckError.memoryProbeRunning(configuration: memoryProbe ?? configuration.name) }
        await refreshProcesses()
        guard supervisor.alive.isEmpty, found.isEmpty else { throw DeckError.memoryProbeBusy }
        guard let installation = configuration.installation(among: installations),
              let rules = SplashMemoryRules.of(version: installation.version),
              let geometry = FamilyGeometry.of(family: family(of: configuration, in: installation), rules: rules),
              let probePort = port ?? Self.freeProbePort()
        else { throw DeckError.memoryProbeUnknownModel }
        memoryProbe = configuration.name
        defer { memoryProbe = nil }
        var probe = configuration
        probe.port = probePort
        probe.observe = false
        probe.parameters["--max-context"] = .value(String(geometry.maximumContextTokens))
        probe.parameters["--max-memory"] = nil
        let fingerprint = try await fingerprint(of: probe)

        let whole = try await probeRun(probe)
        guard let wholePlan = whole.reading else { throw DeckError.splash(whole.failure ?? "") }
        _ = try calibrationStore.record(fingerprint: fingerprint, reading: wholePlan, log: whole.log, streamed: false, port: probe.splashPort)

        let schema = try await schema(for: installation)
        let experts = schema.families?.families[geometry.family]?.facts["experts"] == .bool(true)
        let setting = configuration.parameters["--expert-memory"]
        if experts, setting == nil || setting == .value("auto"), whole.log?.routedExpertsMiB != nil {
            let fixed = wholePlan.fixedRuntime - wholePlan.aneFfn - wholePlan.stateStaging
            let limit = (fixed + wholePlan.laneState + (1 << 30) + (1 << 20) - 1) >> 20
            var streamed = probe
            streamed.parameters["--max-memory"] = .value("\(limit)M")
            let run = try await probeRun(streamed)
            if let plan = run.reading, run.log?.expertStoreMiB != nil {
                _ = try calibrationStore.record(fingerprint: fingerprint, reading: plan, log: run.log, streamed: true, port: probe.splashPort)
            }
        }
        calibrationCache = nil
        guard let entry = calibrationStore.load()[fingerprint] else { throw DeckError.memoryProbeUnknownModel }
        return entry
    }

    private func fingerprint(of configuration: Configuration) async throws -> String {
        let plan = try await plan(for: configuration)
        return MemoryCalibration.fingerprint(version: plan.installation.version, arguments: plan.serveArguments)
    }

    private func probeRun(_ configuration: Configuration, timeout: Duration = .seconds(240)) async throws
        -> (reading: SplashPlanReading?, log: SplashStartLog?, failure: String?) {
        let server = try await startAdmitted(try await assess(configuration))
        recordedPlans.insert(server.id)
        let clock = ContinuousClock(), deadline = clock.now + timeout
        var result: (SplashPlanReading?, SplashStartLog?, String?) = (nil, nil, nil)
        while clock.now < deadline {
            if case .exited = supervisor.phase(of: server) {
                let log = (try? String(contentsOfFile: server.log, encoding: .utf8)).map(SplashStartLog.init(text:))
                result = (log?.breakdown, log, log?.refusalMaximum == nil ? DeckText.text("memory.probe.exited") : nil)
                break
            }
            if let data = try? await StatusClient(port: server.port, apiKey: apiKey(for: server)).get("/status"),
               let reading = try? ServerReading.decode(data), reading.snapshot.ready == true {
                let log = (try? String(contentsOfFile: server.log, encoding: .utf8)).map(SplashStartLog.init(text:))
                result = (reading.plan, log, nil)
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        _ = await stop(server)
        supervisor.forget(server)
        return result
    }
}
