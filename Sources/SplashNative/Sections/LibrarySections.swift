import NativeCore
import NativeUI
import Observation
import SwiftUI

@MainActor @Observable
final class LibraryState {
    let native: NativeModel
    let shelf: ModelShelf
    let configurations: ConfigurationsState
    let discover: DiscoverState
    var modelSelection: String?
    var filter = ModelsFilter.all
    var search = ""
    var deletion: DeletionState?

    init(native: NativeModel) {
        self.native = native
        let shelf = ModelShelf(native: native)
        self.shelf = shelf
        configurations = ConfigurationsState(native: native, shelf: shelf)
        discover = DiscoverState(native: native, shelf: shelf)
    }

    func load() async {
        if let installation = shelf.installation { _ = try? await native.schema(for: installation) }
        if shelf.hubCache == nil { shelf.hubCache = native.hubCache }
        await shelf.refresh()
    }

    func modelsActions(_ loads: LoadController) -> ModelsAdapter.Actions {
        ModelsAdapter.Actions(openSettings: { loads.edit($0) },
                              newSettings: { model, apiModelID, draft in
                                  loads.editNew(loads.newConfiguration(weights: model, apiModelID: apiModelID, draft: draft))
                              },
                              delete: { [weak self] id in self?.askDeletion(id) })
    }

    func askDeletion(_ id: String) {
        let state = DeletionState(id: id, shelf: shelf)
        deletion = state
        Task { await state.check() }
    }
}

struct ModelsColumnView: View {
    @Bindable var state: LibraryState
    let loads: LoadController

    var body: some View {
        ModelsColumn(ModelsAdapter.overview(state.shelf, actions: state.modelsActions(loads)), filter: $state.filter)
            .task { if state.shelf.scanned == nil { await state.load() } }
    }
}

struct ModelsSectionView: View {
    @Bindable var state: LibraryState
    let loads: LoadController

    var body: some View {
        let shelf = state.shelf
        switch ModelsAdapter.overview(shelf, actions: state.modelsActions(loads)) {
        case let .available(overview):
            ModelsScreen(overview, filter: state.filter, search: $state.search, selection: $state.modelSelection,
                         refresh: NativeAction(title: tr("models.refresh"), systemImage: "arrow.clockwise", isEnabled: !shelf.scanning) {
                             Task { await state.load() }
                         })
                .task { if shelf.scanned == nil { await state.load() } }
                .sheet(item: $state.deletion) { deletion in
                    DeletionSheet(DeletionAdapter.content(deletion)) { state.deletion = nil }.nativeTheme()
                }
        case let .unavailable(reason):
            SectionPage(.models, unavailable: reason)
        }
    }
}

struct ModelsInspectorView: View {
    let state: LibraryState
    let loads: LoadController

    var body: some View {
        let overview: ModelsOverview? = if case let .available(overview) = ModelsAdapter.overview(state.shelf, actions: state.modelsActions(loads)) {
            overview
        } else {
            nil
        }
        let id = state.modelSelection
        if let overview, let model = overview.models.first(where: { $0.id == id }) {
            ModelInspector(model)
        } else if let overview, let weights = (overview.drafts + overview.projectors).first(where: { $0.id == id }) {
            WeightsInspector(weights)
        } else {
            EmptyState(symbol: "sidebar.trailing", title: tr("inspector.empty.title"), message: tr("models.inspector.empty"))
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

struct ConfigurationEditorView: View {
    @Bindable var state: ConfigurationsState
    let loads: LoadController
    var pane: String?

    var body: some View {
        if let content = ConfigurationsAdapter.editor(state) {
            ConfigurationEditorSheet(content, header: $state.header, values: $state.values, search: $state.search,
                                     showsInapplicable: $state.showsInapplicable, review: ConfigurationsAdapter.review(state),
                                     menu: ConfigurationsAdapter.menu(state), verify: ConfigurationsAdapter.verifyAction(state),
                                     load: ConfigurationsAdapter.loadAction(state, loads: loads), changed: state.changed,
                                     notices: state.notices, pane: pane) { state.closeEditor() }
        }
    }
}

struct DiscoverSectionView: View {
    @Bindable var state: LibraryState

    var body: some View {
        @Bindable var discover = state.discover
        Group {
            switch DiscoverAdapter.overview(discover) {
            case let .available(overview):
                DiscoverScreen(overview, selection: Binding(get: { discover.selection }, set: { discover.select($0) }),
                               search: $discover.search, format: $discover.format, onlyFitting: $discover.onlyFitting,
                               hubID: $discover.hubID,
                               check: NativeAction(title: tr("discover.check"), systemImage: "checkmark.seal") {
                                   Task { await discover.check() }
                               })
                    .onAppear {
                        if discover.selection == nil, let first = overview.items.first { discover.select(first.id) }
                    }
            case let .unavailable(reason):
                SectionPage(.discover, unavailable: reason)
            }
        }
        .task { if state.shelf.scanned == nil { await state.load() } }
    }
}
