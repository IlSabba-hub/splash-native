import AppKit
import NativeCore
import NativeUI
import Foundation

@MainActor
enum ModelsAdapter {
    struct Actions {
        var openSettings: (_ configuration: Configuration) -> Void = { _ in }
        var newSettings: (_ model: String, _ apiModelID: String?, _ draft: String?) -> Void = { _, _, _ in }
        var delete: (_ id: String) -> Void = { _ in }
    }

    static func overview(_ shelf: ModelShelf, actions: Actions) -> SectionState<ModelsOverview> {
        guard let installation = shelf.installation, let models = shelf.modelsFolder else {
            return .unavailable(reason: tr("models.noInstallation"))
        }
        let families = shelf.native.schemas[installation.id]?.families
        let version = installation.version ?? installation.label
        let inventory = inventory(shelf, families: families, version: version, actions: actions)
        var folders = shelf.roots.map { root in
            let exists = FileManager.default.fileExists(atPath: root.path)
            let count = shelf.weights.filter { $0.path.hasPrefix(root.path + "/") }.count
            return Fact(title: display(root.path),
                        value: exists ? .value(tr("models.folderCount", NativeFormat.count(count))) : .unavailable(reason: tr("models.folderMissing", display(root.path))),
                        provenance: Provenance(source: .nativeDefault(what: tr("provenance.modelRoots"))))
        }
        folders.append(Fact(title: tr("models.splashData"), value: .value(display(models.path)),
                            provenance: Provenance(source: .file(name: "install/paths.py, Splash \(version)"))))
        var notices = shelf.sharedSelections.map { shared in
            tr("models.sharedNotice", shared.link, shared.users.map { "\($0.configuration) (\($0.version))" }.joined(separator: ", "))
        }
        notices += deletionNotices(shelf)
        for (model, outcome) in shelf.removals.sorted(by: { $0.key < $1.key }) {
            switch outcome {
            case .removed(let freed): notices.append(tr("models.removed", model, NativeFormat.disk(freed)))
            case .failed(let message): notices.append(tr("models.removeFailed", model, message))
            }
        }
        let root = shelf.roots.first { FileManager.default.fileExists(atPath: $0.path) } ?? models
        let folder = ModelsFolder(path: display(root.path), actions: [
            NativeAction(title: tr("action.showInFinder"), systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([root]) },
        ])
        return .available(ModelsOverview(folders: folders, scanned: shelf.scanned, models: inventory.cards, drafts: inventory.drafts,
                                         projectors: inventory.projectors, notices: notices, rows: inventory.rows, folder: folder))
    }

    static func sizeReason(_ preparations: [PreparedSelection]) -> String {
        if let assembly = preparations.first(where: { $0.kind == .assembly }) {
            let missing = assembly.files.filter { !$0.present }.count
            return tr("models.size.reason.missing", NativeFormat.count(missing), NativeFormat.count(assembly.files.count))
        }
        if preparations.contains(where: { $0.kind == .package }) { return tr("models.size.reason.package") }
        if let link = preparations.first, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.link.path) {
            return tr("models.size.reason.broken", display(target))
        }
        return tr("models.size.reason.none")
    }

    static func architecture(_ weights: LocalWeights, header: ModelTools.GGUFHeader?, ggufSource: String) -> SourcedText? {
        switch weights.format {
        case .gguf: header?.architecture.map { SourcedText($0, source: ggufSource + " · general.architecture") }
        case .safetensors:
            (weights.modelType ?? weights.architectures.first).map { SourcedText($0, source: tr("models.source.config", weights.modelType != nil ? "model_type" : "architectures")) }
        }
    }

    static func parameters(_ weights: LocalWeights, header: ModelTools.GGUFHeader?, ggufSource: String) -> SourcedText? {
        guard weights.format == .gguf, let header, header.error == nil else { return nil }
        let exact = weights.parts == 1 ? header.parameters : nil
        if let label = header.sizeLabel {
            let detail = exact.map { tr("models.source.paramsCount", NativeFormat.count(Int($0))) } ?? ""
            return SourcedText(label, source: ggufSource + " · general.size_label" + detail)
        }
        guard let exact else { return nil }
        return SourcedText(tr("models.params.billions", NativeFormat.number(Double(exact) / 1e9, fractionDigits: 1)),
                           source: ggufSource + tr("models.source.paramsCount", NativeFormat.count(Int(exact))))
    }

    static func quantization(_ weights: LocalWeights, header: ModelTools.GGUFHeader?, ggufSource: String) -> SourcedText? {
        switch weights.format {
        case .gguf:
            guard let dominant = header?.dominant else { return nil }
            return SourcedText(dominant.type, source: ggufSource + " · "
                               + tr("models.share", dominant.type, NativeFormat.number(dominant.share * 100, fractionDigits: 2)))
        case .safetensors:
            guard let quantization = weights.quantization else { return nil }
            let source = tr("models.source.config", "quantization")
            if let mode = quantization.mode, mode != "affine" { return SourcedText(mode, source: source) }
            if let bits = quantization.bits { return SourcedText(tr("load.bits", NativeFormat.count(bits)), source: source) }
            return quantization.method.map { SourcedText($0, source: source) }
        }
    }

    static func capabilities(_ family: String?, _ families: FamilyReport?) -> [Capability] {
        guard let family, let facts = families?.families[family]?.facts else { return [] }
        var found: [Capability] = []
        if case .bool(true)? = facts["vision"] { found.append(.vision) }
        if case .bool(true)? = facts["reasoning_switch"] { found.append(.reasoning) }
        return found
    }

    static func preparedDate(_ selection: PreparedSelection) -> Date? {
        let record = selection.link.resolvingSymlinksInPath().appending(path: "model.json")
        return try? record.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func preparedText(_ date: Date) -> SourcedText {
        SourcedText(NativeFormat.ago(date), source: tr("models.source.prepared", NativeFormat.moment(date)))
    }

    static func reveal(_ path: String) -> NativeAction {
        NativeAction(title: tr("action.showInFinder"), systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
        }
    }

    static func verifyActions(_ preparations: [PreparedSelection], shelf: ModelShelf) -> [NativeAction] {
        let assemblies = preparations.filter { $0.kind == .assembly }
        return assemblies.flatMap { selection -> [NativeAction] in
            let busy = shelf.verifying[selection.id] != nil
            let suffix = assemblies.count > 1 ? " · " + (selection.hashed ? String(selection.name.prefix(8)) : selection.name) : ""
            return [
                NativeAction(title: tr("models.verify.quick") + suffix, systemImage: "checkmark.shield", isEnabled: !busy) {
                    Task { await shelf.verify(selection, full: false) }
                },
                NativeAction(title: tr("models.verify.full", NativeFormat.disk(selection.bytes)) + suffix, systemImage: "number", isEnabled: !busy) {
                    Task { await shelf.verify(selection, full: true) }
                },
            ]
        }
    }

    static func settings(_ names: [String], shelf: ModelShelf, actions: Actions, newDisabledReason: String? = nil,
                         new: @escaping @MainActor @Sendable () -> Void) -> [NativeAction] {
        let configurations = names.compactMap { name in shelf.native.configurations.first { $0.name == name } }
        guard !configurations.isEmpty else {
            return [NativeAction(title: tr("models.settings"), systemImage: "gearshape", isEnabled: newDisabledReason == nil,
                               disabledReason: newDisabledReason, perform: new)]
        }
        return configurations.map { configuration in
            NativeAction(title: configurations.count == 1 ? tr("models.settings") : tr("models.settingsOf", configuration.name),
                       systemImage: "gearshape") { actions.openSettings(configuration) }
        }
    }

    static func commonTags(name: String, preparations: [PreparedSelection]) -> [ModelTag] {
        var tags: [ModelTag] = []
        if preparations.isEmpty {
            tags.append(ModelTag(tr("models.tag.notPrepared"), symbol: "circle.dashed"))
        } else if preparations.contains(where: \.present) {
            tags.append(ModelTag(tr("models.tag.prepared"), symbol: "checkmark.circle.fill", tone: .ready))
        } else if preparations.contains(where: { $0.kind == .package }) {
            tags.append(ModelTag(tr("models.tag.package"), symbol: "xmark.octagon.fill", tone: .error))
        } else {
            tags.append(ModelTag(tr("models.tag.missing"), symbol: "exclamationmark.triangle.fill", tone: .error))
        }
        if preparations.contains(where: { ($0.visionFormat ?? "none") != "none" && $0.present }) {
            tags.append(ModelTag(tr("badge.vision"), symbol: "eye"))
        }
        if name.localizedCaseInsensitiveContains("uncensored") { tags.append(ModelTag(tr("badge.uncensored"), tone: .accent)) }
        return tags
    }

    static func formatFacts(_ weights: LocalWeights, header: ModelTools.GGUFHeader?) -> [Fact] {
        switch weights.format {
        case .gguf:
            let source = Provenance(source: .file(name: tr("models.ggufHeader")))
            guard let header else {
                return [Fact(title: tr("models.quantization"), value: .unavailable(reason: tr("models.headerUnread")), provenance: source)]
            }
            if let error = header.error {
                return [Fact(title: tr("models.quantization"), value: .unavailable(reason: error), provenance: source)]
            }
            var facts: [Fact] = []
            if let dominant = header.dominant {
                facts.append(Fact(title: tr("models.quantization"),
                                  value: .value(tr("models.share", dominant.type, NativeFormat.number(dominant.share * 100, fractionDigits: 2))),
                                  provenance: source))
            }
            if let architecture = header.architecture {
                facts.append(Fact(title: tr("models.architecture"), value: .value(architecture), provenance: source))
            }
            return facts
        case .safetensors:
            let source = Provenance(source: .file(name: "config.json"))
            var facts: [Fact] = []
            if let quantization = weights.quantization {
                var parts: [String] = []
                if let mode = quantization.mode ?? quantization.method { parts.append(mode) }
                if let bits = quantization.bits { parts.append(tr("models.bits", NativeFormat.count(bits))) }
                if let group = quantization.groupSize { parts.append(tr("models.group", NativeFormat.count(group))) }
                if quantization.mixed { parts.append(tr("models.mixed")) }
                facts.append(Fact(title: tr("models.quantization"), value: .value(parts.joined(separator: " · ")), provenance: source))
            } else {
                facts.append(Fact(title: tr("models.quantization"), value: .unavailable(reason: tr("models.noQuantization")), provenance: source))
            }
            if let architecture = weights.architectures.first ?? weights.modelType {
                facts.append(Fact(title: tr("models.architecture"), value: .value(architecture), provenance: source))
            }
            return facts
        }
    }

    static func familyFacts(_ preparations: [PreparedSelection], families: FamilyReport?, version: String,
                                    header: ModelTools.GGUFHeader?) -> [Fact] {
        let recordSource = Provenance(source: .file(name: "model.json · family"))
        guard let family = preparations.compactMap(\.family).first else {
            var facts = [Fact(title: tr("models.family"), value: .unavailable(reason: tr("models.familyUnknown")), provenance: recordSource)]
            if let context = header?.contextLength {
                facts.append(Fact(title: tr("models.context"), value: .value(NativeFormat.count(context)),
                                  provenance: Provenance(source: .file(name: tr("models.ggufHeader")))))
            }
            return facts
        }
        var facts = [Fact(title: tr("models.family"), value: .value(family), provenance: recordSource)]
        let source = Provenance(flag: "--max-context", source: .file(name: "install/families.py, Splash \(version)"))
        if let entry = families?.families[family], let nativeTokens = entry.contextTokens {
            let most = entry.maxContextTokens ?? nativeTokens
            facts.append(Fact(title: tr("models.context"),
                              value: .value(most > nativeTokens ? tr("models.contextYarn", NativeFormat.count(nativeTokens), NativeFormat.count(most))
                                            : NativeFormat.count(nativeTokens)),
                              provenance: source))
        } else {
            facts.append(Fact(title: tr("models.context"), value: .unavailable(reason: tr("models.familyNotInVersion", family, version)), provenance: source))
        }
        let drafts = Set(preparations.compactMap(\.draft)).sorted()
        if !drafts.isEmpty {
            facts.append(Fact(title: tr("models.draft"), value: .value(drafts.map { URL(filePath: $0).lastPathComponent }.joined(separator: ", ")),
                              provenance: Provenance(flag: "--draft-model", source: .file(name: "model.json · sources.draft"))))
        }
        return facts
    }

    static func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func preparation(_ selection: PreparedSelection, shelf: ModelShelf, version: String) -> PreparationSummary {
        var title: [String] = []
        switch selection.kind {
        case .package: title.append(tr("models.prep.package"))
        case .broken: title.append(tr("models.prep.broken"))
        case .assembly:
            if !selection.hashed { title.append(tr("models.prep.alone")) }
            if let draft = selection.draft { title.append(tr("models.prep.draft", URL(filePath: draft).lastPathComponent)) }
            switch selection.visionFormat {
            case "none"?, nil: title.append(tr("models.prep.textOnly"))
            case let format?: title.append(tr("models.prep.vision", format))
            }
        }
        var tags: [ModelTag] = []
        var facts: [Fact] = []
        let record = Provenance(source: .file(name: "model.json"))
        if selection.kind == .assembly {
            let present = selection.files.filter(\.present).count
            tags.append(selection.present ? ModelTag(tr("models.prep.filesPresent"), symbol: "checkmark.circle.fill", tone: .ready)
                        : ModelTag(tr(selection.files.count - present == 1 ? "models.prep.filesMissing.one" : "models.prep.filesMissing",
                                      NativeFormat.count(selection.files.count - present)),
                                   symbol: "exclamationmark.triangle.fill", tone: .error))
            facts.append(Fact(title: tr("models.prep.files"),
                              value: .value(tr("models.prep.filesOf", NativeFormat.count(present), NativeFormat.count(selection.files.count))),
                              provenance: record))
            facts.append(Fact(title: tr("models.size"), value: .value(NativeFormat.disk(selection.bytes)),
                              provenance: Provenance(source: .file(name: "model.json · files[].bytes"))))
            if let assembly = selection.assembly {
                facts.append(Fact(title: tr("models.prep.assembly"), value: .value(".resolved/" + assembly.prefix(12)), provenance: record))
            }
            if let reason = selection.visionUnavailable {
                facts.append(Fact(title: tr("models.prep.visionUnavailable"), value: .value(reason),
                                  provenance: Provenance(source: .file(name: "model.json · vision_unavailable"))))
            }
        }
        let link = selection.hashed ? ".selections/" + selection.name.prefix(12) + "…" : selection.name
        let id = selection.id
        let state: VerificationState = if let full = shelf.verifying[id] {
            .running(full: full)
        } else if let error = shelf.verifyErrors[id] {
            .failed(full: false, message: error, seconds: nil)
        } else if let result = shelf.verifications[id] {
            result.passed ? .passed(full: result.full, seconds: result.seconds, date: result.date)
                : .failed(full: result.full, message: result.message ?? "", seconds: result.seconds)
        } else {
            .none
        }
        let busy = shelf.verifying[id] != nil
        let canVerify = selection.kind == .assembly
        let verifyQuick = canVerify ? NativeAction(title: tr("models.verify.quick"), systemImage: "checkmark.shield", isEnabled: !busy) {
            Task { await shelf.verify(selection, full: false) }
        } : nil
        let verifyFull = canVerify ? NativeAction(title: tr("models.verify.full", NativeFormat.disk(selection.bytes)), systemImage: "number",
                                                isEnabled: !busy, disabledReason: busy ? tr("models.verify.busy") : nil) {
            Task { await shelf.verify(selection, full: true) }
        } : nil
        var remove: NativeAction?
        var refusal: String?
        switch shelf.removalVerdict(selection) {
        case let .allowed(model, links, assemblies):
            remove = NativeAction(
                title: tr("models.remove"), systemImage: "trash",
                role: .destructive(question: tr("models.remove.question", model),
                                   consequence: tr("models.remove.consequence", links.joined(separator: ", "),
                                                   assemblies.map { String($0.prefix(12)) }.joined(separator: ", ")),
                                   confirmTitle: tr("models.remove")),
                isEnabled: shelf.removing == nil, disabledReason: shelf.removing.map { tr("models.remove.running", $0) }) {
                Task { await shelf.remove(selection) }
            }
        case let .refused(reason):
            refusal = reason.message
        }
        let configurations = shelf.configurations(using: selection.link).map(\.name).sorted()
        let warning = shelf.sharedSelections.first { $0.link == selection.link.path }.map { shared in
            tr("models.shared", shared.users.map { "\($0.configuration) (\($0.version))" }.joined(separator: ", "))
        }
        return PreparationSummary(id: id, title: title.joined(separator: " · "), link: link, present: selection.present, tags: tags,
                                  facts: facts, verification: state, verifyQuick: verifyQuick, verifyFull: verifyFull,
                                  remove: remove, removeRefusal: refusal, configurations: configurations, warning: warning)
    }
}
