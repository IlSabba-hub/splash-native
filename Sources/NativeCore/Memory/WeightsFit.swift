import Foundation

public struct WeightsFit: Sendable, Equatable {
    public typealias Verdict = MemoryRoom.Verdict

    public let weightsBytes: UInt64
    public let needIsLowerBound: Bool
    public let room: MemoryRoom
    public let loadedEstimated: Bool
    public let forecast: MemoryForecast?

    public init(weightsBytes: UInt64, needIsLowerBound: Bool = false, room: MemoryRoom, loadedEstimated: Bool = false,
                forecast: MemoryForecast? = nil) {
        self.weightsBytes = weightsBytes
        self.needIsLowerBound = needIsLowerBound
        self.room = room
        self.loadedEstimated = loadedEstimated
        self.forecast = forecast
    }

    public var budget: UInt64 { room.metalBudget }
    public var loadedBytes: UInt64 { room.splashBytes }
    public var othersBytes: UInt64 { room.othersBytes }
    public var headroom: UInt64 { room.tightMargin }
    public var freeBytes: UInt64 { room.free }

    public var verdict: Verdict {
        if case .exceeds = forecast?.verdict { return .doesNotFit }
        return room.verdict(need: weightsBytes)
    }
}

extension NativeModel {
    public func memoryRoom(replacing configuration: String? = nil,
                           physical: UInt64 = ProcessInfo.processInfo.physicalMemory) -> (room: MemoryRoom, estimated: Bool)? {
        memoryRoom(replacing: configuration.map { [$0] } ?? [], physical: physical)
    }

    public func memoryRoom(replacing configurations: Set<String>,
                           physical: UInt64 = ProcessInfo.processInfo.physicalMemory) -> (room: MemoryRoom, estimated: Bool)? {
        guard let budget else { return nil }
        var splash: UInt64 = 0
        var estimated = false
        for server in supervisor.alive where !configurations.contains(server.configuration) {
            let planned = MemoryGuard.Reservation.planned(
                label: server.configuration,
                maxMemory: ProcessArguments(executable: "", argv: server.serveArguments).value(of: "--max-memory"), budget: budget)
            let reservation = MemoryGuard.Reservation.running(label: server.configuration, status: statuses[server.id],
                                                              plan: livePlans[server.id], planned: planned)
            if reservation.source != .measuredPlan { estimated = true }
            splash += reservation.bytes
        }
        let outside = others.filter { $0.engine == .splash }.reduce(UInt64(0)) { $0 + $1.charge }
        let rest = others.reduce(UInt64(0)) { $0 + $1.charge } - outside
        return (MemoryRoom(metalBudget: budget, physical: physical, splashBytes: splash + outside, othersBytes: rest), estimated)
    }

    public func weightsFit(bytes: UInt64?, configuration: Configuration? = nil, replacing: String? = nil, alsoReplacing: Set<String> = [],
                           physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> WeightsFit? {
        let names = alsoReplacing.union((replacing ?? configuration?.name).map { [$0] } ?? [])
        guard let (room, estimated) = memoryRoom(replacing: names, physical: physicalMemory) else { return nil }
        if let configuration, let forecast = forecast(configuration, physical: physicalMemory) {
            return WeightsFit(weightsBytes: forecast.total.value, needIsLowerBound: !forecast.total.isExact, room: room,
                              loadedEstimated: estimated, forecast: forecast)
        }
        guard let bytes else { return nil }
        return WeightsFit(weightsBytes: bytes, needIsLowerBound: true, room: room, loadedEstimated: estimated)
    }
}
