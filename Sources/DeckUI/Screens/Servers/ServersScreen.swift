import AppKit
import SwiftUI

public struct ServersScreen: View {
    private let control: ServerControl?
    private let detail: ServerDetail?
    private let principals: SectionState<[PrincipalSummary]>?
    private let principalAction: (PrincipalSummary) -> DeckAction?
    private let principalMenu: (PrincipalSummary) -> [DeckAction]
    private let picker: ModelPickerContent?
    private let openPicker: (() -> Void)?
    @Binding private var tab: ServerTab
    private let notice: ServerNotice?
    private let pending: DeckAction?
    private let loadedActions: [DeckAction]
    private let benchAction: DeckAction?
    @State private var query = ""
    @State private var follow = true
    @State private var level: LogFilter = .all
    @State private var topHeight: CGFloat?
    @State private var showsDetails = false
    @Environment(\.deckPalette) private var palette

    public init(control: ServerControl?, detail: ServerDetail?, principals: SectionState<[PrincipalSummary]>? = nil,
                principalAction: @escaping (PrincipalSummary) -> DeckAction? = { _ in nil },
                principalMenu: @escaping (PrincipalSummary) -> [DeckAction] = { _ in [] },
                picker: ModelPickerContent? = nil, openPicker: (() -> Void)? = nil, tab: Binding<ServerTab>, notice: ServerNotice? = nil,
                pending: DeckAction? = nil, loadedActions: [DeckAction] = [], benchAction: DeckAction? = nil) {
        self.control = control
        self.detail = detail
        self.principals = principals
        self.principalAction = principalAction
        self.principalMenu = principalMenu
        self.picker = picker
        self.openPicker = openPicker
        _tab = tab
        self.notice = notice
        self.pending = pending
        self.loadedActions = loadedActions
        self.benchAction = benchAction
    }

    public var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                if let control {
                    ServerControlBar(control, picker: picker, openPicker: openPicker,
                                     details: detail == nil ? nil : { showsDetails = true })
                        .padding(.horizontal, Space.xl)
                        .padding(.vertical, Space.m)
                    Divider().overlay(palette.separator.color)
                } else if let picker {
                    HStack {
                        Spacer()
                        LoadModelButton(picker: picker, open: openPicker)
                    }
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.m)
                    Divider().overlay(palette.separator.color)
                }
                if notice != nil || pending != nil {
                    VStack(alignment: .leading, spacing: Space.s) {
                        if let notice { NoticeView(notice) }
                        if let pending { ActionButton(pending) }
                    }
                    .padding(.horizontal, Space.xl)
                    .padding(.top, Space.m)
                }
                ScrollView {
                    top.background(GeometryReader { Color.clear.preference(key: TopHeight.self, value: $0.size.height) })
                }
                .frame(height: min(topHeight ?? .infinity, max(220, geometry.size.height * 0.52)))
                .onPreferenceChange(TopHeight.self) { topHeight = $0 }
                if let detail {
                    Divider().overlay(palette.separator.color)
                    bottom(detail)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .sheet(isPresented: $showsDetails) {
            if let detail { ServerDetailsSheet(detail) { showsDetails = false }.deckTheme() }
        }
    }

    private var top: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if case let .available(list) = principals {
                PrincipalsStrip(list, compact: true) { principal in
                    guard let action = principalAction(principal) else { return [] }
                    return [action] + principalMenu(principal)
                }
            } else if case let .unavailable(reason) = principals {
                UnavailableState(title: tr("overview.principals"), reason: reason)
            }
            if let detail {
                LoadedModelSection(detail: detail, control: control, actions: loadedActions)
                if let endpoints = detail.endpoints { EndpointsSection(endpoints, base: control?.endpoint) }
            } else if control == nil {
                EmptyState(symbol: "server.rack", title: tr("servers.empty.title"), message: tr("servers.list.emptyMessage"))
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bottom(_ detail: ServerDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                Picker(tr("server.tabs"), selection: $tab) {
                    ForEach(ServerTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                if tab == .log, case let .available(log) = detail.log {
                    logTools(log)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.s)
            .background(palette.column.color)
            Divider().overlay(palette.separator.color)
            switch tab {
            case .log: logPane(detail.log)
            case .requests: ScrollView { ServerRequestsTab(detail).padding(Space.xl) }
            case .bench: ScrollView { ServerBenchTab(detail.bench, action: benchAction).padding(Space.xl) }
            }
        }
    }

    private func logTools(_ log: ServerLog) -> some View {
        HStack(spacing: Space.m) {
            HStack(spacing: Space.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
                TextField(tr("server.log.search"), text: $query).textFieldStyle(.plain)
            }
            .font(Typo.small)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs + 1)
            .frame(minWidth: 150, idealWidth: 240, maxWidth: 240)
            .background(palette.surface.color, in: .rect(cornerRadius: Radius.small))
            Picker(tr("server.log.level"), selection: $level) {
                ForEach(LogFilter.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Toggle(tr("server.log.follow"), isOn: $follow).toggleStyle(.checkbox).controlSize(.small).font(Typo.small).fixedSize()
            Spacer(minLength: Space.s)
            Button {
                let path = log.path.hasPrefix("~/") ? URL.homeDirectory.path + String(log.path.dropFirst(1)) : log.path
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(tr("action.showInFinder") + " · " + log.path)
            .accessibilityLabel(tr("action.showInFinder"))
        }
    }

    @ViewBuilder
    private func logPane(_ state: SectionState<ServerLog>) -> some View {
        switch state {
        case let .available(log):
            let lines = level == .all && query.isEmpty ? log.lines
                : log.lines.filter { (level == .all || level.keeps(LogLine($0).kind)) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) }
            if lines.isEmpty {
                EmptyState(symbol: "doc.text", title: tr(log.lines.isEmpty ? "server.log.empty" : "server.log.noMatch"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.rail.color)
            } else {
                LogView(lines, follow: follow, highlight: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case let .unavailable(reason):
            EmptyState(symbol: "doc.text", title: reason)
                .padding(Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(palette.rail.color)
        }
    }
}

private struct TopHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

public enum LogFilter: String, Sendable, CaseIterable, Identifiable {
    case all, phases, problems

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: tr("server.log.level.all")
        case .phases: tr("server.log.level.phases")
        case .problems: tr("server.log.level.problems")
        }
    }

    func keeps(_ kind: LogLine.Kind) -> Bool {
        switch self {
        case .all: true
        case .phases: kind == .phase || kind == .done || kind == .warning || kind == .error
        case .problems: kind == .warning || kind == .error
        }
    }
}

struct ServerControlBar: View {
    let control: ServerControl
    let picker: ModelPickerContent?
    var openPicker: (() -> Void)? = nil
    var details: (() -> Void)? = nil
    @State private var confirming = false
    @State private var copied = false
    @Environment(\.deckPalette) private var palette

    init(_ control: ServerControl, picker: ModelPickerContent?, openPicker: (() -> Void)? = nil, details: (() -> Void)? = nil) {
        self.control = control
        self.picker = picker
        self.openPicker = openPicker
        self.details = details
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.m) {
                    name
                    status(short: false)
                    outside
                    reachable(short: false).fixedSize()
                    Spacer(minLength: Space.s)
                    buttons(iconOnly: false)
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.m) {
                        name
                        status(short: false)
                        outside
                        Spacer(minLength: Space.s)
                        buttons(iconOnly: false)
                    }
                    reachable(short: false).fixedSize()
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        name
                        status(short: false)
                        outside
                        Spacer(minLength: Space.s)
                        buttons(iconOnly: true)
                    }
                    reachable(short: false).fixedSize()
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        name.layoutPriority(-1)
                        status(short: true)
                        Spacer(minLength: 0)
                        buttons(iconOnly: true)
                    }
                    HStack(spacing: Space.s) {
                        outside
                        reachable(short: true)
                    }
                }
            }
            if confirming, let toggle = control.toggle, case let .destructive(question, consequence, confirmTitle) = toggle.role {
                InlineConfirmation(question: question, consequence: consequence, confirmTitle: confirmTitle,
                                   cancel: { confirming = false }, confirm: { confirming = false; toggle.perform() })
                    .frame(maxWidth: 560, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var name: some View {
        if let name = control.name {
            Text(verbatim: name).font(Typo.headline).lineLimit(1).truncationMode(.tail).help(name)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var outside: some View {
        if control.foundOutside { DeckBadge(tr("chip.outside"), tone: .accent, monospaced: false).fixedSize() }
    }

    private func buttons(iconOnly: Bool) -> some View {
        HStack(spacing: Space.s) {
            settingsButton(iconOnly: iconOnly)
            detailsButton(iconOnly: iconOnly)
            loadButton(iconOnly: iconOnly)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func settingsButton(iconOnly: Bool) -> some View {
        if let settings = control.settings {
            Button(action: settings.perform) {
                if iconOnly {
                    Image(systemName: settings.systemImage ?? "gearshape").accessibilityLabel(settings.title)
                } else {
                    Label(settings.title, systemImage: settings.systemImage ?? "gearshape").lineLimit(1)
                }
            }
            .controlSize(.small)
            .disabled(!settings.isEnabled)
            .help(settings.disabledReason ?? settings.title)
        }
    }

    @ViewBuilder
    private func detailsButton(iconOnly: Bool) -> some View {
        if let details {
            Button(action: details) {
                if iconOnly {
                    Image(systemName: "info.circle").accessibilityLabel(tr("server.details"))
                } else {
                    Label(tr("server.details"), systemImage: "info.circle").lineLimit(1)
                }
            }
            .controlSize(.small)
            .help(tr("server.details.help"))
        }
    }

    @ViewBuilder
    private func loadButton(iconOnly: Bool) -> some View {
        if let picker { LoadModelButton(picker: picker, open: openPicker, iconOnly: iconOnly) }
    }

    private var statusWord: String {
        switch control.status {
        case .ready: tr("server.control.running")
        case .starting: control.statusDetail ?? tr("server.control.starting")
        case .error: control.statusDetail.map { tr("server.control.error") + " · " + $0 } ?? tr("server.control.error")
        case .stopped, .foundOutside: tr("server.control.stopped")
        }
    }

    private func status(short: Bool) -> some View {
        HStack(spacing: Space.s) {
            if !short { Text(tr("server.control.status")).foregroundStyle(palette.textTertiary.color).lineLimit(1).fixedSize() }
            Text(statusWord).foregroundStyle(palette.color(of: control.status).color).lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: !short, vertical: false)
            Toggle(isOn: Binding(get: { control.isOn }, set: { on in
                guard on != control.isOn, let toggle = control.toggle else { return }
                if case .destructive = toggle.role { confirming = true } else { toggle.perform() }
            })) {
                Text(tr("server.control.status"))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .fixedSize()
            .disabled(control.toggle?.isEnabled != true)
            .help(control.toggle.map { $0.disabledReason ?? $0.title } ?? "")
            .accessibilityLabel(tr("server.control.a11yToggle"))
            .accessibilityValue(statusWord)
        }
        .font(Typo.small)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xxs + 1)
        .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.separator.color, lineWidth: 1))
        .fixedSize(horizontal: !short, vertical: true)
        .help(control.statusDetail ?? statusWord)
    }

    private func reachable(short: Bool) -> some View {
        let label = tr(control.isOn ? "server.control.reachable" : "server.control.willListen")
        return HStack(spacing: Space.xs) {
            Text(short ? tr(control.isOn ? "server.control.reachableShort" : "server.control.willListenShort") : label)
                .foregroundStyle(control.isOn ? palette.ready.color : palette.textTertiary.color)
                .lineLimit(1).fixedSize()
                .help(label)
            Text(verbatim: control.endpoint).font(Typo.code).foregroundStyle((control.isOn ? palette.text : palette.textTertiary).color)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .help(control.endpoint)
            if let copy = control.copy {
                Button {
                    copy.perform()
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(palette.textSecondary.color)
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(!copy.isEnabled)
                .help(copy.title)
                .accessibilityLabel(copy.title)
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
        }
        .font(Typo.small)
    }
}

struct LoadModelButton: View {
    let picker: ModelPickerContent
    var open: (() -> Void)? = nil
    var iconOnly = false
    @State private var shows = false

    var body: some View {
        Button { if let open { open() } else { shows = true } } label: {
            if iconOnly {
                Image(systemName: "plus").accessibilityLabel(tr("picker.title"))
            } else {
                Label(tr("picker.title"), systemImage: "plus").lineLimit(1)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .help(tr("picker.title"))
        .modelPickerDropdown(isPresented: $shows, content: picker)
    }
}

struct LoadedModelSection: View {
    let detail: ServerDetail
    let control: ServerControl?
    let actions: [DeckAction]
    @Environment(\.deckPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(tr("server.loaded"))
            if detail.status == .stopped && detail.memory == nil {
                HStack(spacing: Space.m) {
                    Image(systemName: "cube").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
                    Text(tr("server.loaded.none")).font(Typo.small).foregroundStyle(palette.textSecondary.color)
                    Spacer(minLength: Space.s)
                    if let toggle = control?.toggle, control?.isOn == false { ActionButton(toggle).controlSize(.small) }
                }
                .padding(Space.m)
                .overlay(RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(palette.separator.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                row
                if let last = detail.lastRequest {
                    MetricsStrip(last, title: tr("metrics.lastRequest"), compact: true)
                        .padding(.horizontal, Space.m)
                }
                if case let .available(list) = detail.requests, !list.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) { ForEach(list) { RequestRow($0) } }
                        .padding(.horizontal, Space.m)
                }
            }
        }
    }

    private var row: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.m) {
                identity.frame(minWidth: 220, alignment: .leading)
                Spacer(minLength: 0)
                stats
                menu
            }
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.m) {
                    identity
                    Spacer(minLength: 0)
                    menu
                }
                HStack(spacing: Space.l) { stats }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.separator.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        HStack(spacing: Space.s) {
            StatusDot(detail.status)
            Text(verbatim: detail.model).font(Typo.code.weight(.medium)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .layoutPriority(2)
                .help(detail.model)
            if let family = detail.family { DeckBadge(family).fixedSize() }
        }
        .layoutPriority(1)
    }

    @ViewBuilder
    private var stats: some View {
        stat(tr("server.stat.memory"), memoryText)
        stat(tr("card.decodeRecent"), decodeText)
        stat(tr("server.stat.inFlight"), requestsText)
        if let released = detail.weightsReleased {
            stat(tr("chip.weights"), .value(tr(released ? "chip.weights.released" : "chip.weights.loaded")))
        }
        ForEach(detail.streaming?.summary ?? []) { fact in
            stat(fact.title, fact.value).help(fact.provenance?.sourceDescription ?? "")
        }
    }

    @ViewBuilder
    private var menu: some View {
        if !actions.isEmpty {
            Menu {
                ForEach(actions.indices, id: \.self) { index in
                    let action = actions[index]
                    Button(action: action.perform) { Label(action.title, systemImage: action.systemImage ?? "circle") }
                        .disabled(!action.isEnabled)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("server.loaded.more"))
            .accessibilityLabel(tr("server.loaded.more"))
        }
    }

    private func stat(_ title: String, _ value: Measured<String>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
            MeasuredText(value, font: Typo.small).lineLimit(1)
        }
        .fixedSize()
    }

    private var memoryText: Measured<String> {
        guard let memory = detail.memory else { return .unavailable(reason: tr("server.memory.noReading")) }
        guard let now = memory.current.value else { return memory.current.map { DeckFormat.memory($0) } }
        var parts = [DeckFormat.memory(now)]
        if let peak = memory.peak.value { parts.append(tr("server.stat.peak", DeckFormat.memory(peak))) }
        if let cap = memory.cap.value { parts.append(tr("server.stat.cap", DeckFormat.memory(cap))) }
        return .value(parts.joined(separator: " · "))
    }

    private var decodeText: Measured<String> {
        guard let series = detail.decodeSeries else { return .unavailable(reason: tr("server.memory.noReading")) }
        return series.latest.map { .value(DeckFormat.tokensPerSecond($0)) } ?? .unavailable(reason: tr("server.decode.idle"))
    }

    private var requestsText: Measured<String> {
        switch detail.requests {
        case let .available(list): .value(DeckFormat.count(list.count))
        case let .unavailable(reason): .unavailable(reason: reason)
        }
    }
}

struct EndpointsSection: View {
    let endpoints: ServerEndpoints
    let base: String?
    @State private var expanded: Bool
    @Environment(\.deckPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ endpoints: ServerEndpoints, base: String?, expanded: Bool = false) {
        self.endpoints = endpoints
        self.base = base
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withDeckAnimation(.settle, reduceMotion: reduceMotion) { expanded.toggle() }
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "chevron.right").font(Typo.caption.weight(.semibold)).foregroundStyle(palette.textTertiary.color)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
                    SectionHeader(tr("server.endpoints"), detail: DeckFormat.count(endpoints.routes.count))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(tr(expanded ? "a11y.collapse" : "a11y.expand"))
            if expanded {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.xxs) {
                        ForEach(endpoints.routes) { route in
                            GridRow {
                                DeckBadge(route.method, tone: route.method == "GET" ? .neutral : route.method == "DELETE" ? .warning : .accent)
                                Text(verbatim: route.path).font(Typo.code).textSelection(.enabled)
                                    .help(route.pattern.map { tr("server.endpoints.pattern", $0) } ?? (base.map { Self.url(base: $0, path: route.path) } ?? ""))
                                if route.open {
                                    Text(tr("server.endpoints.open")).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                                } else {
                                    Color.clear.frame(width: 1, height: 1)
                                }
                            }
                        }
                    }
                    Text(endpoints.provenance.sourceDescription).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                }
                .padding(.leading, Space.l)
                .transition(DeckMotion.comingAndGoing(reduceMotion: reduceMotion))
            }
        }
    }

    static func url(base: String, path: String) -> String {
        let root = base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
        return root + path
    }
}

public struct NoticeView: View {
    private let notice: ServerNotice
    @Environment(\.deckPalette) private var palette

    public init(_ notice: ServerNotice) {
        self.notice = notice
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            switch notice.kind {
            case .progress: ProgressView().controlSize(.small)
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.ready.color)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.starting.color)
            case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(palette.error.color)
            }
            Text(notice.text).font(Typo.small).foregroundStyle(palette.text.color).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
        .accessibilityElement(children: .combine)
    }
}

struct ServerRequestsTab: View {
    let detail: ServerDetail
    @Environment(\.deckPalette) private var palette

    init(_ detail: ServerDetail) {
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            if !detail.traffic.isEmpty {
                HStack(alignment: .top, spacing: Space.xl) {
                    ForEach(detail.traffic) { fact in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(fact.title).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                            MeasuredText(fact.value, font: Typo.small)
                        }
                        .help(fact.provenance?.sourceDescription ?? "")
                    }
                    Spacer(minLength: 0)
                }
            }
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader(tr("overview.requests"))
                switch detail.requests {
                case let .available(list) where list.isEmpty:
                    Text(tr("requests.empty.title")).font(Typo.small).foregroundStyle(palette.textTertiary.color)
                case let .available(list):
                    VStack(alignment: .leading, spacing: Space.m) { ForEach(list) { RequestRow($0) } }
                case let .unavailable(reason):
                    UnavailableValue(reason: reason, font: Typo.small)
                }
            }
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader(tr("server.history")).help(tr("server.history.source"))
                switch detail.history {
                case let .available(list) where list.isEmpty:
                    Text(tr("server.history.empty")).font(Typo.small).foregroundStyle(palette.textTertiary.color)
                case let .available(list):
                    history(list)
                case let .unavailable(reason):
                    UnavailableValue(reason: reason, font: Typo.small)
                }
            }
            if let captured = detail.captured { CapturedRequestsBlock(captured) }
        }
    }

    private func history(_ list: [LogRequest]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.xs) {
            GridRow {
                Text(tr("server.history.clock")); Text(tr("server.history.request")); Text(tr("server.history.event"))
                Text(tr("server.history.input")); Text(tr("server.history.cached")); Text(tr("server.history.output"))
                Text(tr("server.history.ttft")); Text(tr("server.history.speed"))
            }
            .font(Typo.caption.weight(.semibold))
            .foregroundStyle(palette.textTertiary.color)
            ForEach(list.reversed()) { line in
                GridRow {
                    Text(verbatim: line.clock)
                    Text(tr("request.number", String(line.request)))
                    Text(line.kind == .done ? tr("server.history.done") : tr("server.history.started"))
                        .foregroundStyle((line.kind == .done ? palette.ready : palette.starting).color)
                    Text(line.input.map { DeckFormat.count($0) } ?? "")
                    Text(line.cached.map { DeckFormat.count($0) } ?? "")
                    Text(line.output.map { DeckFormat.count($0) } ?? "")
                    Text(line.ttftSeconds.map { DeckFormat.number($0, fractionDigits: 1) + " " + tr("unit.seconds") } ?? "")
                    Text(line.tokensPerSecond.map { DeckFormat.tokensPerSecond($0) } ?? "")
                }
                .font(Typo.caption.monospacedDigit())
            }
        }
    }
}

struct ServerBenchTab: View {
    let state: SectionState<BenchSummary>
    let action: DeckAction?
    @Environment(\.deckPalette) private var palette

    init(_ state: SectionState<BenchSummary>, action: DeckAction?) {
        self.state = state
        self.action = action
    }

    var body: some View {
        switch state {
        case let .available(bench):
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    if let action { ActionButton(action).controlSize(.small) }
                    InfoButton(tr("server.tab.bench"), details: SettingDetails(flag: nil, source: nil, splashDefault: nil, help: nil,
                                                                               about: bench.method))
                    if bench.running { ProgressView().controlSize(.small); Text(tr("bench.running")).font(Typo.small) }
                }
                if let failure = bench.failure { NoticeView(ServerNotice(.failure, failure)) }
                VStack(alignment: .leading, spacing: Space.s) {
                    SectionHeader(tr("bench.results"), detail: bench.results.isEmpty ? nil : DeckFormat.count(bench.results.count))
                    if bench.results.isEmpty {
                        Text(tr("bench.empty.title")).font(Typo.small).foregroundStyle(palette.textTertiary.color)
                    } else {
                        results(bench.results)
                    }
                }
            }
        case let .unavailable(reason):
            EmptyState(symbol: "speedometer", title: reason)
        }
    }

    private func results(_ rows: [BenchRow]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.xs) {
            GridRow {
                Text(tr("bench.when")); Text(tr("bench.ttft")); Text(tr("bench.decode")); Text(tr("bench.tokens"))
                Text(tr("bench.warmup")); Text(tr("bench.peak"))
            }
            .font(Typo.caption.weight(.semibold))
            .foregroundStyle(palette.textTertiary.color)
            ForEach(rows.reversed()) { row in
                GridRow {
                    Text(DeckFormat.moment(row.at))
                    Text(DeckFormat.latency(milliseconds: row.ttftMilliseconds))
                    MeasuredText(row.decodeTokensPerSecond.map { .value(DeckFormat.tokensPerSecond($0)) } ?? .unavailable(reason: tr("bench.oneToken")),
                                 font: Typo.caption)
                    Text(DeckFormat.count(row.completionTokens))
                    Text(DeckFormat.latency(milliseconds: row.warmupTTFTMilliseconds))
                    MeasuredText(row.peakFootprintBytes.map { .value(DeckFormat.memory($0)) } ?? .unavailable(reason: tr("bench.noPeak")),
                                 font: Typo.caption)
                }
                .font(Typo.caption.monospacedDigit())
            }
        }
    }
}

public struct ServerInspector: View {
    private let detail: ServerDetail?
    private let expanded: Bool
    @Environment(\.deckPalette) private var palette

    static let shownInPage: Set<String> = ["--model", "--port", "--host"]

    public init(_ detail: ServerDetail?, expanded: Bool = false) {
        self.detail = detail
        self.expanded = expanded
    }

    public var body: some View {
        if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let flags = detail.configuration.filter { !Self.shownInPage.contains($0.provenance?.flag ?? "") }
                    PanelSection(tr("inspector.configurationInUse"), detail: DeckFormat.count(flags.count)) {
                        VStack(alignment: .leading, spacing: Space.s) {
                            Text(detail.configurationSource).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                                .fixedSize(horizontal: false, vertical: true)
                            if flags.isEmpty { UnavailableValue(reason: tr("inspector.noFlags")) }
                            ForEach(flags) { LabeledValueRow($0, compact: !expanded) }
                        }
                    }
                    section(tr("server.panel.process"), detail.identity)
                    section(tr("server.block.weights"), detail.weights)
                    section(tr("server.block.cache"), detail.cache)
                    ForEach(detail.streaming?.sections ?? []) { section($0.title, $0.facts) }
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            InspectorEmpty()
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ facts: [Fact]) -> some View {
        if !facts.isEmpty {
            Divider().overlay(palette.separator.color)
            PanelSection(title, expanded: expanded) {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(facts) { LabeledValueRow($0, compact: !expanded) }
                }
            }
        }
    }
}

public struct ServerDetailsSheet: View {
    private let detail: ServerDetail
    private let close: () -> Void
    @Environment(\.deckPalette) private var palette

    public init(_ detail: ServerDetail, close: @escaping () -> Void) {
        self.detail = detail
        self.close = close
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                StatusDot(detail.status)
                Text(tr("server.details.title", detail.name)).font(Typo.headline).lineLimit(1).truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                if detail.foundOutside { DeckBadge(tr("chip.outside"), tone: .accent, monospaced: false) }
                Spacer(minLength: Space.s)
                Text(verbatim: detail.model).font(Typo.code).foregroundStyle(palette.textSecondary.color).lineLimit(1).truncationMode(.middle)
            }
            .padding(Space.l)
            Divider().overlay(palette.separator.color)
            ServerInspector(detail, expanded: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(palette.separator.color)
            HStack {
                Spacer()
                Button(tr("editor.close"), action: close).keyboardShortcut(.cancelAction)
            }
            .padding(Space.m)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 420, idealHeight: 560)
        .background(palette.column.color)
    }
}

struct FactGrid: View {
    let facts: [Fact]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: Space.xl, verticalSpacing: Space.m) {
            ForEach(Array(stride(from: 0, to: facts.count, by: 2)), id: \.self) { index in
                GridRow {
                    LabeledValueRow(facts[index], compact: true)
                    if index + 1 < facts.count { LabeledValueRow(facts[index + 1], compact: true) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
    }
}
