import SwiftUI

public struct SettingDetails: Sendable, Equatable {
    public let flag: String?
    public let source: String?
    public let splashDefault: String?
    public let help: String?
    public let about: String?
    public let effect: String?
    public let reason: String?
    public let value: String?

    public static let explanationLimit = 160
    static let shortDefaultLimit = 36

    public init(flag: String?, source: String?, splashDefault: String?, help: String?, about: String? = nil, effect: String? = nil,
                reason: String? = nil, value: String? = nil) {
        self.value = value
        self.flag = flag
        self.source = source
        self.splashDefault = splashDefault
        self.help = help
        self.about = about
        self.effect = effect
        self.reason = reason
    }

    public init(_ descriptor: ParameterDescriptor, value: String? = nil) {
        self.init(flag: descriptor.flag, source: descriptor.provenance?.shortDescription, splashDefault: descriptor.splashDefault,
                  help: descriptor.help, effect: descriptor.effect, value: value)
    }

    public init?(provenance: Provenance?, splashDefault: String? = nil, help: String? = nil, about: String? = nil, effect: String? = nil,
                 reason: String? = nil) {
        guard provenance != nil || splashDefault != nil || help != nil || effect != nil || reason != nil else { return nil }
        self.init(flag: provenance?.flag, source: provenance?.shortDescription, splashDefault: splashDefault, help: help,
                  about: about, effect: effect, reason: reason)
    }

    public var explanation: String? { about ?? flag.flatMap(FlagLabels.about(for:)) }

    public var shortDefault: String? {
        guard let splashDefault else { return nil }
        let first = splashDefault.split(whereSeparator: { $0 == "," || $0 == ";" }).first.map(String.init) ?? splashDefault
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.count > Self.shortDefaultLimit ? nil : trimmed
    }
}

public struct InfoButton: View {
    private let title: String
    private let details: SettingDetails
    @State private var shown = false
    @Environment(\.deckPalette) private var palette

    public init(_ title: String, details: SettingDetails) {
        self.title = title
        self.details = details
    }

    public var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(Typo.caption)
                .foregroundStyle((shown ? palette.accent : palette.textTertiary).color)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(tr("info.help"))
        .accessibilityLabel(tr("info.a11y", title))
        .accessibilityHint(tr("info.a11yHint"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            InfoPopover(title, details: details)
                .deckTheme()
        }
    }
}

public struct InfoPopover: View {
    private let title: String
    private let details: SettingDetails
    @State private var showsHelp: Bool
    @Environment(\.deckPalette) private var palette

    public static let width: CGFloat = 300

    public init(_ title: String, details: SettingDetails, showsHelp: Bool = false) {
        self.title = title
        self.details = details
        _showsHelp = State(initialValue: showsHelp)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(Typo.headline).foregroundStyle(palette.text.color).accessibilityAddTraits(.isHeader)
            if let about = details.explanation {
                Text(about).font(Typo.small).foregroundStyle(palette.textSecondary.color)
            }
            if let value = details.value {
                Text(verbatim: value).font(Typo.code).foregroundStyle(palette.text.color).textSelection(.enabled)
                    .accessibilityLabel(tr("info.value", value))
            }
            if let effect = details.effect {
                Label {
                    Text(effect).monospacedDigit()
                } icon: {
                    Image(systemName: "memorychip").accessibilityLabel(tr("info.effect"))
                }
                .font(Typo.caption)
                .foregroundStyle(palette.text.color)
            }
            if let reason = details.reason {
                Label(reason, systemImage: "questionmark.circle").font(Typo.caption).foregroundStyle(palette.textSecondary.color)
            }
            if flagLine != nil || details.source != nil || details.help != nil {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    if let flagLine {
                        Text(flagLine).font(Typo.caption).foregroundStyle(palette.textSecondary.color).textSelection(.enabled)
                    }
                    if let source = details.source {
                        Text(source).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                    }
                    if let help = details.help {
                        Button {
                            showsHelp.toggle()
                        } label: {
                            Label(tr(showsHelp ? "info.hideHelp" : "info.showHelp"), systemImage: showsHelp ? "chevron.down" : "chevron.right")
                                .font(Typo.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(palette.accent.color)
                        .padding(.top, Space.xxs)
                        if showsHelp {
                            Text(verbatim: help).font(Typo.caption).foregroundStyle(palette.textTertiary.color).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(Space.m)
        .frame(width: Self.width, alignment: .leading)
        .background(palette.column.color)
        .accessibilityElement(children: .contain)
    }

    private var flagLine: AttributedString? {
        guard details.flag != nil || details.shortDefault != nil else { return nil }
        var line = AttributedString()
        if let flag = details.flag {
            var code = AttributedString(flag)
            code.font = Typo.code
            line += code
        }
        if let value = details.shortDefault {
            if details.flag != nil { line += AttributedString(" · ") }
            line += AttributedString(tr("info.default", value))
        }
        return line
    }
}

public struct SettingRow<Control: View, Below: View>: View {
    private let title: String
    private let changed: Bool
    private let reset: (() -> Void)?
    private let resetHelp: String?
    private let details: SettingDetails?
    private let help: String?
    private let disabledReason: String?
    private let problem: String?
    private let notes: [String]
    private let control: Control
    private let below: Below
    @Environment(\.deckPalette) private var palette

    static var shortReason: Int { 80 }

    public init(_ title: String, changed: Bool = false, reset: (() -> Void)? = nil, resetHelp: String? = nil,
                details: SettingDetails? = nil, help: String? = nil, disabledReason: String? = nil, problem: String? = nil,
                notes: [String] = [], @ViewBuilder control: () -> Control, @ViewBuilder below: () -> Below) {
        self.title = title
        self.changed = changed
        self.reset = reset
        self.resetHelp = resetHelp
        self.details = details
        self.help = help
        self.disabledReason = disabledReason
        self.problem = problem
        self.notes = notes
        self.control = control()
        self.below = below()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .center, spacing: Space.s) {
                HStack(spacing: Space.xs) {
                    label
                    mark
                }
                .layoutPriority(1)
                Spacer(minLength: Space.s)
                control
                    .disabled(disabledReason != nil)
            }
            .help(help ?? "")
            below
                .disabled(disabledReason != nil)
            note
        }
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var label: some View {
        Text(title)
            .font(Typo.body)
            .foregroundStyle((disabledReason == nil ? palette.text : palette.textSecondary).color)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        if let details { InfoButton(title, details: details) }
    }

    @ViewBuilder
    private var mark: some View {
        if changed {
            Circle().fill(palette.accent.color).frame(width: 6, height: 6)
                .accessibilityLabel(tr("setting.changed"))
            if let reset, disabledReason == nil {
                Button(action: reset) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(Typo.caption.weight(.semibold))
                        .foregroundStyle(palette.textSecondary.color)
                }
                .buttonStyle(.borderless)
                .help(resetText)
                .accessibilityLabel(resetText)
            }
        }
    }

    private var resetText: String {
        resetHelp ?? details?.splashDefault.map { tr("setting.resetTo", $0) } ?? tr("parameter.reset")
    }

    @ViewBuilder
    private var note: some View {
        if let disabledReason {
            let short = disabledReason.count <= Self.shortReason
            Label(short ? disabledReason : tr("setting.noEffect"), systemImage: "nosign")
                .font(Typo.caption)
                .foregroundStyle(palette.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
                .help(disabledReason)
                .accessibilityHint(short ? "" : disabledReason)
        } else {
            ForEach(notes, id: \.self) { line in
                Text(line).font(Typo.caption).foregroundStyle(palette.textTertiary.color).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").font(Typo.caption).foregroundStyle(palette.error.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension SettingRow where Below == EmptyView {
    public init(_ title: String, changed: Bool = false, reset: (() -> Void)? = nil, resetHelp: String? = nil,
                details: SettingDetails? = nil, help: String? = nil, disabledReason: String? = nil, problem: String? = nil,
                notes: [String] = [], @ViewBuilder control: () -> Control) {
        self.init(title, changed: changed, reset: reset, resetHelp: resetHelp, details: details, help: help,
                  disabledReason: disabledReason, problem: problem, notes: notes, control: control, below: { EmptyView() })
    }
}

struct SettingFieldStyle: ViewModifier {
    static let width: CGFloat = 92
    var width: CGFloat? = SettingFieldStyle.width
    var alignment: TextAlignment = .trailing
    var invalid = false
    @Environment(\.deckPalette) private var palette

    func body(content: Content) -> some View {
        content
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .font(alignment == .trailing ? Typo.value : Typo.body)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs + 1)
            .frame(width: width)
            .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Radius.small)
                .strokeBorder((invalid ? palette.error : palette.separator).color, lineWidth: 1))
    }
}

extension View {
    func settingField(width: CGFloat? = SettingFieldStyle.width, invalid: Bool = false) -> some View {
        modifier(SettingFieldStyle(width: width, invalid: invalid))
    }

    func settingTextField(width: CGFloat? = nil, invalid: Bool = false) -> some View {
        modifier(SettingFieldStyle(width: width, alignment: .leading, invalid: invalid))
    }
}
