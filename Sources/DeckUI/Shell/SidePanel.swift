import SwiftUI

public struct DeckSidePanel<Content: View>: View {
    private let content: Content
    @Environment(\.deckPalette) private var palette

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(width: DeckLayout.inspectorWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(palette.column.color)
            .overlay(alignment: .leading) { Rectangle().fill(palette.separator.color).frame(width: 1) }
    }
}

public struct PanelSection<Content: View>: View {
    private let title: String
    private let detail: String?
    @State private var expanded: Bool
    private let content: Content
    @Environment(\.deckPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ title: String, detail: String? = nil, expanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        _expanded = State(initialValue: expanded)
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withDeckAnimation(.settle, reduceMotion: reduceMotion) { expanded.toggle() }
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "chevron.right")
                        .font(Typo.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(title).font(Typo.headline)
                    Spacer(minLength: Space.s)
                    if let detail { Text(detail).font(Typo.caption).foregroundStyle(palette.textTertiary.color) }
                }
                .foregroundStyle(palette.text.color)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(tr(expanded ? "a11y.collapse" : "a11y.expand"))
            if expanded {
                content.transition(DeckMotion.comingAndGoing(reduceMotion: reduceMotion))
            }
        }
        .padding(.vertical, Space.s)
    }
}
