import DeckCore
import DeckUI
import Foundation

@MainActor
enum ProfilesAdapter {
    static func content(board: ServerBoard, controller: LoadController, state: ConfigurationsState, shelf: ModelShelf?,
                        navigation: DeckNavigation?) -> ProfilesContent {
        let items: SectionState<[ProfileItem]>
        if !board.prepared {
            items = .unavailable(reason: tr("reason.reading"))
        } else if let error = board.configurationsError {
            items = .unavailable(reason: error)
        } else {
            items = .available(board.model.configurations.map { item($0, board: board, controller: controller, state: state, navigation: navigation) })
        }
        var fromModel: [DeckAction] = []
        if let shelf {
            for weights in shelf.weights where weights.role == .target {
                let path = weights.path, name = weights.name
                let draft = shelf.preparations(of: weights).compactMap(\.draft).first
                let incomplete = weights.isIncomplete ? ModelsAdapter.incompleteText(weights) : nil
                fromModel.append(DeckAction(title: [weights.displayName, incomplete].compactMap { $0 }.joined(separator: " · "),
                                            isEnabled: incomplete == nil, disabledReason: incomplete) {
                    controller.editNew(controller.newConfiguration(weights: path, apiModelID: "local/" + name, draft: draft))
                })
            }
            for model in shelf.hubModels {
                fromModel.append(DeckAction(title: model) {
                    controller.editNew(controller.newConfiguration(weights: model, apiModelID: nil, draft: nil))
                })
            }
        }
        return ProfilesContent(items: items,
                               newBlank: DeckAction(title: tr("profiles.new.blank"), systemImage: "doc") { state.newBlank() },
                               newFromModel: fromModel, notice: state.panelFailure.map { ServerNotice(.failure, $0) })
    }

    static func item(_ configuration: Configuration, board: ServerBoard, controller: LoadController, state: ConfigurationsState,
                     navigation: DeckNavigation?) -> ProfileItem {
        let name = configuration.name
        let server = board.server(for: configuration)
        let waiting = server == nil ? ServerActions.waitingReason(configuration) : nil
        let load = server.map { LoadAdapter.ejectAction($0, actions: controller.actions, board: board) }
            ?? DeckAction(title: tr("action.start"), systemImage: "play.fill", isEnabled: waiting == nil, disabledReason: waiting) {
                controller.open(configuration)
            }
        let show = navigation.map { navigation in
            DeckAction(title: tr("profiles.show"), systemImage: "terminal") { [actions = controller.actions] in
                actions.choose(server?.id ?? ServerActions.itemID(configuration: name))
                navigation.section = .servers
            }
        }
        let remove = DeckAction(title: tr("config.remove"), systemImage: "trash",
                                role: .destructive(question: tr("config.remove.question", name), consequence: tr("config.remove.consequence"),
                                                   confirmTitle: tr("config.remove")),
                                isEnabled: server == nil, disabledReason: server == nil ? nil : tr("profiles.remove.loaded")) {
            Task { await state.remove(named: name) }
        }
        return ProfileItem(
            id: name, name: name, subtitle: ([OverviewAdapter.modelName(configuration), DeckFormat.port(configuration.port)]
                + (waiting == nil ? [] : [tr("files.waiting")])).joined(separator: " · "),
            status: server?.status.kind ?? .stopped, principal: configuration.principal, load: load, edit: controller.editAction(configuration),
            duplicate: DeckAction(title: tr("config.duplicate"), systemImage: "plus.square.on.square") { Task { await state.duplicate(named: name) } },
            remove: remove, show: show,
            rename: { new in Task { await state.rename(name, to: new) } },
            renameProblem: { new in state.renameProblem(name, to: new) })
    }
}
