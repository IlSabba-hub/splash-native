import Foundation

public struct ProfileItem: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let status: StatusKind
    public let principal: Bool
    public let load: NativeAction?
    public let edit: NativeAction
    public let duplicate: NativeAction?
    public let remove: NativeAction?
    public let show: NativeAction?
    public let rename: (@MainActor @Sendable (String) -> Void)?
    public let renameProblem: @MainActor @Sendable (String) -> String?

    public init(id: String, name: String, subtitle: String, status: StatusKind, principal: Bool, load: NativeAction?, edit: NativeAction,
                duplicate: NativeAction? = nil, remove: NativeAction? = nil, show: NativeAction? = nil,
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
    public let newBlank: NativeAction?
    public let newFromModel: [NativeAction]
    public let current: String?
    public let notice: ServerNotice?

    public init(items: SectionState<[ProfileItem]>, newBlank: NativeAction?, newFromModel: [NativeAction] = [], current: String? = nil,
                notice: ServerNotice? = nil) {
        self.items = items
        self.newBlank = newBlank
        self.newFromModel = newFromModel
        self.current = current
        self.notice = notice
    }
}
