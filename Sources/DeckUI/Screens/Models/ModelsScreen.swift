import SwiftUI

public struct ModelsScreen: View {
    private let overview: ModelsOverview
    private let filter: ModelsFilter
    @Binding private var search: String
    @Binding private var selection: String?
    private let refresh: DeckAction?
    @State private var confirming: PendingConfirmation?
    @Environment(\.deckPalette) private var palette

    public init(_ overview: ModelsOverview, filter: ModelsFilter, search: Binding<String>, selection: Binding<String?>,
                refresh: DeckAction? = nil) {
        self.overview = overview
        self.filter = filter
        _search = search
        _selection = selection
        self.refresh = refresh
    }

    static var columns: [DeckTableColumn] {
        [DeckTableColumn(id: "arch", title: tr("models.column.arch"), width: .fixed(128), priority: 1),
         DeckTableColumn(id: "params", title: tr("models.column.params"), width: .fixed(64), priority: 3),
         DeckTableColumn(id: "name", title: tr("models.column.name"), width: .flexible(min: 200)),
         DeckTableColumn(id: "quant", title: tr("models.column.quant"), width: .fixed(80)),
         DeckTableColumn(id: "size", title: tr("models.column.size"), width: .fixed(78), trailing: true),
         DeckTableColumn(id: "modified", title: tr("models.column.modified"), width: .fixed(104), priority: 2),
         DeckTableColumn(id: "actions", title: tr("models.column.actions"), width: .fixed(64), trailing: true)]
    }

    private var rows: [ModelRow] {
        overview.rows.filter { filter.includes($0.kind) && $0.matches(search) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ForEach(overview.notices, id: \.self) { NoticeCard(text: $0).padding(.horizontal, Space.l).padding(.bottom, Space.s) }
            let rows = rows
            if overview.rows.filter({ filter.includes($0.kind) }).isEmpty {
                EmptyState(symbol: "shippingbox", title: tr("models.empty.title"), message: tr("models.empty.message"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                EmptyState(symbol: "line.3.horizontal.decrease", title: tr("models.noMatch.title"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DeckTable(columns: Self.columns, rows: rows, selection: $selection) { row, column in
                    cell(row, column).contextMenu { menuItems(row) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            if let confirming {
                ConfirmStrip(confirming) { self.confirming = nil }
            }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            Text(filter.title).font(Typo.pageTitle).lineLimit(1).fixedSize().accessibilityAddTraits(.isHeader)
            if let scanned = overview.scanned {
                ViewThatFits(in: .horizontal) {
                    Text(tr("models.scanned", DeckFormat.moment(scanned))).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                        .lineLimit(1).fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(-1)
            }
            if let refresh {
                Button { refresh.perform() } label: {
                    Image(systemName: refresh.systemImage ?? "arrow.clockwise").accessibilityLabel(refresh.title)
                }
                .buttonStyle(.borderless)
                .disabled(!refresh.isEnabled)
                .help(overview.scanned.map { refresh.title + " · " + tr("models.scanned", DeckFormat.moment($0)) } ?? refresh.title)
            }
            Spacer(minLength: Space.m)
            HStack(spacing: Space.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
                TextField(tr("models.filter"), text: $search, prompt: Text(tr("models.filter.prompt"))).textFieldStyle(.plain)
            }
            .font(Typo.small)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + 1)
            .frame(minWidth: 150, idealWidth: 260, maxWidth: 260)
            .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
    }

    private var footer: some View {
        let shown = overview.rows.filter { filter.includes($0.kind) }
        let bytes = shown.compactMap(\.bytes).reduce(0, +)
        let models = filter == .all || filter == .llm
        let one = shown.count == 1
        let summary = tr(models ? (one ? "models.footer.one" : "models.footer") : (one ? "models.footer.files.one" : "models.footer.files"),
                         DeckFormat.count(shown.count), DeckFormat.disk(bytes))
        let reveal = overview.folder?.actions.first
        return DeckTableFooter(summary, folder: overview.folder?.path, action: reveal)
    }

    @ViewBuilder
    private func cell(_ row: ModelRow, _ column: DeckTableColumn) -> some View {
        switch column.id {
        case "arch":
            if let architecture = row.architecture { DeckBadge(architecture.text).help(architecture.source) }
        case "params":
            if let parameters = row.parameters { DeckBadge(parameters.text).help(parameters.source) }
        case "name":
            ViewThatFits(in: .horizontal) {
                nameCell(row, fullName: true, noteText: true)
                nameCell(row, fullName: true, noteText: false)
                nameCell(row, fullName: false, noteText: false)
            }
        case "quant":
            if let quantization = row.quantization { DeckBadge(quantization.text, tone: .accent).help(quantization.source) }
        case "size":
            Text(row.bytes.map { DeckFormat.disk($0) } ?? tr("value.unavailable")).font(Typo.small.monospacedDigit())
                .foregroundStyle(palette.textSecondary.color)
                .lineLimit(1).fixedSize()
                .help(row.sizeReason ?? "")
        case "modified":
            if let modified = row.modified {
                Text(modified.text).font(Typo.small).foregroundStyle(palette.textSecondary.color).lineLimit(1).help(modified.source)
            }
        default:
            actions(row)
        }
    }

    private func nameCell(_ row: ModelRow, fullName: Bool, noteText: Bool) -> some View {
        HStack(spacing: Space.s) {
            Text(verbatim: row.name).font(Typo.code.weight(.medium)).lineLimit(1).truncationMode(.tail)
                .fixedSize(horizontal: fullName, vertical: false)
                .help(row.name == row.location ? row.location : row.name + "\n" + row.location)
            if !row.capabilities.isEmpty {
                CapabilityBadges(row.capabilities).fixedSize().help(row.capabilitiesSource ?? "")
            }
            if let note = row.note {
                Group {
                    if noteText { DeckBadge(note) } else { DeckBadge(ModelTag("", symbol: note.symbol, tone: note.tone)) }
                }
                .fixedSize()
                .help(row.noteHelp ?? note.title)
                .accessibilityLabel(note.title)
            }
        }
    }

    private func actions(_ row: ModelRow) -> some View {
        HStack(spacing: Space.xs) {
            if row.busy { ProgressView().controlSize(.mini).accessibilityLabel(tr("models.verify.busy")) }
            if !row.menu.isEmpty {
                Menu {
                    menuItems(row)
                } label: {
                    RowIcon(symbol: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("models.more"))
                .accessibilityLabel(tr("models.more"))
            }
            if row.settings.count == 1, let open = row.settings.first {
                Button { open.perform() } label: { RowIcon(symbol: "gearshape") }
                    .buttonStyle(.plain)
                    .disabled(!open.isEnabled)
                    .help(open.disabledReason ?? open.title)
                    .accessibilityLabel(open.title)
            } else if row.settings.count > 1 {
                Menu {
                    ForEach(row.settings.indices, id: \.self) { index in
                        Button { row.settings[index].perform() } label: { label(row.settings[index]) }
                            .disabled(!row.settings[index].isEnabled)
                    }
                } label: {
                    RowIcon(symbol: "gearshape")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("models.settings"))
                .accessibilityLabel(tr("models.settings"))
            }
        }
    }

    @ViewBuilder
    private func menuItems(_ row: ModelRow) -> some View {
        ForEach(row.menu.indices, id: \.self) { index in
            let action = row.menu[index]
            if case .destructive = action.role {
                Divider()
                Button(role: .destructive) {
                    selection = row.id
                    confirming = PendingConfirmation(action)
                } label: { label(action) }
                    .disabled(!action.isEnabled)
            } else {
                Button { action.perform() } label: { label(action) }.disabled(!action.isEnabled)
            }
        }
    }

    @ViewBuilder
    private func label(_ action: DeckAction) -> some View {
        if let symbol = action.systemImage { Label(action.title, systemImage: symbol) } else { Text(action.title) }
    }
}

struct RowIcon: View {
    let symbol: String
    @Environment(\.deckPalette) private var palette

    var body: some View {
        Image(systemName: symbol)
            .font(Typo.caption.weight(.semibold))
            .foregroundStyle(palette.textSecondary.color)
            .frame(width: 24, height: 20)
            .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.small))
            .contentShape(.rect)
    }
}

struct PendingConfirmation: Identifiable {
    let id = UUID()
    let action: DeckAction

    init(_ action: DeckAction) {
        self.action = action
    }
}

struct ConfirmStrip: View {
    let pending: PendingConfirmation
    let dismiss: () -> Void
    @FocusState private var cancelFocused: Bool
    @Environment(\.deckPalette) private var palette

    init(_ pending: PendingConfirmation, dismiss: @escaping () -> Void) {
        self.pending = pending
        self.dismiss = dismiss
    }

    private var words: (question: String, consequence: String?, confirm: String) {
        if case let .destructive(question, consequence, confirmTitle) = pending.action.role { return (question, consequence, confirmTitle) }
        return (tr("confirm.genericQuestion", pending.action.title), nil, pending.action.title)
    }

    var body: some View {
        let words = words
        HStack(alignment: .center, spacing: Space.m) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.error.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(words.question).font(Typo.body.weight(.semibold))
                if let consequence = words.consequence {
                    Text(consequence).font(Typo.small).foregroundStyle(palette.textSecondary.color).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.m)
            Button(tr("confirm.cancel"), action: dismiss)
                .keyboardShortcut(.cancelAction)
                .focused($cancelFocused)
            Button(role: .destructive) {
                dismiss()
                pending.action.perform()
            } label: {
                Text(words.confirm)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.error.color)
            .disabled(!pending.action.isEnabled)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .background(palette.error.over(palette.surface, alpha: 0.10).color)
        .overlay(alignment: .top) { Rectangle().fill(palette.error.color.opacity(0.5)).frame(height: 1) }
        .onAppear {
            cancelFocused = true
            AccessibilityNotification.Announcement(words.question).post()
        }
        .accessibilityElement(children: .contain)
    }
}

public struct ModelsColumn: View {
    private let overview: SectionState<ModelsOverview>
    @Binding private var filter: ModelsFilter

    public init(_ overview: SectionState<ModelsOverview>, filter: Binding<ModelsFilter>) {
        self.overview = overview
        _filter = filter
    }

    public var body: some View {
        let groups: SectionState<[ColumnGroup]> = switch overview {
        case let .available(overview):
            .available([ColumnGroup(id: "views", items: ModelsFilter.allCases.map { view in
                ColumnItem(id: view.rawValue, title: view.title, symbol: Self.symbol(view), detail: DeckFormat.count(overview.count(view)))
            })])
        case let .unavailable(reason):
            .unavailable(reason: reason)
        }
        DeckColumn(tr("models.title"), groups: groups,
                   selection: Binding(get: { filter.rawValue }, set: { filter = $0.flatMap(ModelsFilter.init(rawValue:)) ?? .all }))
    }

    static func symbol(_ filter: ModelsFilter) -> String {
        switch filter {
        case .all: "square.grid.2x2"
        case .llm: "text.bubble"
        case .drafts: "bolt.horizontal"
        case .projectors: "eye"
        }
    }
}

struct NoticeCard: View {
    let text: String
    @Environment(\.deckPalette) private var palette

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.starting.color)
        }
        .font(Typo.callout)
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.starting.over(palette.surface, alpha: 0.12).color, in: .rect(cornerRadius: Radius.control))
    }
}

struct Tags: View {
    let tags: [ModelTag]

    var body: some View {
        if !tags.isEmpty {
            FlowLayout(spacing: Space.s, lineSpacing: Space.xs) {
                ForEach(tags, id: \.self) { DeckBadge($0) }
            }
        }
    }
}

public struct ModelInspector: View {
    private let model: ModelCardSummary
    @Environment(\.deckPalette) private var palette

    public init(_ model: ModelCardSummary) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(verbatim: model.name).font(Typo.headline).accessibilityAddTraits(.isHeader)
                    if !model.location.isEmpty {
                        Text(verbatim: model.location).font(Typo.code).foregroundStyle(palette.textTertiary.color).textSelection(.enabled)
                    }
                    Tags(tags: model.tags)
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(model.facts) { LabeledValueRow($0, compact: true) }
                }
                if !model.actions.isEmpty {
                    FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
                        ForEach(model.actions.indices, id: \.self) { ActionButton(model.actions[$0]) }
                    }
                    .controlSize(.small)
                }
                SectionHeader(tr("models.preparations"), detail: DeckFormat.count(model.preparations.count))
                if model.preparations.isEmpty {
                    Text(tr("models.preparations.noneDetail")).font(Typo.caption).foregroundStyle(palette.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.preparations) { PreparationRow($0) }
                SectionHeader(tr("models.configurations"), detail: DeckFormat.count(model.configurations.count))
                if model.configurations.isEmpty {
                    Text(tr("models.configurations.none")).font(Typo.caption).foregroundStyle(palette.textSecondary.color)
                }
                ForEach(model.configurations, id: \.self) { Text(verbatim: $0).font(Typo.body) }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.surface.color)
    }
}

public struct WeightsInspector: View {
    private let weights: WeightsSummary
    @Environment(\.deckPalette) private var palette

    public init(_ weights: WeightsSummary) {
        self.weights = weights
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(verbatim: weights.name).font(Typo.headline).accessibilityAddTraits(.isHeader)
                    if !weights.location.isEmpty {
                        Text(verbatim: weights.location).font(Typo.code).foregroundStyle(palette.textTertiary.color).textSelection(.enabled)
                    }
                }
                ForEach(weights.facts) { LabeledValueRow($0, compact: true) }
                if !weights.actions.isEmpty {
                    FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
                        ForEach(weights.actions.indices, id: \.self) { ActionButton(weights.actions[$0]) }
                    }
                    .controlSize(.small)
                }
                SectionHeader(tr("models.usedByTitle"), detail: DeckFormat.count(weights.usedBy.count))
                ForEach(weights.usedBy, id: \.self) { Text(verbatim: $0).font(Typo.caption).foregroundStyle(palette.textSecondary.color) }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.surface.color)
    }
}

struct PreparationRow: View {
    let preparation: PreparationSummary
    @Environment(\.deckPalette) private var palette

    init(_ preparation: PreparationSummary) {
        self.preparation = preparation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(preparation.title).font(Typo.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: preparation.link).font(Typo.code).foregroundStyle(palette.textTertiary.color)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(preparation.link)
            Tags(tags: preparation.tags)
            ForEach(preparation.facts) { LabeledValueRow($0, compact: true) }
            if !preparation.configurations.isEmpty {
                Text(tr("models.configurations.list", preparation.configurations.joined(separator: ", ")))
                    .font(Typo.caption).foregroundStyle(palette.textSecondary.color)
            }
            if let warning = preparation.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(Typo.caption)
                    .foregroundStyle(palette.starting.color).fixedSize(horizontal: false, vertical: true)
            }
            VerificationLine(state: preparation.verification)
            FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
                if let quick = preparation.verifyQuick { ActionButton(quick) }
                if let full = preparation.verifyFull { ActionButton(full) }
            }
            .controlSize(.small)
            if let remove = preparation.remove {
                ActionButton(remove).controlSize(.small)
            } else if let refusal = preparation.removeRefusal {
                Label(refusal, systemImage: "nosign").font(Typo.caption).foregroundStyle(palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.control))
        .accessibilityElement(children: .contain)
    }
}

struct VerificationLine: View {
    let state: VerificationState
    @Environment(\.deckPalette) private var palette

    var body: some View {
        switch state {
        case .none:
            Text(tr("models.verify.never")).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
        case let .running(full):
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.mini)
                Text(tr(full ? "models.verify.runningFull" : "models.verify.running"))
            }
            .font(Typo.caption).foregroundStyle(palette.textSecondary.color)
        case let .passed(full, seconds, date):
            Label(tr(full ? "models.verify.passedFull" : "models.verify.passed",
                     DeckFormat.latency(milliseconds: seconds * 1000), DeckFormat.moment(date)),
                  systemImage: "checkmark.circle.fill")
                .font(Typo.caption).foregroundStyle(palette.ready.color)
        case let .failed(full, message, seconds):
            VStack(alignment: .leading, spacing: Space.xxs) {
                Label(tr(full ? "models.verify.failedFull" : "models.verify.failed",
                         seconds.map { DeckFormat.latency(milliseconds: $0 * 1000) } ?? tr("value.unavailable")),
                      systemImage: "xmark.octagon.fill")
                    .foregroundStyle(palette.error.color)
                Text(verbatim: message).foregroundStyle(palette.textSecondary.color).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Typo.caption)
        }
    }
}
