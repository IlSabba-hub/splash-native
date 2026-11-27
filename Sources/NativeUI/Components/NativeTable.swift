import SwiftUI

public struct NativeTableColumn: Sendable, Equatable, Identifiable {
    public enum Width: Sendable, Equatable {
        case fixed(CGFloat)
        case flexible(min: CGFloat)
    }

    public let id: String
    public let title: String
    public let width: Width
    public let trailing: Bool
    public let priority: Int

    public init(id: String, title: String, width: Width, trailing: Bool = false, priority: Int = 0) {
        self.id = id
        self.title = title
        self.width = width
        self.trailing = trailing
        self.priority = priority
    }

    var minimum: CGFloat {
        switch width {
        case let .fixed(width): width
        case let .flexible(min): min
        }
    }

    public static func fitting(_ columns: [NativeTableColumn], in width: CGFloat) -> [NativeTableColumn] {
        guard width > 0 else { return columns }
        var shown = columns
        func needed(_ list: [NativeTableColumn]) -> CGFloat {
            list.reduce(0) { $0 + $1.minimum } + Space.m * CGFloat(max(0, list.count - 1)) + 2 * Space.m
        }
        while needed(shown) > width, let drop = shown.indices.filter({ shown[$0].priority > 0 })
            .max(by: { shown[$0].priority < shown[$1].priority || (shown[$0].priority == shown[$1].priority && $0 > $1) }) {
            shown.remove(at: drop)
        }
        return shown
    }
}

public struct NativeTable<Row: Identifiable & Sendable, Cell: View>: View where Row.ID: Sendable {
    private let allColumns: [NativeTableColumn]
    private let rows: [Row]
    @Binding private var selection: Row.ID?
    private let cell: (Row, NativeTableColumn) -> Cell
    private let scrolls: Bool
    @State private var hovered: Row.ID?
    @State private var width: CGFloat = 0
    @Environment(\.nativePalette) private var palette

    public init(columns: [NativeTableColumn], rows: [Row], selection: Binding<Row.ID?>, scrolls: Bool = true,
                @ViewBuilder cell: @escaping (Row, NativeTableColumn) -> Cell) {
        allColumns = columns
        self.rows = rows
        _selection = selection
        self.scrolls = scrolls
        self.cell = cell
    }

    private var columns: [NativeTableColumn] { NativeTableColumn.fitting(allColumns, in: width) }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                ForEach(columns) { column in
                    sized(Text(column.title).font(Typo.small).foregroundStyle(palette.textSecondary.color), column)
                }
            }
            .padding(.horizontal, Space.m)
            .frame(height: 28)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Rectangle().fill(palette.separator.color).frame(height: 1)
            if scrolls {
                ScrollView { LazyVStack(spacing: 0) { rowList } }
            } else {
                VStack(spacing: 0) { rowList }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var rowList: some View {
        ForEach(rows) { row in
            rowView(row)
            Rectangle().fill(palette.separator.color.opacity(0.6)).frame(height: 1)
        }
    }

    private func rowView(_ row: Row) -> some View {
        let selected = selection == row.id
        return HStack(spacing: Space.m) {
            ForEach(columns) { column in
                sized(cell(row, column), column)
            }
        }
        .padding(.horizontal, Space.m)
        .frame(minHeight: 36)
        .background(selected ? palette.selection.color : hovered == row.id ? palette.surface.color : .clear)
        .contentShape(.rect)
        .onTapGesture { selection = row.id }
        .onHover { inside in hovered = inside ? row.id : (hovered == row.id ? nil : hovered) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func sized(_ view: some View, _ column: NativeTableColumn) -> some View {
        let cell = ZStack(alignment: column.trailing ? .trailing : .leading) {
            Color.clear.frame(height: 1)
            view
        }
        switch column.width {
        case let .fixed(width):
            cell.frame(width: width, alignment: column.trailing ? .trailing : .leading)
        case let .flexible(min):
            cell.frame(minWidth: min, maxWidth: .infinity, alignment: column.trailing ? .trailing : .leading)
        }
    }
}

public struct NativeTableFooter: View {
    private let summary: String
    private let folder: String?
    private let action: NativeAction?
    @Environment(\.nativePalette) private var palette

    public init(_ summary: String, folder: String? = nil, action: NativeAction? = nil) {
        self.summary = summary
        self.folder = folder
        self.action = action
    }

    public var body: some View {
        HStack(spacing: Space.s) {
            Text(summary).font(Typo.small).foregroundStyle(palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: Space.s)
            if let folder {
                Text(verbatim: folder)
                    .font(Typo.code)
                    .foregroundStyle(palette.textSecondary.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xxs)
                    .background(palette.surface.color, in: .rect(cornerRadius: Radius.small))
                    .textSelection(.enabled)
            }
            if let action {
                Button { action.perform() } label: {
                    Image(systemName: action.systemImage ?? "ellipsis").accessibilityLabel(action.title)
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help(action.title)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.xs)
        .frame(minHeight: 40)
        .background(palette.column.color)
    }
}
