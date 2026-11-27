import AppKit
import NativeCore
import NativeUI
import Foundation

@MainActor
extension ModelsAdapter {
    struct InventoryContent {
        var rows: [ModelRow] = []
        var cards: [ModelCardSummary] = []
        var drafts: [WeightsSummary] = []
        var projectors: [WeightsSummary] = []
    }

    static func inventory(_ shelf: ModelShelf, families: FamilyReport?, version: String, actions: Actions) -> InventoryContent {
        var content = InventoryContent()
        let ggufSource = tr("models.source.gguf", version)
        for model in shelf.inventory.models {
            let weights = model.weights.first
            let header = weights.flatMap { shelf.headers[$0.path] }
            let selections = model.selections
            let configurations = DeletionPlanner.configurations(using: model, among: shelf.native.configurations).map(\.name)
            let location = weights.map { display($0.path) } ?? model.hubModels.first ?? selections.first.map { display($0.link.path) } ?? ""
            var menu = verifyActions(selections, shelf: shelf)
            var inspector: [NativeAction] = []
            if model.role == .target {
                let newSettings = newSettingsAction(model, actions: actions)
                if let newSettings {
                    menu.append(newSettings)
                    inspector.append(newSettings)
                }
            }
            if let path = weights?.path ?? selections.first?.link.path {
                menu.append(reveal(path))
                inspector.append(reveal(path))
            }
            let delete = deleteAction(model, shelf: shelf, actions: actions)
            menu.append(delete)
            inspector.append(delete)
            let date = weights?.modified ?? selections.compactMap(preparedDate).max()
            let modified: SourcedText? = date.map { date in
                weights?.modified != nil ? SourcedText(NativeFormat.ago(date), source: tr("models.source.modified", NativeFormat.moment(date)))
                    : preparedText(date)
            }
            content.rows.append(ModelRow(
                id: model.id, kind: kind(model.role),
                architecture: weights.flatMap { architecture($0, header: header, ggufSource: ggufSource) }
                    ?? model.family.map { SourcedText($0, source: tr("models.source.family")) },
                family: model.family,
                parameters: weights.flatMap { model.role == .projector ? nil : parameters($0, header: header, ggufSource: ggufSource) },
                name: model.name, location: location,
                capabilities: capabilities(model.family, families),
                capabilitiesSource: model.family.map { tr("models.source.capabilities", $0, version) },
                quantization: weights.flatMap { quantization($0, header: header, ggufSource: ggufSource) } ?? hubQuantization(model),
                bytes: model.bytes, sizeReason: model.bytes == nil ? sizeReason(selections) : nil,
                note: stateTag(model), noteHelp: noteHelp(model),
                modified: modified, modifiedDate: date,
                busy: selections.contains { shelf.verifying[$0.id] != nil } || shelf.deleting == model.name, menu: menu,
                settings: gear(model, configurations: configurations, shelf: shelf, actions: actions)))
            switch model.role {
            case .target:
                content.cards.append(card(model, shelf: shelf, families: families, version: version, header: header,
                                          configurations: configurations, actions: inspector))
            case .draft, .projector:
                let summary = weightsSummary(model, shelf: shelf, actions: inspector)
                if model.role == .draft { content.drafts.append(summary) } else { content.projectors.append(summary) }
            }
        }
        return content
    }

    static func gear(_ model: InventoryModel, configurations: [String], shelf: ModelShelf, actions: Actions) -> [NativeAction] {
        guard model.role == .target else { return [] }
        let newSettings = newSettingsAction(model, actions: actions)
        if configurations.isEmpty, newSettings == nil { return [] }
        return settings(configurations, shelf: shelf, actions: actions, newDisabledReason: newSettings?.disabledReason) {
            newSettings?.perform()
        }
    }

    static func kind(_ role: LocalWeights.Role) -> ModelKind {
        switch role {
        case .target: .llm
        case .draft: .draft
        case .projector: .projector
        }
    }

    static func hubQuantization(_ model: InventoryModel) -> SourcedText? {
        if let hub = model.hubModels.first, let variant = hub.split(separator: ":", maxSplits: 1).dropFirst().first {
            return SourcedText(String(variant), source: tr("models.source.variant", hub))
        }
        return model.selections.compactMap(\.targetFormat).first.map { SourcedText($0, source: tr("models.source.targetFormat")) }
    }

    static func stateTag(_ model: InventoryModel) -> ModelTag {
        switch model.state {
        case .prepared: ModelTag(tr("models.state.prepared"), symbol: "checkmark.circle.fill", tone: .ready)
        case .ready: ModelTag(tr("models.state.ready"), symbol: "internaldrive")
        case .hubOnly: ModelTag(tr("models.state.hubOnly"), symbol: "icloud", tone: .warning)
        case .obsolete: ModelTag(tr("models.state.obsolete"), symbol: "xmark.octagon", tone: .error)
        case .incomplete: ModelTag(incompleteReason(model) ?? tr("models.state.incomplete.short"), symbol: "exclamationmark.triangle.fill", tone: .warning)
        }
    }

    static func incompleteText(_ weights: LocalWeights) -> String {
        tr("models.state.incomplete", NativeFormat.count(weights.parts), NativeFormat.count(weights.expectedParts))
    }

    static func incompleteReason(_ model: InventoryModel) -> String? {
        model.incompleteWeights.map(incompleteText)
    }

    static func stateHelp(_ state: InventoryModel.State) -> String {
        switch state {
        case .prepared: tr("models.state.prepared.help")
        case .ready: tr("models.state.ready.help")
        case .hubOnly: tr("models.state.hubOnly.help")
        case .obsolete: tr("models.state.obsolete.help")
        case .incomplete: tr("models.state.incomplete.help")
        }
    }

    static func noteHelp(_ model: InventoryModel) -> String {
        let missing = (model.incompleteWeights?.missingParts ?? []).map { file in
            let name = URL(filePath: file.path).lastPathComponent
            return tr("models.incomplete.missing", file.partialBytes.map { tr("files.partial", name, NativeFormat.disk($0)) } ?? name)
        }
        return ([stateHelp(model.state)] + missing + model.sources.map(sourceLine)).joined(separator: "\n")
    }

    static func sourceLine(_ source: InventorySource) -> String {
        let path = display(source.path)
        switch source.kind {
        case .localFiles: return tr("models.source.kind.local", path)
        case let .otherApp(app): return tr("models.source.kind.otherApp", app, path)
        case .hubCache: return tr("models.source.kind.hubCache", path)
        case .preparation:
            let name = sourceValue(source)
            return tr(source.present ? "models.source.kind.preparation" : "models.source.kind.preparationMissing", name)
        case .obsolete: return tr("models.source.kind.obsolete", path)
        }
    }

    static func sourceValue(_ source: InventorySource) -> String {
        guard let selection = source.selection else { return display(source.path) }
        return selection.hashed ? ".selections/" + selection.name.prefix(12) + "…" : selection.name
    }

    static func newSettingsAction(_ model: InventoryModel, actions: Actions) -> NativeAction? {
        let draft = model.selections.compactMap(\.draft).first
        if let weights = model.weights.first(where: { $0.role == .target }) {
            let path = weights.path, name = weights.name
            let incomplete = incompleteReason(model)
            return NativeAction(title: tr("models.newSettings"), systemImage: "plus", isEnabled: incomplete == nil,
                              disabledReason: incomplete) { actions.newSettings(path, "local/" + name, draft) }
        }
        if model.state == .hubOnly, let hub = model.hubModels.first {
            return NativeAction(title: tr("models.newSettings"), systemImage: "plus") { actions.newSettings(hub, nil, draft) }
        }
        return nil
    }

    static func deleteAction(_ model: InventoryModel, shelf: ModelShelf, actions: Actions) -> NativeAction {
        let id = model.id
        return NativeAction(title: tr("models.delete"), systemImage: "trash", isEnabled: shelf.deleting == nil,
                          disabledReason: shelf.deleting.map { tr("models.delete.running", $0) }) { actions.delete(id) }
    }

    static func card(_ model: InventoryModel, shelf: ModelShelf, families: FamilyReport?, version: String,
                     header: ModelTools.GGUFHeader?, configurations: [String], actions: [NativeAction]) -> ModelCardSummary {
        var tags = [stateTag(model)]
        if let weights = model.weights.first {
            tags.append(ModelTag(weights.format == .gguf ? tr("models.format.gguf") : tr("models.format.safetensors")))
        }
        tags += commonTags(name: model.name, preparations: model.selections).filter { tag in
            ![tr("models.tag.notPrepared"), tr("models.tag.prepared"), tr("models.tag.package"), tr("models.tag.missing")].contains(tag.title)
        }
        var facts = model.sources.map { source in
            Fact(title: sourceTitle(source.kind), value: .value(sourceValue(source)), provenance: Provenance(source: .system(name: tr("models.inventory.source"))))
        }
        if let weights = model.weights.first { facts += formatFacts(weights, header: header) }
        facts.append(Fact(title: tr("models.size"),
                          value: model.bytes.map { .value(tr(model.files.count == 1 ? "models.inventory.size.one" : "models.inventory.size", NativeFormat.disk($0), NativeFormat.count(model.files.count))) }
                              ?? .unavailable(reason: sizeReason(model.selections)),
                          provenance: Provenance(source: .system(name: tr("models.inventory.sizeSource")))))
        facts += familyFacts(model.selections, families: families, version: version, header: header)
        return ModelCardSummary(id: model.id, name: model.name,
                                location: location(model.weights.first.map { display($0.path) } ?? model.hubModels.first ?? "", facts: facts),
                                tags: tags, facts: facts, preparations: model.selections.map { preparation($0, shelf: shelf, version: version) },
                                configurations: configurations, actions: actions)
    }

    static func location(_ path: String, facts: [Fact]) -> String {
        facts.contains { $0.value == .value(path) } ? "" : path
    }

    static func sourceTitle(_ kind: InventorySource.Kind) -> String {
        switch kind {
        case .localFiles: tr("models.source.title.local")
        case let .otherApp(app): tr("models.source.title.otherApp", app)
        case .hubCache: tr("models.source.title.hubCache")
        case .preparation: tr("models.source.title.preparation")
        case .obsolete: tr("models.source.title.obsolete")
        }
    }

    static func weightsSummary(_ model: InventoryModel, shelf: ModelShelf, actions: [NativeAction]) -> WeightsSummary {
        var facts = model.sources.map { source in
            Fact(title: sourceTitle(source.kind), value: .value(sourceValue(source)), provenance: Provenance(source: .system(name: tr("models.inventory.source"))))
        }
        facts.append(Fact(title: tr("models.size"),
                          value: model.bytes.map { .value(tr(model.files.count == 1 ? "models.inventory.size.one" : "models.inventory.size", NativeFormat.disk($0), NativeFormat.count(model.files.count))) }
                              ?? .unavailable(reason: tr("models.inventory.noFiles")),
                          provenance: Provenance(source: .system(name: tr("models.inventory.sizeSource")))))
        if let weights = model.weights.first, weights.role == .draft, let architecture = weights.architectures.first {
            facts.append(Fact(title: tr("models.architecture"), value: .value(architecture), provenance: Provenance(source: .file(name: "config.json"))))
        }
        if let weights = model.weights.first, let header = shelf.headers[weights.path], let dominant = header.dominant {
            facts.append(Fact(title: tr("models.quantization"),
                              value: .value(tr("models.share", dominant.type, NativeFormat.number(dominant.share * 100, fractionDigits: 2))),
                              provenance: Provenance(source: .file(name: tr("models.ggufHeader")))))
        }
        return WeightsSummary(id: model.id, name: model.name, location: location(model.weights.first.map { display($0.path) } ?? "", facts: facts),
                              facts: facts,
                              usedBy: model.usedBy.map { "\(LocalWeights.displayName(path: $0.model ?? $0.name)) · \($0.hashed ? String($0.name.prefix(12)) : $0.name)" },
                              actions: actions)
    }

    static func deletionNotices(_ shelf: ModelShelf) -> [String] {
        shelf.deletions.sorted { $0.key < $1.key }.compactMap { name, outcome in
            if let failure = outcome.failure, !outcome.moved.isEmpty || !outcome.removals.isEmpty {
                return tr(outcome.moved.count == 1 ? "models.deleted.partial.one" : "models.deleted.partial", name, NativeFormat.count(outcome.moved.count), failure)
            }
            guard outcome.failure == nil else { return nil }
            return tr(outcome.moved.count == 1 ? "models.deleted.one" : "models.deleted", name, NativeFormat.count(outcome.moved.count))
        }
    }
}
