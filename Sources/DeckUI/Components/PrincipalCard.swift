import SwiftUI

public struct PrincipalCard: View {
    private let principal: PrincipalSummary
    private let actions: [DeckAction]
    @Environment(\.deckPalette) private var palette

    public init(_ principal: PrincipalSummary, actions: [DeckAction] = []) {
        self.principal = principal
        self.actions = actions
    }

    public var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: Space.m) {
                header
                if !principal.facts.isEmpty {
                    Divider().overlay(palette.separator.color)
                    facts
                }
                if principal.memory != nil || principal.memorySeries != nil || principal.decodeSeries != nil {
                    Divider().overlay(palette.separator.color)
                    measures
                }
                LabeledValueRow(title: tr("card.lastBench"), value: principal.lastBench, compact: true)
                if !actions.isEmpty {
                    HStack(spacing: Space.s) {
                        ForEach(actions.indices, id: \.self) { ActionButton(actions[$0]) }
                        Spacer(minLength: 0)
                    }
                    .controlSize(.regular)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("a11y.principal", principal.name))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(principal.name)
                    .font(Typo.cardTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            HStack(spacing: Space.xs) {
                Text(principal.model).lineLimit(1).truncationMode(.tail).textSelection(.enabled).help(principal.model)
                if let port = principal.port {
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text(DeckFormat.port(port)).monospacedDigit().fixedSize()
                }
            }
            .font(Typo.callout)
            .foregroundStyle(palette.textSecondary.color)
            FlowLayout(spacing: Space.s, lineSpacing: Space.xs) {
                StatusPill(principal.status, detail: principal.statusDetail)
                if principal.foundOutside { StatusPill(.foundOutside) }
                ForEach(principal.badges, id: \.self) { badge in
                    DeckBadge(badge.title, monospaced: false)
                }
                if let since = principal.readySince, principal.status == .ready {
                    TimelineView(.everyMinute) { context in
                        Text(tr("card.readySince", DeckFormat.elapsed(since: since, now: context.date)))
                            .font(Typo.caption)
                            .foregroundStyle(palette.textTertiary.color)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .topLeading, horizontalSpacing: Space.l, verticalSpacing: Space.s) {
            ForEach(Array(stride(from: 0, to: principal.facts.count, by: 2)), id: \.self) { index in
                GridRow {
                    LabeledValueRow(principal.facts[index], compact: true)
                    if index + 1 < principal.facts.count {
                        LabeledValueRow(principal.facts[index + 1], compact: true)
                    }
                }
            }
        }
    }

    private var measures: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let memory = principal.memory {
                HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                    FigureView(caption: tr("card.memoryNow"), value: memory.current.map { DeckFormat.memory($0) })
                    FigureView(caption: tr("card.memoryPeak"), value: memory.peak.map { DeckFormat.memory($0) })
                    FigureView(caption: tr("card.memoryCap"), value: memory.cap.map { DeckFormat.memory($0) })
                }
            }
            if let series = principal.memorySeries {
                seriesRow(tr("card.memorySeries"), series, range: principal.memory?.cap.value.map { 0 ... Double($0) }) {
                    DeckFormat.memory(Int64($0))
                }
            }
            if let series = principal.decodeSeries {
                seriesRow(tr("card.decodeRecent"), series, range: nil, color: palette.ready) { DeckFormat.tokensPerSecond($0) }
            }
        }
    }

    private func seriesRow(_ title: String, _ series: TimeSeries, range: ClosedRange<Double>?, color: RGB? = nil,
                           format: @escaping @Sendable (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
                Text(title).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                Spacer()
                Text(series.latest.map(format) ?? tr("value.unavailable"))
                    .font(Typo.caption.monospacedDigit())
                    .foregroundStyle(palette.textSecondary.color)
            }
            Sparkline(series, title: title, range: range, color: color, format: format)
        }
    }
}

public struct PrincipalTile: View {
    private let principal: PrincipalSummary
    private let action: DeckAction?
    private let menu: [DeckAction]
    @Environment(\.deckPalette) private var palette

    public init(_ principal: PrincipalSummary, action: DeckAction?, menu: [DeckAction] = []) {
        self.principal = principal
        self.action = action
        self.menu = menu
    }

    public var body: some View {
        DeckCard(padding: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    Image(systemName: "star.fill").font(Typo.caption).foregroundStyle(palette.accent.color).accessibilityHidden(true)
                    Text(principal.name).font(Typo.headline).lineLimit(1).truncationMode(.middle).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Space.xs)
                    StatusPill(principal.status, detail: principal.statusDetail)
                    if !menu.isEmpty {
                        Menu { items } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help(tr("principal.more"))
                            .accessibilityLabel(tr("principal.more"))
                    }
                }
                HStack(spacing: Space.xs) {
                    Text(principal.model).lineLimit(1).truncationMode(.tail).help(principal.model)
                    if let port = principal.port {
                        Text(verbatim: "·").accessibilityHidden(true)
                        Text(DeckFormat.port(port)).monospacedDigit().fixedSize()
                    }
                }
                .font(Typo.caption)
                .foregroundStyle(palette.textTertiary.color)
                HStack(alignment: .bottom, spacing: Space.xs) {
                    FlowLayout(spacing: Space.xs, lineSpacing: Space.xs) {
                        if principal.foundOutside { DeckBadge(tr("chip.outside"), tone: .accent, monospaced: false) }
                        if let draft = principal.draft {
                            DeckBadge(tr("badge.draft"), monospaced: false).help(tr("badge.draft.help", draft))
                        }
                        ForEach(principal.badges, id: \.self) { DeckBadge($0.title, monospaced: false) }
                        if let memory = principal.memory?.current.value {
                            Text(DeckFormat.memory(memory)).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.textSecondary.color)
                                .padding(.vertical, 1)
                        }
                    }
                    if let action { ActionButton(action).controlSize(.small).fixedSize() }
                }
            }
        }
        .contextMenu { if !menu.isEmpty { items } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("a11y.principal", principal.name))
    }

    @ViewBuilder
    private var items: some View {
        ForEach(menu.indices, id: \.self) { index in
            let action = menu[index]
            Button(action: action.perform) { Label(action.title, systemImage: action.systemImage ?? "circle") }
                .disabled(!action.isEnabled)
        }
    }
}

public struct PrincipalsStrip: View {
    private let principals: [PrincipalSummary]
    private let actions: (PrincipalSummary) -> [DeckAction]
    private let emptyAction: DeckAction?
    private let compact: Bool

    public init(_ principals: [PrincipalSummary], compact: Bool = false, emptyAction: DeckAction? = nil,
                actions: @escaping (PrincipalSummary) -> [DeckAction] = { _ in [] }) {
        self.principals = principals
        self.actions = actions
        self.emptyAction = emptyAction
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(tr("overview.principals"), detail: principals.isEmpty ? nil : DeckFormat.count(principals.count))
            if principals.isEmpty {
                DeckCard {
                    EmptyState(symbol: "star", title: tr("principals.empty.title"), message: tr("principals.empty.message"), action: emptyAction)
                }
            } else if compact {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: Space.m, alignment: .top)], alignment: .leading, spacing: Space.m) {
                    ForEach(principals) { principal in
                        let list = actions(principal)
                        PrincipalTile(principal, action: list.first, menu: Array(list.dropFirst()))
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: DeckLayout.principalCardMinWidth), spacing: Space.l, alignment: .top)],
                          alignment: .leading, spacing: Space.l) {
                    ForEach(principals) { PrincipalCard($0, actions: actions($0)) }
                }
            }
        }
    }
}
