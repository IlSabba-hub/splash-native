import SwiftUI

public struct ReplyMetrics: Sendable, Equatable {
    public let ttft: Measured<String>
    public let prefill: Measured<String>
    public let decode: Measured<String>
    public let tokens: Measured<String>
    public let live: Bool
    public let source: String

    public init(ttft: Measured<String>, prefill: Measured<String>, decode: Measured<String>, tokens: Measured<String>, live: Bool,
                source: String) {
        self.ttft = ttft
        self.prefill = prefill
        self.decode = decode
        self.tokens = tokens
        self.live = live
        self.source = source
    }
}

public struct MetricsStrip: View {
    private let metrics: ReplyMetrics
    private let title: String?
    private let compact: Bool
    @Environment(\.nativePalette) private var palette

    public init(_ metrics: ReplyMetrics, title: String? = nil, compact: Bool = false) {
        self.metrics = metrics
        self.title = title
        self.compact = compact
    }

    public var body: some View {
        FlowLayout(spacing: compact ? Space.l : Space.xl, lineSpacing: Space.xs) {
            if metrics.live || title != nil {
                HStack(spacing: Space.xs) {
                    if metrics.live {
                        Circle().fill(palette.ready.color).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                    Text(metrics.live ? tr("metrics.live") : title ?? "")
                        .font(Typo.caption.weight(.semibold))
                        .foregroundStyle((metrics.live ? palette.ready : palette.textTertiary).color)
                }
                .padding(.top, compact ? 0 : Space.xs)
            }
            figure(tr("metrics.ttft"), metrics.ttft)
            figure(tr("metrics.prefill"), metrics.prefill)
            figure(tr("metrics.decode"), metrics.decode)
            figure(tr("metrics.tokens"), metrics.tokens)
        }
        .help(metrics.source)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("metrics.a11y"))
    }

    private func figure(_ title: String, _ value: Measured<String>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
            MeasuredText(value, font: compact ? Typo.small.weight(.medium) : Typo.headline.monospacedDigit())
                .lineLimit(1)
        }
        .fixedSize()
    }
}

extension ReplyMetrics {
    public static func done(_ numbers: ChatReplyNumbers) -> ReplyMetrics {
        let missing = tr("chat.fact.notSent")
        func value<T>(_ x: T?, _ format: (T) -> String) -> Measured<String> { x.map { .value(format($0)) } ?? .unavailable(reason: missing) }
        var source = tr("metrics.source.done")
        if let client = numbers.clientTTFTMs { source += " " + tr("metrics.source.client", NativeFormat.latency(milliseconds: client)) }
        return ReplyMetrics(ttft: value(numbers.ttftMs) { NativeFormat.latency(milliseconds: $0) },
                            prefill: value(numbers.prefillTokensPerSecond) { NativeFormat.tokensPerSecond($0) },
                            decode: value(numbers.decodeTokensPerSecond) { NativeFormat.tokensPerSecond($0) },
                            tokens: tokens(prompt: numbers.promptTokens, completion: numbers.completionTokens, missing: missing),
                            live: false, source: source)
    }

    public static func tokens(prompt: Int?, completion: Int?, missing: String) -> Measured<String> {
        switch (prompt, completion) {
        case let (prompt?, completion?): .value(tr("metrics.tokens.value", NativeFormat.count(prompt), NativeFormat.count(completion)))
        case let (nil, completion?): .value(tr("metrics.tokens.out", NativeFormat.count(completion)))
        case let (prompt?, nil): .value(tr("metrics.tokens.in", NativeFormat.count(prompt)))
        default: .unavailable(reason: missing)
        }
    }
}
