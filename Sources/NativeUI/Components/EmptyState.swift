import SwiftUI

public struct EmptyState: View {
    private let symbol: String
    private let title: String
    private let message: String?
    private let action: NativeAction?
    @Environment(\.nativePalette) private var palette

    public init(symbol: String, title: String, message: String? = nil, action: NativeAction? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(palette.textTertiary.color)
                .accessibilityHidden(true)
            Text(title)
                .font(Typo.headline)
                .foregroundStyle(palette.text.color)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Typo.callout)
                    .foregroundStyle(palette.textSecondary.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                ActionButton(action).padding(.top, Space.xs)
            }
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

public struct UnavailableState: View {
    private let title: String
    private let reason: String
    @Environment(\.nativePalette) private var palette

    public init(title: String, reason: String) {
        self.title = title
        self.reason = reason
    }

    public var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "questionmark.circle")
                .font(.title)
                .foregroundStyle(palette.textTertiary.color)
                .accessibilityHidden(true)
            Text(tr("state.unavailableTitle", title))
                .font(Typo.headline)
                .foregroundStyle(palette.text.color)
                .multilineTextAlignment(.center)
            Text(reason)
                .font(Typo.callout)
                .foregroundStyle(palette.textSecondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

public struct ActionButton: View {
    private let action: NativeAction

    public init(_ action: NativeAction) {
        self.action = action
    }

    public var body: some View {
        switch action.role {
        case .destructive:
            ConfirmButton(action)
        case .primary:
            button.buttonStyle(.borderedProminent)
        case .normal:
            button.buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button {
            action.perform()
        } label: {
            if let symbol = action.systemImage { Label(action.title, systemImage: symbol) } else { Text(action.title) }
        }
        .disabled(!action.isEnabled)
        .help(action.disabledReason ?? "")
    }
}

#Preview("Stato vuoto e n/d") {
    VStack(spacing: Space.l) {
        NativeCard { EmptyState(symbol: "server.rack", title: tr("servers.empty.title")) }
        NativeCard { UnavailableState(title: tr("section.servers"), reason: tr("reason.reading")) }
    }
    .padding(Space.xl)
    .frame(width: 520)
    .nativeTheme()
}
