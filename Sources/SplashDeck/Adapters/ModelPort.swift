import DeckCore
import DeckUI
import Foundation
import Observation

@MainActor @Observable
final class ModelPort {
    static var shared = ModelPort()

    @ObservationIgnored let defaults: UserDefaults
    private(set) var outcome: ServerNotice?
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var port: Int {
        _ = revision
        let stored = defaults.integer(forKey: DeckPreferences.modelPort)
        return (1 ... 65535).contains(stored) ? stored : DeckPreferences.defaultModelPort
    }

    var asks: Bool {
        _ = revision
        return !defaults.bool(forKey: DeckPreferences.swapWithoutAsking)
    }

    func stopAsking() {
        defaults.set(true, forKey: DeckPreferences.swapWithoutAsking)
        revision += 1
    }

    func problem(_ port: Int) -> String? {
        guard (1 ... 65535).contains(port) else { return tr("settings.modelPort.range") }
        if Configuration.reservedPorts.contains(port) { return tr("settings.modelPort.reserved", DeckFormat.port(port)) }
        return nil
    }

    static func ports(of configuration: Configuration) -> Set<Int> { [configuration.port, configuration.splashPort] }

    static func ports(of server: ServerBoard.Server) -> Set<Int> { Set([server.port] + (server.owned?.observedPort.map { [$0] } ?? [])) }

    static func occupant(of configuration: Configuration, board: ServerBoard) -> ServerBoard.Server? {
        let wanted = ports(of: configuration)
        return board.activeServers.first { server in
            server.owned?.configuration != configuration.name && !ports(of: server).isDisjoint(with: wanted)
        }
    }

    static func replaced(by configuration: Configuration, board: ServerBoard) -> Set<String> {
        occupant(of: configuration, board: board)?.owned.map { [$0.configuration] } ?? []
    }

    func change(to new: Int, model: DeckModel) async {
        let old = port
        guard new != old, problem(new) == nil else { return }
        let users = model.configurations.filter { $0.port == old }
        var moved: [String] = []
        for var configuration in users {
            configuration.port = new
            do {
                try await model.save(configuration, message: tr("config.commit.modelPort", configuration.name, DeckFormat.port(old), DeckFormat.port(new)))
                moved.append(configuration.name)
            } catch {
                outcome = ServerNotice(.failure, tr("config.saveFailed", error.localizedDescription))
                return
            }
        }
        defaults.set(new, forKey: DeckPreferences.modelPort)
        revision += 1
        outcome = ServerNotice(.success, moved.isEmpty ? tr("settings.modelPort.changed", DeckFormat.port(new))
                               : tr("settings.modelPort.moved", DeckFormat.port(new), moved.joined(separator: ", ")))
    }
}
