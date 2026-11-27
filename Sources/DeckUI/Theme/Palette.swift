import SwiftUI

public struct RGB: Sendable, Equatable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    public func over(_ base: RGB, alpha: Double) -> RGB {
        RGB(red: red * alpha + base.red * (1 - alpha),
            green: green * alpha + base.green * (1 - alpha),
            blue: blue * alpha + base.blue * (1 - alpha))
    }

    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

public struct Palette: Sendable, Equatable {
    public let rail: RGB
    public let column: RGB
    public let background: RGB
    public let surface: RGB
    public let surfaceRaised: RGB
    public let separator: RGB
    public let stroke: RGB

    public let text: RGB
    public let textSecondary: RGB
    public let textTertiary: RGB

    public let accent: RGB
    public let accentFill: RGB
    public let onAccent: RGB

    public let ready: RGB
    public let starting: RGB
    public let error: RGB
    public let stopped: RGB
    public let foundOutside: RGB

    public let others: RGB

    public let pillFillOpacity: Double
    public let selectionOpacity: Double

    public func pillFill(_ status: StatusKind) -> RGB { color(of: status).over(surface, alpha: pillFillOpacity) }

    public var selection: RGB { accent.over(column, alpha: selectionOpacity) }

    public func color(of status: StatusKind) -> RGB {
        switch status {
        case .stopped: stopped
        case .starting: starting
        case .ready: ready
        case .error: error
        case .foundOutside: foundOutside
        }
    }

    public static let standard = Palette(
        rail: RGB(0x161617),
        column: RGB(0x19191B),
        background: RGB(0x1C1C1E),
        surface: RGB(0x252528),
        surfaceRaised: RGB(0x2E2E32),
        separator: RGB(0x38383D),
        stroke: RGB(0x7A7A82),
        text: RGB(0xECECEE),
        textSecondary: RGB(0xA9A9B0),
        textTertiary: RGB(0x9E9EA5),
        accent: RGB(0x8C95FF),
        accentFill: RGB(0x4D57D9),
        onAccent: RGB(0xFFFFFF),
        ready: RGB(0x4CD68F),
        starting: RGB(0xE9B44C),
        error: RGB(0xFF7A7A),
        stopped: RGB(0xA3A3AB),
        foundOutside: RGB(0x6CC0FF),
        others: RGB(0x808088),
        pillFillOpacity: 0.16,
        selectionOpacity: 0.2
    )

    public static let increased = Palette(
        rail: RGB(0x0C0C0D),
        column: RGB(0x101012),
        background: RGB(0x111113),
        surface: RGB(0x1C1C1F),
        surfaceRaised: RGB(0x26262A),
        separator: RGB(0x55555C),
        stroke: RGB(0x96969E),
        text: RGB(0xFFFFFF),
        textSecondary: RGB(0xD0D0D6),
        textTertiary: RGB(0xBBBBC2),
        accent: RGB(0xA9B0FF),
        accentFill: RGB(0x3E48C8),
        onAccent: RGB(0xFFFFFF),
        ready: RGB(0x6BE6A6),
        starting: RGB(0xF3C76A),
        error: RGB(0xFF9A9A),
        stopped: RGB(0xC2C2C9),
        foundOutside: RGB(0x8DD0FF),
        others: RGB(0x8E8E96),
        pillFillOpacity: 0.2,
        selectionOpacity: 0.26
    )
}
