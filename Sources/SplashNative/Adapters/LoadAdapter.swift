import AppKit
import NativeCore
import NativeUI
import Foundation
import Observation

@MainActor @Observable
final class LoadController {
    static let shared = LoadController(board: .shared, actions: .shared)

    let board: ServerBoard
    let actions: ServerActions
    private(set) var target: Configuration?
    private(set) var isNew = false
    var settings = LoadSettings()
    private(set) var requested = false
    private(set) var saveFailure: String?
    private(set) var schemaFailure: String?
    private(set) var loading = false
    private var previousServer: String?
    var showsPicker = false
    @ObservationIgnored var openAdvanced: ((Configuration, Bool) -> Void)?

    init(board: ServerBoard, actions: ServerActions) {
        self.board = board
        self.actions = actions
    }

    var model: NativeModel { board.model }
    var showsSheet: Bool { target != nil }

    func open(_ configuration: Configuration, isNew: Bool = false) {
        model.refreshBudget()
        target = configuration
        self.isNew = isNew
        reset(configuration)
        settings = Self.settings(from: configuration, schema: schema(configuration), remember: false)
        loadSchema(configuration)
    }

    func open(weights path: String, apiModelID: String?, draft: String?) {
        model.refreshBudget()
        let configuration = newConfiguration(weights: path, apiModelID: apiModelID, draft: draft)
        target = configuration
        isNew = true
        reset(configuration)
        settings = Self.settings(from: configuration, schema: schema(configuration), remember: false)
        loadSchema(configuration)
    }

    func newConfiguration(weights path: String, apiModelID: String?, draft: String?) -> Configuration {
        let installation = model.installations.first { $0.linked } ?? model.installations.first
        let base = URL(filePath: path).lastPathComponent.replacing(/(?i)\.gguf$/, with: "")
        let name = ConfigurationEditor.freeName(String(base.split(separator: ":").first ?? Substring(base)).lowercased(),
                                                among: model.configurations.map(\.name))
        let port: Int? = ModelPort.shared.port
        var parameters: [String: NativeCore.ParameterValue] = [:]
        if let draft { parameters["--draft-model"] = .value(ModelsAdapter.display(draft)) }
        let local = path.hasPrefix("/") || path.hasPrefix("~/")
        return Configuration(name: name, splashVersion: installation?.version, model: local ? ModelsAdapter.display(path) : path,
                             apiModelID: apiModelID, port: port ?? 0, parameters: parameters)
    }

    func edit(_ configuration: Configuration) {
        showsPicker = false
        openAdvanced?(configuration, false)
        close()
    }

    func editNew(_ configuration: Configuration) {
        showsPicker = false
        openAdvanced?(configuration, true)
        close()
    }

    func editAction(_ configuration: Configuration) -> NativeAction {
        NativeAction(title: tr("config.edit"), systemImage: "pencil") { [weak self] in self?.edit(configuration) }
    }

    private func reset(_ configuration: Configuration) {
        requested = false
        loading = false
        saveFailure = nil
        schemaFailure = nil
        previousServer = nil
        actions.clearNotice(ServerActions.itemID(configuration: configuration.name))
    }

    func close() {
        target = nil
        requested = false
    }

    private func loadSchema(_ configuration: Configuration) {
        guard schema(configuration) == nil else { return }
        guard let installation = configuration.installation(among: model.installations) else {
            schemaFailure = NativeText.problem(.noInstallation(version: configuration.splashVersion))
            return
        }
        Task {
            do {
                let schema = try await model.schema(for: installation)
                guard var target, target.name == configuration.name else { return }
                if target.port == 0 {
                    target.port = ModelPort.shared.port
                    self.target = target
                }
                settings = Self.settings(from: target, schema: schema, remember: settings.remember)
            } catch {
                if target?.name == configuration.name { schemaFailure = error.localizedDescription }
            }
        }
    }

    func schema(_ configuration: Configuration) -> VersionSchema? {
        configuration.installation(among: model.installations).flatMap { model.schemas[$0.id] }
    }

    static let flags = (context: "--max-context", memory: "--max-memory", kv: "--kv-format", activations: "--activations",
                        verifyRows: "--verify-rows", draft: "--draft-model", experts: "--expert-memory", ple: "--ple-memory",
                        cacheDisk: "--max-cache-disk")

    static func settings(from configuration: Configuration, schema: VersionSchema?, remember: Bool) -> LoadSettings {
        func editor(_ flag: String) -> EditorValue? {
            guard let parameter = schema?.serve.parameter(flag) else { return nil }
            return ParameterText.read(configuration.parameters[flag], kind: parameter.kind)
        }
        func number(_ flag: String) -> Double? {
            switch editor(flag) {
            case let .integer(n)?: Double(n)
            case let .bytes(b)?: Double(b)
            default: nil
            }
        }
        func choice(_ flag: String) -> String? {
            if case let .value(text)? = configuration.parameters[flag] { return text }
            return nil
        }
        let experts = choice(flags.experts)?.lowercased()
        let expertLimit = experts.flatMap { $0 == "off" || $0 == "auto" ? nil : SizeText.bytes($0) }.map { Double($0) }
        return LoadSettings(context: number(flags.context), memory: number(flags.memory), kvFormat: choice(flags.kv),
                            activations: choice(flags.activations), verifyRows: choice(flags.verifyRows),
                            draft: choice(flags.draft), expertMemory: experts == "off" ? "off" : expertLimit != nil ? "limit" : nil,
                            expertLimit: expertLimit, pleInMemory: choice(flags.ple)?.lowercased() == "off",
                            cacheDiskOff: choice(flags.cacheDisk).flatMap(SizeText.bytes) == 0, remember: remember)
    }

    static func applying(_ settings: LoadSettings, to configuration: Configuration, schema: VersionSchema?) -> Configuration {
        var result = configuration
        func set(_ flag: String, _ value: EditorValue?) {
            guard let kind = schema?.serve.parameter(flag)?.kind else { return }
            result.parameters[flag] = value.flatMap { ParameterText.write($0, kind: kind) }
        }
        set(flags.context, settings.context.map { .integer(Int64($0)) })
        set(flags.memory, settings.memory.map { .bytes(Int64($0)) })
        set(flags.kv, settings.kvFormat.map(EditorValue.choice))
        set(flags.activations, settings.activations.map(EditorValue.choice))
        set(flags.verifyRows, settings.verifyRows.map(EditorValue.choice))
        set(flags.draft, settings.draft.map(EditorValue.text))
        if let kind = schema?.serve.parameter(flags.experts)?.kind {
            switch settings.expertMemory {
            case "off": result.parameters[flags.experts] = .value("off")
            case "limit": result.parameters[flags.experts] = settings.expertLimit.flatMap { ParameterText.write(.bytes(Int64($0)), kind: kind) }
            default: result.parameters[flags.experts] = nil
            }
        }
        if schema?.serve.parameter(flags.ple) != nil {
            if settings.pleInMemory {
                result.parameters[flags.ple] = .value("off")
            } else if case .value(let text)? = result.parameters[flags.ple], text.lowercased() == "off" {
                result.parameters[flags.ple] = nil
            }
        }
        if schema?.serve.parameter(flags.cacheDisk) != nil {
            if settings.cacheDiskOff {
                result.parameters[flags.cacheDisk] = .value("0")
            } else if case .value(let text)? = result.parameters[flags.cacheDisk], SizeText.bytes(text) == 0 {
                result.parameters[flags.cacheDisk] = nil
            }
        }
        return result
    }

    var running: ServerBoard.Server? {
        guard let target else { return nil }
        return board.activeServers.first { $0.managed && $0.owned?.configuration == target.name }
    }

    func load() {
        guard let target, !loading else { return }
        let configuration = Self.applying(settings, to: target, schema: schema(target))
        let ejecting = [running, occupant].compactMap { $0 }
        let saved = model.configurations.first { $0.name == target.name }
        let save = settings.remember && (isNew || saved != configuration)
        let wasNew = isNew
        saveFailure = nil
        previousServer = running?.id
        requested = true
        loading = true
        Task {
            defer { loading = false }
            if save {
                do {
                    try await model.save(configuration, message: tr(wasNew ? "load.commit.new" : "load.commit.changed", configuration.name))
                    if self.target?.name == configuration.name {
                        self.target = configuration
                        isNew = false
                    }
                } catch {
                    saveFailure = tr("config.saveFailed", error.localizedDescription)
                    requested = false
                    return
                }
            }
            if !ejecting.isEmpty, let failure = await actions.eject(ejecting) {
                saveFailure = failure.text
                requested = false
                return
            }
            actions.start(configuration)
        }
    }

    var estimate: MemoryEstimate? {
        guard let target, !waitingForModel else { return nil }
        let configuration = Self.applying(settings, to: target, schema: schema(target))
        return LoadAdapter.estimate(configuration, board: board)
    }

    var itemID: String? { target.map { ServerActions.itemID(configuration: $0.name) } }

    var estimateMissing: String? {
        waitingForModel ? tr("estimate.waiting.short") : nil
    }

    var estimateMissingHelp: String? {
        guard waitingForModel, let target else { return nil }
        let files = ConfigurationFiles.missing(target).map { file in
            let name = URL(filePath: file.path).lastPathComponent
            return file.partialBytes.map { tr("files.partial", name, NativeFormat.disk($0)) } ?? name
        }
        return tr("files.waiting.reason", files.joined(separator: "; ")) + " " + tr("estimate.waiting")
    }

    var waitingForModel: Bool {
        guard let target else { return false }
        return ConfigurationFiles.missing(target).contains { $0.flag == nil }
    }

    var notice: ServerNotice? {
        if let saveFailure { return ServerNotice(.failure, saveFailure) }
        return itemID.flatMap(actions.notice)
    }

    var pending: NativeAction? { itemID.flatMap(actions.pendingAction) }

    var loaded: Bool {
        guard requested, let target, notice == nil, pending == nil else { return false }
        return board.activeServers.contains { $0.owned?.configuration == target.name && $0.id != previousServer }
    }

    var content: LoadSheetContent? {
        guard let target else { return nil }
        let applied = Self.applying(settings, to: target, schema: schema(target))
        return LoadAdapter.content(target, isNew: isNew, schema: schema(target), native: model, board: board,
                                   drafts: LoadAdapter.drafts(AppServices.shared.library.shelf),
                                   forecast: model.forecast(applied), applied: applied)
    }

    var occupant: ServerBoard.Server? {
        guard let target else { return nil }
        return ModelPort.occupant(of: target, board: board)
    }

    var swapNote: String? { occupant.map(ServerActions.swapNote) }

    var loadAction: NativeAction {
        let own = running
        let reason = (target.map { $0.usesAPIKey && ServerActions.apiKey($0) == nil } == true ? tr("reason.apiKeyNotPassed") : nil)
            ?? (target.map { schema($0) == nil } == true ? (schemaFailure ?? tr("reason.reading")) : nil)
            ?? target.flatMap { ServerActions.waitingReason(Self.applying(settings, to: $0, schema: schema($0))) }
            ?? refusedByMemory
            ?? model.memoryProbe.map { tr("reason.memoryProbe", $0) }
        let working = notice?.kind == .progress || loading || measuring
        let (role, remember) = occupant.map { actions.swapRole(target?.name ?? "", occupant: $0) } ?? (.primary, nil)
        return NativeAction(title: tr(own == nil ? "action.start" : "action.reload"), systemImage: own == nil ? "play.fill" : "arrow.clockwise",
                          role: role, isEnabled: reason == nil && !working, disabledReason: reason, remember: remember) { [weak self] in self?.load() }
    }

    var refusedByMemory: String? {
        guard let target, let forecast = model.forecast(Self.applying(settings, to: target, schema: schema(target))),
              !forecast.loadable else { return nil }
        return LoadAdapter.summary(forecast).explanation
    }

    private(set) var measuring = false
    private(set) var measureFailure: String?

    var measureAction: NativeAction? {
        guard let target, !waitingForModel, let forecast = model.forecast(target), !forecast.parts.measured else { return nil }
        let busy = !board.model.supervisor.alive.isEmpty || !board.model.found.isEmpty
        let reason = busy ? NativeError.memoryProbeBusy.localizedDescription : measureFailure
        let running = measuring || model.memoryProbe != nil
        return NativeAction(title: tr(running ? "forecast.measuring" : "forecast.measure"), systemImage: "gauge.with.dots.needle.33percent",
                          isEnabled: !busy && !running && !loading, disabledReason: busy ? reason : nil) { [weak self] in
            guard let self else { return }
            measuring = true
            measureFailure = nil
            Task {
                defer { self.measuring = false }
                do { _ = try await self.model.measureMemory(target) } catch { self.measureFailure = error.localizedDescription }
            }
        }
    }

    var advancedAction: NativeAction? {
        guard let target, let openAdvanced else { return nil }
        let isNew = isNew
        let edited = Self.applying(settings, to: target, schema: schema(target))
        return NativeAction(title: tr("load.advanced"), systemImage: "slider.horizontal.3") { [weak self] in
            openAdvanced(edited, isNew)
            self?.close()
        }
    }
}

@MainActor
enum LoadAdapter {

    static func content(_ configuration: Configuration, isNew: Bool, schema: VersionSchema?, native: NativeModel, board: ServerBoard,
                        drafts: [ParameterChoice], forecast: MemoryForecast? = nil, applied: Configuration? = nil) -> LoadSheetContent {
        let installation = configuration.installation(among: native.installations)
        let version = installation?.version ?? configuration.splashVersion ?? ""
        let shelf = AppServices.shared.library.shelf
        let family = Self.family(of: configuration, shelf: shelf) ?? installation.flatMap { native.family(of: configuration, in: $0) }
        let familyEntry = family.flatMap { schema?.families?.families[$0] }
        var facts: [String] = []
        if let family {
            facts.append(family)
        } else if let draftFamily = NativeModel.waitingDraftFamily(configuration) {
            facts.append(tr("load.familyFromDraft", draftFamily))
        }
        if !version.isEmpty { facts.append(tr("load.splashVersion", version)) }
        if configuration.port > 0 { facts.append(NativeFormat.port(configuration.port)) }
        let model = configuration.apiModelID ?? configuration.model

        func provenance(_ flag: String) -> Provenance {
            let parameter = schema?.serve.parameter(flag)
            return Provenance(flag: flag, source: .help(version: version, group: parameter?.group), line: parameter?.helpLine)
        }
        let applied = applied ?? configuration
        let summary = forecast.map(Self.summary)
        let dense = native.ssdOffload(applied).flatMap { $0.nothing ? tr("storage.denseNote", $0.family) : nil }
        let contextEffect = [summary?.contextEffect, dense].compactMap { $0 }.joined(separator: "\n")
        func reason(_ parameter: ServeParameter) -> String? {
            guard let report = schema?.families else { return nil }
            if case .noEffect = Applicability.of(parameter, family: family, in: report) {
                return Applicability.of(parameter, family: family, in: report).reason
            }
            return nil
        }
        func title(_ flag: String) -> String { FlagLabels.title(for: flag) ?? flag }

        var context: SliderSpec?
        if let parameter = schema?.serve.parameter(LoadController.flags.context), case let .contextTokens(max) = parameter.kind {
            let highest = familyEntry?.maxContextTokens.map(Int64.init) ?? max
            if let highest {
                var notes: [String] = []
                if let nativeTokens = familyEntry?.contextTokens, nativeTokens != Int(highest) {
                    notes.append(tr("load.context.native", NativeFormat.count(nativeTokens)))
                }
                var extra = familyEntry?.contextTokens.map { [Double($0)] } ?? []
                var mark: SliderMark?
                if let forecast, let summary, forecast.maximumResident.value > 0, forecast.maximumResident.value < UInt64(highest) {
                    let streams = forecast.maximumStreaming != nil || forecast.verdict == .kvOnSSD
                    mark = SliderMark(value: Double(forecast.maximumResident.value), title: summary.markTitle, beyond: streams ? .streams : .refused)
                    extra.append(Double(forecast.maximumResident.value))
                    notes.append(summary.markTitle + " " + tr(streams ? "forecast.mark.beyondStreams" : "forecast.mark.beyondRefused"))
                }
                context = SliderSpec(title: title(parameter.flag),
                                     scale: .powersOfTwo(from: 1024, through: Double(highest), including: extra),
                                     unit: .tokens, automatic: tr("parameter.word.auto"), splashDefault: parameter.helpDefault,
                                     notes: notes, provenance: provenance(parameter.flag), disabledReason: reason(parameter), mark: mark,
                                     effect: contextEffect.isEmpty ? nil : contextEffect, help: parameter.help)
            }
        }

        func segment(_ flag: String, effect: String? = nil) -> SegmentSpec? {
            guard let parameter = schema?.serve.parameter(flag), case let .choice(choices) = parameter.kind else { return nil }
            return SegmentSpec(title: title(flag), choices: choices.map { ParameterChoice(token: $0) },
                               defaultToken: parameter.parserDefault.text ?? parameter.helpDefault, provenance: provenance(flag),
                               disabledReason: reason(parameter), effect: effect, help: parameter.help)
        }

        var draft: DraftSpec?
        if let parameter = schema?.serve.parameter(LoadController.flags.draft) {
            var choices = drafts
            if case let .value(current)? = configuration.parameters[parameter.flag], !choices.contains(where: { $0.token == current }) {
                choices.insert(ParameterChoice(token: current, title: URL(filePath: current).lastPathComponent), at: 0)
            }
            draft = DraftSpec(title: title(parameter.flag), choices: choices, provenance: provenance(parameter.flag), disabledReason: reason(parameter),
                              effect: forecast.flatMap(Self.draftEffect), help: parameter.help)
        }

        return LoadSheetContent(name: configuration.name, model: model, facts: facts, context: context,
                                kvFormat: segment(LoadController.flags.kv, effect: kvFormatEffect(applied, native: native, summary: summary)), activations: segment(LoadController.flags.activations),
                                verifyRows: segment(LoadController.flags.verifyRows), draft: draft, isNew: isNew,
                                storage: storage(configuration, applied: applied, native: native, schema: schema, forecast: forecast,
                                                 provenance: provenance))
    }

    static func kvFormatEffect(_ configuration: Configuration, native: NativeModel, summary: MemoryForecastSummary?) -> String? {
        guard let summary else { return nil }
        func with(_ format: String) -> MemoryForecastSummary? {
            var copy = configuration
            copy.parameters[LoadController.flags.kv] = .value(format)
            return native.forecast(copy).map(Self.summary)
        }
        guard let int8 = with("int8"), let bf16 = with("bf16") else { return nil }
        return summary.kvFormatEffect(int8: int8, bf16: bf16)
    }

    static func draftEffect(_ forecast: MemoryForecast) -> String? {
        guard let bytes = forecast.parts.draftWeights, bytes > 0 else { return nil }
        let source = forecast.parts.measuredAt.map { tr("effect.source.measured", NativeFormat.dateTime($0)) } ?? tr("effect.source.files")
        return tr("effect.draft", NativeFormat.memory(Int64(clamping: bytes)), source)
    }

    static func storage(_ configuration: Configuration, applied: Configuration, native: NativeModel, schema: VersionSchema?,
                        forecast: MemoryForecast?, provenance: (String) -> Provenance) -> StorageSpec? {
        guard let offload = native.ssdOffload(applied), !offload.nothing else { return nil }
        let waiting = ConfigurationFiles.missing(applied).contains { $0.flag == nil }
        func details(_ flag: String, about: String) -> SettingDetails {
            let parameter = schema?.serve.parameter(flag)
            return SettingDetails(flag: flag, source: provenance(flag).shortDescription,
                                  splashDefault: parameter?.helpDefault ?? parameter?.parserDefault.text, help: parameter?.help, about: about)
        }
        func text(_ flag: String) -> String? { if case .value(let value)? = applied.parameters[flag] { value } else { nil } }
        let context = forecast.map { NativeFormat.count(Int($0.context)) }
        var rows: [StorageSpec.Row] = []
        for part in offload.parts {
            guard let flag = SSDOffload.flag(part), schema?.serve.parameter(flag) != nil else { continue }
            switch part {
            case .experts:
                rows.append(expertsRow(flag: flag, applied: applied, forecast: forecast, context: context, waiting: waiting,
                                       details: details(flag, about: tr("storage.experts.about")), provenance: provenance(flag)))
            case .pleTable:
                let inMemory = text(flag)?.lowercased() == "off"
                let size = forecast?.parts.streamedTable.flatMap { $0 > 0 ? NativeFormat.memory(Int64(clamping: $0)) : nil }
                let status = inMemory ? tr("storage.ple.status.off")
                    : size.map { tr("storage.ple.status.cache", $0) } ?? tr(waiting ? "storage.ple.status.waiting" : "storage.ple.status.auto")
                rows.append(StorageSpec.Row(part: .ple, title: tr("storage.ple"),
                                            choices: [ParameterChoice(token: "auto", title: tr("storage.auto")),
                                                      ParameterChoice(token: "off", title: tr("storage.ple.off"))],
                                            details: details(flag, about: tr("storage.ple.about")), status: status,
                                            tone: inMemory ? .ready : .warning))
            case .kvOnSSD:
                let off = text(flag).flatMap(SizeText.bytes) == 0
                let status: String
                let tone: ModelTag.Tone
                switch forecast?.verdict {
                case _ where off:
                    status = tr("storage.kv.status.off")
                    tone = forecast?.loadable == false ? .error : .neutral
                case .kvOnSSD?:
                    status = tr("storage.kv.status.spills", context ?? "")
                    tone = .warning
                case .fits?, .streamsExperts?, .limitedExperts?:
                    status = tr("storage.kv.status.memory", context ?? "", NativeFormat.memory(Int64(clamping: forecast?.kv ?? 0)))
                    tone = .ready
                default:
                    status = tr(waiting ? "storage.kv.status.waiting" : "storage.kv.status.unknown")
                    tone = .neutral
                }
                rows.append(StorageSpec.Row(part: .kv, title: tr("storage.kv"),
                                            choices: [ParameterChoice(token: "auto", title: tr("storage.kv.on")),
                                                      ParameterChoice(token: "off", title: tr("storage.kv.off"))],
                                            details: details(flag, about: tr("storage.kv.about")), status: status, tone: tone))
            }
        }
        return StorageSpec(rows: rows)
    }

    static func expertsRow(flag: String, applied: Configuration, forecast: MemoryForecast?, context: String?, waiting: Bool,
                           details: SettingDetails, provenance: Provenance) -> StorageSpec.Row {
        let setting: String? = if case .value(let value)? = applied.parameters[flag] { value.lowercased() } else { nil }
        let size = setting.flatMap { $0 == "off" || $0 == "auto" ? nil : SizeText.bytes($0) }
        let bounds = forecast?.parts.expertStoreBounds
        var choices = [ParameterChoice(token: "auto", title: tr("storage.auto")), ParameterChoice(token: "off", title: tr("storage.experts.off"))]
        var limit: StorageSpec.Limit?
        if let bounds {
            let gib: UInt64 = 1 << 30
            var stops = [Double(bounds.lowerBound), Double(bounds.upperBound)]
            var whole = (bounds.lowerBound / gib + 1) * gib
            while whole < bounds.upperBound { stops.append(Double(whole)); whole += gib }
            let resting = Double(min(max(size ?? (bounds.upperBound / gib) * gib, bounds.lowerBound), bounds.upperBound))
            limit = StorageSpec.Limit(title: tr("storage.experts.limit"), scale: SliderScale(stops: stops), resting: resting, provenance: provenance)
        }
        if bounds != nil || size != nil { choices.append(ParameterChoice(token: "limit", title: tr("storage.experts.limitChoice"))) }

        let experts = forecast?.parts.routedExperts.map { NativeFormat.memory(Int64(clamping: $0)) }
        let status: String
        let tone: ModelTag.Tone
        switch forecast?.verdict {
        case .fits? where experts != nil:
            status = tr("storage.experts.status.fits", experts ?? "")
            tone = .ready
        case .streamsExperts(let streamed?)? where experts != nil:
            let total = forecast?.parts.routedExperts ?? 0
            status = tr("storage.experts.status.streams", experts ?? "", NativeFormat.memory(Int64(clamping: total > streamed ? total - streamed : 0)),
                        NativeFormat.memory(Int64(clamping: streamed)))
            tone = .warning
        case .limitedExperts(let store, let streamed)? where experts != nil:
            status = tr("storage.experts.status.limited", experts ?? "", NativeFormat.memory(Int64(clamping: store)),
                        NativeFormat.memory(Int64(clamping: streamed)))
            tone = .warning
        case .exceeds(let most)? where experts != nil:
            let value = NativeFormat.count(Int(most.value))
            status = tr("storage.experts.status.refused", experts ?? "", context ?? "", most.isExact ? value : tr("forecast.atMostTokens", value))
            tone = .error
        case .streamsExperts?:
            status = tr("storage.experts.status.streamsUnmeasured")
            tone = .warning
        case .kvOnSSD? where experts != nil:
            status = tr("storage.experts.status.kvOnSSD", experts ?? "")
            tone = .warning
        default:
            if let size, bounds == nil, setting != nil {
                status = tr("storage.experts.status.sizeUnbounded", NativeFormat.memory(Int64(clamping: size)))
            } else {
                status = tr(waiting ? "storage.experts.status.waiting" : "storage.experts.status.unmeasured")
            }
            tone = .neutral
        }
        return StorageSpec.Row(part: .experts, title: tr("storage.experts"), choices: choices, details: details, status: status,
                               tone: tone, limit: limit)
    }

    static func drafts(_ shelf: ModelShelf) -> [ParameterChoice] {
        shelf.weights.filter { $0.role == .draft }.map {
            ParameterChoice(token: ModelsAdapter.display($0.path), title: $0.name)
        }
    }

    static func picker(board: ServerBoard, controller: LoadController, shelf: ModelShelf?) -> ModelPickerContent {
        let overview = OverviewAdapter(board: board)
        let configurations: SectionState<[LoadableItem]>
        if !board.prepared {
            configurations = .unavailable(reason: tr("reason.reading"))
        } else if let error = board.configurationsError {
            configurations = .unavailable(reason: error)
        } else {
            configurations = .available(board.model.configurations.filter { !$0.principal }.map { configuration in
                let server = board.server(for: configuration)
                let weights = shelf.flatMap { localWeights(of: configuration, in: $0) }
                var tags: [ModelTag] = []
                if let family = shelf.flatMap({ family(of: configuration, shelf: $0) }) { tags.append(ModelTag(family)) }
                if let weights, let quant = quantization(weights, shelf: shelf) { tags.append(quant) }
                if OverviewAdapter.draftName(configuration) != nil { tags.append(ModelTag(tr("badge.draft"))) }
                let version = configuration.splashVersion.map { tr("load.splashVersion", $0) }
                let waiting = server == nil && ServerActions.waitingReason(configuration) != nil ? tr("files.waiting") : nil
                let subtitle = [OverviewAdapter.modelName(configuration), version, NativeFormat.port(configuration.port), waiting].compactMap { $0 }
                    .joined(separator: " · ")
                let bytes = weights?.bytes ?? shelf.flatMap { hubBytes(configuration.model, shelf: $0) }
                let help = [configuration.name, OverviewAdapter.modelTitle(configuration)].joined(separator: " · ")
                return LoadableItem(id: configuration.name, title: configuration.name, subtitle: subtitle,
                                    detail: bytes.map { NativeFormat.disk($0) }, tags: tags, loadedID: server?.id,
                                    open: NativeAction(title: tr("picker.open")) { controller.open(configuration) },
                                    fit: server == nil ? fit(bytes: bytes, configuration: configuration, board: board) : nil,
                                    titleHelp: help, lastLoaded: lastLoaded(configuration.name),
                                    edit: controller.editAction(configuration))
            })
        }
        let local: SectionState<[LoadableItem]>
        if let shelf, shelf.scanned != nil {
            let used = Set(board.model.configurations.map { LocalWeightsScanner.splashPath(expand($0.model)) })
            let fresh = Configuration(name: "", splashVersion: nil, model: "", apiModelID: nil, port: 0, parameters: [:])
            local = .available(shelf.weights.filter { $0.role == .target && !used.contains(LocalWeightsScanner.splashPath($0.path)) }.map { weights in
                let preparations = shelf.preparations(of: weights)
                var tags: [ModelTag] = []
                if let family = preparations.compactMap(\.family).first { tags.append(ModelTag(family)) }
                tags.append(ModelTag(weights.format == .gguf ? tr("models.format.gguf") : tr("models.format.safetensors")))
                if let quant = quantization(weights, shelf: shelf) { tags.append(quant) }
                let incomplete = weights.isIncomplete ? ModelsAdapter.incompleteText(weights) : nil
                if let incomplete { tags.append(ModelTag(incomplete, symbol: "exclamationmark.triangle.fill", tone: .warning)) }
                let path = weights.path, name = weights.name
                return LoadableItem(id: path, title: weights.displayName, subtitle: ModelsAdapter.display(path), detail: NativeFormat.disk(weights.bytes),
                                    tags: tags,
                                    open: NativeAction(title: tr("picker.open"), isEnabled: incomplete == nil, disabledReason: incomplete) {
                                        controller.open(weights: path, apiModelID: "local/" + name, draft: preparations.compactMap(\.draft).first)
                                    },
                                    fit: incomplete != nil ? nil
                                        : fit(bytes: weights.bytes, configuration: freshConfiguration(weights, draft: preparations.compactMap(\.draft).first,
                                                                                      template: fresh, board: board), board: board),
                                    titleHelp: ModelsAdapter.display(path))
            })
        } else {
            local = .unavailable(reason: tr("reason.reading"))
        }
        return ModelPickerContent(
            principals: overview.principals,
            principalAction: { principalAction($0, board: board, controller: controller) },
            principalMenu: { principalMenu($0, board: board, controller: controller) },
            configurations: configurations, local: local)
    }

    static func localWeights(of configuration: Configuration, in shelf: ModelShelf) -> LocalWeights? {
        guard configuration.isLocal else { return nil }
        let path = LocalWeightsScanner.splashPath(expand(configuration.model))
        return shelf.weights.first { LocalWeightsScanner.splashPath($0.path) == path }
    }

    static func family(of configuration: Configuration, shelf: ModelShelf?) -> String? {
        guard let shelf else { return nil }
        if let weights = localWeights(of: configuration, in: shelf) {
            return shelf.preparations(of: weights).compactMap(\.family).first
        }
        return shelf.preparations(ofHub: configuration.model).compactMap(\.family).first
    }

    static func quantization(_ weights: LocalWeights, shelf: ModelShelf?) -> ModelTag? {
        if let dominant = shelf?.headers[weights.path]?.dominant { return ModelTag(dominant.type, tone: .accent) }
        if let bits = weights.quantization?.bits { return ModelTag(tr("load.bits", NativeFormat.count(bits)), tone: .accent) }
        return nil
    }

    static func lastLoaded(_ name: String, now: Date = .now) -> Date? {
        if let cached = lastLoadedCache[name], now.timeIntervalSince(cached.read) < 5 { return cached.date }
        let folder = ServerSupervisor.defaultLogs.appending(path: name)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".log") }
        let date = names.max().flatMap(logDate)
        lastLoadedCache[name] = (now, date)
        return date
    }

    private static var lastLoadedCache: [String: (read: Date, date: Date?)] = [:]

    static func logDate(_ name: String) -> Date? {
        guard name.hasSuffix(".log") else { return nil }
        let stamp = String(name.dropLast(4))
        guard let split = stamp.firstIndex(of: "T") else { return nil }
        return ISO8601DateFormatter().date(from: String(stamp[..<split] + stamp[split...].replacing("-", with: ":")))
    }

    static func hubBytes(_ model: String, shelf: ModelShelf) -> Int64? {
        shelf.preparations(ofHub: model).first { $0.kind == .assembly && $0.present }?.bytes
    }

    static func freshConfiguration(_ weights: LocalWeights, draft: String?, template: Configuration, board: ServerBoard) -> Configuration {
        var configuration = template
        let installation = board.model.installations.first { $0.linked } ?? board.model.installations.first
        configuration.name = weights.name.lowercased()
        configuration.splashVersion = installation?.version
        configuration.model = ModelsAdapter.display(weights.path)
        configuration.port = ModelPort.shared.port
        if let draft { configuration.parameters["--draft-model"] = .value(ModelsAdapter.display(draft)) }
        return configuration
    }

    static func fit(bytes: Int64?, configuration: Configuration, board: ServerBoard) -> WeightsFitEstimate? {
        guard let fit = board.model.weightsFit(bytes: bytes.flatMap { $0 > 0 ? UInt64($0) : nil }, configuration: configuration,
                                               replacing: configuration.name,
                                               alsoReplacing: ModelPort.replaced(by: configuration, board: board)) else { return nil }
        let verdict: WeightsFitEstimate.Verdict = switch fit.verdict {
        case .fits: .fits
        case .tight: .tight
        case .doesNotFit: .doesNotFit
        }
        let guess = estimate(configuration, board: board)
        let confirmation = guess?.decision == .block ? guess.map { $0.blockReason ?? $0.outcome } : nil
        return WeightsFitEstimate(verdict: verdict, confirmation: confirmation, weights: Int64(fit.weightsBytes), free: Int64(fit.freeBytes), budget: Int64(fit.budget),
                                  loaded: Int64(fit.loadedBytes), loadedEstimated: fit.loadedEstimated, others: Int64(fit.othersBytes),
                                  headroom: Int64(fit.headroom), forecast: fit.forecast.map(summary), room: room(fit.room))
    }

    static func summary(_ forecast: MemoryForecast) -> MemoryForecastSummary {
        let outcome: MemoryForecastSummary.Outcome = switch forecast.verdict {
        case .fits: .fits
        case .streamsExperts(let streamed): .streamsExperts(streamed: streamed.map { Int64(clamping: $0) })
        case .limitedExperts(let store, let streamed): .limitedExperts(store: Int64(clamping: store), streamedAtLeast: Int64(clamping: streamed))
        case .kvOnSSD: .kvOnSSD
        case .exceeds: .exceeds
        case .unknown: .unknown
        }
        var measuredAt: Date?
        if case .measured(let at, _, _) = forecast.parts.source { measuredAt = at }
        return MemoryForecastSummary(
            family: forecast.family, outcome: outcome, need: Int64(clamping: forecast.total.value), needAtLeast: !forecast.total.isExact,
            weights: Int64(clamping: forecast.weights.value), runtime: Int64(clamping: forecast.runtime.value), kv: Int64(clamping: forecast.kv),
            splashBudget: Int64(clamping: forecast.budget), context: Int64(clamping: forecast.context), contextIsAutomatic: forecast.contextIsAutomatic,
            maximum: Int64(clamping: forecast.maximumResident.value), maximumAtMost: !forecast.maximumResident.isExact,
            maximumStreaming: forecast.maximumStreaming.map { Int64(clamping: $0.value) },
            streamingAtMost: forecast.maximumStreaming.map { !$0.isExact } ?? false,
            kvBytesPerToken: forecast.kvBytesPerToken, kvBytesPerTokenBeyondWindow: forecast.kvBytesPerTokenBeyondWindow,
            measuredAt: measuredAt, missing: forecast.missing, draft: forecast.parts.draftWeights.map { Int64(clamping: $0) })
    }

    static func room(_ room: MemoryRoom) -> MemoryRoomSummary {
        MemoryRoomSummary(metalBudget: Int64(clamping: room.metalBudget), metalMargin: Int64(clamping: room.metalMargin),
                          physical: Int64(clamping: room.physical), macOSReserve: Int64(clamping: room.macOSReserve),
                          splash: Int64(clamping: room.splashBytes), others: Int64(clamping: room.othersBytes))
    }

    static func estimate(_ configuration: Configuration, board: ServerBoard) -> MemoryEstimate? {
        let model = board.model
        guard let guess = model.estimate(configuration, replacing: ModelPort.replaced(by: configuration, board: board), foundStatus: { found in
            board.live.track(.found(pid: found.pid, started: found.started))?.reading?.snapshot
        }) else { return nil }
        let verdict = guess.verdict
        let decision: MemoryEstimate.Decision
        var reason: String?
        switch guess.decision {
        case .admit: decision = .fits
        case .warn: decision = .warn
        case .block(.unlimitedNeighbours(let list)):
            decision = .block
            reason = NativeError.unlimitedNeighbours(names: list.map { "\($0.name) \(NativeFormat.port($0.port))" }).localizedDescription
        case .block(.overBudget): decision = .block
        }
        return MemoryEstimate(decision: decision, budget: Int64(verdict.budget), requested: Int64(verdict.requested.bytes),
                              requestedIsWholeBudget: verdict.requested.source == .wholeBudget,
                              running: Int64(verdict.running.reduce(0) { $0 + $1.bytes }), others: Int64(verdict.othersBytes),
                              blockReason: reason, forecast: guess.forecast.map(summary), room: room(verdict.room))
    }

    static func principalAction(_ principal: PrincipalSummary, board: ServerBoard, controller: LoadController) -> NativeAction? {
        guard let configuration = board.model.configurations.first(where: { $0.name == principal.id }) else { return nil }
        if let server = board.server(for: configuration) { return ejectAction(server, actions: controller.actions, board: board) }
        return NativeAction(title: tr("action.start"), systemImage: "play.fill", role: .primary) { controller.open(configuration) }
    }

    static func principalMenu(_ principal: PrincipalSummary, board: ServerBoard, controller: LoadController) -> [NativeAction] {
        guard let configuration = board.model.configurations.first(where: { $0.name == principal.id }) else { return [] }
        return [controller.editAction(configuration)]
    }

    private static func expand(_ path: String) -> String {
        path.hasPrefix("~/") ? URL.homeDirectory.path + String(path.dropFirst(1)) : path
    }

    static func ejectAction(_ server: ServerBoard.Server, actions: ServerActions, board: ServerBoard) -> NativeAction {
        let stop = actions.stopAction(server)
        return NativeAction(title: stop.title, systemImage: "eject", role: stop.role, isEnabled: stop.isEnabled,
                          disabledReason: stop.disabledReason, perform: stop.perform)
    }

    private static func rank(_ server: ServerBoard.Server, modelPort: Int) -> Int {
        ModelPort.ports(of: server).contains(modelPort) ? 0 : server.managed ? 1 : 2
    }

    static func loaded(board: ServerBoard, actions: ServerActions, navigation: NativeNavigation, controller: LoadController? = nil) -> [LoadedModel] {
        let modelPort = ModelPort.shared.port
        let ordered = board.activeServers.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element, modelPort: modelPort), rank(b.element, modelPort: modelPort))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        return ordered.map { server in
            let status = server.status
            let reading = server.reading
            let memory = reading.map { ServerFacts.measured($0.snapshot.memoryActual?.currentBytes, field: "memory_actual.current_bytes") }
                ?? .unavailable(reason: server.track?.failure ?? tr("reason.noStatusYet"))
            var facts: [Fact] = [
                Fact(title: tr("card.memoryNow"), value: memory.map { NativeFormat.memory($0) },
                     provenance: Provenance(source: .status(field: "memory_actual.current_bytes"))),
            ]
            if let peak = reading?.snapshot.memoryActual?.peakBytes {
                facts.append(Fact(title: tr("card.memoryPeak"), value: .value(NativeFormat.memory(peak)),
                                  provenance: Provenance(source: .status(field: "memory_actual.peak_bytes"))))
            }
            if let cap = reading?.detail.governorLimitBytes {
                facts.append(Fact(title: tr("card.memoryCap"), value: .value(NativeFormat.memory(cap)),
                                  provenance: Provenance(source: .status(field: "memory_governor.limit_bytes"))))
            }
            if let released = reading?.snapshot.weights?.released {
                facts.append(Fact(title: tr("chip.weights"), value: .value(tr(released ? "chip.weights.released" : "chip.weights.loaded")),
                                  provenance: Provenance(source: .status(field: "weights.released"))))
            }
            facts.append(Fact(title: tr("chip.version"),
                              value: server.version.map { .value($0) } ?? .unavailable(reason: tr("reason.noReleaseFile")),
                              provenance: Provenance(source: .file(name: "release.json"))))
            let hermes = board.hermes.flatMap(\.localPort) == server.port
            let others = Array(actions.actions(for: server).dropFirst())
            let open = NativeAction(title: tr("chip.openInServers"), systemImage: "terminal") { [weak actions] in
                actions?.selection = server.id
                navigation.section = .servers
            }
            return LoadedModel(id: server.id, name: server.name, model: server.track?.servedModels?.first ?? server.configuration?.apiModelID ?? server.name,
                               port: server.port, status: status.kind, statusDetail: status.detail, foundOutside: !server.managed,
                               usedByHermes: hermes, memory: memory, endpoint: server.endpoint, facts: facts,
                               eject: ejectAction(server, actions: actions, board: board), actions: others + [open],
                               edit: server.configuration.flatMap { configuration in controller.map { $0.editAction(configuration) } })
        }
    }
}
