import Foundation

public struct SplashPlanReading: Codable, Sendable, Equatable {
    public var hardBudget: UInt64
    public var configuredLimit: UInt64
    public var targetWeights: UInt64
    public var draftWeights: UInt64
    public var visionWeights: UInt64
    public var lanes: UInt64
    public var laneState: UInt64
    public var sharedPrefill: UInt64
    public var sharedDecode: UInt64
    public var streamedTable: UInt64
    public var aneFfn: UInt64
    public var stateStaging: UInt64
    public var hostHeldBack: UInt64
    public var fixedRuntime: UInt64
    public var kvPageBytes: UInt64
    public var kvCapacityTokens: UInt64
    public var kvCapacityBytes: UInt64 = 0
    public var windowFloorPages: UInt64
    public var kvExtentPages: UInt64?
    public var kvPageTokens: UInt64?
    public var slimPageBytes: UInt64?
    public var maximumContext: UInt64
    public var servedContext: UInt64?

    public init?(status data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = root["memory_plan"] as? [String: Any], let b = plan["budget"] as? [String: Any] else { return nil }
        func n(_ key: String) -> UInt64? { (b[key] as? NSNumber)?.uint64Value }
        guard let hard = n("hard_budget_bytes"), let target = n("target_weights_bytes"), let fixed = n("fixed_runtime_bytes") else { return nil }
        hardBudget = hard
        configuredLimit = n("configured_memory_limit_bytes") ?? 0
        targetWeights = target
        draftWeights = n("draft_weights_bytes") ?? 0
        visionWeights = n("vision_weights_bytes") ?? 0
        lanes = n("maximum_batch_width") ?? 4
        laneState = n("lane_state_bytes") ?? 0
        sharedPrefill = n("shared_prefill_bytes") ?? 0
        sharedDecode = n("shared_decode_bytes") ?? 0
        streamedTable = n("streamed_table_bytes") ?? 0
        aneFfn = n("ane_ffn_bytes") ?? 0
        stateStaging = n("state_staging_bytes") ?? 0
        hostHeldBack = n("host_held_back_bytes") ?? 0
        fixedRuntime = fixed
        kvPageBytes = n("kv_page_bytes") ?? 0
        kvCapacityTokens = n("kv_capacity_tokens") ?? 0
        kvCapacityBytes = n("kv_capacity_bytes") ?? 0
        windowFloorPages = ((b["kv_window"] as? [String: Any])?["floor_pages"] as? NSNumber)?.uint64Value ?? 0
        kvExtentPages = n("kv_extent_pages")
        kvPageTokens = n("kv_page_tokens")
        slimPageBytes = ((b["kv_window"] as? [String: Any])?["slim_page_bytes"] as? NSNumber)?.uint64Value
        maximumContext = (plan["maximum_context_tokens"] as? NSNumber)?.uint64Value
            ?? (root["maximum_context_tokens"] as? NSNumber)?.uint64Value ?? 0
        servedContext = (root["maximum_context_tokens"] as? NSNumber)?.uint64Value
    }

    public var peakBytes: UInt64? {
        guard let kv = Self.contextKVBytes(context: servedContext ?? maximumContext, pageTokens: kvPageTokens ?? 0, pageBytes: kvPageBytes,
                                           extentPages: kvExtentPages ?? 0, slimPageBytes: slimPageBytes ?? 0, floorPages: windowFloorPages,
                                           capacityBytes: kvCapacityBytes, capacityTokens: kvCapacityTokens)
        else { return nil }
        return fixedRuntime + laneState + kv
    }

    public static func contextKVBytes(context: UInt64, pageTokens: UInt64, pageBytes: UInt64, extentPages: UInt64, slimPageBytes: UInt64,
                                      floorPages: UInt64, capacityBytes: UInt64, capacityTokens: UInt64) -> UInt64? {
        guard capacityTokens > 0, capacityBytes > 0, context > 0 else { return nil }
        let rules = SplashMemoryRules.splash173
        let tokens = context + rules.speculativeScratchTokens
        guard pageTokens == rules.pageTokens, pageBytes > 0, extentPages > 0 else {
            return UInt64(Double(capacityBytes) * min(1, Double(tokens) / Double(capacityTokens)))
        }
        let pages = (tokens + pageTokens - 1) / pageTokens
        let slim = slimPageBytes > 0 && floorPages > 0
        let full = slim ? min(pages, floorPages) : pages
        func extents(_ count: UInt64) -> UInt64 { count > 0 ? (count - 1) / extentPages + 1 : 0 }
        return extentPages * (extents(full) * pageBytes + extents(pages - full) * slimPageBytes) + tokens * rules.lookupIndexTokenBytes
    }

    public init?(breakdown text: String) {
        var values: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let number = rest.split(separator: " ").first.flatMap({ UInt64($0) }) { values[key] = number }
            if key == "maximum DFlash batch width", let lanes = UInt64(rest) { values[key] = lanes }
            if key == "KV page", let bytes = rest.firstMatch(of: /tokens, (\d+) bytes/) { values["kv page bytes"] = UInt64(bytes.1) }
            if key == "KV capacity of one request", let tokens = rest.firstMatch(of: /\/ (\d+) tokens/) { values["kv capacity tokens"] = UInt64(tokens.1) }
            if key == "KV past the windows", let floor = rest.firstMatch(of: /keeping (\d+) pages Full/) { values["floor pages"] = UInt64(floor.1) }
            if key == "context", let tokens = rest.firstMatch(of: /^(\d+) tokens/) { values["context tokens"] = UInt64(tokens.1) }
        }
        guard let hard = values["hard budget"], let target = values["target weights"], let fixed = values["fixed runtime"] else { return nil }
        hardBudget = hard
        configuredLimit = values["configured memory limit"] ?? 0
        targetWeights = target
        draftWeights = values["draft weights"] ?? 0
        visionWeights = values["vision weights"] ?? 0
        lanes = values["maximum DFlash batch width"] ?? 4
        laneState = values["lane state"] ?? 0
        sharedPrefill = values["shared prefill"] ?? 0
        sharedDecode = values["shared decode"] ?? 0
        streamedTable = values["streamed table cache"] ?? 0
        aneFfn = values["Neural Engine split"] ?? 0
        stateStaging = values["SSD cache state staging"] ?? 0
        hostHeldBack = values["expert store above its floor at the start"] ?? 0
        fixedRuntime = fixed
        kvPageBytes = values["kv page bytes"] ?? 0
        kvCapacityTokens = values["kv capacity tokens"] ?? 0
        kvCapacityBytes = 0
        windowFloorPages = values["floor pages"] ?? 0
        maximumContext = values["context tokens"] ?? 0
        servedContext = nil
    }
}

public struct SplashStartLog: Sendable, Equatable {
    public var routedExpertsMiB: UInt64?
    public var expertStoreMiB: UInt64?
    public var refusedContext: UInt64?
    public var refusalMaximum: UInt64?
    public var breakdown: SplashPlanReading?
    public var cacheOffReason: String?

    public init(text: String) {
        for line in text.split(separator: "\n") {
            if let m = line.firstMatch(of: /memory holds their (\d+) MiB/) { routedExpertsMiB = UInt64(m.1) }
            if let m = line.firstMatch(of: /a store of (\d+) MiB/) { expertStoreMiB = UInt64(m.1) }
            if let m = line.firstMatch(of: /--max-context (\d+) exceeds the (\d+) tokens/) {
                refusedContext = UInt64(m.1)
                refusalMaximum = UInt64(m.2)
            }
            if let m = line.firstMatch(of: /SSD cache off: ([^;]+)/) { cacheOffReason = String(m.1) }
        }
        breakdown = SplashPlanReading(breakdown: text)
    }
}

public struct MemoryCalibration: Codable, Sendable, Equatable {
    public var fingerprint: String
    public var at: Date
    public var port: Int?
    public var context: UInt64?
    public var whole: SplashPlanReading
    public var streaming: SplashPlanReading?
    public var routedExpertsMiB: UInt64?
    public var expertStoreMiB: UInt64?

    public init(fingerprint: String, at: Date, port: Int?, context: UInt64?, whole: SplashPlanReading,
                streaming: SplashPlanReading? = nil, routedExpertsMiB: UInt64? = nil, expertStoreMiB: UInt64? = nil) {
        self.fingerprint = fingerprint
        self.at = at
        self.port = port
        self.context = context
        self.whole = whole
        self.streaming = streaming
        self.routedExpertsMiB = routedExpertsMiB
        self.expertStoreMiB = expertStoreMiB
    }

    public var parts: MemoryParts {
        var parts = MemoryParts(
            source: .measured(at: at, context: context, port: port), targetWeights: whole.targetWeights,
            draftWeights: whole.draftWeights, visionWeights: whole.visionWeights, laneState: whole.laneState,
            sharedPrefill: whole.sharedPrefill, sharedDecode: whole.sharedDecode, streamedTable: whole.streamedTable,
            aneFfn: whole.aneFfn, stateStaging: whole.stateStaging, hostHeldBack: whole.hostHeldBack, lanes: whole.lanes,
            routedExperts: routedExpertsMiB.map { $0 << 20 })
        if let streaming {
            parts.streaming = .init(targetWeights: streaming.targetWeights, sharedPrefill: streaming.sharedPrefill,
                                    sharedDecode: streaming.sharedDecode, storeBytes: expertStoreMiB.map { $0 << 20 })
        }
        return parts
    }

    public mutating func merge(_ reading: SplashPlanReading, log: SplashStartLog?, streamed: Bool, at date: Date, port: Int?) {
        if streamed {
            streaming = reading
            if let store = log?.expertStoreMiB { expertStoreMiB = store }
            return
        }
        let split = max(whole.aneFfn, reading.aneFfn), staging = max(whole.stateStaging, reading.stateStaging)
        whole = reading
        whole.aneFfn = split
        whole.stateStaging = staging
        if let experts = log?.routedExpertsMiB { routedExpertsMiB = experts }
        at = date
        self.port = port
        context = reading.maximumContext
    }
}

public struct MemoryCalibrationStore: Sendable {
    public let file: URL

    public init(file: URL = URL.applicationSupportDirectory.appending(path: "SplashDeck/memory-calibration.json")) {
        self.file = file
    }

    public func load() -> [String: MemoryCalibration] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let all = (try? decoder.decode([String: MemoryCalibration].self, from: data)) ?? [:]
        return all.filter { MemoryCalibration.identifiesWeights($0.key) }
    }

    public func save(_ all: [String: MemoryCalibration]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(all).write(to: file, options: .atomic)
    }

    @discardableResult
    public func merge(_ calibration: MemoryCalibration) throws -> MemoryCalibration {
        guard MemoryCalibration.identifiesWeights(calibration.fingerprint) else { return calibration }
        var all = load()
        var entry = all[calibration.fingerprint] ?? calibration
        if all[calibration.fingerprint] != nil {
            entry.merge(calibration.whole, log: nil, streamed: false, at: calibration.at, port: calibration.port)
            entry.routedExpertsMiB = calibration.routedExpertsMiB ?? entry.routedExpertsMiB
            if let streaming = calibration.streaming {
                entry.streaming = streaming
                entry.expertStoreMiB = calibration.expertStoreMiB ?? entry.expertStoreMiB
            }
        }
        all[calibration.fingerprint] = entry
        try save(all)
        return entry
    }

    @discardableResult
    public func record(fingerprint: String, reading: SplashPlanReading, log: SplashStartLog?, streamed: Bool,
                       at date: Date = .now, port: Int?) throws -> MemoryCalibration? {
        guard MemoryCalibration.identifiesWeights(fingerprint) else { return nil }
        var all = load()
        if var entry = all[fingerprint] {
            entry.merge(reading, log: log, streamed: streamed, at: date, port: port)
            all[fingerprint] = entry
        } else if !streamed {
            all[fingerprint] = MemoryCalibration(fingerprint: fingerprint, at: date, port: port, context: reading.maximumContext,
                                                 whole: reading, routedExpertsMiB: log?.routedExpertsMiB)
        } else {
            return nil
        }
        try save(all)
        return all[fingerprint]
    }
}

extension MemoryCalibration {
    public static let fingerprintFlags = [
        "--draft-model", "--kv-format", "--state-format", "--cached-states", "--max-concurrent-requests", "--activations",
        "--verify-rows", "--language-only", "--mmproj", "--expert-memory", "--ple-memory", "--disable-ane",
    ]

    public static func identifiesWeights(_ fingerprint: String) -> Bool {
        !fingerprint.hasPrefix("splash=? ") && !fingerprint.contains(" model=? ") && !fingerprint.hasSuffix(" model=?")
    }

    public static func fingerprint(version: String?, arguments: [String]) -> String {
        func value(_ flag: String) -> String? {
            for (index, argument) in arguments.enumerated() {
                if argument.hasPrefix(flag + "=") { return String(argument.dropFirst(flag.count + 1)) }
                if argument == flag {
                    let next = index + 1 < arguments.count ? arguments[index + 1] : "--"
                    return next.hasPrefix("--") ? "on" : next
                }
            }
            return nil
        }
        var parts = ["splash=\(version ?? "?")", "model=\(value("--model-dir") ?? value("--model") ?? "?")"]
        for flag in fingerprintFlags {
            if let text = value(flag) { parts.append("\(flag)=\(text)") }
        }
        return parts.joined(separator: " ")
    }
}
