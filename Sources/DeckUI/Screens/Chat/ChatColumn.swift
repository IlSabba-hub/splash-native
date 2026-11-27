import SwiftUI

public struct ChatColumn: View {
    private let state: ChatColumnState
    private let actions: ChatColumnActions
    @State private var query = ""
    @State private var renaming: UUID?
    @State private var name = ""
    @State private var deleting: UUID?
    @Environment(\.deckPalette) private var palette

    public init(_ state: ChatColumnState, actions: ChatColumnActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(tr("section.chat")).font(Typo.pageTitle).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button {
                    actions.newChat()
                } label: {
                    Image(systemName: "square.and.pencil").accessibilityLabel(tr("chat.new"))
                }
                .buttonStyle(.borderless)
                .help(tr("chat.new"))
            }
            .padding(.horizontal, Space.m)
            HStack(spacing: Space.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
                TextField(tr("chat.search"), text: $query).textFieldStyle(.plain)
            }
            .font(Typo.small)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + 1)
            .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
            .padding(.horizontal, Space.s)
            if state.conversations.isEmpty {
                Text(tr("chat.empty.column")).font(Typo.small).foregroundStyle(palette.textTertiary.color)
                    .padding(.horizontal, Space.m)
                    .fixedSize(horizontal: false, vertical: true)
            } else if groups.isEmpty {
                Text(tr("chat.search.none")).font(Typo.small).foregroundStyle(palette.textTertiary.color)
                    .padding(.horizontal, Space.m)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.m) {
                        ForEach(groups, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.title)
                                    .font(Typo.caption.weight(.semibold))
                                    .foregroundStyle(palette.textTertiary.color)
                                    .padding(.horizontal, Space.s)
                                    .padding(.bottom, Space.xxs)
                                ForEach(group.rows) { row($0) }
                            }
                        }
                    }
                    .padding(.horizontal, Space.s)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Space.m)
        .frame(width: DeckLayout.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.column.color)
    }

    @ViewBuilder
    private func row(_ row: ChatConversationRow) -> some View {
        if renaming == row.id {
            TextField(tr("chat.rename.title"), text: $name)
                .textFieldStyle(.roundedBorder)
                .font(Typo.body)
                .onSubmit {
                    actions.rename(row.id, name)
                    renaming = nil
                }
                .onExitCommand { renaming = nil }
                .padding(.vertical, Space.xxs)
        } else if deleting == row.id {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(tr("chat.delete.question", row.title)).font(Typo.small).lineLimit(2)
                Text(tr("chat.delete.consequence")).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.xs) {
                    Button(tr("chat.cancel")) { deleting = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(tr("chat.delete"), role: .destructive) {
                        deleting = nil
                        actions.delete(row.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.error.color)
                }
                .controlSize(.small)
            }
            .padding(Space.s)
            .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
            .accessibilityElement(children: .contain)
        } else {
            ChatConversationItem(row: row, selected: row.id == state.selection, select: { actions.select(row.id) }) {
                menu(row)
            }
            .contextMenu { menu(row) }
        }
    }

    @ViewBuilder
    private func menu(_ row: ChatConversationRow) -> some View {
        Button {
            name = row.title
            deleting = nil
            renaming = row.id
        } label: {
            Label(tr("chat.rename"), systemImage: "pencil")
        }
        Button {
            actions.duplicate(row.id)
        } label: {
            Label(tr("chat.duplicate"), systemImage: "plus.square.on.square")
        }
        Divider()
        Button(role: .destructive) {
            renaming = nil
            deleting = row.id
        } label: {
            Label(tr("chat.delete.menu"), systemImage: "trash")
        }
    }

    private struct Group { let title: String; let rows: [ChatConversationRow] }

    private var groups: [Group] {
        let calendar = Calendar.current
        let rows = state.conversations.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
        var groups: [Group] = []
        for row in rows {
            let title = calendar.isDateInToday(row.updated) ? tr("chat.today")
                : calendar.isDateInYesterday(row.updated) ? tr("chat.yesterday")
                : DeckFormat.day(row.updated)
            if groups.last?.title == title {
                groups[groups.count - 1] = Group(title: title, rows: groups[groups.count - 1].rows + [row])
            } else {
                groups.append(Group(title: title, rows: [row]))
            }
        }
        return groups
    }
}

struct ChatConversationItem<Menu: View>: View {
    let row: ChatConversationRow
    let selected: Bool
    let select: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var hovered = false
    @Environment(\.deckPalette) private var palette

    var body: some View {
        HStack(spacing: Space.xs) {
            Button(action: select) {
                HStack(spacing: Space.xs) {
                    Text(verbatim: row.title).font(Typo.body).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: Space.xs)
                    if row.answering {
                        Image(systemName: "ellipsis.bubble").font(Typo.caption).foregroundStyle(palette.accent.color)
                            .accessibilityLabel(tr("chat.answering"))
                    } else if let tokens = row.tokens, !hovered {
                        Text(tr(tokens == 1 ? "chat.tokens.one" : "chat.tokens", DeckFormat.count(tokens))).font(Typo.caption.monospacedDigit())
                            .foregroundStyle(palette.textTertiary.color)
                            .help(tr("chat.row.tokens.help"))
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if hovered {
                SwiftUI.Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(palette.textSecondary.color)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("chat.row.menu"))
                .accessibilityLabel(tr("chat.row.menu"))
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs + 1)
        .background((selected ? palette.selection : hovered ? palette.surface : palette.column).color, in: .rect(cornerRadius: Radius.control))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
