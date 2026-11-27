import DeckCore
import DeckUI
import Foundation

@MainActor
enum StatusBarAdapter {
    static func bar(board: ServerBoard, navigation: DeckNavigation) -> DeckStatusBar {
        DeckStatusBar(leading: [memory(board, navigation), servers(board, navigation), hermes(board, navigation)].compactMap { $0 },
                      trailing: [version(board, navigation)])
    }

    private static func go(_ section: DeckSection, _ navigation: DeckNavigation) -> DeckAction {
        DeckAction(title: tr("status.open", section.title)) { navigation.section = section }
    }

    static func memory(_ board: ServerBoard, _ navigation: DeckNavigation) -> StatusBarItem {
        let action = go(.system, navigation)
        guard let budget = board.model.budget, budget > 0 else {
            return StatusBarItem(id: "memory", symbol: "memorychip", text: .unavailable(reason: tr("reason.metalBudget")), action: action)
        }
        guard board.prepared else {
            return StatusBarItem(id: "memory", symbol: "memorychip", text: .unavailable(reason: tr("reason.reading")), action: action)
        }
        let readings = board.activeServers.map { $0.reading?.snapshot.memoryActual?.currentBytes }
        let measured = readings.compactMap { $0 }.reduce(0, +)
        let missing = readings.filter { $0 == nil }.count
        return StatusBarItem(
            id: "memory", symbol: "memorychip",
            text: .value(tr("status.memory", DeckFormat.memory(measured), DeckFormat.memory(Int64(budget)))),
            fraction: Double(measured) / Double(budget),
            help: missing > 0 ? tr(missing == 1 ? "status.memory.missing.one" : "status.memory.missing", DeckFormat.count(missing)) : tr("status.memory.help"),
            action: action)
    }

    static func servers(_ board: ServerBoard, _ navigation: DeckNavigation) -> StatusBarItem {
        let action = go(.servers, navigation)
        guard board.prepared else {
            return StatusBarItem(id: "servers", symbol: "server.rack", text: .unavailable(reason: tr("reason.reading")), action: action)
        }
        let active = board.activeServers
        let outside = active.filter { !$0.managed }.count
        let text = outside > 0 ? tr("status.serversOutside", DeckFormat.count(active.count), DeckFormat.count(outside))
            : tr("status.servers", DeckFormat.count(active.count))
        return StatusBarItem(id: "servers", symbol: "server.rack", text: .value(text), action: action)
    }

    static func hermes(_ board: ServerBoard, _ navigation: DeckNavigation) -> StatusBarItem? {
        guard case let .available(hermes) = OverviewAdapter(board: board).hermes, let serving = hermes.serving else { return nil }
        let text: String = switch serving {
        case let .nobodyOnPort(port): tr("status.hermesNone", DeckFormat.port(port))
        case let .servedBy(server): tr("status.hermesServed", server)
        default: tr("status.hermes")
        }
        let port = board.hermes?.localPort
        let server = port.flatMap { port in board.activeServers.first { $0.port == port } }
        let action = DeckAction(title: tr("status.open", DeckSection.servers.title)) {
            if let server { ServerActions.shared.selection = server.id }
            navigation.section = .servers
        }
        let help = [hermes.model.value.map { tr("status.hermesModel", $0) }, serving.text, tr("hermes.readOnly"),
                    hermes.modelProvenance.sourceDescription].compactMap { $0 }.joined(separator: "\n")
        return StatusBarItem(id: "hermes", symbol: "person.wave.2", text: .value(text), help: help, action: action)
    }

    static func version(_ board: ServerBoard, _ navigation: DeckNavigation) -> StatusBarItem {
        let linked = board.model.installations.first { $0.linked }
        let text: Measured<String> = linked?.version.map { .value(tr("status.splash", $0)) }
            ?? .unavailable(reason: tr("settings.advanced.splashMissing"))
        return StatusBarItem(id: "version", symbol: "shippingbox", text: text, marked: navigation.updateAvailable,
                             help: navigation.updateAvailable ? tr("a11y.updateAvailable") : nil, action: go(.versions, navigation))
    }
}
