import SwiftUI

public struct ConfirmButton: View {
    private let action: NativeAction
    private let question: String
    private let consequence: String?
    private let confirmTitle: String
    @State private var asking = false
    @State private var remembers = false
    @FocusState private var cancelFocused: Bool
    @Environment(\.nativePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ action: NativeAction) {
        self.init(action, asking: false)
    }

    init(_ action: NativeAction, asking: Bool) {
        self.action = action
        _asking = State(initialValue: asking)
        if case let .destructive(question, consequence, confirmTitle) = action.role {
            self.question = question
            self.consequence = consequence
            self.confirmTitle = confirmTitle
        } else {
            question = tr("confirm.genericQuestion", action.title)
            consequence = nil
            confirmTitle = action.title
        }
    }

    public var body: some View {
        Group {
            if asking {
                panel.transition(NativeMotion.comingAndGoing(reduceMotion: reduceMotion))
            } else {
                Button(role: .destructive) {
                    withNativeAnimation(.settle, reduceMotion: reduceMotion) { asking = true }
                } label: {
                    if let symbol = action.systemImage { Label(action.title, systemImage: symbol) } else { Text(action.title) }
                }
                .disabled(!action.isEnabled)
                .help(action.disabledReason ?? "")
            }
        }
        .onChange(of: asking) { _, now in
            if now {
                cancelFocused = true
                AccessibilityNotification.Announcement(question).post()
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label(question, systemImage: "exclamationmark.triangle.fill")
                .font(Typo.headline)
                .foregroundStyle(palette.text.color)
            if let consequence {
                Text(consequence)
                    .font(Typo.callout)
                    .foregroundStyle(palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s) {
                if let remember = action.remember {
                    Toggle(remember.title, isOn: $remembers).toggleStyle(.checkbox).font(Typo.small)
                }
                Spacer(minLength: 0)
                Button(tr("confirm.cancel")) {
                    withNativeAnimation(.settle, reduceMotion: reduceMotion) { asking = false }
                }
                .keyboardShortcut(.cancelAction)
                .focused($cancelFocused)
                Button(role: .destructive) {
                    asking = false
                    if remembers { action.remember?.perform() }
                    action.perform()
                } label: {
                    Text(confirmTitle)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.error.color)
            }
        }
        .padding(Space.m)
        .background(palette.error.over(palette.surface, alpha: 0.10).color, in: .rect(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.error.color.opacity(0.6), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question)
    }
}

#Preview("Conferma in linea") {
    @Previewable @State var confirmed = 0
    NativeCard {
        VStack(alignment: .leading, spacing: Space.s) {
            ConfirmButton(NativeAction(title: tr("action.stop"), systemImage: "stop.fill",
                                     role: .destructive(question: tr("confirm.stopOutsideQuestion", "qwen-unc-hermes"),
                                                        consequence: tr("confirm.stopOutsideConsequence"),
                                                        confirmTitle: tr("action.stop"))) { confirmed += 1 })
            Label(NativeFormat.count(confirmed), systemImage: "checkmark.circle").font(Typo.code)
        }
    }
    .padding(Space.xl)
    .frame(width: 460)
    .nativeTheme()
}
