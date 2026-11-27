import SwiftUI

public struct StatusBarItem: Sendable, Identifiable {
    public let id: String
    public let symbol: String
    public let text: Measured<String>
    public let fraction: Double?
    public let marked: Bool
    public let help: String?
    public let action: NativeAction?

    public init(id: String, symbol: String, text: Measured<String>, fraction: Double? = nil, marked: Bool = false, help: String? = nil,
                action: NativeAction? = nil) {
        self.id = id
        self.symbol = symbol
        self.text = text
        self.fraction = fraction
        self.marked = marked
        self.help = help
        self.action = action
    }
}

public struct NativeStatusBar: View {
    private let leading: [StatusBarItem]
    private let trailing: [StatusBarItem]
    @Environment(\.nativePalette) private var palette

    public init(leading: [StatusBarItem], trailing: [StatusBarItem] = []) {
        self.leading = leading
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: Space.l) {
            ForEach(leading) { item($0) }
            Spacer(minLength: Space.s)
            ForEach(trailing) { item($0) }
        }
        .padding(.horizontal, Space.m)
        .frame(height: NativeLayout.statusBarHeight)
        .frame(maxWidth: .infinity)
        .background(palette.column.color)
        .overlay(alignment: .top) { Rectangle().fill(palette.separator.color).frame(height: 1) }
    }

    private func item(_ item: StatusBarItem) -> some View {
        StatusBarItemView(item: item)
    }
}

private struct StatusBarItemView: View {
    let item: StatusBarItem
    @State private var hovered = false
    @Environment(\.nativePalette) private var palette

    var body: some View {
        let content = HStack(spacing: Space.xs) {
            Image(systemName: item.symbol).accessibilityHidden(true)
            if let fraction = item.fraction {
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.surfaceRaised.color)
                    Capsule().fill((fraction > 1 ? palette.error : palette.accent).color)
                        .frame(width: 44 * min(1, max(0, fraction)))
                }
                .frame(width: 44, height: 5)
                .accessibilityHidden(true)
            }
            switch item.text {
            case let .value(text): Text(text).monospacedDigit()
            case .unavailable: Text(tr("value.unavailable"))
            }
            if item.marked { Circle().fill(palette.accent.color).frame(width: 6, height: 6).accessibilityHidden(true) }
        }
        .font(Typo.small)
        .foregroundStyle((hovered ? palette.text : palette.textSecondary).color)
        .lineLimit(1)
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 2)
        .background(hovered ? palette.surface.color : .clear, in: .rect(cornerRadius: Radius.small))
        let help: String = {
            if case let .unavailable(reason) = item.text { return reason }
            return item.help ?? ""
        }()
        if let action = item.action {
            Button { action.perform() } label: { content.contentShape(.rect) }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help(help.isEmpty ? action.title : help)
                .accessibilityHint(action.title)
        } else {
            content.help(help)
        }
    }
}
