import SwiftUI

public struct DeletionCheckLine: Sendable, Identifiable {
    public let id: String
    public let text: String
    public let tone: ModelTag.Tone
    public let options: [NativeAction]
    public let selected: Int?

    public init(id: String, text: String, tone: ModelTag.Tone, options: [NativeAction] = [], selected: Int? = nil) {
        self.id = id
        self.text = text
        self.tone = tone
        self.options = options
        self.selected = selected
    }
}

public struct DeletionItemLine: Sendable, Identifiable {
    public let id: String
    public let path: String
    public let detail: String
    public let size: String?

    public init(id: String, path: String, detail: String, size: String?) {
        self.id = id
        self.path = path
        self.detail = detail
        self.size = size
    }
}

public struct DeletionSheetContent: Sendable {
    public let title: String
    public let subtitle: String
    public let checking: Bool
    public let checks: [DeletionCheckLine]
    public let items: [DeletionItemLine]
    public let commands: [String]
    public let configurations: [String]
    public let summary: String
    public let confirm: NativeAction?
    public let blockedReason: String?
    public let running: Bool
    public let outcome: [String]
    public let failure: String?

    public init(title: String, subtitle: String, checking: Bool = false, checks: [DeletionCheckLine] = [], items: [DeletionItemLine] = [],
                commands: [String] = [], configurations: [String] = [], summary: String = "", confirm: NativeAction? = nil,
                blockedReason: String? = nil, running: Bool = false, outcome: [String] = [], failure: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.checking = checking
        self.checks = checks
        self.items = items
        self.commands = commands
        self.configurations = configurations
        self.summary = summary
        self.confirm = confirm
        self.blockedReason = blockedReason
        self.running = running
        self.outcome = outcome
        self.failure = failure
    }
}

public struct DeletionSheet: View {
    private let content: DeletionSheetContent
    private let close: () -> Void
    @State private var showsCommands = false
    @Environment(\.nativePalette) private var palette

    public init(_ content: DeletionSheetContent, close: @escaping () -> Void) {
        self.content = content
        self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(content.title).font(Typo.headline).accessibilityAddTraits(.isHeader)
                Text(content.subtitle).font(Typo.small).foregroundStyle(palette.textSecondary.color).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.l)
            Divider().overlay(palette.separator.color)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if content.checking {
                        HStack(spacing: Space.s) {
                            ProgressView().controlSize(.small)
                            Text(tr("delete.checking")).font(Typo.small).foregroundStyle(palette.textSecondary.color)
                        }
                    }
                    if let failure = content.failure {
                        Label(failure, systemImage: "xmark.octagon.fill").font(Typo.small).foregroundStyle(palette.error.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !content.outcome.isEmpty {
                        section(tr("delete.done")) {
                            ForEach(content.outcome, id: \.self) { line in
                                Text(verbatim: line).font(Typo.code).foregroundStyle(palette.textSecondary.color).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if !content.checks.isEmpty {
                        section(tr("delete.checks")) { ForEach(content.checks) { CheckRow(line: $0) } }
                    }
                    section(tr("delete.items")) {
                        if content.items.isEmpty {
                            Text(tr("delete.items.none")).font(Typo.small).foregroundStyle(palette.textTertiary.color)
                        }
                        ForEach(content.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                VStack(alignment: .leading, spacing: Space.xxs) {
                                    Text(verbatim: item.path).font(Typo.code).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    Text(item.detail).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                                }
                                Spacer(minLength: Space.s)
                                if let size = item.size {
                                    Text(size).font(Typo.small.monospacedDigit()).foregroundStyle(palette.textSecondary.color).fixedSize()
                                }
                            }
                        }
                    }
                    if !content.commands.isEmpty {
                        DisclosureGroup(isExpanded: $showsCommands) {
                            VStack(alignment: .leading, spacing: Space.s) {
                                ForEach(content.commands, id: \.self) { line in
                                    Text(verbatim: line).font(Typo.code).foregroundStyle(palette.textSecondary.color).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.top, Space.xs)
                        } label: {
                            SectionHeader(tr("delete.commands"), detail: NativeFormat.count(content.commands.count))
                        }
                    }
                    if !content.configurations.isEmpty {
                        section(tr("delete.configurations")) {
                            ForEach(content.configurations, id: \.self) { Text(verbatim: $0).font(Typo.body) }
                        }
                    }
                }
                .padding(Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 460)
            Divider().overlay(palette.separator.color)
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    if !content.summary.isEmpty { Text(content.summary).font(Typo.small.weight(.semibold)) }
                    if let reason = content.blockedReason {
                        Text(reason).font(Typo.caption).foregroundStyle(palette.textSecondary.color).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Space.m)
                if content.running { ProgressView().controlSize(.small) }
                Button(tr(content.outcome.isEmpty ? "confirm.cancel" : "delete.close"), action: close).keyboardShortcut(.cancelAction)
                if let confirm = content.confirm {
                    Button(role: .destructive) { confirm.perform() } label: {
                        Label(confirm.title, systemImage: confirm.systemImage ?? "touchid")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.error.color)
                    .disabled(!confirm.isEnabled || content.running)
                    .help(confirm.disabledReason ?? confirm.title)
                }
            }
            .padding(Space.l)
        }
        .frame(width: 640)
        .background(palette.column.color)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title)
            content()
        }
    }

    struct CheckRow: View {
        let line: DeletionCheckLine
        @Environment(\.nativePalette) private var palette

        private var symbol: String {
            switch line.tone {
            case .error: "xmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .ready: "checkmark.circle.fill"
            default: "info.circle"
            }
        }

        private var color: Color {
            switch line.tone {
            case .error: palette.error.color
            case .warning: palette.starting.color
            case .ready: palette.ready.color
            default: palette.textTertiary.color
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
                    Text(line.text).font(Typo.small).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if !line.options.isEmpty {
                    HStack(spacing: Space.s) {
                        ForEach(line.options.indices, id: \.self) { index in
                            let option = line.options[index]
                            if index == line.selected {
                                Button { option.perform() } label: { Text(option.title) }.buttonStyle(.borderedProminent)
                            } else {
                                Button { option.perform() } label: { Text(option.title) }.buttonStyle(.bordered)
                            }
                        }
                    }
                    .controlSize(.small)
                    .padding(.leading, Space.l + Space.xs)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}
