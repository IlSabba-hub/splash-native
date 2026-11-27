import SwiftUI

extension EnvironmentValues {
    @Entry public var nativePalette: Palette = .standard
}

extension Palette {
    public static func `for`(_ contrast: ColorSchemeContrast) -> Palette {
        contrast == .increased ? .increased : .standard
    }
}

private struct NativeTheme: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let palette = Palette.for(contrast)
        content
            .environment(\.nativePalette, palette)
            .environment(\.locale, NativeFormat.locale)
            .tint(palette.accentFill.color)
            .foregroundStyle(palette.text.color)
            .preferredColorScheme(.dark)
    }
}

extension View {
    public func nativeTheme() -> some View {
        modifier(NativeTheme())
    }
}
