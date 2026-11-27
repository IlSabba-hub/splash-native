import Foundation

public struct MemoryForecastSummary: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case fits
        case streamsExperts(streamed: Int64?)
        case limitedExperts(store: Int64, streamedAtLeast: Int64)
        case kvOnSSD
        case exceeds
        case unknown
    }

    public let family: String
    public let outcome: Outcome
    public let need: Int64
    public let needAtLeast: Bool
    public let weights: Int64
    public let runtime: Int64
    public let kv: Int64
    public let splashBudget: Int64
    public let context: Int64
    public let contextIsAutomatic: Bool
    public let maximum: Int64
    public let maximumAtMost: Bool
    public let maximumStreaming: Int64?
    public let streamingAtMost: Bool
    public let kvBytesPerToken: Double
    public let kvBytesPerTokenBeyondWindow: Double?
    public let measuredAt: Date?
    public let missing: [String]
    public let draft: Int64?

    public init(family: String, outcome: Outcome, need: Int64, needAtLeast: Bool, weights: Int64, runtime: Int64, kv: Int64,
                splashBudget: Int64, context: Int64, contextIsAutomatic: Bool, maximum: Int64, maximumAtMost: Bool,
                maximumStreaming: Int64?, streamingAtMost: Bool, kvBytesPerToken: Double, kvBytesPerTokenBeyondWindow: Double?,
                measuredAt: Date?, missing: [String], draft: Int64? = nil) {
        self.draft = draft
        self.family = family
        self.outcome = outcome
        self.need = need
        self.needAtLeast = needAtLeast
        self.weights = weights
        self.runtime = runtime
        self.kv = kv
        self.splashBudget = splashBudget
        self.context = context
        self.contextIsAutomatic = contextIsAutomatic
        self.maximum = maximum
        self.maximumAtMost = maximumAtMost
        self.maximumStreaming = maximumStreaming
        self.streamingAtMost = streamingAtMost
        self.kvBytesPerToken = kvBytesPerToken
        self.kvBytesPerTokenBeyondWindow = kvBytesPerTokenBeyondWindow
        self.measuredAt = measuredAt
        self.missing = missing
    }

    public var loadable: Bool { outcome != .exceeds }

    private func amount(_ bytes: Int64, atLeast: Bool) -> String {
        atLeast ? tr("forecast.atLeast", NativeFormat.memory(bytes)) : NativeFormat.memory(bytes)
    }

    private var maximumText: String {
        maximumAtMost ? tr("forecast.atMostTokens", NativeFormat.count(Int(maximum))) : NativeFormat.count(Int(maximum))
    }

    public var headline: String {
        tr("forecast.headline", amount(need, atLeast: needAtLeast), NativeFormat.count(Int(context)), maximumText)
    }

    public var contextEffect: String {
        if let beyond = kvBytesPerTokenBeyondWindow {
            return tr("effect.context.window", NativeFormat.count(Int(context)), NativeFormat.memory(kv), NativeFormat.number(beyond, fractionDigits: 0),
                      amount(need, atLeast: needAtLeast), maximumText)
        }
        return tr("effect.context", NativeFormat.count(Int(context)), NativeFormat.memory(kv), NativeFormat.number(kvBytesPerToken, fractionDigits: 0),
                  amount(need, atLeast: needAtLeast), maximumText)
    }

    public var budgetEffect: String {
        tr("effect.maxMemory", NativeFormat.memory(splashBudget), amount(need, atLeast: needAtLeast), NativeFormat.count(Int(context)), maximumText)
    }

    public func kvFormatEffect(int8: MemoryForecastSummary, bf16: MemoryForecastSummary) -> String {
        tr("effect.kvFormat", NativeFormat.count(Int(context)), NativeFormat.memory(int8.kv), NativeFormat.memory(bf16.kv),
           int8.amount(int8.need, atLeast: int8.needAtLeast), bf16.amount(bf16.need, atLeast: bf16.needAtLeast))
    }

    public var markTitle: String { tr("forecast.mark", maximumText) }

    public var explanation: String {
        switch outcome {
        case .fits:
            return tr("forecast.fits", NativeFormat.memory(splashBudget))
        case .streamsExperts(let streamed?):
            return tr("forecast.streams", NativeFormat.memory(streamed), streamingLimit)
        case .streamsExperts(nil):
            return tr("forecast.streamsUnmeasured", streamingLimit)
        case .limitedExperts(let store, let streamed):
            return tr("forecast.limited", NativeFormat.memory(store), NativeFormat.memory(streamed))
        case .kvOnSSD:
            return tr("forecast.kvOnSSD")
        case .exceeds:
            let reason = tr("forecast.exceeds", NativeFormat.count(Int(context)), amount(need, atLeast: needAtLeast),
                            NativeFormat.memory(weights), NativeFormat.memory(kv), NativeFormat.memory(splashBudget), maximumText)
            return maximumStreaming == nil ? reason + " " + tr("forecast.exceeds.noSSD", family) : reason
        case .unknown:
            return tr("forecast.unknown")
        }
    }

    private var streamingLimit: String {
        guard let maximumStreaming else { return tr("value.unavailable") }
        let value = NativeFormat.count(Int(maximumStreaming))
        return streamingAtMost ? tr("forecast.atMostTokens", value) : value
    }

    static func when(_ date: Date) -> String {
        NativeFormat.dateTime(date)
    }

    public var source: String {
        if let measuredAt { return tr("forecast.source.measured", NativeFormat.dateTime(measuredAt)) }
        return tr("forecast.source.files", missing.joined(separator: ", "))
    }

    public var sourceLine: String {
        if let measuredAt { return tr("forecast.sourceLine.measured", Self.when(measuredAt)) }
        return tr("forecast.sourceLine.files")
    }

    public var parts: String {
        var text = tr("forecast.parts", NativeFormat.memory(weights), NativeFormat.memory(runtime), NativeFormat.memory(kv),
                      NativeFormat.number(kvBytesPerToken, fractionDigits: 0))
        if let beyond = kvBytesPerTokenBeyondWindow {
            text += " " + tr("forecast.parts.window", NativeFormat.number(beyond, fractionDigits: 0))
        }
        return text + " " + source
    }
}

public struct MemoryRoomSummary: Sendable, Equatable {
    public let metalBudget: Int64
    public let metalMargin: Int64
    public let physical: Int64
    public let macOSReserve: Int64
    public let splash: Int64
    public let others: Int64

    public init(metalBudget: Int64, metalMargin: Int64, physical: Int64, macOSReserve: Int64, splash: Int64, others: Int64) {
        self.metalBudget = metalBudget
        self.metalMargin = metalMargin
        self.physical = physical
        self.macOSReserve = macOSReserve
        self.splash = splash
        self.others = others
    }

    public var metalFree: Int64 { max(0, metalBudget - metalMargin - splash) }
    public var unifiedFree: Int64 { max(0, physical - macOSReserve - others - splash) }
    public var free: Int64 { min(metalFree, unifiedFree) }

    public func line(need: Int64) -> String {
        tr("room.line", NativeFormat.memory(splash + need), NativeFormat.memory(metalBudget - metalMargin),
           NativeFormat.memory(macOSReserve + others + splash + need), NativeFormat.memory(physical))
    }

    public var breakdown: String {
        tr("room.breakdown", NativeFormat.memory(metalBudget), NativeFormat.memory(metalMargin), NativeFormat.memory(splash),
           NativeFormat.memory(physical), NativeFormat.memory(macOSReserve), NativeFormat.memory(others), NativeFormat.memory(free))
    }
}

public struct SliderMark: Sendable, Equatable {
    public enum Beyond: Sendable, Equatable {
        case streams
        case refused
    }

    public let value: Double
    public let title: String
    public let beyond: Beyond

    public init(value: Double, title: String, beyond: Beyond) {
        self.value = value
        self.title = title
        self.beyond = beyond
    }
}
