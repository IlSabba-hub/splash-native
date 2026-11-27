import SwiftUI

public struct DeckRail: View {
    @Bindable private var navigation: DeckNavigation
    @Environment(\.deckPalette) private var palette

    public init(navigation: DeckNavigation) {
        self.navigation = navigation
    }

    public var body: some View {
        VStack(spacing: Space.xs) {
            ForEach(DeckSection.allCases.filter { $0.railGroup == .top }) { item($0) }
            Spacer(minLength: Space.l)
            ForEach(DeckSection.allCases.filter { $0.railGroup == .bottom }) { item($0) }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(Typo.railIcon)
                    .foregroundStyle(palette.textSecondary.color)
                    .frame(width: 34, height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(tr("rail.settings"))
            .accessibilityLabel(tr("rail.settings"))
        }
        .padding(.vertical, Space.s)
        .frame(width: DeckLayout.railWidth)
        .frame(maxHeight: .infinity)
        .background(palette.rail.color)
    }

    private func item(_ section: DeckSection) -> some View {
        let selected = navigation.section == section
        return Button {
            navigation.section = section
        } label: {
            Image(systemName: section.symbol)
                .font(Typo.railIcon)
                .symbolVariant(selected ? .fill : .none)
                .foregroundStyle((selected ? palette.text : palette.textSecondary).color)
                .frame(width: 34, height: 34)
                .background(selected ? palette.selection.color : .clear, in: .rect(cornerRadius: Radius.control))
                .overlay(alignment: .topTrailing) { mark(section) }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityValue(value(section))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func mark(_ section: DeckSection) -> some View {
        switch section {
        case .servers:
            if let live = navigation.liveServers, live > 0 {
                Text(DeckFormat.count(live))
                    .font(Typo.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(palette.onAccent.color)
                    .padding(.horizontal, 3)
                    .background(palette.accentFill.color, in: .capsule)
                    .offset(x: 4, y: -2)
            }
        case .versions where navigation.updateAvailable:
            Circle().fill(palette.accent.color).frame(width: 7, height: 7).offset(x: 1, y: 2)
        default:
            EmptyView()
        }
    }

    private func value(_ section: DeckSection) -> String {
        switch section {
        case .servers: navigation.liveServers.map { tr($0 == 1 ? "a11y.liveServers.one" : "a11y.liveServers", DeckFormat.count($0)) } ?? ""
        case .versions where navigation.updateAvailable: tr("a11y.updateAvailable")
        default: ""
        }
    }
}

#Preview("Barra a icone") {
    @Previewable @State var navigation = DeckNavigation(section: .servers, liveServers: 2, updateAvailable: true)
    DeckRail(navigation: navigation)
        .frame(height: 520)
        .deckTheme()
}
