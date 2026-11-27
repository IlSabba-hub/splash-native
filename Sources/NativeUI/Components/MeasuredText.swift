import SwiftUI

public struct MeasuredText: View {
    private let value: Measured<String>
    private let font: Font
    @Environment(\.nativePalette) private var palette

    public init(_ value: Measured<String>, font: Font = Typo.value) {
        self.value = value
        self.font = font
    }

    public var body: some View {
        switch value {
        case let .value(text):
            Text(text).font(font).monospacedDigit()
        case let .unavailable(reason):
            UnavailableValue(reason: reason, font: font)
        }
    }
}

public struct UnavailableValue: View {
    private let reason: String
    private let font: Font
    @Environment(\.nativePalette) private var palette

    public init(reason: String, font: Font = Typo.value) {
        self.reason = reason
        self.font = font
    }

    public var body: some View {
        HStack(spacing: Space.xxs) {
            Text(tr("value.unavailable"))
            Image(systemName: "questionmark.circle").imageScale(.small).accessibilityHidden(true)
        }
        .font(font)
        .foregroundStyle(palette.textSecondary.color)
        .help(reason)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("a11y.unavailable", reason))
    }
}

public struct FigureView: View {
    private let caption: String
    private let value: Measured<String>
    private let unit: String?
    @Environment(\.nativePalette) private var palette

    public init(caption: String, value: Measured<String>, unit: String? = nil) {
        self.caption = caption
        self.value = value
        self.unit = unit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                MeasuredText(value, font: Typo.figure)
                if let unit, value.value != nil {
                    Text(unit).font(Typo.callout).foregroundStyle(palette.textSecondary.color)
                }
            }
            Text(caption).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Valori e n/d") {
    VStack(alignment: .leading, spacing: Space.l) {
        MeasuredText(.value(NativeFormat.memory(21_189_083_136)))
        MeasuredText(.unavailable(reason: tr("reason.notReported")))
        HStack(spacing: Space.xl) {
            FigureView(caption: tr("figure.ttftMedian"), value: .value(NativeFormat.latency(milliseconds: 43.869084)))
            FigureView(caption: tr("figure.lastBench"), value: .unavailable(reason: tr("reason.neverBenchmarked")))
        }
    }
    .padding(Space.xl)
    .background(Palette.standard.surface.color)
    .nativeTheme()
}
