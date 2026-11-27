import SwiftUI

public struct ProfilesButton: View {
    private let content: ProfilesContent
    private let iconOnly: Bool
    @State private var open = false
    @Environment(\.deckPalette) private var palette

    public init(_ content: ProfilesContent, iconOnly: Bool = false) {
        self.init(content, iconOnly: iconOnly, open: false)
    }

    init(_ content: ProfilesContent, iconOnly: Bool, open: Bool) {
        self.content = content
        self.iconOnly = iconOnly
        _open = State(initialValue: open)
    }

    public var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(palette.textSecondary.color).accessibilityHidden(true)
                if !iconOnly {
                    Text(tr("profiles.title")).font(Typo.small).foregroundStyle(palette.textSecondary.color).lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, Space.s)
            .frame(height: 28)
            .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.separator.color, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(tr("profiles.help"))
        .accessibilityLabel(tr("profiles.title"))
        .accessibilityAddTraits(open ? .isSelected : [])
        .deckDropdown(isPresented: $open, width: 460) { width, height, dismiss in
            ProfilesPanel(content, dismiss: dismiss, width: width, maxHeight: height)
        }
    }
}

public struct ProfilesPanel: View {
    private let content: ProfilesContent
    private let dismiss: () -> Void
    private let width: CGFloat
    private let maxHeight: CGFloat
    @Environment(\.deckPalette) private var palette

    public init(_ content: ProfilesContent, dismiss: @escaping () -> Void = {}, width: CGFloat = 460, maxHeight: CGFloat = 572) {
        self.content = content
        self.dismiss = dismiss
        self.width = width
        self.maxHeight = maxHeight
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                Text(tr("profiles.title")).font(Typo.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s)
                newMenu
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            Divider().overlay(palette.separator.color)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    if let notice = content.notice { NoticeView(notice) }
                    switch content.items {
                    case let .available(items) where items.isEmpty:
                        Text(tr("profiles.empty")).font(Typo.small).foregroundStyle(palette.textTertiary.color)
                            .frame(maxWidth: .infinity).padding(.vertical, Space.l)
                    case let .available(items):
                        group(tr("overview.principals"), items.filter(\.principal))
                        group(tr("picker.configurations"), items.filter { !$0.principal })
                    case let .unavailable(reason):
                        UnavailableState(title: tr("profiles.title"), reason: reason)
                    }
                }
                .padding(Space.m)
            }
            .frame(maxHeight: max(120, maxHeight - 46))
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .background(palette.column.color)
    }

    @ViewBuilder
    private var newMenu: some View {
        if content.newBlank != nil || !content.newFromModel.isEmpty {
            Menu {
                if let blank = content.newBlank {
                    Button { dismiss(); blank.perform() } label: { Label(blank.title, systemImage: blank.systemImage ?? "doc") }
                }
                if !content.newFromModel.isEmpty {
                    Menu(tr("profiles.new.fromModel")) {
                        ForEach(content.newFromModel.indices, id: \.self) { index in
                            let action = content.newFromModel[index]
                            Button { dismiss(); action.perform() } label: { Text(verbatim: action.title) }
                                .disabled(!action.isEnabled)
                        }
                    }
                }
            } label: {
                Label(tr("profiles.new"), systemImage: "plus")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help(tr("profiles.new.help"))
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [ProfileItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.xxs) {
                SectionHeader(title, detail: DeckFormat.count(items.count))
                ForEach(items) { ProfileRow(item: $0, dismiss: dismiss) }
            }
        }
    }
}

struct ProfileRow: View {
    let item: ProfileItem
    let dismiss: () -> Void
    @State private var hovered = false
    @State private var renaming: String?
    @State private var confirming: DeckAction?
    @FocusState private var nameFocused: Bool
    @Environment(\.deckPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                if let renaming { renameField(renaming) } else { title }
                Spacer(minLength: Space.xs)
                if renaming == nil { buttons }
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + 1)
            .background(hovered ? palette.surface.color : .clear, in: .rect(cornerRadius: Radius.control))
            .onHover { hovered = $0 }
            if let action = confirming, case let .destructive(question, consequence, confirmTitle) = action.role {
                InlineConfirmation(question: question, consequence: consequence, confirmTitle: confirmTitle,
                                   cancel: { confirming = nil }, confirm: { confirming = nil; action.perform() })
            }
        }
    }

    private var title: some View {
        Button {
            dismiss()
            item.edit.perform()
        } label: {
            HStack(spacing: Space.s) {
                StatusDot(item.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.name).font(Typo.body).lineLimit(1).truncationMode(.tail)
                    Text(verbatim: item.subtitle).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(tr("profiles.row.help", item.name))
        .accessibilityLabel(tr("profiles.row.a11y", item.name, item.status.title))
    }

    @ViewBuilder
    private var buttons: some View {
        if let load = item.load {
            icon(load, symbol: load.systemImage ?? "play.fill") {
                if case .destructive = load.role { confirming = load } else { dismiss(); load.perform() }
            }
        }
        icon(item.edit, symbol: "pencil") { dismiss(); item.edit.perform() }
        Menu {
            if let duplicate = item.duplicate {
                Button { dismiss(); duplicate.perform() } label: { Label(duplicate.title, systemImage: duplicate.systemImage ?? "plus.square.on.square") }
            }
            if item.rename != nil {
                Button {
                    renaming = item.name
                    nameFocused = true
                } label: { Label(tr("profiles.rename"), systemImage: "character.cursor.ibeam") }
            }
            if let show = item.show {
                Button { dismiss(); show.perform() } label: { Label(show.title, systemImage: show.systemImage ?? "terminal") }
            }
            if let remove = item.remove {
                Divider()
                Button(role: .destructive) { confirming = remove } label: {
                    Label(LoadedChip.menuTitle(remove), systemImage: remove.systemImage ?? "trash")
                }
                .disabled(!remove.isEnabled)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("profiles.more"))
        .accessibilityLabel(tr("profiles.more"))
    }

    private func icon(_ action: DeckAction, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).foregroundStyle(palette.textSecondary.color).frame(width: 18)
        }
        .buttonStyle(.borderless)
        .disabled(!action.isEnabled)
        .help(action.disabledReason ?? action.title)
        .accessibilityLabel(action.title)
    }

    private func renameField(_ text: String) -> some View {
        let problem = text == item.name ? nil : item.renameProblem(text)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.xs) {
                TextField(tr("config.name"), text: Binding(get: { renaming ?? "" }, set: { renaming = $0 }))
                    .settingTextField(width: 220, invalid: problem != nil)
                    .focused($nameFocused)
                    .onSubmit(commit)
                    .onExitCommand { renaming = nil }
                Button(tr("profiles.rename.save"), action: commit)
                    .controlSize(.small)
                    .disabled(problem != nil || text == item.name)
                Button(tr("confirm.cancel")) { renaming = nil }.controlSize(.small)
            }
            if let problem {
                Text(problem).font(Typo.caption).foregroundStyle(palette.error.color).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commit() {
        guard let text = renaming?.trimmingCharacters(in: .whitespaces), text != item.name, item.renameProblem(text) == nil,
              let rename = item.rename else { return }
        renaming = nil
        rename(text)
    }
}
