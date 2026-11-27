import Foundation
import Observation

public enum ServerKey: Hashable, Sendable {
    case owned(UUID)
    case found(pid: Int32, started: Int)
}

public struct LiveSample: Sendable, Equatable {
    public let at: Date
    public let value: Double?

    public init(at: Date, value: Double?) {
        self.at = at
        self.value = value
    }
}

public struct LiveTrack: Sendable, Equatable {
    public var reading: ServerReading?
    public var failure: String?
    public var memory: [LiveSample] = []
    public var decode: [LiveSample] = []
    public var prefill: [LiveSample] = []
    public var ssdRead: [LiveSample] = []
    public var expertHit: [LiveSample] = []
    public var servedModels: [String]?
    public var observedRestore: (seconds: Double, at: Date)?
    var restoringSince: Date?

    public static func == (a: LiveTrack, b: LiveTrack) -> Bool {
        a.reading == b.reading && a.failure == b.failure && a.memory == b.memory && a.decode == b.decode && a.prefill == b.prefill
            && a.ssdRead == b.ssdRead && a.expertHit == b.expertHit && a.servedModels == b.servedModels && a.observedRestore?.seconds == b.observedRestore?.seconds
            && a.observedRestore?.at == b.observedRestore?.at
    }

    mutating func add(_ new: ServerReading, window: TimeInterval) {
        let previous = reading
        memory.append(LiveSample(at: new.at, value: new.snapshot.memoryActual?.currentBytes.map(Double.init)))
        decode.append(LiveSample(at: new.at, value: previous.flatMap { Self.decodeRate(from: $0, to: new) }))
        prefill.append(LiveSample(at: new.at, value: previous.flatMap { Self.prefillRate(from: $0, to: new) }))
        if !new.streaming.isEmpty || !ssdRead.isEmpty {
            ssdRead.append(LiveSample(at: new.at, value: previous.flatMap { Self.ssdReadRate(from: $0, to: new) }))
        }
        if new.streaming.experts != nil || !expertHit.isEmpty {
            expertHit.append(LiveSample(at: new.at, value: previous.flatMap { Self.expertHitRate(from: $0, to: new) }))
        }
        if new.snapshot.weights?.restoring == true {
            if restoringSince == nil { restoringSince = previous?.at ?? new.at }
        } else if let since = restoringSince {
            observedRestore = (new.at.timeIntervalSince(since), new.at)
            restoringSince = nil
        }
        reading = new
        failure = nil
        trim(before: new.at.addingTimeInterval(-window))
    }

    mutating func miss(at date: Date, failure text: String, window: TimeInterval) {
        memory.append(LiveSample(at: date, value: nil))
        decode.append(LiveSample(at: date, value: nil))
        prefill.append(LiveSample(at: date, value: nil))
        if !ssdRead.isEmpty { ssdRead.append(LiveSample(at: date, value: nil)) }
        if !expertHit.isEmpty { expertHit.append(LiveSample(at: date, value: nil)) }
        failure = text
        trim(before: date.addingTimeInterval(-window))
    }

    private mutating func trim(before limit: Date) {
        memory.removeAll { $0.at < limit }
        decode.removeAll { $0.at < limit }
        prefill.removeAll { $0.at < limit }
        ssdRead.removeAll { $0.at < limit }
        expertHit.removeAll { $0.at < limit }
    }

    static func ssdReadRate(from old: ServerReading, to new: ServerReading) -> Double? {
        let seconds = new.at.timeIntervalSince(old.at)
        guard seconds > 0, let then = old.streaming.readBytes, let now = new.streaming.readBytes, now >= then else { return nil }
        return Double(now - then) / seconds
    }

    static func expertHitRate(from old: ServerReading, to new: ServerReading) -> Double? {
        guard let then = old.streaming.expertCounts, let now = new.streaming.expertCounts else { return nil }
        let routed = now.routed - then.routed, read = now.read - then.read
        guard routed > 0, read >= 0, read <= routed else { return nil }
        return 1 - Double(read) / Double(routed)
    }

    static func prefillRate(from old: ServerReading, to new: ServerReading) -> Double? {
        let seconds = new.at.timeIntervalSince(old.at)
        guard seconds > 0 else { return nil }
        let after = Dictionary(new.detail.activeRequests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var tokens = 0
        var prefilling = false
        for request in old.detail.activeRequests where request.phase == "prefill" {
            guard let later = after[request.id], let then = request.promptProcessed, let now = later.promptProcessed else { continue }
            prefilling = true
            tokens += max(0, now - then)
        }
        return prefilling ? Double(tokens) / seconds : nil
    }

    static func decodeRate(from old: ServerReading, to new: ServerReading) -> Double? {
        let seconds = new.at.timeIntervalSince(old.at)
        guard seconds > 0 else { return nil }
        let before = Dictionary(old.detail.activeRequests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var tokens = 0
        var decoding = false
        for request in new.detail.activeRequests where request.phase == "decode" {
            guard let earlier = before[request.id], earlier.phase == "decode",
                  let now = request.generatedTokens, let then = earlier.generatedTokens else { continue }
            decoding = true
            tokens += max(0, now - then)
        }
        return decoding ? Double(tokens) / seconds : nil
    }
}

@MainActor @Observable
public final class LiveServers {
    public private(set) var tracks: [ServerKey: LiveTrack] = [:]
    public let window: TimeInterval
    public let interval: Duration
    public let processEvery: Int
    @ObservationIgnored private var round = 0

    public init(window: TimeInterval = 600, interval: Duration = .seconds(1), processEvery: Int = 5) {
        self.window = window
        self.interval = interval
        self.processEvery = processEvery
    }

    public func track(_ key: ServerKey) -> LiveTrack? { tracks[key] }

    public var maximumGap: TimeInterval {
        let components = interval.components
        return 2.5 * (Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    public func poll(_ model: DeckModel) async {
        if round % processEvery == 0 { await model.refreshProcesses() }
        round += 1
        var alive: Set<ServerKey> = []
        for server in model.supervisor.alive {
            let key = ServerKey.owned(server.id)
            alive.insert(key)
            let reading = await read(key, port: server.port, apiKey: model.apiKey(for: server))
            model.record(reading?.snapshot, for: server.id)
            model.recordMemoryPlan(reading, for: server)
        }
        for server in model.supervisor.owned where !alive.contains(.owned(server.id)) {
            model.recordRefusedMemoryPlan(server)
        }
        for server in model.found {
            let key = ServerKey.found(pid: server.pid, started: server.started)
            alive.insert(key)
            _ = await read(key, port: server.port, apiKey: nil)
        }
        for key in tracks.keys where !alive.contains(key) { tracks[key] = nil }
    }

    public func sample(_ target: SampleTarget) -> ServerSample? {
        guard let key = target.server, let track = tracks[key] else { return nil }
        if let failure = track.failure { return ServerSample(target: target, time: .now, reading: .failed(failure)) }
        guard let reading = track.reading, let resources = reading.resources else { return nil }
        return ServerSample(target: target, time: reading.at, reading: .status(resources))
    }

    public func run(_ model: DeckModel) async {
        while !Task.isCancelled {
            await poll(model)
            try? await Task.sleep(for: interval)
        }
    }

    private func read(_ key: ServerKey, port: Int, apiKey: String?) async -> ServerReading? {
        var track = tracks[key] ?? LiveTrack()
        let client = StatusClient(port: port, apiKey: apiKey)
        do {
            let reading = try await client.reading()
            track.add(reading, window: window)
            if track.servedModels == nil { track.servedModels = try? await client.servedModels() }
            tracks[key] = track
            return reading
        } catch {
            track.miss(at: .now, failure: error.localizedDescription, window: window)
            tracks[key] = track
            return nil
        }
    }
}

public enum ServeRecordFile {
    public static func readySince(pid: Int32, port: Int, records: URL) -> Date? {
        let file = records.appending(path: "serve-\(port).json")
        struct Record: Decodable { let pid: Int32; let phase: String }
        guard let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data),
              record.pid == pid, record.phase == "ready" || record.phase == "recovering" else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }
}
