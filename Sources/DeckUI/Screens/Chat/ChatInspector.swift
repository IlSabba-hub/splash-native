import SwiftUI

public struct ChatInspector: View {
    private let state: SectionState<ChatSettingsState>
    private let actions: ChatInspectorActions
    @Environment(\.deckPalette) private var palette

    public init(_ state: SectionState<ChatSettingsState>, actions: ChatInspectorActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(tr("chat.settings.title")).font(Typo.pageTitle).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, Space.s)
                switch state {
                case let .available(state):
                    content(state)
                case let .unavailable(reason):
                    UnavailableState(title: tr("chat.settings.title"), reason: reason)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    @ViewBuilder
    private func content(_ state: ChatSettingsState) -> some View {
        PanelSection(tr("chat.system")) {
            ChatTextArea(text: state.system, placeholder: tr("chat.system.placeholder"), label: tr("chat.system"), monospaced: false,
                         set: actions.setSystem)
        }
        Divider().overlay(palette.separator.color)
        PanelSection(tr("chat.preset"), detail: state.preset) {
            ChatPresetMenu(presets: state.presets, preset: state.preset, actions: actions)
        }
        Divider().overlay(palette.separator.color)
        PanelSection(tr("chat.sampling"), detail: changed(state.sampling)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(state.sampling) { ChatSettingRow(setting: $0, set: actions.setValue) }
            }
        }
        Divider().overlay(palette.separator.color)
        PanelSection(tr("chat.reasoning"), detail: changed(state.reasoning)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(state.reasoning) { ChatSettingRow(setting: $0, set: actions.setValue) }
            }
        }
        Divider().overlay(palette.separator.color)
        PanelSection(tr("chat.tools"), detail: state.toolNames.isEmpty ? nil : DeckFormat.count(state.toolNames.count)) {
            VStack(alignment: .leading, spacing: Space.s) {
                if !state.toolNames.isEmpty {
                    FlowLayout(spacing: Space.xs, lineSpacing: Space.xs) {
                        ForEach(state.toolNames, id: \.self) { DeckBadge($0, symbol: "hammer") }
                    }
                }
                ChatTextArea(text: state.tools, placeholder: tr("chat.tools.placeholder"), label: tr("chat.tools"), monospaced: true,
                             set: actions.setTools)
                if let problem = state.toolsProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(Typo.caption).foregroundStyle(palette.error.color)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(tr("chat.tools.help")).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func changed(_ settings: [ChatSetting]) -> String? {
        let count = settings.filter(\.isChanged).count
        return count == 0 ? nil : tr("chat.settings.changed", DeckFormat.count(count))
    }
}

struct ChatTextArea: View {
    let text: String
    let placeholder: String
    let label: String
    let monospaced: Bool
    let set: @MainActor @Sendable (String) -> Void
    @Environment(\.deckPalette) private var palette

    var body: some View {
        TextEditor(text: Binding(get: { text }, set: { set($0) }))
            .font(monospaced ? Typo.code : Typo.callout)
            .frame(minHeight: 72, maxHeight: 220)
            .scrollContentBackground(.hidden)
            .padding(Space.xs)
            .background(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(monospaced ? Typo.code : Typo.callout).foregroundStyle(palette.textTertiary.color)
                        .padding(.horizontal, Space.s + 1).padding(.vertical, Space.xs)
                        .allowsHitTesting(false)
                }
            }
            .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.control))
            .overlay { RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.separator.color, lineWidth: 1) }
            .accessibilityLabel(label)
    }
}

struct ChatPresetMenu: View {
    let presets: [String]
    let preset: String?
    let actions: ChatInspectorActions
    @State private var naming: String?
    @State private var confirmingDelete = false
    @Environment(\.deckPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Menu {
                Button {
                    actions.choosePreset(nil)
                } label: {
                    if preset == nil { Label(tr("chat.preset.none"), systemImage: "checkmark") } else { Text(tr("chat.preset.none")) }
                }
                ForEach(presets, id: \.self) { name in
                    Button {
                        actions.choosePreset(name)
                    } label: {
                        if preset == name { Label(name, systemImage: "checkmark") } else { Text(verbatim: name) }
                    }
                }
                Divider()
                if let preset {
                    Button(tr("chat.preset.update", preset)) { actions.savePreset(preset) }
                }
                Button(tr("chat.preset.saveAs")) {
                    naming = ""
                    confirmingDelete = false
                }
                if let preset {
                    Button(tr("chat.preset.delete.menu", preset), role: .destructive) {
                        confirmingDelete = true
                        naming = nil
                    }
                }
            } label: {
                Text(preset ?? tr("chat.preset.none"))
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help(tr("chat.preset.help"))
            if let name = naming {
                HStack(spacing: Space.xs) {
                    TextField(tr("chat.preset.name"), text: Binding(get: { name }, set: { naming = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button(tr("chat.cancel")) { naming = nil }
                    Button(tr("chat.preset.save"), action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
            if confirmingDelete, let preset {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(tr("chat.preset.delete.question", preset)).font(Typo.callout)
                    HStack(spacing: Space.xs) {
                        Button(tr("chat.cancel")) { confirmingDelete = false }
                            .keyboardShortcut(.cancelAction)
                        Button(tr("chat.preset.delete"), role: .destructive) {
                            actions.deletePreset(preset)
                            confirmingDelete = false
                        }
                        .tint(palette.error.color)
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
                .padding(Space.s)
                .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func save() {
        guard let name = naming?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        actions.savePreset(name)
        naming = nil
    }
}

struct ChatSettingRow: View {
    let setting: ChatSetting
    let set: @MainActor @Sendable (String, ParameterValue) -> Void

    var body: some View {
        let help = ChatFieldForm.help(setting)
        switch setting.control {
        case let .slider(range, step, digits):
            SliderRow(setting.title, value: number, range: range, step: step, digits: digits, defaultValue: setting.defaultValue,
                      placeholder: setting.placeholder, help: help, provenance: setting.provenance, problem: setting.problem,
                      disabledReason: setting.disabledReason)
        case let .stepper(minimum, maximum):
            SettingStepper(setting.title, value: integer, minimum: minimum, maximum: maximum, defaultValue: setting.defaultValue.map { Int64($0) },
                           placeholder: setting.placeholder, help: help, provenance: setting.provenance, problem: setting.problem,
                           disabledReason: setting.disabledReason)
        case .number:
            SettingNumberField(setting.title, value: number, placeholder: setting.placeholder, help: help, provenance: setting.provenance,
                               problem: setting.problem, disabledReason: setting.disabledReason)
        case let .choice(choices, unoffered):
            ChatChoiceRow(setting: setting, choices: choices, unoffered: unoffered, help: help, set: set)
        case let .lines(limit):
            ChatLinesRow(setting: setting, limit: limit, help: help, set: set)
        }
    }

    private var number: Binding<Double?> {
        Binding(get: { if case let .number(x) = setting.value { x } else { nil } },
                set: { set(setting.id, $0.map(ParameterValue.number) ?? .unset) })
    }

    private var integer: Binding<Int64?> {
        Binding(get: { if case let .integer(x) = setting.value { x } else { nil } },
                set: { set(setting.id, $0.map(ParameterValue.integer) ?? .unset) })
    }
}

struct ChatChoiceRow: View {
    let setting: ChatSetting
    let choices: [String]
    let unoffered: [ChatUnofferedChoice]
    let help: String
    let set: @MainActor @Sendable (String, ParameterValue) -> Void
    @Environment(\.deckPalette) private var palette

    var body: some View {
        SettingRow(setting.title, changed: setting.isChanged, reset: { set(setting.id, .unset) },
                   resetHelp: tr("setting.reset", setting.placeholder), details: SettingDetails(provenance: setting.provenance, splashDefault: setting.placeholder, help: help),
                   help: help, disabledReason: setting.disabledReason, problem: setting.problem) {
            if choices.count <= 4, !choices.isEmpty {
                Picker(setting.title, selection: selection) {
                    ForEach(choices, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            } else {
                Menu {
                    ForEach(choices, id: \.self) { choice in
                        Button {
                            set(setting.id, choice == setting.placeholder ? .unset : .choice(choice))
                        } label: {
                            if choice == selection.wrappedValue { Label(choice, systemImage: "checkmark") } else { Text(verbatim: choice) }
                        }
                    }
                    if !unoffered.isEmpty {
                        Divider()
                        ForEach(unoffered) { choice in
                            Button(tr("chat.choice.unoffered", choice.token)) {}
                                .disabled(true)
                                .help(choice.reason)
                        }
                    }
                } label: {
                    Text(verbatim: selection.wrappedValue)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
            }
        } below: {
            ForEach(unoffered) { choice in
                Label(tr("chat.choice.unoffered", choice.token), systemImage: "nosign")
                    .font(Typo.caption)
                    .foregroundStyle(palette.textTertiary.color)
                    .help(choice.reason)
                    .accessibilityHint(choice.reason)
            }
        }
    }

    private var selection: Binding<String> {
        Binding(get: { if case let .choice(x) = setting.value { x } else { setting.placeholder } },
                set: { set(setting.id, $0 == setting.placeholder ? .unset : .choice($0)) })
    }
}

struct ChatLinesRow: View {
    let setting: ChatSetting
    let limit: Int
    let help: String
    let set: @MainActor @Sendable (String, ParameterValue) -> Void
    @State private var draft: String?
    @Environment(\.deckPalette) private var palette

    var body: some View {
        SettingRow(setting.title, changed: setting.isChanged, reset: {
            draft = nil
            set(setting.id, .unset)
        }, resetHelp: tr("setting.reset", setting.placeholder), details: SettingDetails(provenance: setting.provenance, splashDefault: setting.placeholder, help: help),
                   help: help, disabledReason: setting.disabledReason, problem: setting.problem) {
            EmptyView()
        } below: {
            TextField(setting.title, text: Binding(get: { draft ?? lines }, set: { text in
                draft = text
                let list = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                set(setting.id, list.isEmpty ? .unset : .list(list))
            }), prompt: Text(tr("chat.stop.placeholder", DeckFormat.count(limit))), axis: .vertical)
                .labelsHidden()
                .lineLimit(1 ... limit)
                .textFieldStyle(.plain)
                .font(Typo.code)
                .padding(Space.s)
                .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(palette.separator.color, lineWidth: 1))
        }
        .onChange(of: setting.value) { _, now in
            if let draft, Self.list(draft) != Self.list(lines) { self.draft = nil }
        }
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private var lines: String {
        if case let .list(list) = setting.value { list.joined(separator: "\n") } else { "" }
    }
}
