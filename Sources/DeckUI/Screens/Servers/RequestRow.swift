import SwiftUI

public struct RequestRow: View {
    private let request: ActiveRequestSummary
    private let showsServer: Bool
    @Environment(\.deckPalette) private var palette

    public init(_ request: ActiveRequestSummary, showsServer: Bool = false) {
        self.request = request
        self.showsServer = showsServer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(tr("request.number", String(request.request))).font(Typo.headline.monospacedDigit())
                Text(request.phase.title).font(Typo.pill).foregroundStyle(phaseColor.color)
                if showsServer {
                    Text(verbatim: request.server).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                }
                Spacer(minLength: Space.s)
                if let age = request.ageSeconds {
                    Text(DeckFormat.duration(seconds: age)).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.textTertiary.color)
                }
            }
            HStack(spacing: Space.m) {
                if let processed = request.promptProcessed, let total = request.promptTokens {
                    Text(tr("request.prompt", DeckFormat.count(processed), DeckFormat.count(total)))
                }
                if let generated = request.generated {
                    if let maximum = request.maximumNew {
                        Text(tr("request.generatedOf", DeckFormat.count(generated), DeckFormat.count(maximum)))
                    } else {
                        Text(tr("request.generated", DeckFormat.count(generated)))
                    }
                }
            }
            .font(Typo.caption.monospacedDigit())
            .foregroundStyle(palette.textSecondary.color)
            if let processed = request.promptProcessed, let total = request.promptTokens, total > 0, request.phase == .prefill {
                ProgressView(value: Double(processed), total: Double(total)).progressViewStyle(.linear).tint(palette.starting.color)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var phaseColor: RGB {
        switch request.phase {
        case .decode: palette.ready
        case .prefill: palette.starting
        case .queued, .other: palette.textSecondary
        }
    }
}
