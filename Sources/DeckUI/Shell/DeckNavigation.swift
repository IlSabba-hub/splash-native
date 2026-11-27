import Observation

@MainActor
@Observable
public final class DeckNavigation {
    public var section: DeckSection
    public var showsPanel: Bool
    public var showsColumn: Bool
    public var liveServers: Int?
    public var updateAvailable: Bool

    public init(section: DeckSection = .chat, showsPanel: Bool = true, showsColumn: Bool = true, liveServers: Int? = nil,
                updateAvailable: Bool = false) {
        self.section = section
        self.showsPanel = showsPanel
        self.showsColumn = showsColumn
        self.liveServers = liveServers
        self.updateAvailable = updateAvailable
    }
}
