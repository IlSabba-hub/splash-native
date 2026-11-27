import AppKit
import DeckCore
import DeckUI
import SwiftUI

@main
struct SplashDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(DeckPreferences.menuBarExtraShown) private var menuBarExtraShown = true
    private let navigation = AppServices.shared.navigation
    @State private var chat = ChatController()

    var body: some Scene {
        Window(tr("app.name"), id: DeckScene.main) {
            MainWindowContent(navigation: navigation, chat: chat, library: AppServices.shared.library, loads: .shared)
                .frame(minWidth: DeckLayout.windowMinimum.width, minHeight: DeckLayout.windowMinimum.height)
                .deckTheme()
                .onChange(of: ServerBoard.shared.prepared ? ServerBoard.shared.activeServers.count : nil, initial: true) { _, count in
                    navigation.liveServers = count
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultWindowPlacement { _, context in
            WindowPlacement(size: Self.initialSize(visible: context.defaultDisplay.visibleRect.size))
        }
        .commands {
            CommandGroup(replacing: .help) {}
        }

        Settings {
            SettingsWindow()
        }

        MenuBarExtra(tr("app.name"), systemImage: "drop.fill", isInserted: $menuBarExtraShown) {
            MenuBarSection(board: .shared, actions: .shared, navigation: navigation)
        }
        .menuBarExtraStyle(.menu)
    }

    static func initialSize(visible: CGSize) -> CGSize {
        let ideal = DeckLayout.windowIdeal, minimum = DeckLayout.windowMinimum
        return CGSize(width: max(minimum.width, min(ideal.width, visible.width - 48)),
                      height: max(minimum.height, min(ideal.height, visible.height - 48)))
    }
}

struct MainWindowContent: View {
    let navigation: DeckNavigation
    let chat: ChatController
    let library: LibraryState
    @Bindable var loads: LoadController
    @State private var windowHeight: CGFloat?

    var body: some View {
        let board = ServerBoard.shared
        DeckMainView(navigation: navigation, hasColumn: Self.hasColumn, hasPanel: Self.hasPanel,
                     statusBar: StatusBarAdapter.bar(board: board, navigation: navigation)) {
            if navigation.updateAvailable {
                Button {
                    navigation.section = .versions
                } label: {
                    Label(tr("title.update"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } titleCenter: {
            TitleCenter(loaded: LoadAdapter.loaded(board: board, actions: .shared, navigation: navigation, controller: loads)
                            .map { chat.chip($0, in: board.model) },
                        picker: LoadAdapter.picker(board: board, controller: loads, shelf: library.shelf), isPresented: $loads.showsPicker,
                        profiles: ProfilesAdapter.content(board: board, controller: loads, state: library.configurations, shelf: library.shelf,
                                                          navigation: navigation))
        } column: { section in
            switch section {
            case .chat: ChatColumn(chat.column(), actions: chat.columnActions())
            case .models: ModelsColumnView(state: library, loads: loads)
            default: EmptyView()
            }
        } detail: { section in
            SectionContent(section: section, chat: chat, library: library, loads: loads, navigation: navigation)
        } panel: { section in
            switch section {
            case .chat: ChatInspector(chat.inspector(board.model), actions: chat.inspectorActions())
            case .models: ModelsInspectorView(state: library, loads: loads)
            default: InspectorEmpty()
            }
        }
        .sheet(isPresented: Binding(get: { loads.showsSheet || library.configurations.showsEditor },
                                    set: { if !$0 { loads.close(); library.configurations.closeEditor() } })) {
            if library.configurations.showsEditor {
                ConfigurationEditorView(state: library.configurations, loads: loads)
                    .deckTheme()
            } else if let content = loads.content {
                LoadSheet(content, settings: $loads.settings, notice: loads.notice, pending: loads.pending,
                          advanced: loads.advancedAction, measure: loads.measureAction, estimate: loads.estimate, load: loads.loadAction,
                          swap: loads.swapNote, estimateMissing: loads.estimateMissing,
                          estimateMissingHelp: loads.estimateMissingHelp,
                          maxHeight: windowHeight.map { $0 - DeckLayout.titleBarHeight }, cancel: { loads.close() })
                    .deckTheme()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { windowHeight = $0 }
        .onChange(of: loads.loaded) { _, loaded in if loaded { loads.close() } }
        .onAppear {
            loads.openAdvanced = { configuration, isNew in
                library.configurations.openEditor(configuration, isNew: isNew)
            }
        }
    }

    static func hasColumn(_ section: DeckSection) -> Bool { [.chat, .models].contains(section) }

    static func hasPanel(_ section: DeckSection) -> Bool { [.chat, .models].contains(section) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instance: Int32?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        AppLanguage.markLaunch()
        DeckText.use(language: AppLanguage.displayed)
        switch try? InstanceLock.acquire() {
        case let .acquired(descriptor)?:
            instance = descriptor
        case let .heldBy(pid)?:
            if let pid, let other = NSRunningApplication(processIdentifier: pid) { other.activate() }
            exit(0)
        case nil:
            break
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ServerBoard.shared.start()
        AppServices.shared.start()
    }
}

private struct SectionContent: View {
    let section: DeckSection
    let chat: ChatController
    let library: LibraryState
    let loads: LoadController
    let navigation: DeckNavigation

    var body: some View {
        switch section {
        case .servers:
            ServersSection(actions: .shared, loads: loads).openingOnARunningServer()
        case .chat:
            ChatSectionView(model: ServerBoard.shared.model, chat: chat, loads: loads, navigation: navigation)
        case .models:
            ModelsSectionView(state: library, loads: loads)
        case .discover:
            DiscoverSectionView(state: library)
        case .system:
            SystemSection()
        case .versions:
            VersionsSection()
        }
    }
}

private struct SettingsWindow: View {
    @State private var gpu = GPUMemoryController(didRead: { _ in ServerBoard.shared.model.refreshBudget() })

    var body: some View {
        @Bindable var gpu = gpu
        DeckSettingsView(content: SettingsContent.current) {
            GPUMemorySettings(gpu.presentation, selection: $gpu.selection)
                .task {
                    while !Task.isCancelled {
                        gpu.refresh()
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
        }
        .deckTheme()
    }
}

@MainActor
enum SettingsContent {
    static var current: DeckSettingsContent {
        DeckSettingsContent(folders: [modelFolders, deckFolders], ports: [ports], agents: [hermes], advanced: [linkedSplash, stats],
                            modelPort: modelPort)
    }

    private static var modelPort: ModelPortSettings {
        let board = ServerBoard.shared, shared = ModelPort.shared
        let port = shared.port
        let holder = board.activeServers.first { ModelPort.ports(of: $0).contains(port) }
        return ModelPortSettings(port: port, users: board.model.configurations.filter { $0.port == port }.map(\.name),
                                 holder: holder.map { $0.managed ? $0.name : tr("settings.modelPort.outside", $0.name, String($0.pid)) },
                                 problem: { shared.problem($0) },
                                 apply: { new in Task { await shared.change(to: new, model: board.model) } },
                                 outcome: shared.outcome)
    }

    static func reveal(_ url: URL) -> DeckAction? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return DeckAction(title: tr("action.showInFinder"), systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    static func present(_ url: URL) -> Measured<String> {
        FileManager.default.fileExists(atPath: url.path) ? .value(tr("models.folderPresent"))
            : .unavailable(reason: tr("models.folderMissing", ModelsAdapter.display(url.path)))
    }

    private static var ports: SettingsSection {
        let board = ServerBoard.shared
        let title = tr("settings.ports.configurations"), footer = tr("settings.ports.footer")
        guard board.prepared else { return SettingsSection(title: title, footer: footer, state: .unavailable(reason: tr("reason.reading"))) }
        if let error = board.configurationsError { return SettingsSection(title: title, footer: footer, state: .unavailable(reason: error)) }
        let rows = board.model.configurations.sorted { $0.port < $1.port }.map { configuration in
            let text = configuration.observe
                ? tr("settings.ports.observed", DeckFormat.port(configuration.port), DeckFormat.port(configuration.splashPort))
                : DeckFormat.port(configuration.port)
            let user = board.activeServers.first { server in
                server.port == configuration.splashPort || server.port == configuration.port || server.owned?.observedPort == configuration.port
            }
            return SettingsRow(title: configuration.name, value: .value(text),
                               detail: user.map { tr("settings.ports.inUse", $0.name) } ?? tr("settings.ports.free"),
                               provenance: Provenance(flag: "--port", source: .configuration(name: configuration.name)))
        }
        return SettingsSection(title: title, footer: footer, state: .available(rows))
    }

    private static var hermes: SettingsSection {
        let title = tr("settings.agents.hermes"), footer = tr("settings.agents.footer")
        switch OverviewAdapter(board: .shared).hermes {
        case let .unavailable(reason):
            return SettingsSection(title: title, footer: footer, state: .unavailable(reason: reason))
        case let .available(hermes):
            return SettingsSection(title: title, footer: footer, state: .available([
                SettingsRow(title: tr("overview.hermes.model"), value: hermes.model, provenance: hermes.modelProvenance),
                SettingsRow(title: tr("overview.hermes.endpoint"), value: hermes.endpoint, provenance: hermes.endpointProvenance),
                SettingsRow(title: tr("settings.agents.server"),
                            value: hermes.serving.map { .value($0.text) } ?? .unavailable(reason: tr("reason.hermesFieldMissing")),
                            provenance: Provenance(source: .response(field: "GET /v1/models · data[].id"))),
                SettingsRow(title: tr("settings.agents.file"), value: .value(ModelsAdapter.display(HermesConfig.defaultFile.path)),
                            action: reveal(HermesConfig.defaultFile)),
            ]))
        }
    }

    private static var modelFolders: SettingsSection {
        SettingsSection(title: tr("settings.folders.models"), state: .available(
            LocalWeightsScanner.defaultRoots.map { root in
                SettingsRow(title: ModelsAdapter.display(root.path), value: present(root),
                            provenance: Provenance(source: .deckDefault(what: tr("provenance.modelRoots"))), action: reveal(root))
            }))
    }

    private static var deckFolders: SettingsSection {
        let configurations = ServerBoard.shared.model.store.folder, logs = ServerSupervisor.defaultLogs
        let stats = AppServices.shared.stats.store
        return SettingsSection(title: tr("settings.folders.deck"), state: .available([
            SettingsRow(title: tr("settings.folders.configurations"),
                        value: ServerBoard.shared.prepared
                            ? .value(tr("settings.folders.count", DeckFormat.count(ServerBoard.shared.model.configurations.count)))
                            : .unavailable(reason: tr("reason.reading")),
                        detail: ModelsAdapter.display(configurations.path), action: reveal(configurations)),
            SettingsRow(title: tr("settings.folders.logs"),
                        value: FileManager.default.fileExists(atPath: logs.path) ? .value(tr("settings.folders.present"))
                            : .unavailable(reason: tr("models.folderMissing", ModelsAdapter.display(logs.path))), detail: ModelsAdapter.display(logs.path), action: reveal(logs)),
            SettingsRow(title: tr("settings.folders.stats"), value: .value(DeckFormat.disk(Int64(clamping: stats.bytesOnDisk()))),
                        detail: ModelsAdapter.display(stats.folder.path), action: reveal(stats.folder)),
        ]))
    }

    private static var linkedSplash: SettingsSection {
        let title = tr("settings.advanced.splash")
        guard let linked = LinkedSplash.find() else {
            return SettingsSection(title: title, state: .unavailable(reason: tr("settings.advanced.splashMissing")))
        }
        let root = linked.root
        return SettingsSection(title: title, state: .available([
            SettingsRow(title: tr("settings.advanced.version"), value: .value(linked.version),
                        provenance: Provenance(source: .system(name: "release.json"))),
            SettingsRow(title: tr("settings.advanced.path"), value: .value(root.path),
                        provenance: Provenance(source: .system(name: "/opt/homebrew/opt/splash")), action: reveal(root)),
        ]))
    }

    private static var stats: SettingsSection {
        let recorder = AppServices.shared.stats
        return SettingsSection(title: tr("settings.advanced.stats"), footer: tr("settings.advanced.stats.footer"), state: .available([
            SettingsRow(title: tr("settings.advanced.stats.keep"),
                        value: .value(tr(recorder.store.keepDays == 1 ? "settings.advanced.stats.keepValue.one" : "settings.advanced.stats.keepValue", DeckFormat.count(recorder.store.keepDays)))),
            SettingsRow(title: tr("settings.advanced.stats.cadence"), value: .value(DeckFormat.duration(seconds: recorder.every))),
        ]))
    }
}
