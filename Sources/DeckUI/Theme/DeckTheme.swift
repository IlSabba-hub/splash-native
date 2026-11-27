import SwiftUI

extension EnvironmentValues {
    @Entry public var deckPalette: Palette = .standard
}

extension Palette {
    public static func `for`(_ contrast: ColorSchemeContrast) -> Palette {
        contrast == .increased ? .increased : .standard
    }
}

private struct DeckTheme: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let palette = Palette.for(contrast)
        content
            .environment(\.deckPalette, palette)
            .environment(\.locale, DeckFormat.locale)
            .tint(palette.accentFill.color)
            .foregroundStyle(palette.text.color)
            .preferredColorScheme(.dark)
    }
}

extension View {
    public func deckTheme() -> some View {
        modifier(DeckTheme())
    }
}
