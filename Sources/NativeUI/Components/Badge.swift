import SwiftUI

public struct NativeBadge: View {
    private let title: String
    private let symbol: String?
    private let tone: ModelTag.Tone
    private let monospaced: Bool
    @Environment(\.nativePalette) private var palette

    public init(_ title: String, symbol: String? = nil, tone: ModelTag.Tone = .neutral, monospaced: Bool = true) {
        self.title = title
        self.symbol = symbol
        self.tone = tone
        self.monospaced = monospaced
    }

    public init(_ tag: ModelTag) {
        self.init(tag.title, symbol: tag.symbol, tone: tag.tone, monospaced: false)
    }

    public var body: some View {
        let color = Self.color(tone, palette).color
        HStack(spacing: Space.xxs) {
            if let symbol { Image(systemName: symbol).imageScale(.small).accessibilityHidden(true) }
            Text(title)
        }
        .font(monospaced ? Typo.badge : Typo.pill)
        .lineLimit(1)
        .foregroundStyle(color)
        .padding(.horizontal, Space.xs + 1)
        .padding(.vertical, 1)
        .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(color.opacity(0.55), lineWidth: 1))
    }

    static func color(_ tone: ModelTag.Tone, _ palette: Palette) -> RGB {
        switch tone {
        case .neutral: palette.textSecondary
        case .accent: palette.accent
        case .ready: palette.ready
        case .warning: palette.starting
        case .error: palette.error
        }
    }
}

public enum Capability: String, Sendable, Equatable, Hashable, CaseIterable {
    case vision
    case reasoning

    public var title: String {
        switch self {
        case .vision: tr("capability.vision")
        case .reasoning: tr("capability.reasoning")
        }
    }

    public var symbol: String {
        switch self {
        case .vision: "eye"
        case .reasoning: "lightbulb"
        }
    }

    var tone: ModelTag.Tone {
        switch self {
        case .vision: .warning
        case .reasoning: .ready
        }
    }
}

public struct CapabilityBadges: View {
    private let capabilities: [Capability]
    private let compact: Bool
    @Environment(\.nativePalette) private var palette

    public init(_ capabilities: [Capability], compact: Bool = true) {
        self.capabilities = capabilities
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(capabilities, id: \.self) { capability in
                if compact {
                    let color = NativeBadge.color(capability.tone, palette).color
                    Image(systemName: capability.symbol)
                        .font(Typo.caption)
                        .foregroundStyle(color)
                        .frame(width: 18, height: 16)
                        .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(color.opacity(0.55), lineWidth: 1))
                        .help(capability.title)
                        .accessibilityLabel(capability.title)
                } else {
                    NativeBadge(capability.title, symbol: capability.symbol, tone: capability.tone, monospaced: false)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Badge e capacità") {
    VStack(alignment: .leading, spacing: Space.m) {
        HStack(spacing: Space.s) {
            NativeBadge("Qwen3.8-27B")
            NativeBadge("Q6_K", tone: .accent)
            NativeBadge(tr("models.format.gguf"), monospaced: false)
            NativeBadge(ModelTag(tr("models.tag.prepared"), symbol: "checkmark.circle.fill", tone: .ready))
        }
        CapabilityBadges(Capability.allCases)
        CapabilityBadges(Capability.allCases, compact: false)
    }
    .padding(Space.xl)
    .background(Palette.standard.background.color)
    .nativeTheme()
}
