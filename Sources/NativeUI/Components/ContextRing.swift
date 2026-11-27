import SwiftUI

public struct ContextUse: Sendable, Equatable {
    public let used: Int
    public let limit: Int

    public init(used: Int, limit: Int) {
        self.used = used
        self.limit = limit
    }

    public var fraction: Double { limit > 0 ? min(1, max(0, Double(used) / Double(limit))) : 0 }
}

public struct ContextRing: View {
    private let use: Measured<ContextUse>
    @Environment(\.nativePalette) private var palette

    public init(_ use: Measured<ContextUse>) {
        self.use = use
    }

    public var body: some View {
        HStack(spacing: Space.xs) {
            ZStack {
                Circle().stroke(palette.surfaceRaised.color, lineWidth: 2.5)
                switch use {
                case let .value(use):
                    Circle()
                        .trim(from: 0, to: use.fraction)
                        .stroke(ringColor(use).color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                case .unavailable:
                    Circle().stroke(palette.stroke.color, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
            Text(label)
                .font(Typo.caption.monospacedDigit())
                .foregroundStyle(palette.textSecondary.color)
        }
        .help(Self.spokenValue(use))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("a11y.context"))
        .accessibilityValue(Self.spokenValue(use))
    }

    private var label: String {
        switch use {
        case let .value(use) where use.used > 0 && use.fraction < 0.005: "<" + NativeFormat.percent(0.01)
        case let .value(use): NativeFormat.percent(use.fraction)
        case .unavailable: tr("value.unavailable")
        }
    }

    private func ringColor(_ use: ContextUse) -> RGB {
        use.fraction >= 0.95 ? palette.error : use.fraction >= 0.8 ? palette.starting : palette.accent
    }

    static func spokenValue(_ use: Measured<ContextUse>) -> String {
        switch use {
        case let .value(use): tr("context.used", NativeFormat.count(use.used), NativeFormat.count(use.limit), NativeFormat.percent(use.fraction))
        case let .unavailable(reason): tr("a11y.unavailable", reason)
        }
    }
}

#Preview("Anello del contesto") {
    HStack(spacing: Space.l) {
        ContextRing(.value(ContextUse(used: 14_221, limit: 1_010_000)))
        ContextRing(.value(ContextUse(used: 250_000, limit: 262_144)))
        ContextRing(.unavailable(reason: tr("context.beforeFirstReply")))
    }
    .padding(Space.xl)
    .background(Palette.standard.surface.color)
    .nativeTheme()
}
