import Darwin
import Foundation
import Metal

public enum MemoryGuard {
    public static func metalBudget() -> UInt64? {
        MTLCreateSystemDefaultDevice().map { $0.recommendedMaxWorkingSetSize }
    }

    public struct Reservation: Codable, Sendable, Equatable {
        public enum Source: String, Codable, Sendable {
            case measuredBudget
            case measuredPlan
            case forecast
            case forecastAtLeast
            case maxMemory
            case wholeBudget
        }

        public let label: String
        public let bytes: UInt64
        public let source: Source

        public init(label: String, bytes: UInt64, source: Source) {
            self.label = label
            self.bytes = bytes
            self.source = source
        }

        public static func planned(label: String, parsed: [String: JSONValue], budget: UInt64) -> Reservation {
            if let bytes = parsed["max_memory"]?.int, bytes > 0 {
                return Reservation(label: label, bytes: UInt64(bytes), source: .maxMemory)
            }
            return Reservation(label: label, bytes: budget, source: .wholeBudget)
        }

        public static func forecast(label: String, _ forecast: MemoryForecast) -> Reservation {
            Reservation(label: label, bytes: forecast.total.value, source: forecast.total.isExact ? .forecast : .forecastAtLeast)
        }

        public static func running(label: String, status: StatusSnapshot?, plan: SplashPlanReading? = nil, planned: Reservation) -> Reservation {
            if let plan, let peak = plan.peakBytes { return Reservation(label: label, bytes: peak, source: .measuredPlan) }
            if let bytes = status?.budget?.hardBudgetBytes, bytes > 0 {
                return Reservation(label: label, bytes: UInt64(bytes), source: .measuredBudget)
            }
            return planned
        }
    }

    public struct Verdict: Codable, Sendable, Equatable {
        public let budget: UInt64
        public let physical: UInt64
        public let running: [Reservation]
        public let others: [OtherProcess]
        public let requested: Reservation

        public var othersBytes: UInt64 { others.reduce(0) { $0 + $1.charge } }
        public var outsideSplashBytes: UInt64 { others.filter { $0.engine == .splash }.reduce(0) { $0 + $1.charge } }
        public var runningBytes: UInt64 { running.reduce(0) { $0 + $1.bytes } }
        public var room: MemoryRoom {
            MemoryRoom(metalBudget: budget, physical: physical, splashBytes: runningBytes + outsideSplashBytes,
                       othersBytes: othersBytes - outsideSplashBytes)
        }
        public var metalUsed: UInt64 { runningBytes + outsideSplashBytes + requested.bytes }
        public var unifiedUsed: UInt64 { runningBytes + othersBytes + requested.bytes + room.macOSReserve }
        public var total: UInt64 { metalUsed }
        public var fits: Bool { requested.bytes <= room.free }
        public var excess: UInt64 { requested.bytes > room.free ? requested.bytes - room.free : 0 }
    }

    public static func judge(budget: UInt64, physical: UInt64 = ProcessInfo.processInfo.physicalMemory, running: [Reservation],
                             others: [OtherProcess], requested: Reservation) -> Verdict {
        Verdict(budget: budget, physical: physical, running: running, others: others, requested: requested)
    }
}

public struct MemoryRoom: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable, Equatable { case fits, tight, doesNotFit }

    public let metalBudget: UInt64
    public let physical: UInt64
    public let splashBytes: UInt64
    public let othersBytes: UInt64

    public init(metalBudget: UInt64, physical: UInt64, splashBytes: UInt64, othersBytes: UInt64) {
        self.metalBudget = metalBudget
        self.physical = physical
        self.splashBytes = splashBytes
        self.othersBytes = othersBytes
    }

    static let rules = SplashMemoryRules.splash173

    public var metalMargin: UInt64 { Self.rules.workingSetMargin(recommended: metalBudget) }
    public var macOSReserve: UInt64 { physical / 100 * Self.rules.unwiredFloorPercent }
    public var tightMargin: UInt64 { Self.rules.hostSpareReserve(physical: physical) }

    public var metalFree: UInt64 {
        let used = metalMargin + splashBytes
        return metalBudget > used ? metalBudget - used : 0
    }

    public var unifiedFree: UInt64 {
        let used = macOSReserve + othersBytes + splashBytes
        return physical > used ? physical - used : 0
    }

    public var free: UInt64 { min(metalFree, unifiedFree) }
    public var limitedByUnifiedMemory: Bool { unifiedFree < metalFree }

    public func verdict(need: UInt64) -> Verdict {
        if need > free { return .doesNotFit }
        return free - need < tightMargin ? .tight : .fits
    }
}

public struct OtherProcess: Codable, Sendable, Equatable, Identifiable {
    public struct Weights: Codable, Sendable, Equatable {
        public let path: String
        public let mappedBytes: UInt64
        public let residentBytes: UInt64
        public var countedWith: Int32?
    }

    public let pid: Int32
    public let parent: Int32
    public let name: String
    public let command: String
    public let engine: KnownEngine?
    public let usage: ProcessFacts.Usage
    public var weights: [Weights]
    public var charge: UInt64
    public var rule: Rule
    public let ports: [Int]

    public var id: Int32 { pid }

    public enum Rule: String, Codable, Sendable {
        case footprint
        case peak
        case peakAndWeights
        case resident
    }
}

public enum OtherProcesses {
    public static let threshold: UInt64 = 1 << 30
    public static let weightsMinimum: UInt64 = 64 << 20

    public static func charge(_ usage: ProcessFacts.Usage, known: Bool, weights: UInt64) -> UInt64 {
        guard known else { return usage.footprint }
        return max(max(usage.footprint, usage.lifetimeMax) + weights, usage.resident)
    }

    public static func weightFiles(_ files: [ProcessFacts.MappedFile], home: String) -> [OtherProcess.Weights] {
        func library(_ path: String) -> Bool {
            [".dylib", ".so", ".metallib"].contains { path.hasSuffix($0) } || path.contains(".framework/")
                || ["/System/", "/usr/", "/private/var/folders/", "/Library/Caches/"].contains { path.hasPrefix($0) }
                || path.contains("/Library/Caches/")
        }
        return files.filter { $0.mappedBytes >= weightsMinimum && !library($0.path) }
            .map { OtherProcess.Weights(path: tilde($0.path, home: home), mappedBytes: $0.mappedBytes, residentBytes: $0.residentBytes) }
            .sorted { $0.path < $1.path }
    }

    public static func applyCharges(_ rows: inout [OtherProcess]) {
        var seen: [String: Int32] = [:]
        for index in rows.indices {
            var weights: UInt64 = 0
            for w in rows[index].weights.indices {
                let path = rows[index].weights[w].path
                rows[index].weights[w].countedWith = seen[path]
                if seen[path] == nil {
                    seen[path] = rows[index].pid
                    weights += rows[index].weights[w].mappedBytes
                }
            }
            let usage = rows[index].usage
            let known = rows[index].engine != nil
            rows[index].charge = charge(usage, known: known, weights: weights)
            rows[index].rule = !known ? .footprint
                : rows[index].charge == usage.resident && usage.resident > max(usage.footprint, usage.lifetimeMax) + weights ? .resident
                : weights > 0 ? .peakAndWeights : .peak
        }
    }

    public static func shortCommand(_ argv: [String], home: String) -> String {
        var masked = argv
        for index in masked.indices {
            if masked[index] == "--api-key", index + 1 < masked.count { masked[index + 1] = "•••" }
            if masked[index].hasPrefix("--api-key=") { masked[index] = "--api-key=•••" }
        }
        let parts = masked.enumerated().map { index, argument in
            let text = index == 0 ? URL(filePath: argument).lastPathComponent : tilde(argument, home: home)
            return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }
        let text = parts.joined(separator: " ")
        return text.count <= 160 ? text : String(text.prefix(159)) + "…"
    }

    static func tilde(_ path: String, home: String) -> String {
        home.isEmpty ? path : path.replacing(home, with: "~")
    }

    public static func scan(excluding excluded: Set<pid_t>, threshold: UInt64 = threshold) -> [OtherProcess] {
        let home = URL.homeDirectory.path
        let user = getuid()
        var rows: [OtherProcess] = []
        for pid in ProcessFacts.allPIDs() where !excluded.contains(pid) && pid != getpid() {
            guard let identity = ProcessFacts.identity(pid), identity.user == user,
                  let usage = ProcessFacts.usage(pid) else { continue }
            let heavy = usage.footprint >= threshold || usage.resident >= threshold
            let arguments = ProcessArguments.read(pid)
            let engine = arguments.flatMap { KnownEngine.recognize($0) }
            guard heavy || engine != nil else { continue }
            let weights = engine != nil ? weightFiles(ProcessFacts.mappedFiles(pid) ?? [], home: home) : []
            let name = engine.map(\.rawValue) ?? arguments.map { URL(filePath: $0.executable).lastPathComponent } ?? identity.name
            rows.append(OtherProcess(pid: pid, parent: identity.parent, name: name,
                                     command: shortCommand(arguments?.argv ?? [identity.name], home: home), engine: engine,
                                     usage: usage, weights: weights, charge: 0, rule: .footprint,
                                     ports: ProcessFacts.listeningPorts(pid)))
        }
        rows.sort { $0.usage.footprint != $1.usage.footprint ? $0.usage.footprint > $1.usage.footprint : $0.pid < $1.pid }
        applyCharges(&rows)
        return rows
    }

    public static func descendants(of roots: Set<pid_t>) -> Set<pid_t> {
        var children: [pid_t: [pid_t]] = [:]
        for pid in ProcessFacts.allPIDs() {
            if let parent = ProcessFacts.identity(pid)?.parent { children[parent, default: []].append(pid) }
        }
        var found = roots
        var queue = Array(roots)
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where !found.contains(child) {
                found.insert(child)
                queue.append(child)
            }
        }
        return found
    }
}

public struct ForcedStartLog: Sendable {
    public let file: URL

    public init(file: URL = URL.applicationSupportDirectory.appending(path: "SplashNative/forced-starts.jsonl")) {
        self.file = file
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let at: Date
        public let configuration: String
        public let budget: UInt64
        public let total: UInt64
        public let excess: UInt64
        public let requested: MemoryGuard.Reservation
        public let running: [MemoryGuard.Reservation]
        public let others: [Others]
        public var decision: Decision?
        public var physical: UInt64?
        public var unifiedUsed: UInt64?
        public var room: UInt64?

        public enum Decision: Codable, Sendable, Equatable {
            case forced
            case warned(StartAdmission.Policy)
        }

        public struct Others: Codable, Sendable, Equatable {
            public let pid: Int32
            public let name: String
            public let charge: UInt64
        }
    }

    public func record(_ verdict: MemoryGuard.Verdict, configuration: String, decision: Entry.Decision? = .forced,
                       at date: Date = .now) throws {
        let entry = Entry(at: date, configuration: configuration, budget: verdict.budget, total: verdict.total, excess: verdict.excess,
                          requested: verdict.requested, running: verdict.running,
                          others: verdict.others.map { .init(pid: $0.pid, name: $0.name, charge: $0.charge) }, decision: decision,
                          physical: verdict.physical, unifiedUsed: verdict.unifiedUsed, room: verdict.room.free)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(entry)
        line.append(0x0A)
        try JSONLines.append(line, to: file, synchronize: true)
    }

    public func entries() throws -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 0x0A).map { try decoder.decode(Entry.self, from: Data($0)) }
    }
}
