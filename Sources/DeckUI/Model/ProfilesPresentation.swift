import Foundation

public struct ProfileItem: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let status: StatusKind
    public let principal: Bool
    public let load: DeckAction?
    public let edit: DeckAction
    public let duplicate: DeckAction?
    public let remove: DeckAction?
    public let show: DeckAction?
    public let rename: (@MainActor @Sendable (String) -> Void)?
    public let renameProblem: @MainActor @Sendable (String) -> String?

    public init(id: String, name: String, subtitle: String, status: StatusKind, principal: Bool, load: DeckAction?, edit: DeckAction,
                duplicate: DeckAction? = nil, remove: DeckAction? = nil, show: DeckAction? = nil,
                rename: (@MainActor @Sendable (String) -> Void)? = nil,
                renameProblem: @escaping @MainActor @Sendable (String) -> String? = { _ in nil }) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.status = status
        self.principal = principal
        self.load = load
        self.edit = edit
        self.duplicate = duplicate
        self.remove = remove
        self.show = show
        self.rename = rename
        self.renameProblem = renameProblem
    }
}

public struct ProfilesContent: Sendable {
    public let items: SectionState<[ProfileItem]>
    public let newBlank: DeckAction?
    public let newFromModel: [DeckAction]
    public let current: String?
    public let notice: ServerNotice?

    public init(items: SectionState<[ProfileItem]>, newBlank: DeckAction?, newFromModel: [DeckAction] = [], current: String? = nil,
                notice: ServerNotice? = nil) {
        self.items = items
        self.newBlank = newBlank
        self.newFromModel = newFromModel
        self.current = current
        self.notice = notice
    }
}
