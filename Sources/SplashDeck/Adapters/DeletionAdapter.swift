import DeckCore
import DeckUI
import Foundation

@MainActor
enum DeletionAdapter {
    static func content(_ state: DeletionState) -> DeletionSheetContent {
        let model = state.plan?.model ?? state.shelf.inventory.model(state.id)
        let name = model?.name ?? ""
        let title = tr("delete.title", name)
        guard let plan = state.plan else {
            return DeletionSheetContent(title: title, subtitle: model.map(subtitle) ?? "", checking: true,
                                        blockedReason: state.gone ? tr("delete.gone") : nil, outcome: outcome(state.outcome), failure: state.outcome?.failure)
        }
        let checks = plan.issues.enumerated().map { index, issue in line(issue, index: index, state: state) }
        let items = plan.trash.map { item in
            DeletionItemLine(id: item.path, path: ModelsAdapter.display(item.path), detail: what(item.what),
                             size: item.freedBytes > 0 ? DeckFormat.disk(item.freedBytes) : nil)
        }
        let commands = plan.removals.map { $0.command.map(quote).map(ModelsAdapter.display).joined(separator: " ") }
        var summary = plan.trash.isEmpty ? "" : tr("delete.summary", DeckFormat.count(plan.trash.count), DeckFormat.disk(plan.freedBytes))
        if !plan.removals.isEmpty { summary += tr("delete.summary.splash", DeckFormat.count(plan.removals.count)) }
        if summary.hasPrefix(" · ") { summary.removeFirst(3) }
        let blocked: String? = plan.blocked ? tr("delete.blocked") : plan.isEmpty ? tr("delete.nothing") : nil
        let done = state.outcome.map { $0.failure == nil } ?? false
        let confirm = plan.canProceed && !done
            ? DeckAction(title: tr("delete.confirm"), systemImage: "touchid", isEnabled: !state.running && !state.checking) {
                Task { await state.run() }
            } : nil
        return DeletionSheetContent(title: title, subtitle: subtitle(plan.model), checking: state.checking, checks: checks, items: items,
                                    commands: commands, configurations: plan.removedConfigurations, summary: done ? "" : summary,
                                    confirm: confirm, blockedReason: done ? nil : blocked, running: state.running,
                                    outcome: outcome(state.outcome), failure: state.outcome?.failure)
    }

    static func subtitle(_ model: InventoryModel) -> String {
        let size = model.bytes.map { DeckFormat.disk($0) } ?? tr("value.unavailable")
        return tr("delete.subtitle", ModelsAdapter.stateTag(model).title, size, DeckFormat.count(model.sources.count))
    }

    static func outcome(_ outcome: DeletionOutcome?) -> [String] {
        guard let outcome else { return [] }
        var lines = outcome.moved.map { tr("delete.moved", ModelsAdapter.display($0.path)) }
        for (model, removal) in outcome.removals.sorted(by: { $0.key < $1.key }) {
            switch removal {
            case .removed: lines.append(tr("delete.removed", model))
            case let .failed(message): lines.append(tr("models.removeFailed", model, message))
            }
        }
        lines += outcome.configurations.map { tr("delete.configurationRemoved", $0) }
        return lines
    }

    static func quote(_ argument: String) -> String {
        argument.contains(" ") ? "'" + argument + "'" : argument
    }

    static func what(_ what: DeletionPlan.TrashItem.What) -> String {
        switch what {
        case .weights: tr("delete.what.weights")
        case .hubEntry: tr("delete.what.hubEntry")
        case .hubBlob: tr("delete.what.hubBlob")
        case let .otherApp(app): tr("delete.what.otherApp", app)
        case .selectionLink: tr("delete.what.selectionLink")
        case .packageLink: tr("delete.what.packageLink")
        case .packageFiles: tr("delete.what.packageFiles")
        }
    }

    static func short(_ link: String) -> String {
        let url = URL(filePath: link)
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        let shown = name.wholeMatch(of: /[0-9a-f]{64}/) != nil ? String(name.prefix(12)) + "…" : name
        return "…/models/\(parent)/\(shown)"
    }

    static func list(_ names: [String]) -> String { names.map(ModelsAdapter.display).joined(separator: ", ") }

    static func line(_ issue: DeletionPlan.Issue, index: Int, state: DeletionState) -> DeletionCheckLine {
        let id = "\(index)"
        switch issue {
        case let .served(link):
            return DeletionCheckLine(id: id, text: tr("delete.issue.served", short(link)), tone: .error)
        case let .usedByProcess(pid, name, path):
            return DeletionCheckLine(id: id, text: tr("delete.issue.process", name, String(pid), ModelsAdapter.display(path)), tone: .error)
        case let .splashWouldDelete(paths):
            return DeletionCheckLine(id: id, text: tr(paths.count == 1 ? "delete.issue.splashWouldDelete.one" : "delete.issue.splashWouldDelete", DeckFormat.count(paths.count),
                                                                      list(Array(paths.prefix(3)))),
                                     tone: .error)
        case .noInstallation:
            return DeletionCheckLine(id: id, text: tr("delete.issue.noInstallation"), tone: .error)
        case let .configurationsNeedChoice(names), let .configurationsKept(names), let .configurationsRemoved(names):
            let selected: Int? = switch state.choices.configurations {
            case .keep?: 0
            case .remove?: 1
            case nil: nil
            }
            let one = names.count == 1
            return DeletionCheckLine(id: id, text: one ? tr("delete.issue.configuration", names[0])
                                         : tr("delete.issue.configurations", names.joined(separator: ", ")),
                                     tone: selected == nil ? .warning : .neutral,
                                     options: [
                                         DeckAction(title: one ? tr("delete.choice.keepOne") : tr("delete.choice.keep")) {
                                             state.choose { $0.configurations = .keep }
                                         },
                                         DeckAction(title: one ? tr("delete.choice.removeOne") : tr("delete.choice.remove")) {
                                             state.choose { $0.configurations = .remove }
                                         },
                                     ], selected: selected)
        case let .usedByPreparations(names), let .preparationsBroken(names):
            let chosen = state.choices.breakPreparations
            let models = names.map { $0.hasPrefix("/") ? LocalWeights.displayName(path: $0) : $0 }.joined(separator: ", ")
            return DeletionCheckLine(id: id, text: tr("delete.issue.preparations", models), tone: chosen ? .neutral : .warning,
                                     options: [DeckAction(title: tr("delete.choice.break")) { state.choose { $0.breakPreparations.toggle() } }],
                                     selected: chosen ? 0 : nil)
        case let .otherAppSkipped(app, path), let .otherAppIncluded(app, path):
            let chosen = state.choices.includeOtherApps
            return DeletionCheckLine(id: id, text: tr(chosen ? "delete.issue.otherAppIncluded" : "delete.issue.otherAppSkipped", app,
                                                    ModelsAdapter.display(path)),
                                     tone: chosen ? .warning : .neutral,
                                     options: [DeckAction(title: tr("delete.choice.includeOtherApp", app)) { state.choose { $0.includeOtherApps.toggle() } }],
                                     selected: chosen ? 0 : nil)
        case let .hubCacheSkipped(path), let .hubCacheIncluded(path):
            let chosen = state.choices.includeHubCache
            return DeletionCheckLine(id: id, text: tr(chosen ? "delete.issue.hubCacheIncluded" : "delete.issue.hubCacheSkipped",
                                                    ModelsAdapter.display(path)),
                                     tone: chosen ? .warning : .neutral,
                                     options: [DeckAction(title: tr("delete.choice.includeHubCache")) { state.choose { $0.includeHubCache.toggle() } }],
                                     selected: chosen ? 0 : nil)
        case let .sharedBlobKept(path, users):
            return DeletionCheckLine(id: id, text: tr("delete.issue.sharedBlob", ModelsAdapter.display(path), list(users)), tone: .neutral)
        case let .outsideBlob(link, target):
            return DeletionCheckLine(id: id, text: tr("delete.issue.outsideBlob", ModelsAdapter.display(link), ModelsAdapter.display(target)),
                                     tone: .warning)
        case let .linkedFrom(link):
            return DeletionCheckLine(id: id, text: tr("delete.issue.linkedFrom", ModelsAdapter.display(link)), tone: .warning)
        case let .hardLinks(path):
            return DeletionCheckLine(id: id, text: tr("delete.issue.hardLinks", ModelsAdapter.display(path)), tone: .neutral)
        case let .noSplashCommand(link):
            return DeletionCheckLine(id: id, text: tr("delete.issue.noCommand", short(link)), tone: .neutral)
        case let .obsoletePackage(link, files):
            let text = files.map { tr("delete.issue.packageFiles", ModelsAdapter.display(link), ModelsAdapter.display($0)) }
                ?? tr("delete.issue.package", ModelsAdapter.display(link))
            return DeletionCheckLine(id: id, text: text, tone: .neutral)
        case .splashDataLater:
            return DeletionCheckLine(id: id, text: tr("delete.issue.splashData"), tone: .neutral)
        case .emptyTrashToFree:
            return DeletionCheckLine(id: id, text: tr("delete.issue.emptyTrash"), tone: .neutral)
        }
    }
}
