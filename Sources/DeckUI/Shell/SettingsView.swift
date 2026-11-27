import SwiftUI

public struct SettingsRow: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let value: Measured<String>
    public let detail: String?
    public let provenance: Provenance?
    public let action: DeckAction?

    public init(id: String? = nil, title: String, value: Measured<String>, detail: String? = nil, provenance: Provenance? = nil,
                action: DeckAction? = nil) {
        self.id = id ?? title
        self.title = title
        self.value = value
        self.detail = detail
        self.provenance = provenance
        self.action = action
    }
}

public struct SettingsSection: Sendable {
    public let title: String
    public let footer: String?
    public let state: SectionState<[SettingsRow]>

    public init(title: String, footer: String? = nil, state: SectionState<[SettingsRow]>) {
        self.title = title
        self.footer = footer
        self.state = state
    }
}

public struct DeckSettingsContent: Sendable {
    public let folders: [SettingsSection]
    public let ports: [SettingsSection]
    public let agents: [SettingsSection]
    public let advanced: [SettingsSection]
    public let modelPort: ModelPortSettings?

    public init(folders: [SettingsSection], ports: [SettingsSection], agents: [SettingsSection], advanced: [SettingsSection],
                modelPort: ModelPortSettings? = nil) {
        self.folders = folders
        self.ports = ports
        self.agents = agents
        self.advanced = advanced
        self.modelPort = modelPort
    }
}

public struct ModelPortSettings: Sendable {
    public let port: Int
    public let users: [String]
    public let holder: String?
    public let problem: @MainActor @Sendable (Int) -> String?
    public let apply: @MainActor @Sendable (Int) -> Void
    public let outcome: ServerNotice?

    public init(port: Int, users: [String], holder: String?, problem: @escaping @MainActor @Sendable (Int) -> String?,
                apply: @escaping @MainActor @Sendable (Int) -> Void, outcome: ServerNotice? = nil) {
        self.port = port
        self.users = users
        self.holder = holder
        self.problem = problem
        self.apply = apply
        self.outcome = outcome
    }
}

public struct DeckSettingsView<GPUMemory: View>: View {
    private let content: DeckSettingsContent
    private let gpuMemory: GPUMemory
    @State private var tab: SettingsTab

    public init(content: DeckSettingsContent, @ViewBuilder gpuMemory: () -> GPUMemory) {
        self.init(content: content, tab: .general, gpuMemory: gpuMemory)
    }

    init(content: DeckSettingsContent, tab: SettingsTab, @ViewBuilder gpuMemory: () -> GPUMemory) {
        self.content = content
        self.gpuMemory = gpuMemory()
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        TabView(selection: $tab) {
            Tab(tr("settings.general"), systemImage: "gearshape", value: SettingsTab.general) { GeneralSettings() }
            Tab(tr("settings.folders"), systemImage: "folder", value: SettingsTab.folders) { SettingsPane(sections: content.folders) }
            Tab(tr("settings.ports"), systemImage: "network", value: SettingsTab.ports) {
                SettingsPane(sections: content.ports, modelPort: content.modelPort)
            }
            Tab(tr("settings.agents"), systemImage: "person.2", value: SettingsTab.agents) { SettingsPane(sections: content.agents) }
            Tab(tr("settings.gpu"), systemImage: "memorychip", value: SettingsTab.gpu) { gpuMemory }
            Tab(tr("settings.advanced"), systemImage: "slider.horizontal.3", value: SettingsTab.advanced) {
                SettingsPane(sections: content.advanced)
            }
        }
        .frame(width: 600)
        .frame(minHeight: 340)
    }
}

enum SettingsTab: Hashable { case general, folders, ports, agents, gpu, advanced }

struct GeneralSettings: View {
    @AppStorage(DeckPreferences.menuBarExtraShown) private var menuBarExtraShown = true
    @AppStorage(DeckPreferences.memoryAutoProbe) private var memoryAutoProbe = false
    @State private var language = AppLanguage.stored()
    private let suggestion = AppLanguage.suggestion(stored: AppLanguage.stored(), system: AppLanguage.systemLanguages())

    var body: some View {
        Form {
            Section {
                Toggle(tr("settings.menuBarExtra"), isOn: $menuBarExtraShown)
            }
            Section {
                Toggle(isOn: $memoryAutoProbe) {
                    Text(tr("settings.memoryProbe"))
                    Text(tr("settings.memoryProbe.detail"))
                }
            } header: {
                Text(tr("settings.memoryProbe.title"))
            } footer: {
                Text(tr("settings.memoryProbe.footer")).font(Typo.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker(tr("settings.language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option == suggestion ? tr("settings.language.suggested", option.title) : option.title).tag(option)
                    }
                }
                .onChange(of: language) { _, choice in AppLanguage.store(choice) }
                if AppLanguage.needsRelaunch(language) {
                    LabeledContent {
                        if AppLanguage.canRelaunch {
                            Button(tr("settings.language.relaunch")) { AppLanguage.relaunch() }
                        }
                    } label: {
                        Text(tr("settings.language.relaunchNeeded"))
                    }
                }
                LabeledContent(tr("settings.appearance"), value: tr("settings.appearance.dark"))
            } footer: {
                Text(tr("settings.language.footer")).font(Typo.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingsPane: View {
    let sections: [SettingsSection]
    var modelPort: ModelPortSettings? = nil

    var body: some View {
        Form {
            if let modelPort { ModelPortSection(settings: modelPort) }
            ForEach(sections.indices, id: \.self) { index in
                let section = sections[index]
                Section {
                    switch section.state {
                    case let .available(rows) where rows.isEmpty:
                        Text(tr("settings.none")).foregroundStyle(.secondary)
                    case let .available(rows):
                        ForEach(rows) { SettingsRowView(row: $0) }
                    case let .unavailable(reason):
                        UnavailableState(title: section.title, reason: reason)
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    if let footer = section.footer { Text(footer).font(Typo.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ModelPortSection: View {
    let settings: ModelPortSettings
    @State private var typed: Int?
    @AppStorage(DeckPreferences.swapWithoutAsking) private var withoutAsking = false
    @Environment(\.deckPalette) private var palette

    var body: some View {
        let value = typed ?? settings.port
        let problem = value == settings.port ? nil : settings.problem(value)
        Section {
            LabeledContent {
                HStack(spacing: Space.s) {
                    TextField(tr("settings.modelPort"), value: $typed, format: .number.grouping(.never), prompt: Text(verbatim: String(settings.port)))
                        .settingField(invalid: problem != nil)
                        .onSubmit { if problem == nil, value != settings.port { settings.apply(value); typed = nil } }
                    Button(tr("settings.modelPort.apply")) {
                        settings.apply(value)
                        typed = nil
                    }
                    .disabled(problem != nil || value == settings.port)
                }
            } label: {
                Text(tr("settings.modelPort"))
                Text(settings.users.isEmpty ? tr("settings.modelPort.noUsers")
                     : tr("settings.modelPort.users", settings.users.joined(separator: ", ")))
                    .font(Typo.caption)
            }
            if let problem { Text(problem).font(Typo.caption).foregroundStyle(palette.error.color) }
            LabeledContent(tr("settings.modelPort.holder"), value: settings.holder ?? tr("settings.ports.free"))
            Toggle(isOn: Binding(get: { !withoutAsking }, set: { withoutAsking = !$0 })) {
                Text(tr("settings.modelPort.ask"))
                Text(tr("settings.modelPort.ask.detail")).font(Typo.caption)
            }
            if let outcome = settings.outcome { NoticeView(outcome) }
        } header: {
            Text(tr("settings.modelPort.title"))
        } footer: {
            Text(tr("settings.modelPort.footer")).font(Typo.caption).foregroundStyle(.secondary)
        }
    }
}

struct SettingsRowView: View {
    let row: SettingsRow
    @Environment(\.deckPalette) private var palette

    var body: some View {
        LabeledContent {
            HStack(spacing: Space.s) {
                MeasuredText(row.value, font: Typo.body).foregroundStyle(palette.textSecondary.color).textSelection(.enabled)
                if let action = row.action {
                    Button { action.perform() } label: { Image(systemName: action.systemImage ?? "ellipsis").accessibilityLabel(action.title) }
                        .buttonStyle(.borderless)
                        .disabled(!action.isEnabled)
                        .help(action.disabledReason ?? action.title)
                }
            }
        } label: {
            Text(verbatim: row.title)
            if let detail = row.detail {
                Text(verbatim: detail).font(detail.hasPrefix("~") || detail.hasPrefix("/") ? Typo.code : Typo.caption)
            }
        }
        .help(row.provenance?.sourceDescription ?? "")
    }
}
