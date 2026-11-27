import Foundation

public struct LoadedModel: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let model: String
    public let port: Int
    public let status: StatusKind
    public let statusDetail: String?
    public let foundOutside: Bool
    public let usedByHermes: Bool
    public let memory: Measured<Int64>
    public let endpoint: String
    public let facts: [Fact]
    public let eject: NativeAction?
    public let actions: [NativeAction]
    public let edit: NativeAction?
    public private(set) var inChat = false

    public init(id: String, name: String, model: String, port: Int, status: StatusKind, statusDetail: String? = nil,
                foundOutside: Bool = false, usedByHermes: Bool = false, memory: Measured<Int64>, endpoint: String,
                facts: [Fact] = [], eject: NativeAction? = nil, actions: [NativeAction] = [], edit: NativeAction? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.port = port
        self.status = status
        self.statusDetail = statusDetail
        self.foundOutside = foundOutside
        self.usedByHermes = usedByHermes
        self.memory = memory
        self.endpoint = endpoint
        self.facts = facts
        self.eject = eject
        self.actions = actions
        self.edit = edit
    }

    public var menu: [NativeAction] { (edit.map { [$0] } ?? []) + actions + (eject.map { [$0] } ?? []) }
}

extension LoadedModel {
    public func forChat(_ inChat: Bool, use: NativeAction?) -> LoadedModel {
        var copy = LoadedModel(id: id, name: name, model: model, port: port, status: status, statusDetail: statusDetail,
                               foundOutside: foundOutside, usedByHermes: usedByHermes, memory: memory, endpoint: endpoint, facts: facts,
                               eject: eject, actions: (use.map { [$0] } ?? []) + actions, edit: edit)
        copy.inChat = inChat
        return copy
    }
}

public struct LoadableItem: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let detail: String?
    public let tags: [ModelTag]
    public let loadedID: String?
    public let open: NativeAction
    public let fit: WeightsFitEstimate?
    public let titleHelp: String?
    public let lastLoaded: Date?
    public let edit: NativeAction?

    public init(id: String, title: String, subtitle: String, detail: String? = nil, tags: [ModelTag] = [], loadedID: String? = nil,
                open: NativeAction, fit: WeightsFitEstimate? = nil, titleHelp: String? = nil, lastLoaded: Date? = nil, edit: NativeAction? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.tags = tags
        self.loadedID = loadedID
        self.open = open
        self.fit = fit
        self.titleHelp = titleHelp
        self.lastLoaded = lastLoaded
        self.edit = edit
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [title, subtitle, detail ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
            || tags.contains { $0.title.localizedCaseInsensitiveContains(query) }
    }
}

public struct ModelPickerContent: Sendable {
    public let principals: SectionState<[PrincipalSummary]>
    public let principalAction: @MainActor @Sendable (PrincipalSummary) -> NativeAction?
    public let principalMenu: @MainActor @Sendable (PrincipalSummary) -> [NativeAction]
    public let configurations: SectionState<[LoadableItem]>
    public let local: SectionState<[LoadableItem]>

    public init(principals: SectionState<[PrincipalSummary]>, principalAction: @escaping @MainActor @Sendable (PrincipalSummary) -> NativeAction?,
                principalMenu: @escaping @MainActor @Sendable (PrincipalSummary) -> [NativeAction] = { _ in [] },
                configurations: SectionState<[LoadableItem]>, local: SectionState<[LoadableItem]>) {
        self.principals = principals
        self.principalAction = principalAction
        self.principalMenu = principalMenu
        self.configurations = configurations
        self.local = local
    }
}

public struct WeightsFitEstimate: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case fits, tight, doesNotFit
    }

    public let verdict: Verdict
    public let confirmation: String?
    public let weights: Int64
    public let free: Int64
    public let budget: Int64
    public let loaded: Int64
    public let loadedEstimated: Bool
    public let others: Int64
    public let headroom: Int64
    public let forecast: MemoryForecastSummary?
    public let room: MemoryRoomSummary?

    public init(verdict: Verdict, confirmation: String? = nil, weights: Int64, free: Int64, budget: Int64, loaded: Int64,
                loadedEstimated: Bool = false, others: Int64, headroom: Int64, forecast: MemoryForecastSummary? = nil,
                room: MemoryRoomSummary? = nil) {
        self.forecast = forecast
        self.room = room
        self.verdict = verdict
        self.confirmation = confirmation
        self.weights = weights
        self.free = free
        self.budget = budget
        self.loaded = loaded
        self.loadedEstimated = loadedEstimated
        self.others = others
        self.headroom = headroom
    }

    public var word: String {
        switch verdict {
        case .fits: tr("fit.fits")
        case .tight: tr("fit.tight")
        case .doesNotFit: tr("fit.doesNotFit")
        }
    }

    public var tone: ModelTag.Tone {
        switch verdict {
        case .fits: .ready
        case .tight: .warning
        case .doesNotFit: .error
        }
    }

    public var help: String {
        if let room {
            var lines = [forecast.map { $0.headline + ". " + $0.explanation } ?? tr("fit.weightsOnly", NativeFormat.memory(weights)),
                         room.line(need: weights), room.breakdown, tr("fit.tightRule", NativeFormat.memory(headroom))]
            if let forecast { lines.append(forecast.parts) }
            return lines.joined(separator: "\n")
        }
        let loaded = tr(loadedEstimated ? "fit.loadedEstimated" : "fit.loaded", NativeFormat.memory(self.loaded))
        return tr("fit.help", NativeFormat.memory(weights), NativeFormat.memory(free), NativeFormat.memory(budget), loaded,
                  NativeFormat.memory(others), NativeFormat.memory(headroom))
    }
}

public struct MemoryEstimate: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case fits
        case warn
        case block
    }

    public let decision: Decision
    public let budget: Int64
    public let requested: Int64
    public let requestedIsWholeBudget: Bool
    public let running: Int64
    public let others: Int64
    public let blockReason: String?
    public let forecast: MemoryForecastSummary?
    public let room: MemoryRoomSummary?

    public init(decision: Decision, budget: Int64, requested: Int64, requestedIsWholeBudget: Bool, running: Int64, others: Int64,
                blockReason: String? = nil, forecast: MemoryForecastSummary? = nil, room: MemoryRoomSummary? = nil) {
        self.decision = decision
        self.budget = budget
        self.requested = requested
        self.requestedIsWholeBudget = requestedIsWholeBudget
        self.running = running
        self.others = others
        self.blockReason = blockReason
        self.forecast = forecast
        self.room = room
    }

    public var total: Int64 { requested + running + others }
    public var excess: Int64 {
        if let room { return max(0, requested - room.free) }
        return max(0, total - budget)
    }

    public var word: String {
        if forecast?.loadable == false { return tr("fit.doesNotFit") }
        switch decision {
        case .fits: return tr("estimate.fits")
        case .warn: return tr("estimate.over", NativeFormat.memory(excess))
        case .block: return tr("estimate.blocked")
        }
    }

    public var tone: ModelTag.Tone {
        if forecast?.loadable == false { return .error }
        switch decision {
        case .fits: return .ready
        case .warn: return .warning
        case .block: return .error
        }
    }

    public var breakdown: String {
        if let room {
            let need = forecast?.parts ?? tr("estimate.requested", NativeFormat.memory(requested))
            return need + "\n" + room.breakdown
        }
        let requested = requestedIsWholeBudget ? tr("estimate.requestedWhole", NativeFormat.memory(self.requested))
            : tr("estimate.requested", NativeFormat.memory(self.requested))
        return tr("estimate.breakdown", requested, NativeFormat.memory(running), NativeFormat.memory(others), NativeFormat.memory(budget))
    }

    public var autoCapNote: String? {
        guard requestedIsWholeBudget, decision != .fits, forecast == nil else { return nil }
        return tr("estimate.autoCapNote", NativeFormat.memory(requested))
    }

    public var outcome: String {
        if forecast?.loadable == false { return tr("estimate.outcome.refused") }
        switch decision {
        case .fits: return tr("estimate.outcome.fits")
        case .warn: return tr("estimate.outcome.warn")
        case .block: return blockReason ?? tr("estimate.outcome.block")
        }
    }
}

public struct EstimateBar: Sendable, Equatable {
    public enum Part: String, Sendable, Equatable, CaseIterable {
        case weights, kv, draft, runtime, others

        public var title: String {
            switch self {
            case .weights: tr("bar.part.weights")
            case .kv: tr("bar.part.kv")
            case .draft: tr("bar.part.draft")
            case .runtime: tr("bar.part.runtime")
            case .others: tr("bar.part.others")
            }
        }
    }

    public enum Fit: Sendable, Equatable {
        case fits, tight, over

        public var word: String {
            switch self {
            case .fits: tr("fit.fits")
            case .tight: tr("fit.tight")
            case .over: tr("fit.doesNotFit")
            }
        }

        public var tone: ModelTag.Tone {
            switch self {
            case .fits: .ready
            case .tight: .warning
            case .over: .error
            }
        }
    }

    public struct Segment: Sendable, Equatable, Identifiable {
        public var id: Part { part }
        public let part: Part
        public let bytes: Int64
        public let atLeast: Bool
    }

    public let segments: [Segment]
    public let limit: Int64
    public let macUsed: Int64
    public let macTotal: Int64
    public let atLeast: Bool
    public let fit: Fit
    public let note: String?
    public let details: [String]

    public var used: Int64 { segments.reduce(0) { $0 + $1.bytes } }

    public var usedText: String {
        atLeast ? tr("forecast.atLeast", NativeFormat.memory(used)) : NativeFormat.memory(used)
    }

    public var limitText: String { tr("bar.of", NativeFormat.memory(limit)) }

    public var macText: String { tr("bar.mac", NativeFormat.memory(macUsed), NativeFormat.memory(macTotal)) }
}

extension MemoryEstimate {
    public var bar: EstimateBar? {
        guard let forecast, let room else { return nil }
        let draft = max(0, forecast.draft ?? 0)
        let weights = max(0, forecast.weights - draft)
        var segments = [
            EstimateBar.Segment(part: .weights, bytes: weights, atLeast: forecast.draft == nil),
            EstimateBar.Segment(part: .kv, bytes: forecast.kv, atLeast: false),
        ]
        if draft > 0 { segments.append(EstimateBar.Segment(part: .draft, bytes: draft, atLeast: false)) }
        segments.append(EstimateBar.Segment(part: .runtime, bytes: forecast.runtime, atLeast: forecast.needAtLeast))
        if room.splash > 0 { segments.append(EstimateBar.Segment(part: .others, bytes: room.splash, atLeast: false)) }
        let fit: EstimateBar.Fit
        switch (forecast.outcome, decision) {
        case (.exceeds, _), (_, .block): fit = .over
        case (.streamsExperts, _), (.limitedExperts, _), (.kvOnSSD, _), (_, .warn): fit = .tight
        default: fit = .fits
        }
        let note: String? = switch forecast.outcome {
        case let .streamsExperts(streamed?): tr("bar.note.streams", NativeFormat.memory(streamed))
        case .streamsExperts: tr("bar.note.streamsUnmeasured")
        case let .limitedExperts(_, streamed): tr("bar.note.limited", NativeFormat.memory(streamed))
        case .kvOnSSD: tr("bar.note.kvOnSSD")
        case .exceeds: tr("bar.note.refused", NativeFormat.count(Int(forecast.maximumStreaming ?? forecast.maximum)))
        case .unknown: tr("bar.note.unknown")
        case .fits: decision == .fits ? forecast.sourceLine : tr(decision == .warn ? "bar.note.warn" : "bar.note.block")
        }
        var details = [forecast.source, forecast.explanation]
        if case .fits = forecast.outcome {} else { details.append(forecast.headline) }
        details.append(outcome)
        details.append(room.breakdown)
        return EstimateBar(segments: segments, limit: room.metalBudget - room.metalMargin,
                           macUsed: room.macOSReserve + room.others + room.splash + forecast.need, macTotal: room.physical,
                           atLeast: forecast.needAtLeast, fit: fit, note: note, details: details)
    }
}

public struct SliderSpec: Sendable, Equatable {
    public let title: String
    public let scale: SliderScale
    public let unit: SettingUnit
    public let automatic: String?
    public let splashDefault: String?
    public let notes: [String]
    public let provenance: Provenance
    public let disabledReason: String?
    public let mark: SliderMark?
    public let effect: String?
    public let help: String?

    public init(title: String, scale: SliderScale, unit: SettingUnit, automatic: String?, splashDefault: String?, notes: [String] = [],
                provenance: Provenance, disabledReason: String? = nil, mark: SliderMark? = nil, effect: String? = nil, help: String? = nil) {
        self.effect = effect
        self.help = help
        self.title = title
        self.scale = scale
        self.unit = unit
        self.automatic = automatic
        self.splashDefault = splashDefault
        self.notes = notes
        self.provenance = provenance
        self.disabledReason = disabledReason
        self.mark = mark
    }
}

public struct SegmentSpec: Sendable, Equatable {
    public let title: String
    public let choices: [ParameterChoice]
    public let defaultToken: String?
    public let provenance: Provenance
    public let disabledReason: String?
    public let effect: String?
    public let help: String?

    public init(title: String, choices: [ParameterChoice], defaultToken: String?, provenance: Provenance, disabledReason: String? = nil,
                effect: String? = nil, help: String? = nil) {
        self.effect = effect
        self.help = help
        self.title = title
        self.choices = choices
        self.defaultToken = defaultToken
        self.provenance = provenance
        self.disabledReason = disabledReason
    }
}

public struct DraftSpec: Sendable, Equatable {
    public let title: String
    public let choices: [ParameterChoice]
    public let provenance: Provenance
    public let disabledReason: String?
    public let effect: String?
    public let help: String?

    public init(title: String, choices: [ParameterChoice], provenance: Provenance, disabledReason: String? = nil, effect: String? = nil,
                help: String? = nil) {
        self.effect = effect
        self.help = help
        self.title = title
        self.choices = choices
        self.provenance = provenance
        self.disabledReason = disabledReason
    }
}

public struct LoadSheetContent: Sendable, Equatable {
    public let name: String
    public let model: String
    public let facts: [String]
    public let context: SliderSpec?
    public let kvFormat: SegmentSpec?
    public let activations: SegmentSpec?
    public let verifyRows: SegmentSpec?
    public let draft: DraftSpec?
    public let isNew: Bool
    public let storage: StorageSpec?

    public init(name: String, model: String, facts: [String], context: SliderSpec?, kvFormat: SegmentSpec?,
                activations: SegmentSpec?, verifyRows: SegmentSpec?, draft: DraftSpec?, isNew: Bool, storage: StorageSpec? = nil) {
        self.storage = storage
        self.name = name
        self.model = model
        self.facts = facts
        self.context = context
        self.kvFormat = kvFormat
        self.activations = activations
        self.verifyRows = verifyRows
        self.draft = draft
        self.isNew = isNew
    }
}

public struct LoadSettings: Sendable, Equatable {
    public var context: Double?
    public var memory: Double?
    public var kvFormat: String?
    public var activations: String?
    public var verifyRows: String?
    public var draft: String?
    public var expertMemory: String?
    public var expertLimit: Double?
    public var pleInMemory: Bool
    public var cacheDiskOff: Bool
    public var remember: Bool

    public init(context: Double? = nil, memory: Double? = nil, kvFormat: String? = nil, activations: String? = nil,
                verifyRows: String? = nil, draft: String? = nil, expertMemory: String? = nil, expertLimit: Double? = nil,
                pleInMemory: Bool = false, cacheDiskOff: Bool = false, remember: Bool = false) {
        self.expertMemory = expertMemory
        self.expertLimit = expertLimit
        self.pleInMemory = pleInMemory
        self.cacheDiskOff = cacheDiskOff
        self.context = context
        self.memory = memory
        self.kvFormat = kvFormat
        self.activations = activations
        self.verifyRows = verifyRows
        self.draft = draft
        self.remember = remember
    }

    public func keepsEverythingInMemory(_ parts: [StorageSpec.Part]) -> Bool {
        cacheDiskOff && (!parts.contains(.experts) || expertMemory == "off") && (!parts.contains(.ple) || pleInMemory)
    }

    public mutating func useSSD(_ on: Bool, parts: [StorageSpec.Part]) {
        cacheDiskOff = !on
        if parts.contains(.experts) { expertMemory = on ? nil : "off" }
        if parts.contains(.ple) { pleInMemory = !on }
    }
}

public struct StorageSpec: Sendable, Equatable {
    public enum Part: String, Sendable, Equatable {
        case experts, ple, kv
    }

    public struct Limit: Sendable, Equatable {
        public let title: String
        public let scale: SliderScale
        public let resting: Double
        public let provenance: Provenance

        public init(title: String, scale: SliderScale, resting: Double, provenance: Provenance) {
            self.title = title
            self.scale = scale
            self.resting = resting
            self.provenance = provenance
        }
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var id: Part { part }
        public let part: Part
        public let title: String
        public let choices: [ParameterChoice]
        public let details: SettingDetails
        public let status: String
        public let tone: ModelTag.Tone
        public let limit: Limit?
        public let disabledReason: String?

        public init(part: Part, title: String, choices: [ParameterChoice], details: SettingDetails, status: String,
                    tone: ModelTag.Tone = .neutral, limit: Limit? = nil, disabledReason: String? = nil) {
            self.part = part
            self.title = title
            self.choices = choices
            self.details = details
            self.status = status
            self.tone = tone
            self.limit = limit
            self.disabledReason = disabledReason
        }
    }

    public let rows: [Row]

    public init(rows: [Row]) {
        self.rows = rows
    }
}
