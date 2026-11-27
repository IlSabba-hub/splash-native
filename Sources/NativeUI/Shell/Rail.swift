import SwiftUI

public struct NativeRail: View {
    @Bindable private var navigation: NativeNavigation
    @Environment(\.nativePalette) private var palette

    public init(navigation: NativeNavigation) {
        self.navigation = navigation
    }

    public var body: some View {
        VStack(spacing: Space.xs) {
            ForEach(NativeSection.allCases.filter { $0.railGroup == .top }) { item($0) }
            Spacer(minLength: Space.l)
            ForEach(NativeSection.allCases.filter { $0.railGroup == .bottom }) { item($0) }
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
        .frame(width: NativeLayout.railWidth)
        .frame(maxHeight: .infinity)
        .background(palette.rail.color)
    }

    private func item(_ section: NativeSection) -> some View {
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
    private func mark(_ section: NativeSection) -> some View {
        switch section {
        case .servers:
            if let live = navigation.liveServers, live > 0 {
                Text(NativeFormat.count(live))
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

    private func value(_ section: NativeSection) -> String {
        switch section {
        case .servers: navigation.liveServers.map { tr($0 == 1 ? "a11y.liveServers.one" : "a11y.liveServers", NativeFormat.count($0)) } ?? ""
        case .versions where navigation.updateAvailable: tr("a11y.updateAvailable")
        default: ""
        }
    }
}

#Preview("Barra a icone") {
    @Previewable @State var navigation = NativeNavigation(section: .servers, liveServers: 2, updateAvailable: true)
    NativeRail(navigation: navigation)
        .frame(height: 520)
        .nativeTheme()
}
