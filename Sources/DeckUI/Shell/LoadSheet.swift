import SwiftUI

public struct LoadSheet: View {
    private let content: LoadSheetContent
    @Binding private var settings: LoadSettings
    private let notice: ServerNotice?
    private let pending: DeckAction?
    private let advanced: DeckAction?
    private let measure: DeckAction?
    private let estimate: MemoryEstimate?
    private let load: DeckAction
    private let swap: String?
    private let estimateMissing: String?
    private let estimateMissingHelp: String?
    private let cancel: () -> Void
    private let maxHeight: CGFloat?
    @State private var controlsHeight: CGFloat?
    @State private var chromeHeight: CGFloat = 0
    @State private var confirmingLoad = false
    @Environment(\.deckPalette) private var palette

    public init(_ content: LoadSheetContent, settings: Binding<LoadSettings>, notice: ServerNotice? = nil, pending: DeckAction? = nil,
                advanced: DeckAction? = nil, measure: DeckAction? = nil, estimate: MemoryEstimate? = nil, load: DeckAction,
                swap: String? = nil, estimateMissing: String? = nil, estimateMissingHelp: String? = nil, maxHeight: CGFloat? = nil,
                cancel: @escaping () -> Void) {
        self.estimateMissingHelp = estimateMissingHelp
        self.maxHeight = maxHeight
        self.estimateMissing = estimateMissing
        self.swap = swap
        self.content = content
        _settings = settings
        self.notice = notice
        self.pending = pending
        self.advanced = advanced
        self.measure = measure
        self.estimate = estimate
        self.load = load
        self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, Space.l).padding(.vertical, Space.m)
                .background(GeometryReader { Color.clear.preference(key: ChromeHeight.self, value: $0.size.height) })
            Divider().overlay(palette.separator.color)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let spec = content.context { slider(spec, value: $settings.context) }
                    if let spec = content.kvFormat { segment(spec, value: $settings.kvFormat) }
                    if let spec = content.activations { segment(spec, value: $settings.activations) }
                    if let spec = content.verifyRows { segment(spec, value: $settings.verifyRows) }
                    if let spec = content.draft { DraftRow(spec: spec, value: $settings.draft) }
                    if let storage = content.storage, !storage.rows.isEmpty { StorageSection(storage: storage, settings: $settings) }
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
                .background(GeometryReader { Color.clear.preference(key: ControlsHeight.self, value: $0.size.height) })
            }
            .frame(height: min(controlsHeight ?? Self.tallest, controlsLimit))
            .onPreferenceChange(ControlsHeight.self) { controlsHeight = $0 }
            Divider().overlay(palette.separator.color)
            footer.padding(Space.l)
                .background(GeometryReader { Color.clear.preference(key: ChromeHeight.self, value: $0.size.height) })
        }
        .frame(width: DeckLayout.pickerPanelWidth)
        .background(palette.column.color)
        .onPreferenceChange(ChromeHeight.self) { chromeHeight = $0 }
    }

    static let tallest: CGFloat = 480

    private var controlsLimit: CGFloat {
        guard let maxHeight else { return Self.tallest }
        return max(160, min(Self.tallest, maxHeight - chromeHeight - 2))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Image(systemName: "cube").font(Typo.railIcon).foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Space.m) {
                    names.fixedSize()
                    Spacer(minLength: Space.s)
                    badges
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    names
                    badges
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("a11y.loadSheet", content.name))
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(content.name).font(Typo.headline).accessibilityAddTraits(.isHeader)
            Text(content.model).font(Typo.code).foregroundStyle(palette.textSecondary.color).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var badges: some View {
        HStack(spacing: Space.s) {
            ForEach(content.facts, id: \.self) { DeckBadge($0, monospaced: false).fixedSize() }
        }
    }

    private func slider(_ spec: SliderSpec, value: Binding<Double?>) -> some View {
        SliderRow(spec.title, value: value, scale: spec.scale, format: spec.unit.format, parse: spec.unit.parse, automatic: spec.automatic,
                  splashDefault: spec.splashDefault, notes: spec.notes, provenance: spec.provenance, disabledReason: spec.disabledReason,
                  mark: spec.mark, effect: spec.effect, fullHelp: spec.help)
    }

    private func segment(_ spec: SegmentSpec, value: Binding<String?>) -> some View {
        SegmentedRow(spec.title, value: value, choices: spec.choices, defaultToken: spec.defaultToken, provenance: spec.provenance,
                     disabledReason: spec.disabledReason, effect: spec.effect, fullHelp: spec.help)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let notice { NoticeView(notice) }
            if let pending { ActionButton(pending) }
            HStack(spacing: Space.m) {
                Toggle(tr(content.isNew ? "load.rememberNew" : "load.remember"), isOn: $settings.remember)
                    .toggleStyle(.checkbox)
                    .font(Typo.small)
                    .help(tr(content.isNew ? "load.rememberNew.help" : "load.remember.help"))
                Spacer(minLength: Space.s)
                if let measure { ActionButton(measure).controlSize(.small) }
                if let advanced { ActionButton(advanced).controlSize(.small) }
            }
            if let bar = estimate?.bar { EstimateBarView(bar) }
            HStack(alignment: .center, spacing: Space.m) {
                if estimate?.bar != nil {
                    EmptyView()
                } else if let estimate { EstimateView(estimate) } else {
                    Label(estimateMissing ?? tr("estimate.unknown"), systemImage: "memorychip").font(Typo.small)
                        .foregroundStyle(palette.textTertiary.color).fixedSize(horizontal: false, vertical: true)
                        .help(estimateMissingHelp ?? "")
                }
                Spacer(minLength: Space.s)
                Button(tr("confirm.cancel"), action: cancel).keyboardShortcut(.cancelAction)
                loadButton
            }
            if let swap, !confirmingLoad {
                Label(swap, systemImage: "arrow.left.arrow.right").font(Typo.caption).foregroundStyle(palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if confirmingLoad, case let .destructive(question, consequence, confirmTitle) = load.role {
                InlineConfirmation(question: question, consequence: consequence, confirmTitle: confirmTitle, remember: load.remember,
                                   cancel: { confirmingLoad = false }, confirm: { confirmingLoad = false; load.perform() })
            }
            if estimate?.bar == nil, let note = estimate?.autoCapNote {
                Label(note, systemImage: "info.circle").font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension LoadSheet {
    private var loadButton: some View {
        Button {
            if case .destructive = load.role { confirmingLoad = true } else { load.perform() }
        } label: {
            if let symbol = load.systemImage { Label(load.title, systemImage: symbol) } else { Text(load.title) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!load.isEnabled || confirmingLoad)
        .help(load.disabledReason ?? swap ?? "")
    }
}

private struct ControlsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ChromeHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

public struct EstimateBarView: View {
    private let bar: EstimateBar
    @State private var shows = false
    @Environment(\.deckPalette) private var palette

    public static let height: CGFloat = 14

    public init(_ bar: EstimateBar) {
        self.bar = bar
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(bar.usedText).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(palette.text.color)
                Text(bar.limitText).font(Typo.body).monospacedDigit().foregroundStyle(palette.textSecondary.color)
                Spacer(minLength: Space.s)
                Text(bar.fit.word).font(Typo.body.weight(.semibold)).foregroundStyle(DeckBadge.color(bar.fit.tone, palette).color)
                Button { shows.toggle() } label: {
                    Image(systemName: "info.circle").font(Typo.caption)
                        .foregroundStyle((shows ? palette.accent : palette.textTertiary).color)
                }
                .buttonStyle(.borderless)
                .help(tr("bar.info"))
                .accessibilityLabel(tr("info.a11y", tr("bar.title")))
                .popover(isPresented: $shows, arrowEdge: .bottom) { EstimateBarDetails(bar).deckTheme() }
            }
            SegmentedMemoryBar(bar: bar).frame(height: Self.height)
            HStack(spacing: Space.s) {
                Text(bar.macText).font(Typo.caption).monospacedDigit().foregroundStyle(palette.textSecondary.color).fixedSize()
                GeometryReader { geometry in
                    let scale = geometry.size.width / CGFloat(max(bar.macTotal, bar.macUsed, 1))
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.surfaceRaised.color)
                        Capsule().fill(DeckBadge.color(bar.macUsed > bar.macTotal ? .error : .neutral, palette).color)
                            .frame(width: min(geometry.size.width, CGFloat(bar.macUsed) * scale))
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
            if let note = bar.note {
                Text(note).font(Typo.caption).foregroundStyle(palette.textTertiary.color).lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("bar.title") + " " + bar.fit.word)
        .accessibilityValue(bar.usedText + " " + bar.limitText + ", " + bar.macText)
    }
}

struct SegmentedMemoryBar: View {
    let bar: EstimateBar
    @Environment(\.deckPalette) private var palette

    static func color(_ part: EstimateBar.Part, _ palette: Palette) -> Color {
        switch part {
        case .weights: palette.accent.color
        case .kv: palette.accent.over(palette.text, alpha: 0.45).color
        case .draft: palette.accent.over(palette.column, alpha: 0.55).color
        case .runtime: palette.textTertiary.color
        case .others: palette.others.color
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let total = max(bar.used, bar.limit, 1)
            let scale = geometry.size.width / CGFloat(total)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Radius.small).fill(palette.surfaceRaised.color)
                HStack(spacing: 1) {
                    ForEach(bar.segments) { segment in
                        Rectangle().fill(Self.color(segment.part, palette)).frame(width: max(0, CGFloat(segment.bytes) * scale - 1))
                    }
                    if bar.atLeast {
                        Rectangle().strokeBorder(palette.textTertiary.color, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 10)
                    }
                }
                .clipShape(.rect(cornerRadius: Radius.small))
                RoundedRectangle(cornerRadius: Radius.small).strokeBorder(DeckBadge.color(bar.fit.tone, palette).color.opacity(0.7), lineWidth: 1)
                    .frame(width: CGFloat(bar.limit) * scale)
            }
        }
        .accessibilityHidden(true)
    }
}

public struct EstimateBarDetails: View {
    private let bar: EstimateBar
    @Environment(\.deckPalette) private var palette

    public init(_ bar: EstimateBar) {
        self.bar = bar
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(tr("bar.title")).font(Typo.headline).foregroundStyle(palette.text.color).accessibilityAddTraits(.isHeader)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s, verticalSpacing: Space.xxs) {
                ForEach(bar.segments) { segment in
                    GridRow {
                        RoundedRectangle(cornerRadius: 2).fill(SegmentedMemoryBar.color(segment.part, palette)).frame(width: 10, height: 10)
                        Text(segment.part.title).font(Typo.small).foregroundStyle(palette.textSecondary.color)
                        Text(segment.atLeast ? tr("forecast.atLeast", DeckFormat.memory(segment.bytes)) : DeckFormat.memory(segment.bytes))
                            .font(Typo.small).monospacedDigit().foregroundStyle(palette.text.color).gridColumnAlignment(.trailing)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 10, height: 1)
                    Text(tr("bar.total")).font(Typo.small.weight(.semibold)).foregroundStyle(palette.text.color)
                    Text(bar.usedText + " " + bar.limitText).font(Typo.small.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(palette.text.color)
                }
            }
            Text(bar.macText).font(Typo.caption).monospacedDigit().foregroundStyle(palette.textSecondary.color)
            Divider().overlay(palette.separator.color)
            ForEach(bar.details, id: \.self) { line in
                Text(line).font(Typo.caption).foregroundStyle(palette.textTertiary.color).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.m)
        .frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(palette.column.color)
    }
}

public struct EstimateView: View {
    private let estimate: MemoryEstimate
    @Environment(\.deckPalette) private var palette

    public init(_ estimate: MemoryEstimate) {
        self.estimate = estimate
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Space.s) {
            bar.frame(width: 88, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Space.xs) {
                    Text(estimate.word).fontWeight(.semibold).foregroundStyle(DeckBadge.color(estimate.tone, palette).color)
                    Text(estimate.room?.line(need: estimate.requested)
                         ?? tr("estimate.total", DeckFormat.memory(estimate.total), DeckFormat.memory(estimate.budget)))
                        .foregroundStyle(palette.textSecondary.color).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Typo.small)
                if let forecast = estimate.forecast {
                    Text(forecast.headline).font(Typo.caption).foregroundStyle(palette.textSecondary.color).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    Label(forecast.sourceLine, systemImage: forecast.measuredAt == nil ? "doc.text.magnifyingglass" : "gauge.with.dots.needle.67percent")
                        .font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(forecast.source)
                    switch forecast.outcome {
                    case .streamsExperts, .kvOnSSD, .unknown:
                        Text(forecast.explanation).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    case .fits, .exceeds, .limitedExperts:
                        EmptyView()
                    }
                }
                Text(estimate.outcome)
                    .font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(estimate.breakdown)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("estimate.title") + " " + estimate.word)
        .accessibilityValue(estimate.breakdown)
    }

    private var bar: some View {
        GeometryReader { geometry in
            let limit = estimate.room?.free ?? estimate.budget
            let used = estimate.room == nil ? estimate.total : estimate.requested
            let scale = geometry.size.width / CGFloat(max(used, limit, 1))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(palette.surfaceRaised.color)
                HStack(spacing: 0) {
                    if estimate.room == nil {
                        Rectangle().fill(palette.others.color).frame(width: CGFloat(estimate.others) * scale)
                        Rectangle().fill(palette.textTertiary.color).frame(width: CGFloat(estimate.running) * scale)
                    }
                    Rectangle().fill(DeckBadge.color(estimate.tone, palette).color).frame(width: CGFloat(estimate.requested) * scale)
                }
                .clipShape(.rect(cornerRadius: 2))
                if used > limit {
                    Rectangle().fill(palette.text.color).frame(width: 1.5).offset(x: CGFloat(limit) * scale - 0.75)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct StorageSection: View {
    let storage: StorageSpec
    @Binding var settings: LoadSettings
    @Environment(\.deckPalette) private var palette

    var body: some View {
        let parts = storage.rows.map(\.part)
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("storage.title")).font(Typo.small.weight(.semibold)).foregroundStyle(palette.textSecondary.color)
                .padding(.top, Space.s)
                .accessibilityAddTraits(.isHeader)
            SettingRow(tr("storage.use"), changed: !usesSSD(parts), reset: { settings.useSSD(true, parts: parts) },
                       resetHelp: tr("storage.use.reset"), details: details(parts)) {
                Toggle(tr("storage.use"), isOn: Binding(get: { usesSSD(parts) }, set: { settings.useSSD($0, parts: parts) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            } below: {
                if !usesSSD(parts) {
                    Label {
                        Text(off(parts)).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Circle().fill(palette.textTertiary.color).frame(width: 6, height: 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(Typo.caption)
                    .foregroundStyle(palette.textSecondary.color)
                }
            }
            if usesSSD(parts) {
                ForEach(storage.rows) { row in
                    StorageRow(row: row, token: token(row.part), limit: $settings.expertLimit)
                }
            }
        }
        .padding(.bottom, Space.xs)
    }

    private func usesSSD(_ parts: [StorageSpec.Part]) -> Bool { !settings.keepsEverythingInMemory(parts) }

    private func off(_ parts: [StorageSpec.Part]) -> String {
        var items: [String] = []
        if parts.contains(.experts) { items.append(tr("storage.use.off.experts")) }
        if parts.contains(.ple) { items.append(tr("storage.use.off.ple")) }
        items.append(tr("storage.use.off.cache"))
        return items.joined(separator: " · ")
    }

    private func details(_ parts: [StorageSpec.Part]) -> SettingDetails {
        var flags: [String] = []
        if parts.contains(.experts) { flags.append("--expert-memory off") }
        if parts.contains(.ple) { flags.append("--ple-memory off") }
        flags.append("--max-cache-disk 0")
        return SettingDetails(flag: nil, source: nil, splashDefault: nil, help: nil, about: tr("storage.use.about"),
                              value: flags.joined(separator: " · "))
    }

    private func token(_ part: StorageSpec.Part) -> Binding<String> {
        switch part {
        case .experts:
            Binding(get: { settings.expertMemory ?? "auto" }, set: { settings.expertMemory = $0 == "auto" ? nil : $0 })
        case .ple:
            Binding(get: { settings.pleInMemory ? "off" : "auto" }, set: { settings.pleInMemory = $0 == "off" })
        case .kv:
            Binding(get: { settings.cacheDiskOff ? "off" : "auto" }, set: { settings.cacheDiskOff = $0 == "off" })
        }
    }
}

struct StorageRow: View {
    let row: StorageSpec.Row
    @Binding var token: String
    @Binding var limit: Double?
    @Environment(\.deckPalette) private var palette

    var body: some View {
        SettingRow(row.title, changed: token != "auto", reset: { token = "auto" }, resetHelp: tr("setting.resetTo", tr("storage.auto")),
                   details: row.details, disabledReason: row.disabledReason) {
            Picker(selection: Binding(get: { token }, set: { new in
                if new == "limit", limit == nil { limit = row.limit?.resting }
                token = new
            })) {
                ForEach(row.choices) { choice in
                    Text(choice.title ?? choice.token).tag(choice.token)
                }
            } label: {
                Text(row.title)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        } below: {
            VStack(alignment: .leading, spacing: Space.xs) {
                if token == "limit", let spec = row.limit {
                    SliderRow(spec.title, value: $limit, scale: spec.scale, format: SettingUnit.bytes.format, parse: SettingUnit.bytes.parse,
                              splashDefault: nil, resting: spec.resting, provenance: spec.provenance)
                        .padding(.leading, Space.m)
                }
                Label {
                    Text(row.status).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Circle().fill(DeckBadge.color(row.tone, palette).color).frame(width: 6, height: 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(Typo.caption)
                .foregroundStyle(palette.textSecondary.color)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct DraftRow: View {
    let spec: DraftSpec
    @Binding var value: String?

    var body: some View {
        SettingRow(spec.title, details: SettingDetails(provenance: spec.provenance, help: spec.help, effect: spec.effect), disabledReason: spec.disabledReason,
                   notes: spec.choices.isEmpty ? [tr("load.draft.noneOnMac")] : []) {
            Picker(selection: $value) {
                Text(tr("load.draft.none")).tag(String?.none)
                ForEach(spec.choices) { choice in
                    Text(choice.title ?? choice.token).tag(String?.some(choice.token))
                }
            } label: {
                Text(spec.title)
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }
}
