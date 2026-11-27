import SwiftUI

public struct WeightsPicker: View {
    private let title: String
    private let choices: [WeightsChoice]
    private let current: WeightsChoice?
    private let unset: String?
    private let pick: (String?) -> Void
    private let manual: (() -> Void)?
    @State private var open = false
    @Environment(\.nativePalette) private var palette

    public static let maxWidth: CGFloat = 420

    public init(_ title: String, choices: [WeightsChoice], current: WeightsChoice?, unset: String? = nil,
                pick: @escaping (String?) -> Void, manual: (() -> Void)? = nil) {
        self.title = title
        self.choices = choices
        self.current = current
        self.unset = unset
        self.pick = pick
        self.manual = manual
    }

    public var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Space.s) {
                Text(current?.name ?? unset ?? tr("weights.choose"))
                    .font(Typo.body)
                    .foregroundStyle((current == nil ? palette.textSecondary : palette.text).color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let current {
                    ForEach(current.badges.prefix(2), id: \.self) { NativeBadge($0).fixedSize() }
                    if let unavailable = current.unavailable {
                        NativeBadge(ModelTag(unavailable, symbol: "exclamationmark.triangle.fill", tone: .warning)).fixedSize()
                    }
                }
                Image(systemName: "chevron.up.chevron.down").font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs + 1)
            .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(palette.separator.color, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: Self.maxWidth, alignment: .trailing)
        .help(current?.detail ?? "")
        .accessibilityLabel(title)
        .accessibilityValue(current?.name ?? unset ?? "")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            WeightsPickerList(choices: choices, selected: current?.token, unset: unset, pick: { token in
                open = false
                pick(token)
            }, manual: manual.map { manual in { open = false; manual() } })
            .nativeTheme()
        }
    }
}

public struct WeightsPickerList: View {
    private let choices: [WeightsChoice]
    private let selected: String?
    private let unset: String?
    private let pick: (String?) -> Void
    private let manual: (() -> Void)?
    @Environment(\.nativePalette) private var palette

    public static let width: CGFloat = 480

    public init(choices: [WeightsChoice], selected: String?, unset: String? = nil, pick: @escaping (String?) -> Void,
                manual: (() -> Void)? = nil) {
        self.choices = choices
        self.selected = selected
        self.unset = unset
        self.pick = pick
        self.manual = manual
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xs) {
                if let unset {
                    row(selected: selected == nil, action: { pick(nil) }) {
                        Text(unset).font(Typo.body).foregroundStyle(palette.text.color)
                    }
                }
                ForEach(WeightsChoice.Group.allCases, id: \.self) { group in
                    let items = choices.filter { $0.group == group }
                    if !items.isEmpty {
                        Text(group.title).font(Typo.sectionHeader).foregroundStyle(palette.textTertiary.color)
                            .padding(.horizontal, Space.s)
                            .padding(.top, Space.s)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(items) { item in
                            row(selected: item.token == selected, action: { pick(item.token) }) { label(item) }
                                .disabled(item.unavailable != nil)
                                .help(item.unavailable ?? item.detail)
                        }
                    }
                }
                if choices.isEmpty {
                    Text(tr("weights.empty")).font(Typo.small).foregroundStyle(palette.textSecondary.color).padding(Space.s)
                }
                if let manual {
                    Divider().overlay(palette.separator.color)
                    row(selected: false, action: manual) {
                        Label(tr("weights.manual"), systemImage: "character.cursor.ibeam").font(Typo.small)
                            .foregroundStyle(palette.textSecondary.color)
                    }
                }
            }
            .padding(Space.s)
        }
        .frame(width: Self.width)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(palette.column.color)
    }

    private func label(_ item: WeightsChoice) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.s) {
                Text(item.name).font(Typo.body).foregroundStyle(palette.text.color).lineLimit(1).truncationMode(.middle)
                ForEach(item.badges, id: \.self) { NativeBadge($0).fixedSize() }
                if let unavailable = item.unavailable {
                    NativeBadge(ModelTag(unavailable, symbol: "exclamationmark.triangle.fill", tone: .warning)).fixedSize()
                }
                Spacer(minLength: Space.s)
                if let size = item.size {
                    Text(size).font(Typo.small.monospacedDigit()).foregroundStyle(palette.textSecondary.color).fixedSize()
                }
            }
            Text(verbatim: item.detail).font(Typo.code).foregroundStyle(palette.textTertiary.color)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func row(selected: Bool, action: @escaping () -> Void, @ViewBuilder _ content: () -> some View) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "checkmark").font(Typo.caption.weight(.semibold))
                    .foregroundStyle(palette.accent.color)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(!selected)
                content()
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.selection.color : Color.clear, in: .rect(cornerRadius: Radius.small))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
