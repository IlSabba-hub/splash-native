import AppKit
import SwiftUI

public struct DownloadOffer: Sendable {
    public let model: String
    public let size: Measured<String>
    public let free: Measured<String>
    public let consequence: String
    public let isEnabled: Bool
    public let disabledReason: String?
    public let start: @MainActor @Sendable () -> Void

    public init(model: String, size: Measured<String>, free: Measured<String>, consequence: String, isEnabled: Bool = true,
                disabledReason: String? = nil, start: @escaping @MainActor @Sendable () -> Void) {
        self.model = model
        self.size = size
        self.free = free
        self.consequence = consequence
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.start = start
    }
}

public struct DiscoverItem: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let about: String
    public let repo: String
    public let variant: String
    public let format: String?
    public let family: String?
    public let capabilities: [Capability]
    public let tags: [ModelTag]
    public let facts: [Fact]
    public let fits: Bool
    public let budgetNote: String?
    public let suggested: Bool
    public let installed: Bool
    public let offer: DownloadOffer?

    public init(id: String, name: String, about: String, repo: String = "", variant: String = "", format: String? = nil,
                family: String? = nil, capabilities: [Capability] = [], tags: [ModelTag], facts: [Fact], fits: Bool,
                budgetNote: String? = nil, suggested: Bool = false, installed: Bool = false, offer: DownloadOffer?) {
        self.id = id
        self.name = name
        self.about = about
        self.repo = repo
        self.variant = variant
        self.format = format
        self.family = family
        self.capabilities = capabilities
        self.tags = tags
        self.facts = facts
        self.fits = fits
        self.budgetNote = budgetNote
        self.suggested = suggested
        self.installed = installed
        self.offer = offer
    }
}

public struct DownloadStatus: Sendable {
    public let model: String
    public let fraction: Double?
    public let detail: String
    public let cancel: DeckAction

    public init(model: String, fraction: Double?, detail: String, cancel: DeckAction) {
        self.model = model
        self.fraction = fraction
        self.detail = detail
        self.cancel = cancel
    }
}

public struct HubSummary: Sendable {
    public let downloads: String?
    public let likes: String?
    public let updated: String?
    public let readme: String?
    public let source: String
    public let page: URL?

    public init(downloads: String?, likes: String?, updated: String?, readme: String?, source: String, page: URL?) {
        self.downloads = downloads
        self.likes = likes
        self.updated = updated
        self.readme = readme
        self.source = source
        self.page = page
    }
}

public enum HubState: Sendable {
    case loading
    case available(HubSummary)
    case unavailable(reason: String)
}

public enum DiscoverFormat: String, Sendable, CaseIterable, Identifiable, Hashable {
    case all, gguf, mlx

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: tr("discover.format.all")
        case .gguf: tr("models.format.gguf")
        case .mlx: tr("discover.format.mlx")
        }
    }

    func includes(_ item: DiscoverItem) -> Bool {
        switch self {
        case .all: true
        case .gguf: item.format == "GGUF"
        case .mlx: item.format == "MLX"
        }
    }
}

public struct DiscoverOverview: Sendable {
    public let facts: [Fact]
    public let items: [DiscoverItem]
    public let download: DownloadStatus?
    public let notices: [String]
    public let hubCheck: (message: String?, offer: DownloadOffer?)?
    public let hub: [String: HubState]

    public init(facts: [Fact], items: [DiscoverItem], download: DownloadStatus?, notices: [String],
                hubCheck: (message: String?, offer: DownloadOffer?)?, hub: [String: HubState] = [:]) {
        self.facts = facts
        self.items = items
        self.download = download
        self.notices = notices
        self.hubCheck = hubCheck
        self.hub = hub
    }
}

public struct DiscoverScreen: View {
    private let overview: DiscoverOverview
    @Binding private var selection: String?
    @Binding private var search: String
    @Binding private var format: DiscoverFormat
    @Binding private var onlyFitting: Bool
    @Binding private var hubID: String
    private let check: DeckAction
    @Environment(\.deckPalette) private var palette

    public init(_ overview: DiscoverOverview, selection: Binding<String?>, search: Binding<String>, format: Binding<DiscoverFormat>,
                onlyFitting: Binding<Bool>, hubID: Binding<String>, check: DeckAction) {
        self.overview = overview
        _selection = selection
        _search = search
        _format = format
        _onlyFitting = onlyFitting
        _hubID = hubID
        self.check = check
    }

    private var visible: [DiscoverItem] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        return overview.items.filter { item in
            format.includes(item) && (!onlyFitting || item.fits)
                && (needle.isEmpty || [item.name, item.id, item.about, item.family ?? ""].contains { $0.localizedCaseInsensitiveContains(needle) })
        }
    }

    private var models: [(name: String, variants: [DiscoverItem])] {
        var order: [String] = []
        var groups: [String: [DiscoverItem]] = [:]
        for item in visible {
            if groups[item.name] == nil { order.append(item.name) }
            groups[item.name, default: []].append(item)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private var selected: DiscoverItem? {
        overview.items.first { $0.id == selection } ?? models.first?.variants.first
    }

    public var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 380)
            Rectangle().fill(palette.separator.color).frame(width: 1)
            Group {
                if let selected {
                    DiscoverDetail(item: selected, variants: overview.items.filter { $0.name == selected.name }, selection: $selection,
                                   hub: overview.hub[selected.repo], download: overview.download, notices: overview.notices)
                } else {
                    EmptyState(symbol: "magnifyingglass", title: tr("discover.empty.title"), message: tr("discover.empty.message"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(DeckSection.discover.title).font(Typo.pageTitle).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Space.m)
                .padding(.top, Space.m)
            HStack(spacing: Space.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
                TextField(tr("discover.search"), text: $search, prompt: Text(tr("discover.search.prompt"))).textFieldStyle(.plain)
            }
            .font(Typo.small)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + 1)
            .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
            .padding(.horizontal, Space.m)
            .padding(.top, Space.s)
            HStack(spacing: Space.s) {
                Text(tr("discover.catalog")).font(Typo.small.weight(.semibold)).foregroundStyle(palette.textSecondary.color)
                    .help(overview.facts.first { $0.title == tr("discover.catalogSource") }.flatMap { $0.value.value } ?? "")
                Spacer(minLength: 0)
                Menu {
                    Picker(tr("discover.format"), selection: $format) {
                        ForEach(DiscoverFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Toggle(tr("discover.onlyFitting"), isOn: $onlyFitting)
                } label: {
                    Text(format == .all ? tr("discover.format.allShort") : format.title).font(Typo.small)
                }
                .fixedSize()
                .help(tr("discover.format"))
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(models, id: \.name) { model in
                        row(model.name, variants: model.variants)
                    }
                    if models.isEmpty {
                        Text(tr("discover.empty.message")).font(Typo.small).foregroundStyle(palette.textSecondary.color).padding(Space.m)
                    }
                }
                .padding(.horizontal, Space.s)
            }
            Divider().overlay(palette.separator.color)
            hubField.padding(Space.m)
        }
        .background(palette.column.color)
    }

    private func row(_ name: String, variants: [DiscoverItem]) -> some View {
        let first = variants.first { $0.suggested } ?? variants[0]
        let isSelected = selected?.name == name
        let formats = Array(Set(variants.compactMap(\.format))).sorted()
        return Button { selection = first.id } label: {
            HStack(alignment: .top, spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: Space.xs) {
                        Text(verbatim: name).font(Typo.body.weight(.semibold)).lineLimit(1)
                        if variants.contains(where: \.installed) {
                            Image(systemName: "checkmark.circle.fill").font(Typo.caption).foregroundStyle(palette.ready.color)
                                .help(tr("discover.installed")).accessibilityLabel(tr("discover.installed"))
                        }
                    }
                    Text(verbatim: first.about).font(Typo.small).foregroundStyle(palette.textSecondary.color).lineLimit(1)
                }
                Spacer(minLength: Space.s)
                VStack(alignment: .trailing, spacing: Space.xxs) {
                    CapabilityBadges(first.capabilities)
                    HStack(spacing: Space.xxs) { ForEach(formats, id: \.self) { DeckBadge($0) } }
                }
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.s)
            .background(isSelected ? palette.selection.color : .clear, in: .rect(cornerRadius: Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var hubField: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(tr("discover.hub")).font(Typo.small.weight(.semibold)).foregroundStyle(palette.textSecondary.color)
            HStack(spacing: Space.s) {
                TextField(tr("discover.hub"), text: $hubID, prompt: Text(verbatim: "OWNER/REPO[:VARIANT]"))
                    .textFieldStyle(.roundedBorder)
                Button { check.perform() } label: { Text(check.title) }
                    .disabled(!check.isEnabled)
                    .help(tr("discover.hub.note"))
            }
            if let result = overview.hubCheck {
                if let message = result.message {
                    Label(message, systemImage: "xmark.octagon.fill").font(Typo.caption).foregroundStyle(palette.error.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let offer = result.offer { DownloadButton(offer) }
            }
        }
    }
}

struct DiscoverDetail: View {
    let item: DiscoverItem
    let variants: [DiscoverItem]
    @Binding var selection: String?
    let hub: HubState?
    let download: DownloadStatus?
    let notices: [String]
    @Environment(\.deckPalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                ForEach(notices, id: \.self) { NoticeCard(text: $0) }
                header
                if !item.about.isEmpty {
                    Text(verbatim: item.about).font(Typo.body).foregroundStyle(palette.accent.color)
                }
                facts
                options
                readme
            }
            .padding(Space.xl)
            .frame(maxWidth: 760, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(verbatim: item.repo).font(Typo.cardTitle).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.id, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").accessibilityLabel(tr("discover.copyID"))
                }
                .buttonStyle(.borderless)
                .help(tr("discover.copyID"))
                Spacer(minLength: Space.s)
                if item.suggested { DeckBadge(tr("discover.suggested"), symbol: "star", tone: .accent, monospaced: false) }
            }
            hubLine
        }
    }

    @ViewBuilder
    private var hubLine: some View {
        switch hub {
        case .loading?:
            HStack(spacing: Space.xs) { ProgressView().controlSize(.mini); Text(tr("discover.hub.loading")) }
                .font(Typo.small).foregroundStyle(palette.textTertiary.color)
        case let .available(summary)?:
            HStack(spacing: Space.m) {
                if let downloads = summary.downloads { Label(downloads, systemImage: "arrow.down.circle").help(tr("discover.hub.downloads")) }
                if let likes = summary.likes { Label(likes, systemImage: "heart").help(tr("discover.hub.likes")) }
                if let updated = summary.updated { Text(tr("discover.hub.updated", updated)) }
                Spacer(minLength: 0)
                if let page = summary.page {
                    Link(destination: page) { Label(tr("discover.hub.open"), systemImage: "arrow.up.right.square") }
                        .font(Typo.small)
                }
            }
            .font(Typo.small.monospacedDigit())
            .foregroundStyle(palette.textSecondary.color)
            .help(summary.source)
        case let .unavailable(reason)?:
            Label(tr("discover.hub.unavailable"), systemImage: "icloud.slash").font(Typo.small).foregroundStyle(palette.textTertiary.color)
                .help(reason)
        case nil:
            EmptyView()
        }
    }

    private var facts: some View {
        HStack(spacing: Space.l) {
            HStack(spacing: Space.xs) {
                Text(tr("discover.family")).font(Typo.sectionHeader).foregroundStyle(palette.textTertiary.color)
                if let family = item.family {
                    DeckBadge(family)
                } else {
                    Text(tr("value.unavailable")).font(Typo.small).foregroundStyle(palette.textTertiary.color).help(tr("discover.familyUnknown"))
                }
            }
            if let format = item.format {
                HStack(spacing: Space.xs) {
                    Text(tr("discover.formatTitle")).font(Typo.sectionHeader).foregroundStyle(palette.textTertiary.color)
                    DeckBadge(format, tone: .accent)
                }
            }
            if !item.capabilities.isEmpty {
                HStack(spacing: Space.xs) {
                    Text(tr("discover.capabilities")).font(Typo.sectionHeader).foregroundStyle(palette.textTertiary.color)
                    CapabilityBadges(item.capabilities, compact: false)
                }
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(tr("discover.options")).font(Typo.headline)
            VStack(spacing: 0) {
                ForEach(variants) { variant in
                    option(variant)
                    if variant.id != variants.last?.id { Divider().overlay(palette.separator.color) }
                }
            }
            .background(palette.surface.color, in: .rect(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(palette.separator.color, lineWidth: 1))
        }
    }

    private func option(_ variant: DiscoverItem) -> some View {
        let chosen = variant.id == item.id
        return VStack(alignment: .leading, spacing: Space.s) {
            Button { selection = variant.id } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle((chosen ? palette.accent : palette.textTertiary).color).accessibilityHidden(true)
                    Text(verbatim: variant.variant).font(Typo.code.weight(.medium))
                    if let format = variant.format { DeckBadge(format) }
                    Text(verbatim: variant.repo).font(Typo.caption).foregroundStyle(palette.textTertiary.color).lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Space.s)
                    ForEach(variant.facts) { fact in
                        MeasuredText(fact.value).font(Typo.small.monospacedDigit()).foregroundStyle(palette.textSecondary.color)
                            .help(fact.title + " · " + (fact.provenance?.sourceDescription ?? ""))
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(chosen ? [.isSelected] : [])
            HStack(spacing: Space.s) {
                Tags(tags: variant.tags).help(variant.budgetNote ?? "")
                Spacer(minLength: Space.s)
                if let offer = variant.offer, chosen, download?.model != variant.id {
                    DownloadButton(offer).controlSize(.small)
                }
            }
            if let download, download.model == variant.id { progress(download) }
        }
        .padding(Space.m)
    }

    private func progress(_ download: DownloadStatus) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let fraction = download.fraction {
                ProgressView(value: fraction).accessibilityLabel(tr("discover.downloading"))
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Text(download.detail).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.textSecondary.color)
                Spacer(minLength: Space.s)
                ActionButton(download.cancel).controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var readme: some View {
        if case let .available(summary)? = hub, let text = summary.readme, !text.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(tr("discover.readme")).font(Typo.headline)
                ReadmeText(text: text, repo: item.repo)
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.surface.color, in: .rect(cornerRadius: Radius.card))
            }
        }
    }
}

struct DownloadButton: View {
    let offer: DownloadOffer
    @State private var asking = false
    @FocusState private var cancelFocused: Bool
    @Environment(\.deckPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ offer: DownloadOffer, asking: Bool = false) {
        self.offer = offer
        _asking = State(initialValue: asking)
    }

    var body: some View {
        Group {
            if asking {
                panel.transition(DeckMotion.comingAndGoing(reduceMotion: reduceMotion))
            } else {
                Button {
                    withDeckAnimation(.settle, reduceMotion: reduceMotion) { asking = true }
                } label: {
                    Label(tr("discover.download"), systemImage: "arrow.down.circle")
                }
                .disabled(!offer.isEnabled)
                .help(offer.disabledReason ?? "")
            }
        }
        .onChange(of: asking) { _, now in
            if now {
                cancelFocused = true
                AccessibilityNotification.Announcement(tr("discover.confirm.question", offer.model)).post()
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label(tr("discover.confirm.question", offer.model), systemImage: "arrow.down.circle.fill")
                .font(Typo.headline).foregroundStyle(palette.text.color)
            LabeledValueRow(title: tr("discover.size"), value: offer.size)
            LabeledValueRow(title: tr("discover.free"), value: offer.free)
            Text(offer.consequence).font(Typo.callout).foregroundStyle(palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                Spacer(minLength: 0)
                Button(tr("confirm.cancel")) {
                    withDeckAnimation(.settle, reduceMotion: reduceMotion) { asking = false }
                }
                .keyboardShortcut(.cancelAction)
                .focused($cancelFocused)
                Button(tr("discover.confirm")) {
                    asking = false
                    offer.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!offer.isEnabled)
            }
        }
        .padding(Space.m)
        .background(palette.accent.over(palette.surface, alpha: 0.10).color, in: .rect(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.accent.color.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
