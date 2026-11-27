import SwiftUI

public struct ConfigurationEditorSheet: View {
    private let content: ConfigurationEditorContent
    @Binding private var header: ConfigurationHeader
    @Binding private var values: [String: ParameterValue]
    @Binding private var search: String
    @Binding private var showsInapplicable: Bool
    private let review: ConfigurationReview?
    private let menu: [NativeAction]
    private let verify: NativeAction?
    private let load: NativeAction?
    private let changed: Bool
    private let notices: [String]
    private let close: @MainActor @Sendable () -> Void
    @State private var pane: String
    @State private var confirming: PendingConfirmation?
    @Environment(\.nativePalette) private var palette

    public static let general = "general"
    public static let review = "review"

    public init(_ content: ConfigurationEditorContent, header: Binding<ConfigurationHeader>, values: Binding<[String: ParameterValue]>,
                search: Binding<String>, showsInapplicable: Binding<Bool>, review: ConfigurationReview?, menu: [NativeAction],
                verify: NativeAction?, load: NativeAction?, changed: Bool, notices: [String] = [], pane: String? = nil,
                close: @escaping @MainActor @Sendable () -> Void) {
        self.content = content
        _header = header
        _values = values
        _search = search
        _showsInapplicable = showsInapplicable
        self.review = review
        self.menu = menu
        self.verify = verify
        self.load = load
        self.changed = changed
        self.notices = notices
        self.close = close
        _pane = State(initialValue: pane ?? Self.general)
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(palette.separator.color)
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(palette.separator.color).frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(palette.background.color)
            }
            if let confirming {
                ConfirmStrip(confirming) { self.confirming = nil }
            }
            Divider().overlay(palette.separator.color)
            bottomBar
        }
        .frame(minWidth: 900, idealWidth: 960, minHeight: 600, idealHeight: 680)
        .background(palette.column.color)
    }

    private var titleBar: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "gearshape").foregroundStyle(palette.textSecondary.color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Space.xs) {
                    Text(verbatim: header.name.isEmpty ? tr("editor.untitled") : header.name).font(Typo.headline)
                        .accessibilityAddTraits(.isHeader)
                    if changed {
                        Circle().fill(palette.accent.color).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(tr(content.isNew ? "editor.new" : "editor.unsaved")).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                    }
                }
                Text(verbatim: header.model).font(Typo.code).foregroundStyle(palette.textSecondary.color).lineLimit(1).truncationMode(.middle)
            }
            ForEach(badges, id: \.self) { NativeBadge($0) }
            Spacer(minLength: Space.m)
            HStack(spacing: Space.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
                TextField(tr("config.search"), text: $search, prompt: Text(tr("config.search.prompt"))).textFieldStyle(.plain)
            }
            .font(Typo.small)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + 1)
            .frame(width: 220)
            .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
            if !menu.isEmpty {
                Menu {
                    ForEach(menu.indices, id: \.self) { index in
                        let action = menu[index]
                        if case .destructive = action.role {
                            Divider()
                            Button(role: .destructive) { confirming = PendingConfirmation(action) } label: { label(action) }
                                .disabled(!action.isEnabled)
                        } else {
                            Button { action.perform() } label: { label(action) }.disabled(!action.isEnabled)
                        }
                    }
                } label: {
                    RowIcon(symbol: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("editor.menu"))
                .accessibilityLabel(tr("editor.menu"))
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
    }

    private var badges: [String] {
        var list: [String] = []
        if let version = content.versions.first(where: { $0.token == header.installation }) { list.append(version.title ?? version.token) }
        if let port = header.port { list.append(NativeFormat.port(port)) }
        return list
    }

    private struct PaneItem: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let changed: Int
    }

    private var paneItems: [PaneItem] {
        var items = [PaneItem(id: Self.general, title: tr("editor.pane.general"), symbol: "slider.horizontal.3", changed: 0)]
        for pane in content.panes {
            items.append(PaneItem(id: pane.id, title: pane.title, symbol: Self.symbol(pane.splashName),
                                  changed: pane.settings.filter { (values[$0.id] ?? .unset) != .unset }.count))
        }
        items.append(PaneItem(id: Self.review, title: tr("editor.pane.review"), symbol: "checkmark.seal", changed: 0))
        return items
    }

    static func symbol(_ group: String?) -> String {
        switch group {
        case "model": "shippingbox"
        case "network and access": "network"
        case "memory and context": "memorychip"
        case "SSD cache": "internaldrive"
        case "API": "curlybraces"
        case "requests": "arrow.left.arrow.right"
        default: "questionmark.square.dashed"
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(paneItems) { item in
                let selected = search.isEmpty && pane == item.id
                Button { pane = item.id; search = "" } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: item.symbol).frame(width: 16).foregroundStyle((selected ? palette.accent : palette.textSecondary).color)
                            .accessibilityHidden(true)
                        Text(item.title).lineLimit(1)
                        Spacer(minLength: 0)
                        if item.changed > 0 {
                            Text(NativeFormat.count(item.changed)).font(Typo.caption.monospacedDigit()).foregroundStyle(palette.accent.color)
                                .help(tr(item.changed == 1 ? "editor.changedCount.one" : "editor.changedCount", NativeFormat.count(item.changed)))
                        }
                    }
                    .font(Typo.body)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xs + 1)
                    .background(selected ? palette.selection.color : .clear, in: .rect(cornerRadius: Radius.control))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                if item.id == Self.general || content.panes.last?.id == item.id {
                    Divider().overlay(palette.separator.color).padding(.vertical, Space.xs)
                }
            }
            Spacer(minLength: Space.m)
            Toggle(tr("editor.showInapplicable"), isOn: $showsInapplicable)
                .toggleStyle(.checkbox)
                .font(Typo.small)
                .help(tr("editor.showInapplicable.help"))
        }
        .padding(Space.m)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(notices, id: \.self) { NoticeCard(text: $0).padding(.bottom, Space.s) }
                ForEach(content.notices, id: \.self) { NoticeCard(text: $0).padding(.bottom, Space.s) }
                if let reason = content.schemaUnavailable {
                    UnavailableState(title: tr("config.parameters"), reason: reason)
                } else if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                    results
                } else if pane == Self.general {
                    generalPane
                } else if pane == Self.review {
                    reviewPane
                } else if let selected = content.panes.first(where: { $0.id == pane }) {
                    paneView(selected)
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.l)
            .frame(maxWidth: 680, alignment: .topLeading)
        }
    }

    private func visible(_ settings: [EditorSetting]) -> [EditorSetting] {
        settings.filter { $0.applicable || showsInapplicable || (values[$0.id] ?? .unset) != .unset }
    }

    private func paneView(_ pane: EditorPane) -> some View {
        let settings = visible(pane.settings)
        let hidden = pane.settings.count - settings.count
        return VStack(alignment: .leading, spacing: 0) {
            paneTitle(pane.title)
            if pane.splashName == "model" { modelRows }
            if pane.splashName == "network and access" { networkRows }
            rows(settings)
            if hidden > 0 {
                Button(tr(hidden == 1 ? "editor.hiddenInapplicable.one" : "editor.hiddenInapplicable", NativeFormat.count(hidden))) { showsInapplicable = true }
                    .buttonStyle(.link)
                    .font(Typo.caption)
                    .padding(.top, Space.m)
            }
        }
    }

    private func paneTitle(_ title: String) -> some View {
        Text(title).font(Typo.pageTitle).accessibilityAddTraits(.isHeader)
            .padding(.bottom, Space.s)
    }

    private var rowDivider: some View {
        Divider().overlay(palette.separator.color.opacity(0.6))
    }

    private func rows(_ settings: [EditorSetting]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(settings) { setting in
                settingRow(setting)
                rowDivider
            }
        }
    }

    @ViewBuilder
    private func settingRow(_ setting: EditorSetting) -> some View {
        let flag = setting.descriptor.flag
        let value = Binding(get: { values[flag] ?? .unset }, set: { values[flag] = $0 })
        let problem = content.problems[flag] ?? ParameterValidation.problem(setting.descriptor.kind, value.wrappedValue)
        if case let .slider(scale, unit, automatic) = setting.control {
            EditorSlider(setting: setting, scale: scale, unit: unit, automatic: automatic, problem: problem, value: value)
        } else if case let .weights(choices, current, unset) = setting.control {
            let text = Binding(get: { if case let .text(path) = value.wrappedValue { path } else { "" } },
                               set: { value.wrappedValue = $0.isEmpty ? .unset : .text($0) })
            EditorWeightsRow(title: setting.descriptor.title, choices: choices, current: current, unset: unset, text: text,
                             prompt: setting.descriptor.splashDefault ?? "",
                             details: SettingDetails(setting.descriptor, value: current?.detail),
                             changed: value.wrappedValue != .unset, reset: { values[flag] = .unset },
                             disabledReason: setting.descriptor.disabledReason, problem: problem)
        } else {
            SettingRow(setting.descriptor.title, changed: value.wrappedValue != .unset, reset: { values[flag] = .unset },
                       details: SettingDetails(setting.descriptor), disabledReason: setting.descriptor.disabledReason, problem: problem) {
                SettingControlView(setting: setting, value: value)
            }
        }
    }

    private var results: some View {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let found = content.panes.compactMap { pane -> (pane: EditorPane, settings: [EditorSetting])? in
            let matches = visible(pane.settings).filter { setting in
                setting.descriptor.title.localizedCaseInsensitiveContains(needle) || setting.descriptor.flag.localizedCaseInsensitiveContains(needle)
                    || (setting.descriptor.help?.localizedCaseInsensitiveContains(needle) ?? false)
            }
            return matches.isEmpty ? nil : (pane, matches)
        }
        return VStack(alignment: .leading, spacing: Space.l) {
            if found.isEmpty {
                Text(tr("config.noMatch")).font(Typo.callout).foregroundStyle(palette.textSecondary.color)
            }
            ForEach(found, id: \.pane.id) { entry in
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(entry.pane.title, detail: NativeFormat.count(entry.settings.count))
                    rows(entry.settings)
                }
            }
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneTitle(tr("editor.pane.general"))
            SettingRow(tr("config.name"), problem: content.problems["name"]) {
                TextField(tr("config.name"), text: $header.name).settingTextField(width: 240)
            }
            rowDivider
            SettingRow(tr("config.version"), problem: content.problems["splashVersion"]) {
                Picker(tr("config.version"), selection: $header.installation) {
                    ForEach(content.versions) { Text(verbatim: $0.title ?? $0.token).tag($0.token) }
                }
                .labelsHidden().fixedSize()
            }
            rowDivider
            SettingRow(tr("config.principal")) {
                Toggle(tr("config.principal"), isOn: $header.principal).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            rowDivider
            SettingRow(tr("config.observe")) {
                Toggle(tr("config.observe"), isOn: $header.observe).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help(tr("config.observe.help"))
            }
            if header.observe, let port = header.port {
                Text(tr("config.observe.ports", NativeFormat.port(port), NativeFormat.port(port + 10_000)))
                    .font(Typo.caption).foregroundStyle(palette.textTertiary.color).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Space.s)
            }
            rowDivider
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(content.facts) { LabeledValueRow($0) }
            }
            .padding(.top, Space.m)
        }
    }

    @ViewBuilder
    private var modelRows: some View {
        let flag = header.isLocal ? "--model-dir" : "--model"
        EditorWeightsRow(title: tr("config.model"), choices: content.models, current: content.model, unset: nil, text: $header.model,
                         prompt: tr("config.model.prompt"),
                         details: SettingDetails(flag: flag, source: nil, splashDefault: nil, help: nil, value: content.model?.detail),
                         changed: false, reset: nil, disabledReason: nil, problem: content.problems["model"])
        rowDivider
        if header.isLocal {
            SettingRow(tr("config.apiModelID"), details: SettingDetails(flag: "--model", source: nil, splashDefault: nil, help: nil,
                                                                        value: header.apiModelID.isEmpty ? nil : header.apiModelID),
                       problem: content.problems["apiModelID"]) {
                TextField(tr("config.apiModelID"), text: $header.apiModelID, prompt: Text(verbatim: "OWNER/REPO"))
                    .settingTextField()
                    .frame(minWidth: 200, maxWidth: WeightsPicker.maxWidth)
                    .help(header.apiModelID)
            }
            rowDivider
        }
    }

    @ViewBuilder
    private var networkRows: some View {
        SettingRow(tr("config.port"), problem: content.problems["port"]) {
            HStack(spacing: Space.s) {
                if let shared = content.modelPort {
                    if header.port == shared {
                        Label(tr("config.port.shared"), systemImage: "checkmark.circle").font(Typo.small)
                            .foregroundStyle(palette.textSecondary.color)
                            .help(tr("config.port.shared.help"))
                    } else {
                        Button(tr("config.port.useShared", NativeFormat.port(shared))) { header.port = shared }
                            .controlSize(.small)
                            .help(tr("config.port.shared.help"))
                    }
                }
                TextField(tr("config.port"), value: $header.port, format: .number.grouping(.never)).settingField()
            }
        }
        rowDivider
        SettingRow(FlagLabels.title(for: "--api-key") ?? "--api-key",
                   details: SettingDetails(flag: "--api-key", source: nil, splashDefault: nil, help: nil, about: tr("config.keyNote")),
                   problem: content.problems["--api-key"]) {
            HStack(spacing: Space.s) {
                if header.usesAPIKey {
                    SecureField(tr("flag.api-key"), text: $header.apiKey).settingTextField(width: 180)
                }
                Toggle(tr("config.usesKey"), isOn: $header.usesAPIKey).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        rowDivider
    }

    @ViewBuilder
    private var reviewPane: some View {
        paneTitle(tr("editor.pane.review"))
        if let review {
            ConfigurationReviewView(review: review)
        } else {
            Text(tr("config.verdict.none")).font(Typo.callout).foregroundStyle(palette.textSecondary.color)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: Space.s) {
            verdictLine
            if let verify {
                Button { verify.perform() } label: { Label(verify.title, systemImage: verify.systemImage ?? "checkmark.seal") }
                    .disabled(!verify.isEnabled)
                    .help(verify.disabledReason ?? "")
            }
            Spacer(minLength: Space.m)
            Button(tr("editor.close")) {
                if changed {
                    confirming = PendingConfirmation(NativeAction(
                        title: tr("editor.discard"),
                        role: .destructive(question: tr("editor.discard.question"), consequence: tr("editor.discard.consequence"),
                                           confirmTitle: tr("editor.discard")), perform: close))
                } else {
                    close()
                }
            }
            .keyboardShortcut(.cancelAction)
            if let load {
                Button { load.perform() } label: { Label(load.title, systemImage: load.systemImage ?? "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!load.isEnabled)
                    .help(load.disabledReason ?? "")
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
    }

    @ViewBuilder
    private var verdictLine: some View {
        if review?.verifying == true {
            HStack(spacing: Space.xs) { ProgressView().controlSize(.mini); Text(tr("config.verifying")) }
                .font(Typo.small).foregroundStyle(palette.textSecondary.color)
        } else if let verdict = review?.verdict {
            Button { pane = Self.review; search = "" } label: {
                Label(tr(verdict.accepted ? "config.verdict.accepted" : "config.verdict.refused", NativeFormat.moment(verdict.date)),
                      systemImage: verdict.accepted ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .font(Typo.small)
                    .foregroundStyle((verdict.accepted ? palette.ready : palette.error).color)
            }
            .buttonStyle(.plain)
            .help(verdict.message ?? "")
        } else {
            Text(tr("editor.notVerified")).font(Typo.small).foregroundStyle(palette.textTertiary.color)
        }
    }

    @ViewBuilder
    private func label(_ action: NativeAction) -> some View {
        if let symbol = action.systemImage { Label(action.title, systemImage: symbol) } else { Text(action.title) }
    }
}

struct SettingControlView: View {
    let setting: EditorSetting
    @Binding var value: ParameterValue
    @Environment(\.nativePalette) private var palette

    var body: some View {
        let descriptor = setting.descriptor
        switch setting.control {
        case .field:
            ParameterControl(descriptor: descriptor, value: $value)
        case .toggle:
            Toggle(descriptor.title, isOn: Binding(get: { value == .bool(true) }, set: { value = $0 ? .bool(true) : .unset }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        case let .segmented(choices, defaultToken):
            Picker(descriptor.title, selection: Binding(
                get: { if case let .choice(token) = value { token } else { defaultToken ?? "" } },
                set: { value = $0 == defaultToken ? .unset : .choice($0) })) {
                ForEach(choices) { Text(verbatim: $0.title ?? $0.token).tag($0.token) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        case let .menu(choices, defaultToken):
            Picker(descriptor.title, selection: Binding(get: { defaultToken.map { value == .choice($0) } == true ? .unset : value },
                                                        set: { value = $0 })) {
                Text(ParameterDescriptor.defaultEntry(word: defaultToken.map { token in choices.first { $0.token == token }?.title ?? token },
                                                      value: nil)).tag(ParameterValue.unset)
                ForEach(choices.filter { $0.token != defaultToken }) { Text(verbatim: $0.title ?? $0.token).tag(ParameterValue.choice($0.token)) }
            }
            .labelsHidden().fixedSize()
        case let .stepper(range):
            stepper(range, defaultValue: descriptor.splashDefault.flatMap { Int64($0) })
        case .slider, .weights:
            EmptyView()
        }
    }

    private func stepper(_ range: ClosedRange<Int64>, defaultValue: Int64?) -> some View {
        SettingStepperControl(setting.descriptor.title,
                              value: Binding(get: { if case let .integer(n) = value { n } else { nil } },
                                             set: { value = $0.map { .integer(min(max($0, range.lowerBound), range.upperBound)) } ?? .unset }),
                              minimum: range.lowerBound, maximum: range.upperBound, defaultValue: defaultValue,
                              placeholder: setting.descriptor.splashDefault ?? "")
    }
}

struct EditorWeightsRow: View {
    let title: String
    let choices: [WeightsChoice]
    let current: WeightsChoice?
    let unset: String?
    @Binding var text: String
    let prompt: String
    let details: SettingDetails
    let changed: Bool
    let reset: (() -> Void)?
    let disabledReason: String?
    let problem: String?
    @State private var manual = false

    var body: some View {
        SettingRow(title, changed: changed, reset: reset, details: details, disabledReason: disabledReason, problem: problem) {
            WeightsPicker(title, choices: choices, current: current, unset: unset, pick: { token in
                manual = false
                text = token ?? ""
            }, manual: { manual = true })
        } below: {
            if manual || (current == nil && unset == nil) {
                TextField(title, text: $text, prompt: Text(prompt))
                    .settingTextField()
                    .help(text)
            }
        }
    }
}

struct EditorSlider: View {
    let setting: EditorSetting
    let scale: SliderScale
    let unit: SettingUnit
    let automatic: ParameterWord?
    let problem: String?
    @Binding var value: ParameterValue

    var body: some View {
        let descriptor = setting.descriptor
        let first = descriptor.splashDefault.map { String($0.prefix { !",; ".contains($0) }) }
        let autoValue: ParameterValue = automatic.map { first == $0.token ? .unset : .word($0.token) } ?? .unset
        let shown: String? = if case let .word(token) = value { token } else { first }
        let placeholder = shown.map { token in
            automatic?.token == token ? (automatic?.title ?? token) : Double(token).map(unit.format) ?? token
        } ?? ""
        SliderRow(descriptor.title,
                  value: Binding(get: {
                      switch value {
                      case let .integer(n): Double(n)
                      case let .bytes(b): Double(b)
                      default: nil
                      }
                  }, set: { typed in
                      guard let typed else { value = autoValue; return }
                      value = unit == .bytes ? .bytes(Int64(typed.rounded())) : .integer(Int64(typed.rounded()))
                  }),
                  scale: scale, format: unit.format, parse: unit.parse, automatic: automatic?.title, placeholder: placeholder,
                  resting: first.flatMap(Double.init), changed: value != .unset, reset: { value = .unset },
                  details: SettingDetails(descriptor), problem: problem,
                  disabledReason: descriptor.disabledReason)
    }
}

struct ConfigurationReviewView: View {
    let review: ConfigurationReview
    @Environment(\.nativePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            verdict
            VStack(alignment: .leading, spacing: Space.xs) {
                SectionHeader(tr("config.diff"), detail: NativeFormat.count(review.diff.count))
                if review.diff.isEmpty {
                    Text(tr("config.diff.none")).font(Typo.caption).foregroundStyle(palette.textSecondary.color)
                }
                ForEach(review.diff) { LabeledValueRow($0) }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                SectionHeader(tr("config.history"), detail: NativeFormat.count(review.history.count))
                if review.history.isEmpty {
                    Text(tr("config.history.none")).font(Typo.caption).foregroundStyle(palette.textSecondary.color)
                }
                ForEach(review.history) { entry in
                    Button { review.onSelectHistory(entry.id) } label: {
                        HStack(spacing: Space.s) {
                            Text(verbatim: entry.message).font(Typo.small).foregroundStyle(palette.text.color).lineLimit(1)
                            Spacer(minLength: Space.s)
                            Text(NativeFormat.moment(entry.date)).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                        }
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, Space.xs)
                        .background((review.selectedHistory == entry.id ? palette.selection : palette.surface).color,
                                    in: .rect(cornerRadius: Radius.small))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if review.selectedHistory == entry.id {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            if review.historyDiff.isEmpty {
                                Text(tr("config.history.same")).font(Typo.caption).foregroundStyle(palette.textSecondary.color)
                            }
                            ForEach(review.historyDiff) { LabeledValueRow($0) }
                            ForEach(review.historyActions.indices, id: \.self) { ActionButton(review.historyActions[$0]).controlSize(.small) }
                        }
                        .padding(.leading, Space.m)
                        .padding(.bottom, Space.s)
                    }
                }
            }
        }
    }

    private var verdict: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeader(tr("config.verdict"))
            if let verdict = review.verdict {
                Label(tr(verdict.accepted ? "config.verdict.accepted" : "config.verdict.refused", NativeFormat.moment(verdict.date)),
                      systemImage: verdict.accepted ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .font(Typo.body.weight(.semibold))
                    .foregroundStyle((verdict.accepted ? palette.ready : palette.error).color)
                if let message = verdict.message {
                    Text(verbatim: message).font(Typo.caption).foregroundStyle(palette.textSecondary.color).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(verdict.facts) { LabeledValueRow($0, compact: ($0.value.value?.count ?? 0) > 60) }
                ForEach(verdict.dropped, id: \.self) {
                    Label($0, systemImage: "minus.circle").font(Typo.caption).foregroundStyle(palette.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(verdict.notices, id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle.fill").font(Typo.caption).foregroundStyle(palette.starting.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(tr("config.verdict.none")).font(Typo.caption).foregroundStyle(palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
