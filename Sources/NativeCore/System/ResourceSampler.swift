import Foundation
import Observation

public struct SampleTarget: Sendable, Hashable, Identifiable {
    public let key: String
    public let label: String
    public let port: Int
    public let pid: Int32
    public let owned: Bool
    public let apiKey: String?
    public let server: ServerKey?
    public let version: String?
    public let configuration: String?

    public var id: String { key }

    public init(key: String, label: String, port: Int, pid: Int32, owned: Bool, apiKey: String? = nil, server: ServerKey? = nil,
                version: String? = nil, configuration: String? = nil) {
        self.version = version
        self.configuration = configuration
        self.key = key
        self.label = label
        self.port = port
        self.pid = pid
        self.owned = owned
        self.apiKey = apiKey
        self.server = server
    }
}

public struct ServerSample: Sendable, Equatable {
    public enum Reading: Sendable, Equatable {
        case status(ResourceStatus)
        case failed(String)
    }

    public let target: SampleTarget
    public let time: Date
    public let reading: Reading

    public var status: ResourceStatus? {
        if case let .status(status) = reading { status } else { nil }
    }
}

@MainActor @Observable
public final class ResourceSampler {
    public typealias Reader = @Sendable (_ target: SampleTarget, _ time: Date) async -> ServerSample

    public private(set) var servers: [String: ServerSample] = [:]
    public private(set) var system: SystemReading?
    public private(set) var gpuHistory: [(time: Date, utilization: Int?)] = []

    public let interval: Duration
    public let historyWindow: TimeInterval
    @ObservationIgnored public var onSample: (@MainActor (_ system: SystemReading, _ servers: [ServerSample]) -> Void)?
    @ObservationIgnored private let read: Reader

    public init(interval: Duration = .seconds(5), historyWindow: TimeInterval = 600, session: URLSession = .shared,
                read: Reader? = nil) {
        self.interval = interval
        self.historyWindow = historyWindow
        self.read = read ?? { target, time in await Self.fetch(target, at: time, session: session) }
    }

    public nonisolated static func fetch(_ target: SampleTarget, at time: Date, session: URLSession = .shared) async -> ServerSample {
        do {
            let status = try await StatusClient(port: target.port, apiKey: target.apiKey, session: session).resourceStatus()
            return ServerSample(target: target, time: time, reading: .status(status))
        } catch {
            return ServerSample(target: target, time: time, reading: .failed(error.localizedDescription))
        }
    }

    public func sample(_ targets: [SampleTarget], at time: Date = .now) async {
        let read = read
        let system = await Task.detached { SystemReading.read(at: time) }.value
        let samples = await withTaskGroup(of: ServerSample.self) { group in
            for target in targets {
                group.addTask { await read(target, time) }
            }
            var all: [ServerSample] = []
            for await sample in group { all.append(sample) }
            return all.sorted { $0.target.key < $1.target.key }
        }
        self.system = system
        servers = Dictionary(samples.map { ($0.target.key, $0) }, uniquingKeysWith: { $1 })
        gpuHistory.append((time, system.gpu.first?.deviceUtilization))
        gpuHistory.removeAll { time.timeIntervalSince($0.time) > historyWindow }
        onSample?(system, samples)
    }

    public func run(targets: @escaping @MainActor () -> [SampleTarget]) async {
        while !Task.isCancelled {
            await sample(targets())
            try? await Task.sleep(for: interval)
        }
    }
}

extension NativeModel {
    public var sampleTargets: [SampleTarget] {
        let owned = supervisor.alive.map {
            SampleTarget(key: $0.configuration, label: $0.configuration, port: $0.port, pid: $0.pid, owned: true, apiKey: apiKey(for: $0),
                         server: .owned($0.id), version: $0.version, configuration: $0.configuration)
        }
        let outside = found.map {
            SampleTarget(key: "\($0.model ?? "splash")@:\($0.port)", label: $0.model ?? "splash", port: $0.port, pid: $0.pid, owned: false,
                         server: .found(pid: $0.pid, started: $0.started), version: $0.version)
        }
        return owned + outside
    }
}
