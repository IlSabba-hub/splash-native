import SwiftUI

public struct DeckCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content
    @Environment(\.deckPalette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast

    public init(padding: CGFloat = Space.l, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.color, in: .rect(cornerRadius: Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card)
                    .strokeBorder((contrast == .increased ? palette.stroke : palette.separator).color, lineWidth: 1)
            }
    }
}

public struct SectionHeader: View {
    private let title: String
    private let detail: String?
    @Environment(\.deckPalette) private var palette

    public init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(title)
                .font(Typo.sectionHeader)
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(palette.textSecondary.color)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(Typo.caption)
                    .foregroundStyle(palette.textTertiary.color)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }
}

public struct DeckPage<Content: View>: View {
    private let content: Content
    @Environment(\.deckPalette) private var palette

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) { content }
                .padding(Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background.color)
    }
}

#Preview("Card e intestazione") {
    VStack(alignment: .leading, spacing: Space.s) {
        SectionHeader(tr("overview.principals"), detail: "2")
        DeckCard { Text(verbatim: "nativ-community/Inkling-2-Mini-nvfp4").font(Typo.body) }
    }
    .padding(Space.xl)
    .frame(width: 420)
    .background(Palette.standard.background.color)
    .deckTheme()
}
