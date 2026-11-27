import SwiftUI

public enum StatsRange: String, CaseIterable, Sendable, Identifiable {
    case hour, day, month

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hour: tr("stats.range.hour")
        case .day: tr("stats.range.day")
        case .month: tr("stats.range.month")
        }
    }

    public var bucketLength: TimeInterval {
        switch self {
        case .hour: 60
        case .day: 1800
        case .month: 86_400
        }
    }

    public var bucketCount: Int {
        switch self {
        case .hour: 60
        case .day: 48
        case .month: 30
        }
    }
}

public struct StatsValues: Sendable, Equatable {
    public var decodeRate: Double?
    public var prefillRate: Double?
    public var requests: Double?
    public var tokens: Double?
    public var ssdWritten: Double?
    public var memoryPeak: Double?

    public init(decodeRate: Double? = nil, prefillRate: Double? = nil, requests: Double? = nil, tokens: Double? = nil, ssdWritten: Double? = nil,
                memoryPeak: Double? = nil) {
        self.decodeRate = decodeRate
        self.prefillRate = prefillRate
        self.requests = requests
        self.tokens = tokens
        self.ssdWritten = ssdWritten
        self.memoryPeak = memoryPeak
    }
}

public struct StatsBucket: Sendable, Equatable, Identifiable {
    public let start: Date
    public let appObserved: Double
    public let values: StatsValues
    public var id: Date { start }

    public init(start: Date, appObserved: Double, values: StatsValues) {
        self.start = start
        self.appObserved = appObserved
        self.values = values
    }
}

public struct StatsWindow: Sendable, Equatable {
    public let buckets: [StatsBucket]
    public let total: StatsValues
    public let observed: Double

    public init(buckets: [StatsBucket], total: StatsValues, observed: Double) {
        self.buckets = buckets
        self.total = total
        self.observed = observed
    }
}

public struct StatsSeries: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case all, model, configuration
    }

    public let id: String
    public let title: String
    public let windows: [StatsRange: StatsWindow]
    public let kind: Kind
    public let detail: String?
    public let help: String?

    public init(id: String, title: String, windows: [StatsRange: StatsWindow], kind: Kind = .configuration, detail: String? = nil,
                help: String? = nil) {
        self.id = id
        self.title = title
        self.windows = windows
        self.kind = kind
        self.detail = detail
        self.help = help
    }
}

public struct StatsContent: Sendable {
    public var series: [StatsSeries]
    public var coverage: [StatsRange: [StatsBucket]]
    public var footer: String
    public var writeError: String?

    public init(series: [StatsSeries], coverage: [StatsRange: [StatsBucket]], footer: String, writeError: String? = nil) {
        self.series = series
        self.coverage = coverage
        self.footer = footer
        self.writeError = writeError
    }
}

enum StatsMetric: CaseIterable, Identifiable {
    case decode, prefill, requests, tokens, memory, ssd

    var id: Self { self }

    var title: String {
        switch self {
        case .decode: tr("stats.decode")
        case .prefill: tr("stats.prefill")
        case .requests: tr("stats.requests")
        case .tokens: tr("stats.tokens")
        case .memory: tr("stats.memory")
        case .ssd: tr("stats.ssd")
        }
    }

    func value(_ values: StatsValues) -> Double? {
        switch self {
        case .decode: values.decodeRate
        case .prefill: values.prefillRate
        case .requests: values.requests
        case .tokens: values.tokens
        case .memory: values.memoryPeak
        case .ssd: values.ssdWritten
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .decode, .prefill: NativeFormat.tokensPerSecond(value)
        case .requests, .tokens: NativeFormat.count(Int(value))
        case .memory: NativeFormat.memory(Int64(value))
        case .ssd: NativeFormat.disk(Int64(value))
        }
    }
}

public struct StatsSection: View {
    private let state: SectionState<StatsContent>
    @State private var range: StatsRange
    @State private var seriesID: String?
    @Environment(\.nativePalette) private var palette

    public init(_ state: SectionState<StatsContent>, range: StatsRange = .hour, series: String? = nil) {
        self.state = state
        _range = State(initialValue: range)
        _seriesID = State(initialValue: series)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                SectionHeader(tr("stats.title"))
                if case let .available(content) = state, content.series.count > 1 { seriesMenu(content) }
                Spacer(minLength: Space.s)
                Picker(tr("stats.range"), selection: $range) {
                    ForEach(StatsRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch state {
            case let .available(content):
                available(content)
            case let .unavailable(reason):
                UnavailableState(title: tr("stats.title"), reason: reason)
            }
        }
    }

    private func selected(_ content: StatsContent) -> StatsSeries? {
        content.series.first { $0.id == seriesID } ?? content.series.first
    }

    private func seriesMenu(_ content: StatsContent) -> some View {
        Picker(tr("stats.server"), selection: Binding(get: { selected(content)?.id ?? "" }, set: { seriesID = $0 })) {
            ForEach(content.series.filter { $0.kind == .all }) { Text(verbatim: $0.title).tag($0.id) }
            let models = content.series.filter { $0.kind == .model }
            if !models.isEmpty {
                Section(tr("stats.byModel")) { ForEach(models) { Text(verbatim: $0.title).tag($0.id) } }
            }
            let configurations = content.series.filter { $0.kind == .configuration }
            if !configurations.isEmpty {
                Section(tr("stats.byConfiguration")) { ForEach(configurations) { Text(verbatim: $0.title).tag($0.id) } }
            }
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help(selected(content)?.help ?? "")
    }

    @ViewBuilder
    private func available(_ content: StatsContent) -> some View {
        let coverage = content.coverage[range] ?? []
        if let detail = selected(content)?.detail {
            Text(verbatim: detail).font(Typo.small).foregroundStyle(palette.textSecondary.color).fixedSize(horizontal: false, vertical: true)
        }
        if let series = selected(content), let window = series.windows[range] {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Space.l, alignment: .top)], alignment: .leading,
                      spacing: Space.l) {
                ForEach(StatsMetric.allCases) { metric in
                    StatsChart(metric: metric, window: window, range: range)
                }
            }
        } else {
            EmptyState(symbol: "chart.bar", title: tr("stats.empty.title"), message: tr("stats.empty.message"))
        }
        HStack(spacing: Space.m) {
            HStack(spacing: Space.xs) {
                GapSwatch().frame(width: 12, height: 10)
                Text(tr("stats.legend.closed", NativeFormat.duration(seconds: coverage.reduce(0) { $0 + $1.appObserved })))
            }
            if let error = content.writeError {
                Label(tr("stats.writeError.value", error), systemImage: "exclamationmark.triangle.fill").foregroundStyle(palette.error.color)
            }
            Spacer(minLength: Space.s)
            Text(content.footer).lineLimit(1).truncationMode(.middle)
        }
        .font(Typo.caption)
        .foregroundStyle(palette.textTertiary.color)
    }
}

struct StatsChart: View {
    let metric: StatsMetric
    let window: StatsWindow
    let range: StatsRange
    @State private var hovered: Int?
    @Environment(\.nativePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(metric.title).font(Typo.small).foregroundStyle(palette.textSecondary.color)
                Spacer(minLength: Space.xs)
                if let hovered, window.buckets.indices.contains(hovered) {
                    let bucket = window.buckets[hovered]
                    let missing = tr(bucket.appObserved > 0 ? "stats.noServer" : "stats.appClosed")
                    Text(tr("stats.at", label(bucket.start), metric.value(bucket.values).map(metric.format) ?? missing))
                        .font(Typo.caption.monospacedDigit())
                        .foregroundStyle(palette.textSecondary.color)
                }
            }
            Text(metric.value(window.total).map(metric.format) ?? tr("value.unavailable"))
                .font(Typo.headline.monospacedDigit())
            StatsBars(values: window.buckets.map { metric.value($0.values) }, open: window.buckets.map { $0.appObserved > 0 },
                      hovered: $hovered)
                .frame(height: 56)
                .accessibilityElement()
                .accessibilityLabel(metric.title)
                .accessibilityValue(StatsBars.spokenSummary(window.buckets.map { metric.value($0.values) }, format: metric.format))
            HStack {
                if let first = window.buckets.first { Text(label(first.start)) }
                Spacer()
                Text(tr(range == .month ? "stats.today" : "stats.now"))
            }
            .font(Typo.caption)
            .foregroundStyle(palette.textTertiary.color)
        }
    }

    private func label(_ date: Date) -> String {
        range == .month ? NativeFormat.day(date) : NativeFormat.moment(date)
    }
}

struct StatsBars: View {
    let values: [Double?]
    let open: [Bool]
    @Binding var hovered: Int?
    @Environment(\.nativePalette) private var palette

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in draw(&context, size) }
                .contentShape(.rect)
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(point):
                        guard !values.isEmpty, geometry.size.width > 0 else { return }
                        let index = Int(point.x / (geometry.size.width / CGFloat(values.count)))
                        hovered = values.indices.contains(index) ? index : nil
                    case .ended:
                        hovered = nil
                    }
                }
        }
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        guard !values.isEmpty else { return }
        let top = values.compactMap { $0 }.max() ?? 0
        let slot = size.width / CGFloat(values.count)
        let gap: CGFloat = slot > 6 ? 2 : 1
        let width = max(1, slot - gap)
        let base = size.height - 1
        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * slot + gap / 2
            if let value {
                let height = top > 0 ? max(2, CGFloat(value / top) * (base - 2)) : 2
                let rect = CGRect(x: x, y: base - height, width: width, height: height)
                let radius = min(2, width / 2)
                context.fill(Path(roundedRect: rect, cornerRadii: .init(topLeading: radius, topTrailing: radius)),
                             with: .color(palette.accent.color.opacity(hovered == index ? 1 : 0.78)))
            } else if index < open.count, !open[index] {
                let rect = CGRect(x: x, y: 0, width: width, height: base)
                var band = context
                band.clip(to: Path(rect))
                band.fill(Path(rect), with: .color(palette.surface.color))
                band.stroke(Self.hatch(in: rect), with: .color(palette.stroke.color.opacity(0.4)), lineWidth: 0.75)
            }
            if hovered == index {
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: base)), with: .color(palette.text.color.opacity(0.07)))
            }
        }
        context.fill(Path(CGRect(x: 0, y: base, width: size.width, height: 1)), with: .color(palette.separator.color))
    }

    static func hatch(in rect: CGRect) -> Path {
        var path = Path()
        var offset: CGFloat = -rect.width
        while offset < rect.height {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + offset + rect.width))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + offset))
            offset += 4
        }
        return path
    }

    static func spokenSummary(_ values: [Double?], format: (Double) -> String) -> String {
        let measured = values.compactMap { $0 }
        guard let top = measured.max() else { return tr("stats.a11y.none", NativeFormat.count(values.count)) }
        let latest = values.last.flatMap { $0 }.map(format) ?? tr("value.unavailable")
        return tr(measured.count == 1 ? "stats.a11y.summary.one" : "stats.a11y.summary", NativeFormat.count(measured.count), NativeFormat.count(values.count),
                  format(top), latest)
    }
}

struct GapSwatch: View {
    @Environment(\.nativePalette) private var palette

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .color(palette.surface.color))
            context.stroke(StatsBars.hatch(in: rect), with: .color(palette.stroke.color.opacity(0.4)), lineWidth: 0.75)
        }
        .clipShape(.rect(cornerRadius: 2))
        .accessibilityHidden(true)
    }
}

extension NativeFormat {
    public static func day(_ date: Date, locale: Locale = NativeFormat.locale) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }
}
