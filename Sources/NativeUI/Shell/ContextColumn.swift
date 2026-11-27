import SwiftUI

public struct ColumnItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let symbol: String?
    public let status: StatusKind?
    public let detail: String?

    public init(id: String, title: String, subtitle: String? = nil, symbol: String? = nil, status: StatusKind? = nil, detail: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.status = status
        self.detail = detail
    }
}

public struct ColumnGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String?
    public let items: [ColumnItem]

    public init(id: String, title: String? = nil, items: [ColumnItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

extension ColumnGroup {
    public static func servers(_ items: [ServerListItem]) -> [ColumnGroup] {
        func item(_ item: ServerListItem) -> ColumnItem {
            ColumnItem(id: item.id, title: item.name, subtitle: item.kind == .foundOutside ? tr("status.foundOutside") : item.statusDetail,
                       status: item.status, detail: NativeFormat.port(item.port))
        }
        return [ColumnGroup(id: "servers", title: tr("column.servers.active"), items: items.filter { $0.kind != .configuration }.map(item)),
                ColumnGroup(id: "configurations", title: tr("column.servers.stopped"), items: items.filter { $0.kind == .configuration }.map(item))]
            .filter { !$0.items.isEmpty }
    }
}

public struct NativeColumn: View {
    private let title: String
    private let groups: SectionState<[ColumnGroup]>
    @Binding private var selection: String?
    private let search: Binding<String>?
    private let actions: [NativeAction]
    @Environment(\.nativePalette) private var palette

    public init(_ title: String, groups: SectionState<[ColumnGroup]>, selection: Binding<String?>, search: Binding<String>? = nil,
                actions: [NativeAction] = []) {
        self.title = title
        self.groups = groups
        _selection = selection
        self.search = search
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(title).font(Typo.pageTitle).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                ForEach(actions.indices, id: \.self) { index in
                    let action = actions[index]
                    Button { action.perform() } label: {
                        Image(systemName: action.systemImage ?? "plus").accessibilityLabel(action.title)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!action.isEnabled)
                    .help(action.disabledReason ?? action.title)
                }
            }
            .padding(.horizontal, Space.m)
            if let search {
                HStack(spacing: Space.xs) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
                    TextField(tr("column.search"), text: search).textFieldStyle(.plain)
                }
                .font(Typo.small)
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xs + 1)
                .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
                .padding(.horizontal, Space.s)
            }
            switch groups {
            case let .available(groups):
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.m) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 1) {
                                if let title = group.title {
                                    SectionHeader(title, detail: NativeFormat.count(group.items.count))
                                        .padding(.horizontal, Space.s)
                                        .padding(.bottom, Space.xxs)
                                }
                                ForEach(group.items) { row($0) }
                            }
                        }
                    }
                    .padding(.horizontal, Space.s)
                }
            case let .unavailable(reason):
                UnavailableState(title: title, reason: reason).padding(.horizontal, Space.m)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Space.m)
        .frame(width: NativeLayout.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.column.color)
    }

    private func row(_ item: ColumnItem) -> some View {
        let selected = selection == item.id
        return Button {
            selection = item.id
        } label: {
            HStack(spacing: Space.s) {
                if let status = item.status {
                    StatusDot(status)
                } else if let symbol = item.symbol {
                    Image(systemName: symbol).foregroundStyle(palette.textSecondary.color).frame(width: 16).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(Typo.body).lineLimit(1).truncationMode(.middle)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(Typo.caption).foregroundStyle(palette.textTertiary.color).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: Space.xs)
                if let detail = item.detail {
                    Text(detail).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.textTertiary.color)
                }
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + 1)
            .background(selected ? palette.selection.color : .clear, in: .rect(cornerRadius: Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

public struct StatusDot: View {
    private let status: StatusKind
    @Environment(\.nativePalette) private var palette

    public init(_ status: StatusKind) {
        self.status = status
    }

    public var body: some View {
        Image(systemName: status == .ready ? "circle.fill" : status == .starting ? "circle.dotted" : status == .error ? "exclamationmark.circle.fill" : "circle")
            .font(Typo.caption)
            .foregroundStyle(palette.color(of: status).color)
            .help(status.title)
            .accessibilityLabel(tr("a11y.status"))
            .accessibilityValue(status.title)
    }
}
