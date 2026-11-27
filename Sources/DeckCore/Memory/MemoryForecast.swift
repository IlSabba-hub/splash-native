import Foundation

public struct MemoryParts: Codable, Sendable, Equatable {
    public enum Source: Codable, Sendable, Equatable {
        case measured(at: Date, context: UInt64?, port: Int?)
        case files
    }

    public var source: Source
    public var targetWeights: UInt64?
    public var draftWeights: UInt64?
    public var visionWeights: UInt64?
    public var laneState: UInt64?
    public var sharedPrefill: UInt64?
    public var sharedDecode: UInt64?
    public var streamedTable: UInt64?
    public var aneFfn: UInt64?
    public var stateStaging: UInt64?
    public var hostHeldBack: UInt64?
    public var lanes: UInt64?
    public var routedExperts: UInt64?
    public var expertsStreamed: Bool
    public var streaming: Streaming?
    public var floors: Set<String> = []

    public struct Streaming: Codable, Sendable, Equatable {
        public var targetWeights: UInt64
        public var sharedPrefill: UInt64
        public var sharedDecode: UInt64
        public var storeBytes: UInt64?

        public init(targetWeights: UInt64, sharedPrefill: UInt64, sharedDecode: UInt64, storeBytes: UInt64?) {
            self.targetWeights = targetWeights
            self.sharedPrefill = sharedPrefill
            self.sharedDecode = sharedDecode
            self.storeBytes = storeBytes
        }
    }

    public init(source: Source, targetWeights: UInt64? = nil, draftWeights: UInt64? = nil, visionWeights: UInt64? = nil,
                laneState: UInt64? = nil, sharedPrefill: UInt64? = nil, sharedDecode: UInt64? = nil, streamedTable: UInt64? = nil,
                aneFfn: UInt64? = nil, stateStaging: UInt64? = nil, hostHeldBack: UInt64? = nil, lanes: UInt64? = nil,
                routedExperts: UInt64? = nil, expertsStreamed: Bool = false, streaming: Streaming? = nil) {
        self.source = source
        self.targetWeights = targetWeights
        self.draftWeights = draftWeights
        self.visionWeights = visionWeights
        self.laneState = laneState
        self.sharedPrefill = sharedPrefill
        self.sharedDecode = sharedDecode
        self.streamedTable = streamedTable
        self.aneFfn = aneFfn
        self.stateStaging = stateStaging
        self.hostHeldBack = hostHeldBack
        self.lanes = lanes
        self.routedExperts = routedExperts
        self.expertsStreamed = expertsStreamed
        self.streaming = streaming
    }

    public var measured: Bool { if case .measured = source { true } else { false } }

    public var expertStoreBounds: ClosedRange<UInt64>? {
        guard let experts = routedExperts, let floor = streaming?.storeBytes, floor < experts else { return nil }
        return floor ... experts
    }

    public var measuredAt: Date? { if case .measured(let at, _, _) = source { at } else { nil } }

    public var missing: [String] {
        var names: [String] = []
        if targetWeights == nil { names.append("target_weights_bytes") }
        if draftWeights == nil { names.append("draft_weights_bytes") }
        if visionWeights == nil { names.append("vision_weights_bytes") }
        if laneState == nil { names.append("lane_state_bytes") }
        if sharedPrefill == nil { names.append("shared_prefill_bytes") }
        if sharedDecode == nil { names.append("shared_decode_bytes") }
        return names
    }
}

public enum MemoryAmount: Sendable, Equatable {
    case exact(UInt64)
    case atLeast(UInt64)
    case atMost(UInt64)

    public var value: UInt64 {
        switch self {
        case .exact(let v), .atLeast(let v), .atMost(let v): v
        }
    }

    public var isExact: Bool { if case .exact = self { true } else { false } }
}

public struct MemoryQuestion: Sendable, Equatable {
    public enum StreamSetting: Sendable, Equatable {
        case automatic
        case off
        case size(UInt64)
    }

    public var rules: SplashMemoryRules
    public var geometry: FamilyGeometry
    public var experts: Bool
    public var pleTable: Bool
    public var sparseKv: Bool
    public var kvFormat: KVLayout.Format
    public var context: UInt64?
    public var maxMemory: UInt64?
    public var recommended: UInt64
    public var physical: UInt64
    public var expertMemory: StreamSetting
    public var cacheDiskOff: Bool
    public var parts: MemoryParts

    public init(rules: SplashMemoryRules, geometry: FamilyGeometry, experts: Bool, pleTable: Bool, sparseKv: Bool,
                kvFormat: KVLayout.Format, context: UInt64?, maxMemory: UInt64?, recommended: UInt64, physical: UInt64,
                expertMemory: StreamSetting = .automatic, cacheDiskOff: Bool = false, parts: MemoryParts) {
        self.rules = rules
        self.geometry = geometry
        self.experts = experts
        self.pleTable = pleTable
        self.sparseKv = sparseKv
        self.kvFormat = kvFormat
        self.context = context
        self.maxMemory = maxMemory
        self.recommended = recommended
        self.physical = physical
        self.expertMemory = expertMemory
        self.cacheDiskOff = cacheDiskOff
        self.parts = parts
    }
}

public struct MemoryForecast: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case fits
        case streamsExperts(streamedBytes: UInt64?)
        case kvOnSSD
        case exceeds(maximum: MemoryAmount)
        case limitedExperts(store: UInt64, streamedAtLeast: UInt64)
        case unknown
    }

    public let rules: SplashMemoryRules
    public let family: String
    public let kvFormat: KVLayout.Format
    public let budget: UInt64
    public let context: UInt64
    public let contextIsAutomatic: Bool
    public let kvBytesPerToken: Double
    public let kvBytesPerTokenBeyondWindow: Double?
    public let weights: MemoryAmount
    public let runtime: MemoryAmount
    public let kv: UInt64
    public let total: MemoryAmount
    public let maximumResident: MemoryAmount
    public let maximumStreaming: MemoryAmount?
    public let verdict: Verdict
    public let parts: MemoryParts

    public var loadable: Bool {
        if case .exceeds = verdict { false } else { true }
    }

    public var missing: [String] { parts.missing }
}

extension MemoryForecast {
    public static func answer(_ question: MemoryQuestion) -> MemoryForecast {
        let rules = question.rules, parts = question.parts
        let layout = question.geometry.layout(format: question.kvFormat)
        let budget = rules.hardBudget(recommended: question.recommended, maxMemory: question.maxMemory, physical: question.physical)
        let lanes = parts.lanes ?? rules.defaultLanes
        let reserves = rules.pipelineReserveBytes + rules.runtimeOverheadReserveBytes
        let complete = parts.missing.isEmpty && parts.floors.isEmpty

        let weights = (parts.targetWeights ?? 0) + (parts.draftWeights ?? 0) + (parts.visionWeights ?? 0)
        let arenas = (parts.sharedPrefill ?? 0) + (parts.sharedDecode ?? 0)
        let optional = (parts.streamedTable ?? 0) + (parts.hostHeldBack ?? 0)
        let split = parts.aneFfn ?? 0, staging = parts.stateStaging ?? 0
        let lane = parts.laneState ?? 0
        let fixedCore = weights + arenas + reserves + optional

        let window = question.geometry.maximumContextTokens
        let native = question.geometry.nativeContextTokens
        let floorPages = layout.windowFloorPages(commandPages: 0, rules)

        func capacity(fixed: UInt64, floorPages: UInt64) -> (tokens: UInt64, extent: UInt64) {
            let dynamic = budget > fixed ? budget - fixed : 0
            let available = dynamic > lane ? dynamic - lane : 0
            let onePage = layout.pagesWithin(available, floorPages: floorPages, extentPages: 1, rules)
            let extent = layout.extentPages(for: onePage, rules)
            guard extent > 0 else { return (0, 0) }
            let pages = layout.slimmable ? layout.pagesWithin(available, floorPages: floorPages, extentPages: extent, rules)
                : onePage - onePage % extent
            return (pages * rules.pageTokens, extent)
        }
        func resident(_ capacityTokens: UInt64) -> UInt64 {
            min(window, capacityTokens > rules.speculativeScratchTokens ? capacityTokens - rules.speculativeScratchTokens : 0)
        }

        let withAll = capacity(fixed: fixedCore + split + staging, floorPages: floorPages)
        let withoutExtras = capacity(fixed: fixedCore, floorPages: floorPages)
        let maximum = resident(withoutExtras.tokens)
        let maximumResident: MemoryAmount = complete ? .exact(maximum) : .atMost(maximum)

        let automatic = question.context == nil
        let context = question.context ?? (resident(withAll.tokens) >= native ? native : maximum)

        let keepsExtras = resident(withAll.tokens) >= context
        let extras = keepsExtras ? split + staging : 0
        let extent = keepsExtras ? withAll.extent : withoutExtras.extent
        let kvTokens = context + rules.speculativeScratchTokens
        let pages = rules.pages(ofTokens: kvTokens)
        let kvExtent = extent > 0 ? extent : max(layout.minimumExtentPages(rules), 1)
        let kv = layout.pagesBytes(pages, floorPages: floorPages, extentPages: kvExtent, rules) + kvTokens * rules.lookupIndexTokenBytes

        let runtime = arenas + reserves + optional + extras + lane
        let total = weights + runtime + kv
        let weightsKnown = parts.targetWeights != nil && parts.draftWeights != nil && parts.visionWeights != nil
            && parts.floors.isDisjoint(with: ["target_weights_bytes", "draft_weights_bytes", "vision_weights_bytes"])
        let weightsAmount: MemoryAmount = weightsKnown ? .exact(weights) : .atLeast(weights)
        let runtimeAmount: MemoryAmount = complete ? .exact(runtime) : .atLeast(runtime)
        var totalAmount: MemoryAmount = complete ? .exact(total) : .atLeast(total)

        var maximumStreaming: MemoryAmount?
        var streamedBytes: UInt64?
        var streamingTotal: UInt64?
        let streams = question.experts && question.expertMemory == .automatic && !parts.expertsStreamed
        if question.experts, case .size(let size) = question.expertMemory, !parts.expertsStreamed,
           let experts = parts.routedExperts, let target = parts.targetWeights, size < experts, fixedCore > experts {
            let groupFloor = layout.windowFloorPages(commandPages: rules.prefillGroupChunks * rules.prefillTokenBudget / rules.pageTokens, rules)
            let streamingArenas = parts.streaming.map { $0.sharedPrefill + $0.sharedDecode } ?? arenas
            let limitedTarget = parts.streaming.flatMap { streaming in streaming.storeBytes.map { streaming.targetWeights - $0 + size } }
                ?? target - experts + size
            let fixed = fixedCore - target + limitedTarget - arenas + streamingArenas
            let limitedWeights = weights - target + limitedTarget
            let exact = complete && parts.streaming != nil
            let bound = resident(capacity(fixed: fixed, floorPages: groupFloor).tokens)
            let kvTokens = context + rules.speculativeScratchTokens
            let limitedKV = layout.pagesBytes(rules.pages(ofTokens: kvTokens), floorPages: groupFloor,
                                              extentPages: max(capacity(fixed: fixed, floorPages: groupFloor).extent, layout.minimumExtentPages(rules), 1), rules)
                + kvTokens * rules.lookupIndexTokenBytes
            let limitedTotal = fixed + lane + limitedKV
            let verdict: Verdict = context > bound ? .exceeds(maximum: exact ? .exact(bound) : .atMost(bound))
                : .limitedExperts(store: size, streamedAtLeast: experts - size)
            return MemoryForecast(
                rules: rules, family: question.geometry.family, kvFormat: question.kvFormat, budget: budget, context: context,
                contextIsAutomatic: automatic, kvBytesPerToken: layout.bytesPerToken(.full, rules),
                kvBytesPerTokenBeyondWindow: layout.slimmable ? layout.bytesPerToken(.slim, rules) : nil,
                weights: exact ? .exact(limitedWeights) : .atLeast(limitedWeights),
                runtime: exact ? .exact(limitedTotal - limitedWeights - limitedKV) : .atLeast(limitedTotal - limitedWeights - limitedKV),
                kv: limitedKV, total: exact ? .exact(limitedTotal) : .atLeast(limitedTotal),
                maximumResident: exact ? .exact(bound) : .atMost(bound), maximumStreaming: nil, verdict: verdict, parts: parts)
        }
        if streams, let experts = parts.routedExperts, let target = parts.targetWeights, fixedCore > experts {
            let groupFloor = layout.windowFloorPages(commandPages: rules.prefillGroupChunks * rules.prefillTokenBudget / rules.pageTokens, rules)
            if let streaming = parts.streaming, complete {
                let fixedStreaming = fixedCore - target - arenas + streaming.targetWeights + streaming.sharedPrefill + streaming.sharedDecode
                maximumStreaming = .exact(resident(capacity(fixed: fixedStreaming, floorPages: groupFloor).tokens))
            } else {
                maximumStreaming = .atMost(resident(capacity(fixed: fixedCore - experts, floorPages: groupFloor).tokens))
            }
            let others = fixedCore - experts + lane + kv
            let store = budget > others ? min(budget - others, experts) : 0
            streamedBytes = experts - store
            streamingTotal = others + store
        }

        let verdict: Verdict
        if total <= budget {
            verdict = complete ? .fits : .unknown
        } else if question.sparseKv && layout.spillable && !question.cacheDiskOff {
            verdict = .kvOnSSD
        } else if streams, parts.routedExperts != nil {
            if let bound = maximumStreaming, context > bound.value {
                verdict = .exceeds(maximum: bound)
            } else {
                verdict = .streamsExperts(streamedBytes: streamedBytes)
            }
        } else if streams {
            verdict = .streamsExperts(streamedBytes: nil)
        } else {
            verdict = .exceeds(maximum: maximumResident)
        }

        if case .streamsExperts = verdict, let streamingTotal {
            totalAmount = complete && parts.streaming != nil ? .exact(streamingTotal) : .atLeast(streamingTotal)
        }
        return MemoryForecast(
            rules: rules, family: question.geometry.family, kvFormat: question.kvFormat, budget: budget, context: context,
            contextIsAutomatic: automatic, kvBytesPerToken: layout.bytesPerToken(.full, rules),
            kvBytesPerTokenBeyondWindow: layout.slimmable ? layout.bytesPerToken(.slim, rules) : nil,
            weights: weightsAmount, runtime: runtimeAmount, kv: kv, total: totalAmount, maximumResident: maximumResident,
            maximumStreaming: maximumStreaming, verdict: verdict, parts: parts)
    }
}
