import SwiftUI

public struct SystemScreen: View {
    private let content: SystemContent
    private let range: StatsRange

    public init(_ content: SystemContent, range: StatsRange = .hour) {
        self.content = content
        self.range = range
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            SystemTiles(tiles: content.tiles)
            StatsSection(content.stats, range: range)
            SystemMemoryBlock(memory: content.memory)
            if !content.streaming.isEmpty { SystemStreamingBlock(servers: content.streaming) }
            SystemCacheBlock(cache: content.cache)
        }
    }
}

struct SystemStreamingBlock: View {
    let servers: [SystemStreamingServer]
    @Environment(\.deckPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(tr("system.streaming"))
            ForEach(servers) { server in
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text(verbatim: server.name).font(Typo.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        if let port = server.port {
                            Text(DeckFormat.port(port)).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                        }
                    }
                    HStack(alignment: .top, spacing: Space.xl) {
                        chart(tr("system.streaming.read"), server.readNow, server.read, provenance: server.readProvenance, range: nil) {
                            DeckFormat.throughput(bytesPerSecond: $0)
                        }
                        if let hit = server.hit, let now = server.hitNow {
                            chart(tr("system.streaming.hit"), now, hit, provenance: server.hitProvenance, range: 0 ... 1) {
                                DeckFormat.percent($0)
                            }
                        }
                    }
                }
                .padding(Space.m)
                .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.separator.color, lineWidth: 1))
            }
            Text(tr("system.streaming.footnote")).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chart(_ title: String, _ now: Measured<String>, _ series: TimeSeries, provenance: Provenance?, range: ClosedRange<Double>?,
                       format: @escaping @Sendable (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(Typo.small).foregroundStyle(palette.textSecondary.color)
            MeasuredText(now, font: Typo.headline.monospacedDigit())
            Sparkline(series, title: title, range: range, color: palette.accent, height: 48, format: format)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(provenance?.sourceDescription ?? "")
    }
}

struct SystemTiles: View {
    let tiles: [SystemTile]
    @Environment(\.deckPalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                if index > 0 { Rectangle().fill(palette.separator.color).frame(width: 1).padding(.vertical, Space.xs) }
                SystemTileView(tile: tile)
                    .padding(.horizontal, Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Space.m)
        .background(palette.surface.color, in: .rect(cornerRadius: Radius.card))
        .overlay { RoundedRectangle(cornerRadius: Radius.card).strokeBorder(palette.separator.color, lineWidth: 1) }
    }
}

struct SystemTileView: View {
    let tile: SystemTile
    @Environment(\.deckPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(tile.title).font(Typo.small).foregroundStyle(palette.textSecondary.color)
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                if let tone = tile.tone, tile.value.value != nil {
                    Circle().fill(DeckBadge.color(tone, palette).color).frame(width: 8, height: 8).accessibilityHidden(true)
                }
                MeasuredText(tile.value, font: Typo.figure)
            }
            if let fraction = tile.fraction {
                SystemUsageBar(fraction: fraction).frame(maxWidth: 160).accessibilityHidden(true)
            }
            if let series = tile.series {
                Sparkline(series, title: tile.title, range: 0 ... 100, color: palette.accent) { DeckFormat.percent($0 / 100) }
                    .frame(maxWidth: 160)
                    .frame(height: 18)
                    .clipped()
            }
            if let caption = tile.caption {
                Text(caption).font(Typo.caption).foregroundStyle(palette.textTertiary.color).lineLimit(2)
            }
        }
        .help(tile.provenance?.sourceDescription ?? "")
        .accessibilityElement(children: .combine)
    }
}

struct SystemMemoryBlock: View {
    let memory: SystemMemorySection
    @State private var showsCap = false
    @Environment(\.deckPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.xs) {
                SectionHeader(tr("system.memory")).fixedSize()
                InfoButton(tr("system.memory"), details: SettingDetails(flag: nil, source: nil, splashDefault: nil, help: nil,
                                                                        about: tr("system.table.footnote")))
                Spacer(minLength: 0)
            }
            switch memory.bar {
            case let .available(breakdown): MemoryBar(breakdown)
            case let .unavailable(reason): UnavailableState(title: tr("system.memory"), reason: reason)
            }
            switch memory.unified {
            case let .available(breakdown)?: MemoryBar(breakdown)
            case let .unavailable(reason)?: UnavailableState(title: tr("memory.unified"), reason: reason)
            case nil: EmptyView()
            }
            table
            capNote
        }
    }

    private static var columns: [DeckTableColumn] { [
        DeckTableColumn(id: "name", title: tr("system.table.name"), width: .flexible(min: 200)),
        DeckTableColumn(id: "kind", title: tr("system.table.kind"), width: .fixed(110)),
        DeckTableColumn(id: "memory", title: tr("system.table.memory"), width: .fixed(90), trailing: true),
        DeckTableColumn(id: "peak", title: tr("system.table.peak"), width: .fixed(90), trailing: true, priority: 1),
        DeckTableColumn(id: "cap", title: tr("system.table.cap"), width: .fixed(90), trailing: true),
        DeckTableColumn(id: "rule", title: tr("system.table.rule"), width: .fixed(170), priority: 2),
    ] }

    @ViewBuilder
    private var table: some View {
        let servers = memory.servers.loaded ?? [], others = memory.others.loaded ?? []
        VStack(alignment: .leading, spacing: Space.xs) {
            if !(servers + others).isEmpty {
                DeckTable(columns: Self.columns, rows: servers + others, selection: .constant(nil), scrolls: false) { row, column in
                    cell(row, column)
                }
            }
            if case let .unavailable(reason) = memory.servers {
                missing(tr("system.servers"), reason)
            } else if servers.isEmpty {
                Text(tr("system.servers.none")).font(Typo.small).foregroundStyle(palette.textSecondary.color)
            }
            if case let .unavailable(reason) = memory.others { missing(tr("system.others"), reason) }
        }
    }

    private func missing(_ title: String, _ reason: String) -> some View {
        HStack(spacing: Space.s) {
            Text(title).font(Typo.small).foregroundStyle(palette.textSecondary.color)
            UnavailableValue(reason: reason, font: Typo.small)
        }
        .padding(.horizontal, Space.m)
    }

    static func nameHelp(_ row: SystemMemoryRow) -> String {
        var lines = row.command.map { [$0] } ?? []
        lines.append(tr("system.table.peak") + ": " + (row.peak.value.map { DeckFormat.memory($0) } ?? tr("value.unavailable")))
        if let rule = row.rule { lines.append(tr("system.table.rule") + ": " + rule) }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func cell(_ row: SystemMemoryRow, _ column: DeckTableColumn) -> some View {
        switch column.id {
        case "name":
            HStack(spacing: Space.xs) {
                Text(verbatim: row.name).font(Typo.body).lineLimit(1).truncationMode(.middle)
                if let detail = row.detail {
                    Text(verbatim: detail).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.textTertiary.color)
                }
            }
            .help(Self.nameHelp(row))
        case "kind":
            switch row.kind {
            case .managed: DeckBadge(tr("system.kind.managed"), tone: .accent, monospaced: false)
            case .foundOutside: DeckBadge(tr("system.kind.outside"), tone: .warning, monospaced: false)
            case .engine: DeckBadge(tr("system.kind.engine"), monospaced: false)
            case .process: DeckBadge(tr("system.kind.process"), monospaced: false)
            }
        case "memory": MeasuredText(row.memory.map { DeckFormat.memory($0) })
        case "peak": MeasuredText(row.peak.map { DeckFormat.memory($0) }).foregroundStyle(palette.textSecondary.color)
        case "cap":
            if let cap = row.cap { MeasuredText(cap.map { DeckFormat.memory($0) }).foregroundStyle(palette.textSecondary.color) } else { Color.clear.frame(height: 1) }
        default:
            if let rule = row.rule {
                Text(rule).font(Typo.small).foregroundStyle(palette.textSecondary.color).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true).help(rule)
            } else { Color.clear.frame(height: 1) }
        }
    }

    private var capNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Image(systemName: "info.circle").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
            Button(tr("system.autoCap.title")) { showsCap = true }
                .buttonStyle(.link)
                .popover(isPresented: $showsCap, arrowEdge: .bottom) { SystemAutoCapDetail(autoCap: memory.autoCap) }
        }
        .font(Typo.small)
        .foregroundStyle(palette.textSecondary.color)
    }
}

struct SystemAutoCapDetail: View {
    let autoCap: SystemAutoCap
    @Environment(\.deckPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(tr("system.autoCap.title")).font(Typo.headline)
            Text(tr("system.autoCap.explain")).font(Typo.small).foregroundStyle(palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(autoCap.facts) { LabeledValueRow($0) }
            }
            if let help = autoCap.help { SplashQuote(help, source: autoCap.helpSource) }
        }
        .padding(Space.l)
        .frame(width: 440)
        .deckTheme()
    }
}

struct SystemCacheBlock: View {
    let cache: SystemCacheSection
    @State private var showsRules = false
    @Environment(\.deckPalette) private var palette

    private var info: some View {
        Image(systemName: "info.circle").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
    }

    @ViewBuilder
    private var rulesLink: some View {
        if !cache.rules.isEmpty {
            Button(tr("system.cache.rules")) { showsRules = true }
                .buttonStyle(.link)
                .fixedSize()
                .popover(isPresented: $showsRules, arrowEdge: .bottom) { SystemCacheRules(rules: cache.rules) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(tr("system.cache"))
            servers
            folders
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    info
                    Text(cache.clearing).lineLimit(1).fixedSize()
                    rulesLink
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        info
                        Text(cache.clearing).fixedSize(horizontal: false, vertical: true)
                    }
                    rulesLink.padding(.leading, Space.l)
                }
            }
            .font(Typo.small)
            .foregroundStyle(palette.textSecondary.color)
        }
    }

    private static var columns: [DeckTableColumn] { [
        DeckTableColumn(id: "name", title: tr("system.table.server"), width: .flexible(min: 160)),
        DeckTableColumn(id: "state", title: tr("system.cache.state"), width: .fixed(120)),
        DeckTableColumn(id: "used", title: tr("system.cache.used"), width: .fixed(170)),
        DeckTableColumn(id: "day", title: tr("system.cache.writtenDay"), width: .fixed(100), trailing: true),
        DeckTableColumn(id: "sum", title: tr("system.cache.accumulated"), width: .fixed(150), trailing: true, priority: 1),
        DeckTableColumn(id: "back", title: tr("system.cache.takenBack"), width: .fixed(140), trailing: true, priority: 2),
        DeckTableColumn(id: "more", title: "", width: .fixed(24), trailing: true),
    ] }

    @ViewBuilder
    private var servers: some View {
        switch cache.servers {
        case let .available(rows) where rows.isEmpty:
            Text(tr("system.cache.none")).font(Typo.small).foregroundStyle(palette.textSecondary.color)
        case let .available(rows):
            DeckTable(columns: Self.columns, rows: rows, selection: .constant(nil), scrolls: false) { row, column in
                cacheCell(row, column)
            }
        case let .unavailable(reason):
            UnavailableState(title: tr("system.cache"), reason: reason)
        }
    }

    @ViewBuilder
    private func cacheCell(_ row: SystemCacheServer, _ column: DeckTableColumn) -> some View {
        switch column.id {
        case "name":
            HStack(spacing: Space.xs) {
                Text(verbatim: row.name).font(Typo.body).lineLimit(1).truncationMode(.middle)
                if let port = row.port {
                    Text(DeckFormat.port(port)).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.textTertiary.color)
                }
            }
        case "state": cacheState(row.state)
        case "used":
            HStack(spacing: Space.s) {
                if let used = row.used.value, let quota = row.quota.value, quota > 0 {
                    SystemUsageBar(fraction: Double(used) / Double(quota)).frame(width: 44).accessibilityHidden(true)
                    Text(tr("system.cache.usedOf", DeckFormat.disk(used), DeckFormat.disk(quota))).font(Typo.small.monospacedDigit())
                } else {
                    MeasuredText(row.used.map { DeckFormat.disk($0) }, font: Typo.small)
                }
            }
        case "day": MeasuredText(row.writtenDay, font: Typo.small)
        case "sum": MeasuredText(row.accumulated, font: Typo.small)
        case "back": MeasuredText(row.takenBack, font: Typo.small)
        default: CacheDetailsButton(row: row)
        }
    }

    @ViewBuilder
    private func cacheState(_ state: Measured<SystemCacheState>) -> some View {
        switch state {
        case let .value(.on(persistent)):
            DeckBadge(tr(persistent ? "system.cache.on.persistent" : "system.cache.on.session"), symbol: "checkmark", tone: .ready, monospaced: false)
        case let .value(.off(reason)):
            DeckBadge(tr("system.cache.off"), tone: .warning, monospaced: false).help(reason)
        case let .unavailable(reason):
            UnavailableValue(reason: reason, font: Typo.small)
        }
    }

    @ViewBuilder
    private var folders: some View {
        switch cache.folders {
        case let .available(folders) where !folders.isEmpty:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(folders) { folder in
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        Image(systemName: "folder").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: folder.path).font(Typo.code).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            Text(folder.origins.joined(separator: " · ")).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                        }
                        Spacer(minLength: Space.s)
                        MeasuredText(folder.size.map { DeckFormat.disk($0) }, font: Typo.small)
                        if folder.size.value != nil {
                            Text(tr(folder.namespaces == 1 ? "system.cache.namespaces.one" : "system.cache.namespaces", DeckFormat.count(folder.namespaces)))
                                .font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                        }
                        if let reveal = folder.reveal {
                            Button { reveal.perform() } label: {
                                Image(systemName: reveal.systemImage ?? "folder").accessibilityLabel(reveal.title)
                            }
                            .buttonStyle(.borderless)
                            .help(reveal.title)
                        }
                    }
                    .padding(.vertical, Space.xs + 1)
                    .padding(.horizontal, Space.m)
                }
            }
            .background(palette.surface.color.opacity(0.5), in: .rect(cornerRadius: Radius.control))
        case .available:
            EmptyView()
        case let .unavailable(reason):
            UnavailableState(title: tr("system.cache.folders"), reason: reason)
        }
    }
}

struct CacheDetailsButton: View {
    let row: SystemCacheServer
    @State private var shows = false

    var body: some View {
        Button { shows = true } label: {
            Image(systemName: "ellipsis.circle").accessibilityLabel(tr("system.cache.details"))
        }
        .buttonStyle(.borderless)
        .help(tr("system.cache.details"))
        .popover(isPresented: $shows, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(verbatim: row.name).font(Typo.headline)
                LabeledValueRow(title: tr("system.cache.accumulated"), value: row.accumulated)
                LabeledValueRow(title: tr("system.cache.takenBack"), value: row.takenBack)
                ForEach(row.details) { LabeledValueRow($0) }
            }
            .padding(Space.l)
            .frame(width: 380)
            .deckTheme()
        }
    }
}

struct SystemCacheRules: View {
    let rules: [SystemHelpRule]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(tr("system.cache.rules")).font(Typo.headline)
            ForEach(rules) { rule in
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text(rule.title).font(Typo.body)
                        Text(verbatim: rule.flag).font(Typo.code)
                        Spacer()
                        if let value = rule.splashDefault { Text(tr("system.cache.rules.default", value)).font(Typo.small) }
                    }
                    SplashQuote(rule.help, source: rule.provenance.sourceDescription)
                }
            }
        }
        .padding(Space.l)
        .frame(width: 480)
        .deckTheme()
    }
}

struct SplashQuote: View {
    private let text: String
    private let source: String?
    @Environment(\.deckPalette) private var palette

    init(_ text: String, source: String?) {
        self.text = text
        self.source = source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(verbatim: text)
                .font(Typo.code)
                .foregroundStyle(palette.textSecondary.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let source {
                Text(source).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
            }
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.control))
    }
}

struct SystemUsageBar: View {
    let fraction: Double
    @Environment(\.deckPalette) private var palette

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.surfaceRaised.color)
                Capsule().fill((fraction > 1 ? palette.error : palette.accent).color)
                    .frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 5)
        .accessibilityElement()
    }
}

private extension SectionState {
    var loaded: Content? {
        if case let .available(content) = self { content } else { nil }
    }
}
