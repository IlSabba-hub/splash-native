import Foundation

public struct GuardEstimate: Sendable, Equatable {
    public let verdict: MemoryGuard.Verdict
    public let decision: StartAdmission.Decision
    public let forecast: MemoryForecast?

    public init(verdict: MemoryGuard.Verdict, decision: StartAdmission.Decision, forecast: MemoryForecast? = nil) {
        self.verdict = verdict
        self.decision = decision
        self.forecast = forecast
    }
}

extension MemoryGuard.Reservation {
    public static func planned(label: String, maxMemory text: String?, budget: UInt64) -> Self {
        if let text, let bytes = SizeText.bytes(text), bytes > 0 {
            return Self(label: label, bytes: bytes, source: .maxMemory)
        }
        return Self(label: label, bytes: budget, source: .wholeBudget)
    }
}

extension DeckModel {
    public func estimate(_ configuration: Configuration, replacing: Set<String> = [],
                         foundStatus: (FoundServer) -> StatusSnapshot?) -> GuardEstimate? {
        guard let budget else { return nil }
        let forecast = forecast(configuration)
        let requested = requestedReservation(configuration, parsed: nil, budget: budget)
        let alive = supervisor.alive.filter { $0.configuration != configuration.name && !replacing.contains($0.configuration) }
        let running = alive.map { server in
            let planned = MemoryGuard.Reservation.planned(
                label: server.configuration, maxMemory: ProcessArguments(executable: "", argv: server.serveArguments).value(of: "--max-memory"),
                budget: budget)
            return MemoryGuard.Reservation.running(label: server.configuration, status: statuses[server.id], plan: livePlans[server.id],
                                                   planned: planned)
        }
        let verdict = MemoryGuard.judge(budget: budget, running: running, others: others, requested: requested)
        var neighbours: [StartAdmission.Neighbour] = []
        for server in alive {
            if let (limit, source) = StartAdmission.Neighbour.limit(status: statuses[server.id], arguments: server.serveArguments) {
                neighbours.append(.init(name: server.configuration, port: server.port, limitBytes: limit, source: source))
            }
        }
        for server in found {
            if let (limit, source) = StartAdmission.Neighbour.limit(status: foundStatus(server), arguments: ProcessArguments.read(server.pid)?.argv) {
                neighbours.append(.init(name: server.model ?? String(server.port), port: server.port, limitBytes: limit, source: source))
            }
        }
        return GuardEstimate(verdict: verdict, decision: StartAdmission.decide(verdict, neighbours: neighbours), forecast: forecast)
    }
}
