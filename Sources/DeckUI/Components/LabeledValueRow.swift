import SwiftUI

public struct LabeledValueRow: View {
    private let fact: Fact
    private let compact: Bool
    @Environment(\.deckPalette) private var palette

    public init(_ fact: Fact, compact: Bool = false) {
        self.fact = fact
        self.compact = compact
    }

    public init(title: String, value: Measured<String>, provenance: Provenance? = nil, compact: Bool = false) {
        self.init(Fact(title: title, value: value, provenance: provenance), compact: compact)
    }

    private var expandable: Bool {
        if fact.provenance != nil { return true }
        if case .unavailable = fact.value { return true }
        return false
    }

    public var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Space.s))
        layout {
            HStack(spacing: Space.xs) {
                Text(fact.title)
                    .font(compact ? Typo.caption : Typo.body)
                    .foregroundStyle((compact ? palette.textTertiary : palette.textSecondary).color)
                if let details { InfoButton(fact.title, details: details) }
            }
            .frame(minWidth: compact ? nil : DeckLayout.labelColumn, alignment: .leading)
            if !compact { Spacer(minLength: Space.s) }
            MeasuredText(fact.value)
                .foregroundStyle(palette.text.color)
                .multilineTextAlignment(compact ? .leading : .trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .contain)
    }

    private var details: SettingDetails? {
        var reason: String?
        if case let .unavailable(why) = fact.value { reason = why }
        guard fact.provenance != nil || reason != nil else { return nil }
        return SettingDetails(flag: fact.provenance?.flag, source: fact.provenance?.shortDescription, splashDefault: nil, help: nil,
                              reason: reason)
    }
}

#Preview("Righe con provenienza") {
    DeckCard {
        VStack(alignment: .leading, spacing: Space.m) {
            LabeledValueRow(title: FlagLabels.title(for: "--max-context") ?? "", value: .value(DeckFormat.count(1_010_000)),
                            provenance: Provenance(flag: "--max-context", source: .status(field: "maximum_context_tokens")))
            LabeledValueRow(title: FlagLabels.title(for: "--kv-format") ?? "", value: .value("int8"),
                            provenance: Provenance(flag: "--kv-format", source: .splashDefault(version: "1.7.3")))
            LabeledValueRow(title: FlagLabels.title(for: "--idle-release") ?? "", value: .value(DeckFormat.duration(seconds: 600)),
                            provenance: Provenance(flag: "--idle-release", source: .status(field: "weights.idle_release_seconds")))
            LabeledValueRow(title: tr("figure.gpuPerProcess"), value: .unavailable(reason: tr("reason.gpuPerProcess")))
        }
    }
    .padding(Space.xl)
    .frame(width: 520)
    .deckTheme()
}
