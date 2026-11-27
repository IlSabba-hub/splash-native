import SwiftUI

public enum Space {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum Radius {
    public static let small: CGFloat = 4
    public static let control: CGFloat = 7
    public static let card: CGFloat = 11
    public static let bubble: CGFloat = 14
}

public enum DeckLayout {
    public static let principalCardMinWidth: CGFloat = 340
    public static let labelColumn: CGFloat = 180
    public static let inspectorWidth: CGFloat = 300
    public static let sparklineHeight: CGFloat = 28
    public static let memoryBarHeight: CGFloat = 14

    public static let railWidth: CGFloat = 48
    public static let columnWidth: CGFloat = 232
    public static let titleBarHeight: CGFloat = 40
    public static let trafficLightsInset: CGFloat = 78
    public static let statusBarHeight: CGFloat = 24
    public static let pickerWidth: CGFloat = 360
    public static let pickerPanelWidth: CGFloat = 560
    public static let chipMaxWidth: CGFloat = 240
    public static let readingWidth: CGFloat = 760
    public static let contentMinWidth: CGFloat = 620
    public static let windowMinimum = CGSize(width: 1000, height: 640)
    public static let windowIdeal = CGSize(width: 1280, height: 820)
}

public enum Typo {
    public static let pageTitle = Font.headline
    public static let sectionHeader = Font.caption.weight(.semibold)
    public static let cardTitle = Font.headline
    public static let headline = Font.headline
    public static let body = Font.body
    public static let callout = Font.callout
    public static let small = Font.subheadline
    public static let figure = Font.title3.weight(.semibold).monospacedDigit()
    public static let value = Font.body.monospacedDigit()
    public static let caption = Font.caption
    public static let code = Font.caption.monospaced()
    public static let codeBlock = Font.callout.monospaced()
    public static let pill = Font.caption.weight(.semibold)
    public static let badge = Font.caption.monospaced().weight(.medium)
    public static let railIcon = Font.title3
}
