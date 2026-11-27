import SwiftUI

public struct Sparkline: View {
    private let series: TimeSeries
    private let range: ClosedRange<Double>?
    private let includesZero: Bool
    private let color: RGB?
    private let accessibilityTitle: String
    private let format: @Sendable (Double) -> String
    private let height: CGFloat
    @Environment(\.deckPalette) private var palette

    public init(_ series: TimeSeries, title: String, range: ClosedRange<Double>? = nil, includesZero: Bool = true,
                color: RGB? = nil, height: CGFloat = DeckLayout.sparklineHeight, format: @escaping @Sendable (Double) -> String) {
        self.height = height
        self.series = series
        self.range = range
        self.includesZero = includesZero
        self.color = color
        self.accessibilityTitle = title
        self.format = format
    }

    public var body: some View {
        let stroke = (color ?? palette.accent).color
        Canvas { context, size in
            guard let geometry = SparklineGeometry(series: series, range: resolvedRange, size: size) else { return }
            for run in geometry.runs {
                if run.count == 1, let point = run.first {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)), with: .color(stroke))
                    continue
                }
                var line = Path()
                line.addLines(run)
                var area = line
                if let first = run.first, let last = run.last {
                    area.addLine(to: CGPoint(x: last.x, y: size.height))
                    area.addLine(to: CGPoint(x: first.x, y: size.height))
                    area.closeSubpath()
                }
                context.fill(area, with: .color(stroke.opacity(0.18)))
                context.stroke(line, with: .color(stroke), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(Self.spokenSummary(series, format: format))
    }

    private var resolvedRange: ClosedRange<Double>? {
        if let range { return range }
        let values = series.values
        guard var low = values.min(), let high = values.max() else { return nil }
        if includesZero { low = min(low, 0) }
        return low ... max(high, low + .ulpOfOne)
    }

    static func spokenSummary(_ series: TimeSeries, format: (Double) -> String) -> String {
        let values = series.values
        guard let low = values.min(), let high = values.max() else { return tr("a11y.seriesEmpty") }
        let latest = series.latest.map(format) ?? tr("value.unavailable")
        return tr("a11y.series", latest, format(low), format(high), DeckFormat.count(series.gaps))
    }
}

struct SparklineGeometry {
    let runs: [[CGPoint]]

    init?(series: TimeSeries, range: ClosedRange<Double>?, size: CGSize) {
        guard let domain = series.domain, let range, size.width > 0, size.height > 0 else { return nil }
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let height = range.upperBound - range.lowerBound
        func x(_ time: Date) -> CGFloat {
            span > 0 ? CGFloat(time.timeIntervalSince(domain.lowerBound) / span) * size.width : size.width
        }
        func y(_ value: Double) -> CGFloat {
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            let fraction = height > 0 ? (clamped - range.lowerBound) / height : 0.5
            return 1 + CGFloat(1 - fraction) * (size.height - 2)
        }
        runs = series.runs.map { run in run.samples.map { CGPoint(x: x($0.time), y: y($0.value)) } }
    }
}

#Preview("Sparkline con buchi (dati d'esempio)") {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let example: [Double?] = [31, 34, 36, 35, nil, nil, 33, 36, 37, nil, 30, nil, 35, 36, 38, 36]
    let series = TimeSeries(samples: example.enumerated().map { .init(time: start.addingTimeInterval(Double($0.offset) * 2), value: $0.element) },
                            maximumGap: 3)
    DeckCard {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(tr("card.decodeRecent")).font(Typo.caption)
            Sparkline(series, title: tr("card.decodeRecent")) { DeckFormat.tokensPerSecond($0) }
        }
    }
    .padding(Space.xl)
    .frame(width: 360)
    .deckTheme()
}
