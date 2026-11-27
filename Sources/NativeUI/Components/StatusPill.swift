import SwiftUI

public struct StatusPill: View {
    private let status: StatusKind
    private let detail: String?
    @Environment(\.nativePalette) private var palette

    public init(_ status: StatusKind, detail: String? = nil) {
        self.status = status
        self.detail = detail
    }

    public var body: some View {
        let color = palette.color(of: status).color
        HStack(spacing: Space.xs) {
            Image(systemName: status.symbol).imageScale(.small)
            Text(status.title)
            if let detail {
                Text(verbatim: "·").accessibilityHidden(true)
                Text(detail).monospacedDigit()
            }
        }
        .font(Typo.pill)
        .lineLimit(1)
        .foregroundStyle(color)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xxs + 1)
        .background(palette.pillFill(status).color, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("a11y.status"))
        .accessibilityValue(Self.spokenValue(status, detail: detail))
    }

    static func spokenValue(_ status: StatusKind, detail: String?) -> String {
        detail.map { tr("a11y.statusWithDetail", status.title, $0) } ?? status.title
    }
}

#Preview("Pill di stato") {
    VStack(alignment: .leading, spacing: Space.s) {
        ForEach(StatusKind.allCases, id: \.self) { StatusPill($0) }
        StatusPill(.starting, detail: tr("status.warming", NativeFormat.count(6), NativeFormat.count(16)))
    }
    .padding(Space.xl)
    .background(Palette.standard.surface.color)
    .nativeTheme()
}
