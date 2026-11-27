import SwiftUI

public struct VersionsScreen: View {
    private let content: VersionsContent
    private let asking: Bool
    @State private var diffID: String?
    @Environment(\.deckPalette) private var palette

    public init(_ content: VersionsContent) {
        self.init(content, asking: false)
    }

    init(_ content: VersionsContent, asking: Bool) {
        self.content = content
        self.asking = asking
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            upgrade
            versions
            diff
        }
    }

    @ViewBuilder
    private var upgrade: some View {
        let upgrade = content.upgrade
        if upgrade.action.isEnabled || upgrade.state != .idle {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .center, spacing: Space.m) {
                    Image(systemName: "arrow.down.circle.fill").font(Typo.figure).foregroundStyle(palette.accent.color).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(upgrade.newer.map { tr("versions.update.title", $0) } ?? tr("versions.upgrade")).font(Typo.headline)
                        Text(upgrade.note).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.s)
                    CommandChip(upgrade.command)
                }
                if upgrade.state != .running { ConfirmButton(upgrade.action, asking: asking) }
                upgradeState
            }
            .padding(Space.l)
            .background(palette.accent.over(palette.surface, alpha: 0.08).color, in: .rect(cornerRadius: Radius.card))
            .overlay { RoundedRectangle(cornerRadius: Radius.card).strokeBorder(palette.accent.color.opacity(0.35), lineWidth: 1) }
        } else {
            HStack(spacing: Space.s) {
                Image(systemName: "checkmark.circle").foregroundStyle(palette.ready.color).accessibilityHidden(true)
                Text(upgrade.action.disabledReason ?? tr("versions.upgrade.nothingNewer"))
                Spacer(minLength: Space.s)
                githubControls
            }
            .font(Typo.small)
            .foregroundStyle(palette.textSecondary.color)
        }
    }

    @ViewBuilder
    private var upgradeState: some View {
        switch content.upgrade.state {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text(tr("versions.upgrade.running")).font(Typo.small)
            }
        case let .finished(status, output):
            VStack(alignment: .leading, spacing: Space.xs) {
                Label(status == 0 ? tr("versions.upgrade.done") : tr("versions.upgrade.exit", String(status)),
                      systemImage: status == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(Typo.small)
                    .foregroundStyle((status == 0 ? palette.ready : palette.error).color)
                ScrollView {
                    Text(verbatim: output).font(Typo.code).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").font(Typo.small).foregroundStyle(palette.error.color)
        }
    }

    @ViewBuilder
    private var githubControls: some View {
        switch content.github {
        case let .notChecked(check):
            Button { check.perform() } label: { Label(check.title, systemImage: check.systemImage ?? "arrow.down.circle") }
                .controlSize(.small)
                .help(tr("versions.github.notChecked"))
        case .checking:
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.mini)
                Text(tr("versions.github.checking"))
            }
        case let .failed(reason, retry):
            HStack(spacing: Space.xs) {
                Label(tr("versions.github.failed", reason), systemImage: "exclamationmark.triangle.fill").foregroundStyle(palette.error.color)
                Button(retry.title) { retry.perform() }.controlSize(.small)
            }
        case let .checked(at, refresh):
            HStack(spacing: Space.xs) {
                Text(tr("versions.github.checked", DeckFormat.moment(at))).foregroundStyle(palette.textTertiary.color)
                Button { refresh.perform() } label: { Image(systemName: "arrow.clockwise").accessibilityLabel(refresh.title) }
                    .buttonStyle(.borderless)
                    .help(refresh.title)
            }
        }
    }

    private static var columns: [DeckTableColumn] { [
        DeckTableColumn(id: "version", title: tr("versions.column.version"), width: .fixed(90)),
        DeckTableColumn(id: "state", title: tr("versions.column.state"), width: .fixed(190)),
        DeckTableColumn(id: "source", title: tr("versions.column.source"), width: .flexible(min: 200)),
        DeckTableColumn(id: "date", title: tr("versions.column.date"), width: .fixed(110)),
        DeckTableColumn(id: "flags", title: tr("versions.column.flags"), width: .fixed(70), trailing: true),
        DeckTableColumn(id: "actions", title: "", width: .fixed(64), trailing: true),
    ] }

    private var versions: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                SectionHeader(tr("versions.list"))
                if content.upgrade.action.isEnabled || content.upgrade.state != .idle {
                    githubControls.font(Typo.small).foregroundStyle(palette.textSecondary.color)
                }
            }
            switch content.rows {
            case let .available(rows) where rows.isEmpty:
                EmptyState(symbol: "shippingbox", title: tr("versions.installed.empty.title"), message: tr("versions.installed.empty.message"))
            case let .available(rows):
                DeckTable(columns: Self.columns, rows: rows, selection: .constant(nil), scrolls: false) { row, column in
                    cell(row, column)
                }
            case let .unavailable(reason):
                UnavailableState(title: tr("versions.list"), reason: reason)
            }
        }
    }

    @ViewBuilder
    private func cell(_ row: VersionRow, _ column: DeckTableColumn) -> some View {
        switch column.id {
        case "version":
            Text(verbatim: row.version).font(Typo.headline.monospacedDigit())
        case "state":
            switch row.state {
            case .inUse: DeckBadge(tr("versions.state.inUse"), symbol: "checkmark", tone: .ready, monospaced: false)
            case .installed: DeckBadge(tr("versions.state.installed"), monospaced: false)
            case .update: DeckBadge(tr("versions.state.update"), symbol: "arrow.up", tone: .accent, monospaced: false)
            case .older: Text(tr("versions.state.older")).font(Typo.small).foregroundStyle(palette.textTertiary.color)
            }
        case "source":
            Text(row.source).font(Typo.small).lineLimit(1).help(row.path ?? "")
        case "date":
            if let date = row.date { Text(DeckFormat.day(date)).font(Typo.small).foregroundStyle(palette.textSecondary.color) } else { Color.clear.frame(height: 1) }
        case "flags":
            if let schema = row.schema { MeasuredText(schema, font: Typo.small) } else { Color.clear.frame(height: 1) }
        default:
            HStack(spacing: Space.s) {
                if let notes = row.notes { NotesButton(note: notes) }
                if let reveal = row.reveal {
                    Button { reveal.perform() } label: { Image(systemName: reveal.systemImage ?? "folder").accessibilityLabel(reveal.title) }
                        .buttonStyle(.borderless)
                        .help(reveal.title)
                }
            }
        }
    }

    private var selectedDiff: VersionDiff? {
        content.diffs.first { $0.id == diffID } ?? content.diffs.first
    }

    private var diff: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                SectionHeader(tr("versions.diff"))
                if let selected = selectedDiff {
                    if content.diffs.count > 1 {
                        Picker(tr("versions.diff.pair"), selection: Binding(get: { selected.id }, set: { diffID = $0 })) {
                            ForEach(content.diffs) { Text(tr("versions.diff.pairValue", $0.from, $0.to)).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .controlSize(.small)
                        .help(selected.source)
                    } else {
                        Text(tr("versions.diff.pairValue", selected.from, selected.to)).font(Typo.small.weight(.semibold))
                            .help(selected.source)
                    }
                }
            }
            if let selected = selectedDiff {
                let rows = FlagChange.rows(selected)
                if rows.isEmpty {
                    Text(tr("versions.diff.identical")).font(Typo.small).foregroundStyle(palette.textSecondary.color)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { FlagChangeRow(change: $0) }
                    }
                }
            } else {
                EmptyState(symbol: "arrow.left.arrow.right", title: tr("versions.diff.empty.title"),
                           message: tr("versions.diff.empty.message", schemaList))
            }
        }
    }

    private var schemaList: String {
        content.schemaVersions.isEmpty ? tr("versions.diff.none") : content.schemaVersions.joined(separator: ", ")
    }
}

struct CommandChip: View {
    private let command: String
    @Environment(\.deckPalette) private var palette

    init(_ command: String) {
        self.command = command
    }

    var body: some View {
        Text(verbatim: command)
            .font(Typo.code)
            .textSelection(.enabled)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.control))
    }
}

struct FlagChange: Identifiable, Equatable {
    enum Kind: Equatable { case added, removed, defaults, needs, parser, environment, help }

    let flag: String
    let kind: Kind
    let before: String?
    let after: String?
    var id: String { "\(flag)·\(kind)" }

    var title: String {
        switch kind {
        case .added: tr("versions.diff.kind.added")
        case .removed: tr("versions.diff.kind.removed")
        case .defaults: tr("versions.diff.kind.default")
        case .needs: tr("versions.diff.kind.needs")
        case .parser: tr("versions.diff.kind.parser")
        case .environment: tr("versions.diff.kind.environment")
        case .help: tr("versions.diff.kind.help")
        }
    }

    var tone: ModelTag.Tone {
        switch kind {
        case .added: .ready
        case .removed: .error
        case .defaults, .needs: .warning
        default: .neutral
        }
    }

    static func rows(_ diff: VersionDiff) -> [FlagChange] {
        func list(_ changes: [VersionDiff.Change], _ kind: Kind) -> [FlagChange] {
            changes.map { FlagChange(flag: $0.flag, kind: kind, before: $0.before, after: $0.after) }
        }
        return diff.added.map { FlagChange(flag: $0, kind: .added, before: nil, after: nil) }
            + diff.removed.map { FlagChange(flag: $0, kind: .removed, before: nil, after: nil) }
            + list(diff.defaults, .defaults) + list(diff.needs, .needs) + list(diff.parsers, .parser)
            + list(diff.environment, .environment) + list(diff.help, .help)
    }

    static func fragment(_ before: String, _ after: String) -> (removed: String, added: String, head: Bool, tail: Bool) {
        let a = before.split(separator: " "), b = after.split(separator: " ")
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        return (a[head ..< a.count - tail].joined(separator: " "), b[head ..< b.count - tail].joined(separator: " "), head > 0, tail > 0)
    }
}

struct FlagChangeRow: View {
    let change: FlagChange
    @State private var expanded = false
    @Environment(\.deckPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(verbatim: change.flag).font(Typo.code.weight(.semibold)).frame(width: 200, alignment: .leading)
                DeckBadge(change.title, tone: change.tone, monospaced: false).frame(width: 130, alignment: .leading)
                summary
                Spacer(minLength: Space.s)
                if change.kind == .help {
                    Button { expanded.toggle() } label: {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                            .accessibilityLabel(tr(expanded ? "versions.diff.hideFull" : "versions.diff.showFull"))
                    }
                    .buttonStyle(.borderless)
                    .help(tr(expanded ? "versions.diff.hideFull" : "versions.diff.showFull"))
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: Space.xs) {
                    fullText("−", change.before, palette.error)
                    fullText("+", change.after, palette.ready)
                }
                .padding(Space.s)
                .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.control))
            }
        }
        .padding(.vertical, Space.s)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.separator.color.opacity(0.6)).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var summary: some View {
        switch change.kind {
        case .added, .removed:
            EmptyView()
        case .help:
            let part = FlagChange.fragment(change.before ?? "", change.after ?? "")
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                if part.head { Text(verbatim: "…").foregroundStyle(palette.textTertiary.color) }
                if !part.removed.isEmpty { Text(verbatim: part.removed).strikethrough().foregroundStyle(palette.error.color) }
                if !part.added.isEmpty { Text(verbatim: part.added).foregroundStyle(palette.ready.color) }
                if part.tail { Text(verbatim: "…").foregroundStyle(palette.textTertiary.color) }
            }
            .font(Typo.code)
            .lineLimit(2)
        default:
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(change.before ?? tr("versions.diff.absent")).foregroundStyle(palette.textSecondary.color)
                Image(systemName: "arrow.right").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
                Text(change.after ?? tr("versions.diff.absent"))
            }
            .font(Typo.code)
        }
    }

    private func fullText(_ sign: String, _ text: String?, _ color: RGB) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(verbatim: sign).foregroundStyle(color.color)
            Text(text ?? tr("versions.diff.absent")).foregroundStyle(palette.textSecondary.color).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(Typo.code)
    }
}

struct NotesButton: View {
    let note: VersionReleaseNote
    @State private var shows = false

    var body: some View {
        Button { shows = true } label: { Image(systemName: "doc.text").accessibilityLabel(tr("versions.notes.show")) }
            .buttonStyle(.borderless)
            .help(tr("versions.notes.show"))
            .popover(isPresented: $shows, arrowEdge: .bottom) { ReleaseNotesView(note: note).deckTheme() }
    }
}

struct ReleaseNotesView: View {
    let note: VersionReleaseNote
    @Environment(\.deckPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(verbatim: note.title ?? note.version).font(Typo.headline)
                if note.prerelease { DeckBadge(tr("versions.notes.prerelease"), tone: .warning, monospaced: false) }
                Spacer()
                if let date = note.published { Text(DeckFormat.day(date)).font(Typo.caption).foregroundStyle(palette.textTertiary.color) }
            }
            .padding(Space.l)
            Divider().overlay(palette.separator.color)
            ScrollView {
                MarkdownText(text: note.body ?? "")
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(palette.separator.color)
            Text(verbatim: note.url).font(Typo.code).foregroundStyle(palette.textTertiary.color).textSelection(.enabled)
                .padding(.horizontal, Space.l).padding(.vertical, Space.s)
        }
        .frame(width: 560, height: 520)
    }

}
