import DeckCore
import DeckUI
import Foundation

@MainActor
enum ConfigurationsAdapter {

    static func ui(_ value: EditorValue) -> DeckUI.ParameterValue {
        switch value {
        case .unset: .unset
        case .on: .bool(true)
        case .integer(let n): .integer(n)
        case .number(let n): .number(n)
        case .choice(let c): .choice(c)
        case .word(let w): .word(w)
        case .seconds(let s): .seconds(s)
        case .bytes(let b): .bytes(b)
        case .text(let t): .text(t)
        case .list(let l): .list(l)
        }
    }

    static func core(_ value: DeckUI.ParameterValue) -> EditorValue {
        switch value {
        case .unset, .bool(false): .unset
        case .bool(true): .on
        case .integer(let n): .integer(n)
        case .number(let n): .number(n)
        case .choice(let c): .choice(c)
        case .word(let w): .word(w)
        case .seconds(let s): .seconds(s)
        case .bytes(let b): .bytes(b)
        case .text(let t), .secret(let t): t.isEmpty ? .unset : .text(t)
        case .list(let l): l.isEmpty ? .unset : .list(l)
        }
    }

    static func kind(_ parameter: ServeParameter) -> ParameterKind {
        let placeholder = parameter.metavar
        switch parameter.kind {
        case .flag: return .toggle
        case .choice(let choices), .reasoningEffort(let choices): return .choice(choices.map { ParameterChoice(token: $0) })
        case .contextTokens(let max): return .integer(range: 1 ... (max ?? Int64.max), unit: .tokens, words: [.auto])
        case .sizeOrAuto: return .size(words: [.auto])
        case .sizeOrAutoOr(let words): return .size(words: [.auto] + words.map(word))
        case .sizeAutoOrZero: return .size(words: [.auto, ParameterWord(token: "0", title: tr("parameter.word.zeroDisables"))])
        case .sizeOrZero: return .size(words: [ParameterWord(token: "0", title: tr("parameter.word.zeroNoLimit"))])
        case .size: return .size(words: [])
        case .duration: return .duration(words: [])
        case .durationOrOff: return .duration(words: [.off])
        case .integer(let min, let max): return .integer(range: (min ?? Int64.min) ... (max ?? Int64.max), unit: nil, words: [])
        case .port: return .integer(range: 1 ... 65535, unit: nil, words: [])
        case .nonnegativeNumber: return .number(range: 0 ... Double.greatestFiniteMagnitude)
        case .path(let directory): return .path(directory: directory)
        case .secret: return .secret
        case .samplingDefault: return .list(placeholder: placeholder)
        case .modelID, .draft, .host, .origin, .servedName, .text, .unknown:
            return parameter.repeatable ? .list(placeholder: placeholder) : .text(placeholder: placeholder)
        }
    }

    private static func word(_ token: String) -> ParameterWord {
        token == "off" ? .off : token == "auto" ? .auto : ParameterWord(token: token, title: token)
    }

    static func descriptor(_ field: EditorField, version: String, effect: String? = nil) -> ParameterDescriptor {
        let parameter = field.parameter
        let reason: String? = switch field.state {
        case .active: nil
        case .noEffect(let reason): reason
        case .absent(let versions): tr("config.absent", version, versions.joined(separator: ", "))
        case .unknown: tr("config.unknownFlag", version)
        }
        return ParameterDescriptor(
            title: FlagLabels.title(for: field.flag) ?? field.flag, flag: field.flag,
            kind: parameter.map(kind) ?? .text(placeholder: nil),
            splashDefault: parameter?.helpDefault ?? parameter?.parserDefault.text,
            help: parameter?.help,
            provenance: Provenance(flag: field.flag, source: .help(version: version, group: parameter?.group), line: parameter?.helpLine),
            disabledReason: reason, effect: effect)
    }

    static func memoryEffects(_ configuration: Configuration, deck: DeckModel) -> [String: String] {
        guard let forecast = deck.forecast(configuration) else { return [:] }
        let summary = LoadAdapter.summary(forecast)
        var effects = ["--max-context": summary.contextEffect, "--max-memory": summary.budgetEffect]
        effects["--kv-format"] = LoadAdapter.kvFormatEffect(configuration, deck: deck, summary: summary)
        effects["--draft-model"] = LoadAdapter.draftEffect(forecast)
        return effects
    }

    static func editor(_ state: ConfigurationsState) -> ConfigurationEditorContent? {
        guard state.isOpen else { return nil }
        let deck = state.deck
        let version = state.installation?.version ?? state.installation?.label ?? "—"
        let versions = deck.installations.map { ParameterChoice(token: $0.id, title: $0.label) }
        let models = WeightsAdapter.choices(state.shelf, role: .target)
        let familyEntry = state.family.flatMap { state.schema?.families?.families[$0] }
        let effects = memoryEffects(state.current(), deck: deck)
        let panes = state.groups.map { group in
            EditorPane(id: group.name.isEmpty ? "foreign" : group.name,
                       title: group.name.isEmpty ? tr("config.group.foreign", version) : FlagLabels.group(group.name) ?? group.name,
                       splashName: group.name.isEmpty ? nil : group.name,
                       settings: group.fields.map { field in
                           let noEffect = if case .noEffect = field.state { true } else { false }
                           let weights = WeightsAdapter.control(field.flag, value: state.values[field.flag], shelf: state.shelf)
                           return EditorSetting(descriptor(field, version: version, effect: effects[field.flag]),
                                                control: weights ?? control(field.parameter, family: familyEntry, budget: deck.budget),
                                                applicable: !noEffect)
                       })
        }
        var facts: [Fact] = []
        if let installation = state.installation {
            let family = Fact(title: tr("models.family"),
                              value: state.family.map { .value($0) } ?? .unavailable(reason: DeckText.unknownFamily),
                              provenance: Provenance(source: .file(name: "model.json · family")))
            facts.append(family)
            facts.append(Fact(title: tr("config.schema"), value: .value(installation.label),
                              provenance: Provenance(source: .file(name: "install/launcher.py · serve --help, server/serve_options.py"))))
        }
        var notices: [String] = []
        if let link = state.shelf.configurationLinks[state.header.name],
           let shared = state.shelf.sharedSelections.first(where: { $0.link == link.path }) {
            notices.append(tr("models.shared", shared.users.map { "\($0.configuration) (\($0.version))" }.joined(separator: ", ")))
        }
        let current = state.current()
        if !current.isLocal, current.parameters["--offline"] != .on, !current.model.isEmpty {
            notices.append(tr("config.mayContactHub"))
        }
        return ConfigurationEditorContent(versions: versions, models: models,
                                          model: WeightsAdapter.describe(state.header.model, among: models, shelf: state.shelf), panes: panes, facts: facts, problems: state.problems,
                                          notices: notices, isNew: state.base == nil, schemaUnavailable: state.schemaError,
                                          modelPort: ModelPort.shared.port)
    }

    static func control(_ parameter: ServeParameter?, family: FamilyReport.Family?, budget: UInt64?) -> SettingControl {
        guard let parameter else { return .field }
        switch parameter.kind {
        case .flag:
            return .toggle
        case let .choice(choices), let .reasoningEffort(choices):
            let options = choices.map { ParameterChoice(token: $0) }
            let fallback = parameter.parserDefault.text ?? parameter.helpDefault
            let defaultToken = fallback.flatMap { choices.contains($0) ? $0 : nil }
            return choices.count <= 4 ? .segmented(options, defaultToken: defaultToken) : .menu(options, defaultToken: defaultToken)
        case let .contextTokens(max):
            guard let highest = family?.maxContextTokens.map(Int64.init) ?? max else { return .field }
            return .slider(.powersOfTwo(from: 1024, through: Double(highest), including: family?.contextTokens.map { [Double($0)] } ?? []),
                           unit: .tokens, automatic: .auto)
        case .sizeOrAuto where parameter.flag == LoadController.flags.memory:
            guard let budget, budget > 1 << 30 else { return .field }
            return .slider(.linear(Double(1 << 30) ... Double(budget), step: Double(1 << 30)), unit: .bytes, automatic: .auto)
        case let .integer(min?, max?):
            if max - min <= 32 { return .stepper(min ... max) }
            guard min > 0 else { return .field }
            return .slider(.powersOfTwo(from: Double(min), through: Double(max), including: [Double(min)]),
                           unit: parameter.flag == "--max-image-pixels" ? .pixels : .tokens, automatic: nil)
        default:
            return .field
        }
    }

    static func menu(_ state: ConfigurationsState) -> [DeckAction] {
        let problems = state.problems
        let blocking = problems.filter { !$0.key.hasPrefix("--") || $0.key == "--api-key" }
        var actions = [
            DeckAction(title: tr("config.save"), systemImage: "square.and.arrow.down",
                       isEnabled: state.changed && blocking.isEmpty, disabledReason: blocking.values.first) {
                Task { await state.save() }
            },
        ]
        if state.base != nil {
            actions.append(DeckAction(title: tr("config.duplicate"), systemImage: "plus.square.on.square") { Task { await state.duplicate() } })
        }
        if state.fields.contains(where: { if case .absent = $0.state { true } else { $0.state == .unknown } }) {
            actions.append(DeckAction(title: tr("config.dropForeign"), systemImage: "minus.circle") { state.dropForeignFlags() })
        }
        if let base = state.base {
            actions.append(DeckAction(title: tr("config.remove"), systemImage: "trash",
                                      role: .destructive(question: tr("config.remove.question", base.name),
                                                         consequence: tr("config.remove.consequence"), confirmTitle: tr("config.remove"))) {
                Task {
                    if await state.remove() { state.closeEditor() }
                }
            })
        }
        return actions
    }

    static func verifyAction(_ state: ConfigurationsState) -> DeckAction {
        DeckAction(title: tr("config.verify"), systemImage: "checkmark.seal", isEnabled: !state.verifying && state.schema != nil) {
            Task { await state.verify() }
        }
    }

    static func loadAction(_ state: ConfigurationsState, loads: LoadController) -> DeckAction {
        let blocking = state.problems.filter { !$0.key.hasPrefix("--") }
        return DeckAction(title: tr("editor.load"), systemImage: "play.fill", role: .primary, isEnabled: blocking.isEmpty && state.schema != nil,
                          disabledReason: blocking.values.first) {
            let configuration = state.current()
            let isNew = state.base == nil
            state.closeEditor()
            loads.open(configuration, isNew: isNew)
        }
    }

    static func review(_ state: ConfigurationsState) -> ConfigurationReview? {
        guard state.isOpen else { return nil }
        let current = state.current()
        let diff = current.parameters.sorted { $0.key < $1.key }.map { flag, value in
            Fact(title: FlagLabels.title(for: flag) ?? flag, value: .value(text(value)),
                 provenance: Provenance(flag: flag, source: .configuration(name: current.name)))
        }
        var verdict: ConfigurationVerdict?
        if let assessment = state.assessment, let date = state.verified {
            var facts: [Fact] = []
            var notices: [String] = []
            if let memory = assessment.memory {
                facts.append(Fact(title: tr("config.verdict.reserve"), value: .value(DeckFormat.memory(Int64(memory.requested.bytes))),
                                  provenance: Provenance(flag: "--max-memory", source: .system(name: tr("config.verdict.reserveSource")))))
                facts.append(Fact(title: tr("config.verdict.total"),
                                  value: .value(tr("config.verdict.totalValue", DeckFormat.memory(Int64(memory.total)), DeckFormat.memory(Int64(memory.budget)))),
                                  provenance: Provenance(source: .system(name: "MTLDevice.recommendedMaxWorkingSetSize"))))
                if !memory.fits { notices.append(tr("config.verdict.overBudget", DeckFormat.memory(Int64(memory.excess)))) }
                if case .block(.unlimitedNeighbours(let list))? = assessment.admission {
                    notices.append(DeckError.unlimitedNeighbours(names: list.map { "\($0.name) \(DeckFormat.port($0.port))" }).localizedDescription)
                } else if case .warn? = assessment.admission {
                    notices.append(tr("config.verdict.warn"))
                }
            } else {
                facts.append(Fact(title: tr("config.verdict.total"), value: .unavailable(reason: DeckError.budgetUnknown.localizedDescription)))
            }
            if assessment.plan.mayContactHub { notices.append(tr("config.mayContactHub")) }
            facts.append(Fact(title: tr("config.verdict.argv"), value: .value(assessment.plan.serveArguments.map(ModelsAdapter.display).joined(separator: " ")),
                              provenance: Provenance(source: .file(name: "LaunchPlan"))))
            verdict = ConfigurationVerdict(accepted: assessment.parser.accepted, message: assessment.parser.message, facts: facts,
                                           dropped: assessment.plan.dropped.map { tr("config.verdict.dropped", $0.flag, $0.applicability.reason ?? "") },
                                           notices: notices, date: date)
        } else if let failure = state.verifyFailure, let date = state.verified {
            verdict = ConfigurationVerdict(accepted: false, message: failure, date: date)
        }
        var historyDiff: [Fact] = []
        var historyActions: [DeckAction] = []
        if let old = state.historyConfiguration {
            historyDiff = changes(from: old, to: current)
            historyActions = [DeckAction(title: tr("config.history.restore"), systemImage: "arrow.uturn.backward") {
                Task { await state.restoreHistory() }
            }]
        }
        return ConfigurationReview(
            diff: diff, verdict: verdict, verifying: state.verifying, actions: [],
            history: state.history.map { HistoryEntry(id: $0.commit, date: $0.date, message: $0.message) },
            selectedHistory: state.historySelection, historyDiff: historyDiff, historyActions: historyActions,
            onSelectHistory: { commit in Task { await state.selectHistory(commit) } })
    }

    static func text(_ value: DeckCore.ParameterValue) -> String {
        switch value {
        case .on: tr("config.on")
        case .value(let text): text
        case .values(let list): list.joined(separator: ", ")
        }
    }

    static func changes(from old: Configuration, to new: Configuration) -> [Fact] {
        var facts: [Fact] = []
        let header: [(String, String, String)] = [
            (tr("config.model"), old.model, new.model), (tr("config.port"), String(old.port), String(new.port)),
            (tr("config.version"), old.splashVersion ?? "—", new.splashVersion ?? "—"),
            (tr("config.principal"), old.principal ? tr("config.on") : tr("config.off"), new.principal ? tr("config.on") : tr("config.off")),
            (tr("config.observe"), old.observe ? tr("config.on") : tr("config.off"), new.observe ? tr("config.on") : tr("config.off")),
        ]
        for (title, before, after) in header where before != after {
            facts.append(Fact(title: title, value: .value(tr("config.history.change", before, after))))
        }
        let none = tr("config.default")
        for flag in Set(old.parameters.keys).union(new.parameters.keys).sorted() where old.parameters[flag] != new.parameters[flag] {
            facts.append(Fact(title: FlagLabels.title(for: flag) ?? flag,
                              value: .value(tr("config.history.change", old.parameters[flag].map(text) ?? none, new.parameters[flag].map(text) ?? none)),
                              provenance: Provenance(flag: flag, source: .configuration(name: new.name))))
        }
        return facts
    }
}
