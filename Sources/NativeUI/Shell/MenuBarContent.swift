import AppKit
import SwiftUI

public struct MenuServerItem: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let status: StatusKind
    public let port: Int?
    public let actions: [NativeAction]
    public let principal: Bool
    public let memory: String?
    public let foundOutside: Bool

    public init(id: String, name: String, status: StatusKind, port: Int?, actions: [NativeAction] = [], principal: Bool = false,
                memory: String? = nil, foundOutside: Bool = false) {
        self.id = id
        self.name = name
        self.status = status
        self.port = port
        self.actions = actions.filter { if case .destructive = $0.role { false } else { true } }
        self.principal = principal
        self.memory = memory
        self.foundOutside = foundOutside
    }

    var title: String {
        var state = port.map { tr("menu.serverStatusPort", status.title, NativeFormat.port($0)) } ?? status.title
        if let memory { state += " · " + memory }
        if foundOutside { state += " · " + tr("chip.outside") }
        return tr("menu.serverLine", name, state)
    }
}

public struct NativeMenuBarContent: View {
    private let loaded: SectionState<[MenuServerItem]>
    private let loadable: [MenuServerItem]
    private let summary: String?
    @Environment(\.openWindow) private var openWindow

    public init(loaded: SectionState<[MenuServerItem]>, loadable: [MenuServerItem] = [], summary: String? = nil) {
        self.loaded = loaded
        self.loadable = loadable
        self.summary = summary
    }

    public var body: some View {
        switch loaded {
        case let .available(items):
            Section(tr("menu.loaded")) {
                if items.isEmpty { Text(tr("menu.nothingLoaded")) }
                ForEach(items) { item($0) }
            }
            if !loadable.isEmpty {
                Menu(tr("picker.title")) {
                    let principals = loadable.filter(\.principal), others = loadable.filter { !$0.principal }
                    if !principals.isEmpty {
                        Section(tr("overview.principals")) { ForEach(principals) { loadEntry($0) } }
                    }
                    if !others.isEmpty {
                        Section(tr("picker.configurations")) { ForEach(others) { loadEntry($0) } }
                    }
                }
            }
        case let .unavailable(reason):
            Text(tr("menu.serversUnavailable"))
            Text(reason)
        }
        if let summary {
            Divider()
            Text(summary)
        }
        Divider()
        Button(tr("menu.openApp")) {
            openWindow(id: NativeScene.main)
            NSApp.activate()
        }
        SettingsLink { Text(tr("menu.settings")) }
        Divider()
        Button(tr("menu.quit")) { NSApp.terminate(nil) }
    }

    @ViewBuilder
    private func loadEntry(_ entry: MenuServerItem) -> some View {
        ForEach(entry.actions.indices, id: \.self) { index in
            let action = entry.actions[index]
            let name = entry.port.map { tr("menu.loadLine", entry.name, NativeFormat.port($0)) } ?? entry.name
            Button(action.role == .primary ? name : tr("menu.actionOn", action.title, entry.name)) { action.perform() }
                .disabled(!action.isEnabled)
                .help(action.disabledReason ?? "")
        }
    }

    @ViewBuilder
    private func item(_ item: MenuServerItem) -> some View {
        if item.actions.isEmpty {
            Text(item.title)
        } else {
            Menu(item.title) {
                ForEach(item.actions.indices, id: \.self) { index in
                    let action = item.actions[index]
                    Button(action.title) { action.perform() }.disabled(!action.isEnabled)
                }
            }
        }
    }
}
