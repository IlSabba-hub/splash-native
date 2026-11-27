import SwiftUI

public struct GPUMemorySettings: View {
    private let content: GPUMemoryPresentation
    @Binding private var selection: Double?
    @Environment(\.deckPalette) private var palette

    public init(_ content: GPUMemoryPresentation, selection: Binding<Double?>) {
        self.content = content
        _selection = selection
    }

    public var body: some View {
        Form {
            Section {
                ForEach(content.now) { SettingsRowView(row: $0) }
            } header: {
                Text(tr("gpu.now"))
            }
            Section {
                switch content.slider {
                case let .available(slider):
                    SliderRow(tr("gpu.slider"), value: $selection,
                              scale: .linear(slider.lowestBytes ... slider.highestBytes, step: Double(1 << 30)),
                              format: { DeckFormat.memory(Int64($0)) }, parse: SettingUnit.bytes.parse, automatic: nil,
                              placeholder: slider.current, resting: slider.restingBytes,
                              changed: selection.map { $0 != slider.restingBytes } ?? false,
                              reset: { selection = slider.restingBytes }, notes: slider.notes,
                              details: SettingDetails(flag: "iogpu.wired_limit_mb", source: tr("provenance.system", "sysctl"),
                                                      splashDefault: "0", help: nil),
                              help: tr("gpu.slider.help"))
                    ForEach(content.effect) { SettingsRowView(row: $0) }
                case let .unavailable(reason):
                    UnavailableState(title: tr("gpu.slider"), reason: reason)
                }
            } header: {
                Text(tr("gpu.new"))
            } footer: {
                if let reserve = content.reserve { footnote([tr("gpu.rule", reserve), tr("gpu.rule.splash")]) }
            }
            Section {
                actions(content.apply, content.reset)
                if content.confirmation?.placement == .apply { confirmation }
                progressAndOutcome(.apply)
            } header: {
                Text(tr("gpu.applySection"))
            } footer: {
                footnote([tr("gpu.warning.memory"), tr("gpu.warning.reboot"), tr("gpu.warning.splash")], warning: true)
            }
            Section {
                ForEach(content.daemon) { SettingsRowView(row: $0) }
                actions(content.install, content.remove)
                if content.confirmation?.placement == .daemon { confirmation }
                progressAndOutcome(.daemon)
            } header: {
                Text(tr("gpu.daemon"))
            } footer: {
                footnote([tr("gpu.daemon.footer")])
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func actions(_ first: DeckAction?, _ second: DeckAction?) -> some View {
        if first != nil || second != nil {
            HStack(spacing: Space.s) {
                if let first { ActionButton(first) }
                if let second { ActionButton(second) }
                Spacer(minLength: 0)
            }
            .disabled(content.confirmation != nil || content.progress != nil)
        }
    }

    @ViewBuilder
    private func progressAndOutcome(_ placement: GPUMemoryConfirmation.Placement) -> some View {
        if content.confirmation == nil, placement == content.lastPlacement {
            if let progress = content.progress {
                HStack(spacing: Space.xs) {
                    ProgressView().controlSize(.mini)
                    Text(progress).font(Typo.small).foregroundStyle(palette.textSecondary.color)
                }
            } else if let outcome = content.outcome {
                Label(outcome.text, systemImage: outcome.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .font(Typo.small)
                    .foregroundStyle((outcome.isError ? palette.error : palette.textSecondary).color)
                    .textSelection(.enabled)
            }
        }
    }

    private var confirmation: some View {
        GPUMemoryConfirmationPanel(content.confirmation)
    }

    private func footnote(_ lines: [String], warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(lines, id: \.self) { line in
                if warning {
                    Label(line, systemImage: "exclamationmark.triangle")
                } else {
                    Text(line)
                }
            }
        }
        .font(Typo.caption)
        .foregroundStyle(palette.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct GPUMemoryConfirmationPanel: View {
    private let confirmation: GPUMemoryConfirmation?
    @FocusState private var cancelFocused: Bool
    @Environment(\.deckPalette) private var palette

    init(_ confirmation: GPUMemoryConfirmation?) {
        self.confirmation = confirmation
    }

    var body: some View {
        if let confirmation {
            VStack(alignment: .leading, spacing: Space.s) {
                Label(confirmation.question, systemImage: "lock.shield")
                    .font(Typo.headline)
                    .foregroundStyle(palette.text.color)
                Text(tr("gpu.confirm.runs")).font(Typo.callout).foregroundStyle(palette.textSecondary.color)
                code(confirmation.command)
                if let path = confirmation.filePath {
                    Text(tr("gpu.confirm.writes", path)).font(Typo.callout).foregroundStyle(palette.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.s) {
                    Spacer(minLength: 0)
                    Button(confirmation.cancel.title) { confirmation.cancel.perform() }
                        .keyboardShortcut(.cancelAction)
                        .focused($cancelFocused)
                    Button(confirmation.confirm.title) { confirmation.confirm.perform() }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.starting.color)
                }
            }
            .padding(Space.m)
            .background(palette.starting.over(palette.surface, alpha: 0.10).color, in: .rect(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.starting.color.opacity(0.6), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(confirmation.question)
            .onAppear {
                cancelFocused = true
                AccessibilityNotification.Announcement(confirmation.question).post()
            }
        }
    }

    private func code(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Typo.code)
            .foregroundStyle(palette.text.color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s)
            .background(palette.column.color, in: .rect(cornerRadius: Radius.small))
    }
}
