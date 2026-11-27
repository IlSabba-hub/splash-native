import AppKit
import NativeCore
import NativeUI
import SwiftUI

struct MenuBarSection: View {
    let board: ServerBoard
    let actions: ServerActions
    let navigation: NativeNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NativeMenuBarContent(loaded: loaded, loadable: loadable, summary: summary)
    }

    private var loaded: SectionState<[MenuServerItem]> {
        guard board.prepared else { return .unavailable(reason: tr("reason.reading")) }
        if let error = board.configurationsError { return .unavailable(reason: error) }
        let principals = Set(board.model.principals.map(\.name))
        let servers = board.activeServers.sorted { a, b in
            let (pa, pb) = (principals.contains(a.name), principals.contains(b.name))
            return pa != pb ? pa : a.port < b.port
        }
        return .available(servers.map { item($0, name: $0.name) })
    }

    private var loadable: [MenuServerItem] {
        guard board.prepared, board.configurationsError == nil else { return [] }
        let stopped = board.model.configurations.filter { board.server(for: $0) == nil }
        return (stopped.filter(\.principal) + stopped.filter { !$0.principal }).map { configuration in
            let id = ServerActions.itemID(configuration: configuration.name)
            let start = actions.startAction(configuration)
            let swapAsks = if case .destructive = start.role { true } else { false }
            let action = actions.pendingAction(for: id) != nil ? showInWindow(id, title: tr("menu.confirmInWindow"))
                : swapAsks ? showInWindow(id, title: tr("menu.swapInWindow")) : start
            return MenuServerItem(id: id, name: configuration.name, status: .stopped, port: configuration.port, actions: [action],
                                  principal: configuration.principal)
        }
    }

    private func item(_ server: ServerBoard.Server, name: String) -> MenuServerItem {
        let status = server.status
        var list = actions.actions(for: server).map { action -> NativeAction in
            guard case .destructive = action.role else { return action }
            return showInWindow(server.id, title: tr("menu.stopInWindow"))
        }
        list.append(showInWindow(server.id, title: tr("chip.openInServers")))
        let title = status.detail.map { "\(name) · \($0)" } ?? name
        return MenuServerItem(id: server.id, name: title, status: status.kind, port: server.port, actions: list,
                              memory: server.reading?.snapshot.memoryActual?.currentBytes.map { NativeFormat.memory($0) },
                              foundOutside: !server.managed)
    }

    private func showInWindow(_ id: String, title: String) -> NativeAction {
        let openWindow = openWindow
        return NativeAction(title: title, systemImage: "macwindow") { [actions, navigation] in
            actions.selection = id
            navigation.section = .servers
            openWindow(id: NativeScene.main)
            NSApp.activate()
        }
    }

    private var summary: String? {
        guard board.prepared, let budget = board.model.budget else { return nil }
        let readings = board.activeServers.map { ($0.name, $0.reading?.snapshot.memoryActual?.currentBytes) }
        let missing = readings.filter { $0.1 == nil }.map(\.0)
        let measured = readings.compactMap(\.1).reduce(0, +)
        let line = tr("menu.memory", NativeFormat.memory(measured), NativeFormat.memory(Int64(budget)))
        return missing.isEmpty ? line : tr("menu.memoryPartial", line, missing.joined(separator: ", "))
    }
}
