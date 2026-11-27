import Foundation

public struct SplashMemoryRules: Sendable, Equatable {
    public let version: String
    public let pageTokens: UInt64
    public let speculativeScratchTokens: UInt64
    public let prefillTokenBudget: UInt64
    public let defaultLanes: UInt64
    public let maximumContextTokens: UInt64
    public let attentionBlockTokens: UInt64
    public let pipelineReserveBytes: UInt64
    public let runtimeOverheadReserveBytes: UInt64
    public let lookupIndexTokenBytes: UInt64
    public let extentRegionAlignmentBytes: UInt64
    public let allocationExtentTargetBytes: UInt64
    public let minimumWorkingSetMarginBytes: UInt64
    public let workingSetMarginPercent: UInt64
    public let unwiredFloorPercent: UInt64
    public let prefillGroupChunks: UInt64
    public let residentAllowanceTokens: UInt64
    public let expertFloorShare: Double

    public static let splash173 = SplashMemoryRules(
        version: "1.7.3", pageTokens: 32, speculativeScratchTokens: 15, prefillTokenBudget: 2048, defaultLanes: 4,
        maximumContextTokens: 1_048_576, attentionBlockTokens: 4, pipelineReserveBytes: 256 << 20,
        runtimeOverheadReserveBytes: 512 << 20, lookupIndexTokenBytes: 89, extentRegionAlignmentBytes: 64 << 10,
        allocationExtentTargetBytes: 128 << 20, minimumWorkingSetMarginBytes: 1 << 30, workingSetMarginPercent: 2,
        unwiredFloorPercent: 10, prefillGroupChunks: 4, residentAllowanceTokens: 65_536, expertFloorShare: 0.85)

    public static func of(version: String?) -> SplashMemoryRules? {
        version == splash173.version ? splash173 : nil
    }

    public func workingSetMargin(recommended: UInt64) -> UInt64 {
        let proportional = recommended / 100 * workingSetMarginPercent + recommended % 100 * workingSetMarginPercent / 100
        return max(proportional, minimumWorkingSetMarginBytes)
    }

    public func hardBudget(recommended: UInt64, maxMemory: UInt64?, physical: UInt64) -> UInt64 {
        let margin = workingSetMargin(recommended: recommended)
        let ceiling = recommended > margin ? recommended - margin : 0
        if let maxMemory, maxMemory > 0 { return min(maxMemory, ceiling) }
        let floored = physical - physical / 100 * unwiredFloorPercent
        return min(floored, ceiling)
    }

    public func hostSpareReserve(physical: UInt64) -> UInt64 {
        min(max(physical / 100 * 7, 2 << 30), 7 << 30)
    }

    public func runwayPages(extentPages: UInt64, lanes: UInt64) -> UInt64 {
        let warmup = (prefillTokenBudget + pageTokens - 1) / pageTokens
        let pages = warmup * max(lanes, defaultLanes) / defaultLanes
        return (pages + extentPages - 1) / extentPages * extentPages
    }

    public func pages(ofTokens tokens: UInt64) -> UInt64 { (tokens + pageTokens - 1) / pageTokens }
}

public struct KVLayout: Sendable, Equatable, Codable {
    public enum Format: String, Sendable, Equatable, Codable {
        case int8
        case bf16
    }

    public enum PageForm: Sendable, Equatable {
        case full
        case slim
        case index
    }

    public var attentionLayers: UInt64
    public var kvHeads: UInt64
    public var headDimension: UInt64
    public var format: Format
    public var indexDimension: UInt64
    public var windowTokens: UInt64
    public var windowedLayers: UInt64
    public var selectedBlocks: Bool

    public init(attentionLayers: UInt64, kvHeads: UInt64, headDimension: UInt64, format: Format, indexDimension: UInt64 = 0,
                windowTokens: UInt64 = 0, windowedLayers: UInt64 = 0, selectedBlocks: Bool = false) {
        self.attentionLayers = attentionLayers
        self.kvHeads = kvHeads
        self.headDimension = headDimension
        self.format = format
        self.indexDimension = indexDimension
        self.windowTokens = windowTokens
        self.windowedLayers = windowedLayers
        self.selectedBlocks = selectedBlocks
    }

    public func regions(_ form: PageForm) -> UInt64 {
        switch form {
        case .full: attentionLayers
        case .slim: attentionLayers - windowedLayers
        case .index: 0
        }
    }

    public func bytesPerLayerPage(_ rules: SplashMemoryRules) -> UInt64 {
        let elements = rules.pageTokens * kvHeads * headDimension
        let data = elements * (format == .int8 ? 1 : 2)
        let scales = format == .int8 ? rules.pageTokens * kvHeads * 4 : 0
        return 2 * (data + scales)
    }

    public func indexBytesPerLayerPage(_ rules: SplashMemoryRules) -> UInt64 {
        rules.pageTokens / rules.attentionBlockTokens * indexDimension * 2
    }

    public func bytesPerPage(_ form: PageForm = .full, _ rules: SplashMemoryRules) -> UInt64 {
        regions(form) * bytesPerLayerPage(rules) + attentionLayers * indexBytesPerLayerPage(rules)
    }

    public func bytesPerToken(_ form: PageForm = .full, _ rules: SplashMemoryRules) -> Double {
        Double(bytesPerPage(form, rules)) / Double(rules.pageTokens)
    }

    public var spillable: Bool { selectedBlocks && indexDimension > 0 }
    public var slimmable: Bool { windowedLayers > 0 && !spillable }

    public func windowPages(_ rules: SplashMemoryRules) -> UInt64 { (windowTokens + rules.pageTokens - 1) / rules.pageTokens }

    private static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 { b == 0 ? a : gcd(b, a % b) }
    private static func lcm(_ a: UInt64, _ b: UInt64) -> UInt64 { a > 0 && b > 0 ? a / gcd(a, b) * b : 0 }

    private static func pagesForAlignedRegion(_ bytes: UInt64, _ rules: SplashMemoryRules) -> UInt64 {
        bytes > 0 ? rules.extentRegionAlignmentBytes / gcd(rules.extentRegionAlignmentBytes, bytes) : 0
    }

    public func extentAlignmentPages(_ rules: SplashMemoryRules) -> UInt64 {
        let elements = rules.pageTokens * kvHeads * headDimension
        let data = elements * (format == .int8 ? 1 : 2)
        var pages = format == .bf16 ? Self.pagesForAlignedRegion(data, rules)
            : Self.lcm(Self.pagesForAlignedRegion(data, rules), Self.pagesForAlignedRegion(rules.pageTokens * kvHeads * 4, rules))
        if indexDimension > 0 { pages = Self.lcm(pages, Self.pagesForAlignedRegion(indexBytesPerLayerPage(rules), rules)) }
        return pages
    }

    public func minimumExtentPages(_ rules: SplashMemoryRules) -> UInt64 {
        let unit = extentAlignmentPages(rules) * bytesPerPage(.full, rules)
        guard unit > 0 else { return 0 }
        return max(1, (rules.allocationExtentTargetBytes / 2 + unit - 1) / unit) * extentAlignmentPages(rules)
    }

    public func maximumExtentPages(_ rules: SplashMemoryRules) -> UInt64 {
        let unit = extentAlignmentPages(rules) * bytesPerPage(.full, rules)
        guard unit > 0 else { return 0 }
        return max(rules.allocationExtentTargetBytes * 3 / 2 / unit * extentAlignmentPages(rules), minimumExtentPages(rules))
    }

    public func extentPages(for pages: UInt64, _ rules: SplashMemoryRules) -> UInt64 {
        let step = extentAlignmentPages(rules), smallest = minimumExtentPages(rules)
        guard smallest > 0, pages >= smallest else { return 0 }
        let largest = min(maximumExtentPages(rules), pages)
        var best: UInt64 = 0, bestLeft: UInt64 = 0, bestDistance: UInt64 = 0
        var extent = smallest
        while extent <= largest {
            let bytes = extent * bytesPerPage(.full, rules)
            let target = rules.allocationExtentTargetBytes
            let distance = bytes > target ? bytes - target : target - bytes
            if best == 0 || pages % extent < bestLeft || (pages % extent == bestLeft && distance < bestDistance) {
                best = extent
                bestLeft = pages % extent
                bestDistance = distance
            }
            extent += step
        }
        return best
    }

    public func windowFloorPages(commandPages: UInt64, _ rules: SplashMemoryRules) -> UInt64 {
        guard slimmable else { return 0 }
        let command = commandPages > 0 ? commandPages : rules.prefillTokenBudget / rules.pageTokens
        return windowPages(rules) + command + 1
    }

    public func pagesBytes(_ pages: UInt64, floorPages: UInt64, extentPages: UInt64, _ rules: SplashMemoryRules) -> UInt64 {
        guard extentPages > 0 else { return 0 }
        let full = slimmable ? min(pages, floorPages) : pages
        func extents(_ count: UInt64) -> UInt64 { count > 0 ? (count - 1) / extentPages + 1 : 0 }
        return extentPages * (extents(full) * bytesPerPage(.full, rules) + extents(pages - full) * bytesPerPage(.slim, rules))
    }

    public func pagesWithin(_ bytes: UInt64, floorPages: UInt64, extentPages: UInt64, _ rules: SplashMemoryRules) -> UInt64 {
        guard extentPages > 0 else { return 0 }
        let index = rules.pageTokens * rules.lookupIndexTokenBytes
        func whole(_ room: UInt64, _ form: PageForm) -> UInt64 {
            room / (extentPages * (bytesPerPage(form, rules) + index)) * extentPages
        }
        let floorBytes = pagesBytes(floorPages, floorPages: floorPages, extentPages: extentPages, rules) + floorPages * index
        if !slimmable || bytes < floorBytes { return whole(bytes, .full) }
        return floorPages + whole(bytes - floorBytes, .slim)
    }
}

public struct FamilyGeometry: Sendable, Equatable {
    public let family: String
    public let nativeContextTokens: UInt64
    public let maximumContextTokens: UInt64
    public let layers: UInt64
    public let attentionLayers: UInt64
    public let kvHeads: UInt64
    public let headDimension: UInt64
    public let windowTokens: UInt64
    public let windowedLayers: UInt64
    public let indexDimension: UInt64
    public let source: String
    public var experts = false
    public var pleTable = false
    public var sparseKv = false

    public func layout(format: KVLayout.Format) -> KVLayout {
        KVLayout(attentionLayers: attentionLayers, kvHeads: kvHeads, headDimension: headDimension, format: format,
                 indexDimension: indexDimension, windowTokens: windowTokens, windowedLayers: windowedLayers,
                 selectedBlocks: indexDimension > 0)
    }

    public static let splash173: [FamilyGeometry] = facts([
        FamilyGeometry(family: "Qwen3.8-27B", nativeContextTokens: 262_144, maximumContextTokens: 1_010_000, layers: 64,
                       attentionLayers: 64 / 4, kvHeads: 4, headDimension: 256, windowTokens: 0, windowedLayers: 0, indexDimension: 0,
                       source: "runtime/model/Qwen3_8.hpp:24-46 (layers 64, attentionKvHeads 4, attentionHeadDimension 256, fullAttentionPeriod 4)"),
        FamilyGeometry(family: "Qwen3.6-35B-A3B", nativeContextTokens: 262_144, maximumContextTokens: 1_010_000, layers: 40,
                       attentionLayers: 40 / 4, kvHeads: 2, headDimension: 256, windowTokens: 0, windowedLayers: 0, indexDimension: 0,
                       source: "runtime/model/Qwen3_6Moe.hpp:26-52 (layers 40, attentionKvHeads 2, attentionHeadDimension 256, fullAttentionPeriod 4)"),
        FamilyGeometry(family: "Qwen3.5-122B-A10B", nativeContextTokens: 262_144, maximumContextTokens: 1_010_000, layers: 48,
                       attentionLayers: 48 / 4, kvHeads: 2, headDimension: 256, windowTokens: 0, windowedLayers: 0, indexDimension: 0,
                       source: "runtime/model/Qwen3_6Moe.hpp:59-86 (layers 48, attentionKvHeads 2, attentionHeadDimension 256, fullAttentionPeriod 4)"),
        FamilyGeometry(family: "Qwen3.8-Flash-Next", nativeContextTokens: 262_144, maximumContextTokens: 1_010_000, layers: 48,
                       attentionLayers: 48 / 4, kvHeads: 2, headDimension: 256, windowTokens: 0, windowedLayers: 0, indexDimension: 128,
                       source: "runtime/model/Qwen4Exp.hpp:56-96 (layers 48, attentionKvHeads 2, attentionHeadDimension 256, fullAttentionPeriod 4, indexerHeadDimension 128)"),
        FamilyGeometry(family: "Flint", nativeContextTokens: 262_144, maximumContextTokens: 262_144, layers: 49,
                       attentionLayers: 49, kvHeads: 4, headDimension: 128, windowTokens: 513 - 1, windowedLayers: 35, indexDimension: 0,
                       source: "runtime/model/Flint.hpp:41-46, :58-89 (layers 49, fullAttentionPeriod 1, attentionKvHeads 4, attentionHeadDimension 128, slidingWindow 513)"),
        FamilyGeometry(family: "Inkling-2-Mini", nativeContextTokens: 1_010_000, maximumContextTokens: 1_010_000, layers: 48,
                       attentionLayers: 48, kvHeads: 8, headDimension: 128, windowTokens: 1024 - 1, windowedLayers: 40, indexDimension: 0,
                       source: "runtime/model/Inkling2Loop.hpp:345-398, :485 (layers 48, fullAttentionPeriod 1, attentionKvHeads 8, attentionHeadDimension 128, slidingWindow 1024)"),
    ])

    private static func facts(_ list: [FamilyGeometry]) -> [FamilyGeometry] {
        list.map { family in
            var family = family
            family.experts = family.family != "Qwen3.8-27B"
            family.pleTable = family.family == "Qwen3.8-Flash-Next"
            family.sparseKv = family.family == "Qwen3.8-Flash-Next"
            return family
        }
    }

    public static func of(family: String?, rules: SplashMemoryRules) -> FamilyGeometry? {
        guard rules.version == SplashMemoryRules.splash173.version else { return nil }
        return splash173.first { $0.family == family }
    }
}
