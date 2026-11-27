import AppKit
import SwiftUI

public struct ChatPage: View {
    private let state: ChatPageState
    private let actions: ChatPageActions
    @Environment(\.nativePalette) private var palette

    public init(_ state: ChatPageState, actions: ChatPageActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let title = state.title {
                HStack {
                    Text(verbatim: title).font(Typo.callout.weight(.medium)).foregroundStyle(palette.textSecondary.color)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.l)
                .frame(height: 32)
                .overlay(alignment: .bottom) { Rectangle().fill(palette.separator.color).frame(height: 1) }
            }
            if state.messages.isEmpty {
                ChatStart(model: state.model, blocked: state.sendBlocked, loadModel: actions.loadModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ChatTranscript(state: state, actions: actions)
            }
            if let metrics = state.metrics {
                MetricsStrip(metrics, title: tr("metrics.last"))
                    .frame(maxWidth: NativeLayout.readingWidth, alignment: .leading)
                    .padding(.horizontal, Space.xl + Space.m)
                    .padding(.top, Space.s)
                    .frame(maxWidth: .infinity)
            }
            ChatComposer(state: state, actions: actions)
        }
        .background(palette.background.color)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

struct ChatStart: View {
    let model: ChatModelState
    let blocked: String?
    let loadModel: @MainActor @Sendable () -> Void
    @Environment(\.nativePalette) private var palette

    var body: some View {
        VStack(spacing: Space.m) {
            switch model {
            case .none:
                Image(systemName: "cube.transparent").font(Typo.figure).foregroundStyle(palette.textTertiary.color).accessibilityHidden(true)
                Text(tr("chat.noModel.title")).font(Typo.headline)
                Button {
                    loadModel()
                } label: {
                    Label(tr("picker.title"), systemImage: "cube")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            case let .reading(name):
                Text(verbatim: name).font(Typo.code).foregroundStyle(palette.textSecondary.color)
                if let blocked { Text(blocked).font(Typo.callout).foregroundStyle(palette.textTertiary.color).multilineTextAlignment(.center) }
            case let .ready(_, served):
                Image(systemName: "bubble.left.and.text.bubble.right").font(Typo.figure).foregroundStyle(palette.textTertiary.color)
                    .accessibilityHidden(true)
                AssistantHeader(served)
                Text(tr("chat.start.message")).font(Typo.callout).foregroundStyle(palette.textTertiary.color)
            }
        }
        .padding(Space.xl)
    }
}

struct ChatTranscript: View {
    let state: ChatPageState
    let actions: ChatPageActions
    @State private var atBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xl) {
                    ForEach(state.messages) { message in
                        ChatMessageView(message: message, canAnswer: !state.answering && state.sendBlocked == nil
                                            && message.id == state.messages.last?.id,
                                        answerTool: actions.answerTool,
                                        inStrip: state.metrics != nil && message.id == state.messages.last { $0.role == .assistant }?.id)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.xl)
                .frame(maxWidth: NativeLayout.readingWidth + 2 * Space.xl)
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
            } action: { _, now in atBottom = now }
            .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: state.messages.last?.id) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: state.messages.last) { if atBottom { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
        }
    }

    private static let bottom = "chat.bottom"
}

struct ChatMessageView: View {
    let message: ChatBubble
    let canAnswer: Bool
    let answerTool: @MainActor @Sendable (String, String) -> Void
    var inStrip = false
    @State private var hovered = false
    @State private var confirmingDelete = false
    @State private var showsReasoning = false
    @State private var showsFacts = false
    @State private var showsResult = false
    @Environment(\.nativePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: Space.s) {
            switch message.role {
            case .user:
                UserBubble(message.text)
                actionBar(trailing: true)
            case .tool:
                toolResult
                actionBar(trailing: false)
            case .assistant:
                assistant
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .contentShape(.rect)
        .onHover { hovered = $0 }
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let model = message.model { AssistantHeader(model) }
            if let line = message.line {
                ThoughtDisclosure(expanded: $showsReasoning, canToggle: !message.reasoning.isEmpty) {
                    lineLabel(line)
                } content: {
                    Text(verbatim: message.reasoning).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !message.text.isEmpty { MarkdownText(text: message.text) }
            ForEach(message.toolCalls) { call in
                ChatToolCallView(call: call, canAnswer: canAnswer && !call.answered, answer: answerTool)
            }
            if let error = message.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Typo.callout)
                    .foregroundStyle(palette.error.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !message.live { footer }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func lineLabel(_ line: ChatReplyLine) -> some View {
        switch line {
        case let .reading(read, since):
            Text(read.map { tr("chat.line.readingPercent", NativeFormat.percent($0)) } ?? tr("chat.line.reading"))
            ElapsedText(since: since)
        case let .thinking(since):
            Text(tr("chat.line.thinking"))
            ElapsedText(since: since)
        case let .thought(tokens, seconds):
            Text(seconds.map { tr("chat.line.thoughtFor", NativeFormat.latency(milliseconds: $0 * 1000)) } ?? tr("chat.line.thought"))
            if let tokens {
                Text(verbatim: "· " + tr(tokens == 1 ? "chat.tokens.one" : "chat.tokens", NativeFormat.count(tokens))).foregroundStyle(palette.textTertiary.color)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: Space.s) {
            if message.stopped { Text(tr("chat.stopped")).foregroundStyle(palette.starting.color) }
            if !message.summary.isEmpty {
                Button {
                    withNativeAnimation(.settle, reduceMotion: reduceMotion) { showsFacts.toggle() }
                } label: {
                    if inStrip {
                        Text(tr("chat.numbers.details"))
                    } else {
                        Text(verbatim: message.summary.joined(separator: " · ")).monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .help(tr("chat.numbers.help"))
                .accessibilityHint(tr(showsFacts ? "a11y.hideSource" : "a11y.showSource"))
            }
            Spacer(minLength: 0)
            actions
        }
        .font(Typo.caption)
        .foregroundStyle(palette.textTertiary.color)
        .frame(minHeight: 20)
        if confirmingDelete { deleteConfirmation }
        if showsFacts {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .topLeading)], alignment: .leading, spacing: Space.s) {
                ForEach(message.facts) { LabeledValueRow($0, compact: true) }
            }
            .padding(Space.m)
            .background(palette.surface.color, in: .rect(cornerRadius: Radius.card))
            .transition(NativeMotion.comingAndGoing(reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder
    private func actionBar(trailing: Bool) -> some View {
        HStack(spacing: Space.s) {
            if trailing { Spacer(minLength: 0) }
            actions
            if !trailing { Spacer(minLength: 0) }
        }
        .font(Typo.caption)
        .frame(minHeight: 20)
        if confirmingDelete { deleteConfirmation }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Space.xs) {
            if !message.text.isEmpty {
                icon(tr("chat.copy"), "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
            }
            ForEach(message.actions, id: \.title) { action in
                icon(action.title, action.systemImage ?? "arrow.clockwise", enabled: action.isEnabled, reason: action.disabledReason) {
                    action.perform()
                }
            }
            if let delete = message.delete {
                icon(delete.title, delete.systemImage ?? "trash", enabled: delete.isEnabled, reason: delete.disabledReason) {
                    confirmingDelete = true
                }
            }
        }
        .opacity(hovered || confirmingDelete ? 1 : 0)
        .accessibilityHidden(!(hovered || confirmingDelete))
    }

    private func icon(_ title: String, _ symbol: String, enabled: Bool = true, reason: String? = nil,
                      perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(Typo.caption).foregroundStyle(palette.textSecondary.color)
                .frame(width: 22, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(reason ?? title)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var deleteConfirmation: some View {
        if let delete = message.delete, case let .destructive(question, consequence, confirmTitle) = delete.role {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(question).font(Typo.callout)
                if let consequence { Text(consequence).font(Typo.caption).foregroundStyle(palette.textTertiary.color) }
                HStack(spacing: Space.xs) {
                    Button(tr("chat.cancel")) { confirmingDelete = false }
                        .keyboardShortcut(.cancelAction)
                    Button(confirmTitle, role: .destructive) {
                        confirmingDelete = false
                        delete.perform()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.error.color)
                }
                .controlSize(.small)
            }
            .padding(Space.s)
            .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
            .accessibilityElement(children: .contain)
        }
    }

    private var toolResult: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withNativeAnimation(.settle, reduceMotion: reduceMotion) { showsResult.toggle() }
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "chevron.right").font(Typo.caption.weight(.semibold))
                        .rotationEffect(.degrees(showsResult ? 90 : 0)).accessibilityHidden(true)
                    Image(systemName: "arrow.uturn.left").accessibilityHidden(true)
                    Text(tr("chat.tool.result", message.toolName ?? ""))
                    Text(Self.lines(message.text.split(separator: "\n", omittingEmptySubsequences: false).count))
                        .foregroundStyle(palette.textTertiary.color)
                }
                .font(Typo.callout)
                .foregroundStyle(palette.textSecondary.color)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(tr(showsResult ? "a11y.collapse" : "a11y.expand"))
            if showsResult {
                CodeBlock(language: nil, code: message.text)
                    .transition(NativeMotion.comingAndGoing(reduceMotion: reduceMotion))
            }
        }
    }
}

struct ElapsedText: View {
    let since: Date
    @Environment(\.nativePalette) private var palette

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(verbatim: NativeFormat.duration(seconds: context.date.timeIntervalSince(since)))
                .monospacedDigit()
                .foregroundStyle(palette.textTertiary.color)
        }
    }
}

struct ChatToolCallView: View {
    let call: ChatToolCallItem
    let canAnswer: Bool
    let answer: @MainActor @Sendable (String, String) -> Void
    @State private var expanded = false
    @State private var result: String?
    @Environment(\.nativePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withNativeAnimation(.settle, reduceMotion: reduceMotion) { expanded.toggle() }
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "chevron.right").font(Typo.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
                    Image(systemName: "hammer").accessibilityHidden(true)
                    Text(verbatim: call.name).font(Typo.code.weight(.semibold)).foregroundStyle(palette.text.color)
                    Text(verbatim: Self.brief(call.arguments)).font(Typo.code).foregroundStyle(palette.textTertiary.color)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: Space.s)
                    if call.answered {
                        Label(tr("chat.tool.answered"), systemImage: "checkmark").font(Typo.caption).foregroundStyle(palette.ready.color)
                    }
                }
                .font(Typo.callout)
                .foregroundStyle(palette.textSecondary.color)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("chat.tool.call", call.name))
            .accessibilityHint(tr(expanded ? "a11y.collapse" : "a11y.expand"))
            if expanded {
                VStack(alignment: .leading, spacing: Space.xs) {
                    CodeBlock(language: "json", code: call.arguments)
                    if let id = call.callID {
                        Text(verbatim: id).font(Typo.code).foregroundStyle(palette.textTertiary.color).textSelection(.enabled)
                    }
                }
                .transition(NativeMotion.comingAndGoing(reduceMotion: reduceMotion))
            }
            if canAnswer { answerField }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(palette.surface.color, in: .rect(cornerRadius: Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(palette.separator.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var answerField: some View {
        if let text = result {
            TextEditor(text: Binding(get: { text }, set: { result = $0 }))
                .font(Typo.code)
                .frame(minHeight: 60, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(Space.xs)
                .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.control))
                .accessibilityLabel(tr("chat.tool.resultField", call.name))
            HStack {
                Button(tr("chat.cancel")) { result = nil }
                Button(tr("chat.tool.send")) {
                    answer(call.id, text)
                    result = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.isEmpty)
            }
            .controlSize(.small)
        } else {
            Button(tr("chat.tool.answer")) { result = "" }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(tr("chat.tool.answer.help"))
        }
    }

    static func brief(_ arguments: String) -> String {
        var text = arguments.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("{"), text.hasSuffix("}") { text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
        return text
    }
}

struct ChatComposer: View {
    let state: ChatPageState
    let actions: ChatPageActions
    @State private var text = ""
    @Environment(\.nativePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            TextField(tr("chat.composer.placeholder"), text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .lineLimit(2 ... 12)
                .disabled(state.sendBlocked != nil && !state.answering)
                .onSubmit(send)
            HStack(spacing: Space.s) {
                toolsMenu
                presetMenu
                if let reason = state.sendBlocked, !state.answering {
                    if case .none = state.model, state.messages.isEmpty {
                        EmptyView()
                    } else if case .none = state.model {
                        Button(tr("picker.title")) { actions.loadModel() }
                            .buttonStyle(.link)
                            .font(Typo.caption)
                    } else {
                        Label(reason, systemImage: "nosign").font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                            .lineLimit(1).truncationMode(.tail)
                            .help(reason)
                    }
                }
                Spacer(minLength: Space.s)
                ContextRing(state.context)
                Rectangle().fill(palette.separator.color).frame(width: 1, height: 16)
                sendButton
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.top, Space.m)
        .padding(.bottom, Space.s)
        .background(palette.surface.color, in: .rect(cornerRadius: Radius.bubble))
        .overlay(RoundedRectangle(cornerRadius: Radius.bubble).strokeBorder(palette.separator.color, lineWidth: 1))
        .frame(maxWidth: NativeLayout.readingWidth)
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.l)
        .padding(.top, Space.s)
        .frame(maxWidth: .infinity)
    }

    private var toolsMenu: some View {
        Menu {
            if state.tools.isEmpty {
                Text(tr("chat.tools.none"))
            } else {
                Section(tr("chat.tools.declared")) {
                    ForEach(state.tools, id: \.self) { Text(verbatim: $0) }
                }
            }
            Divider()
            Button(tr("chat.tools.edit")) { actions.showSettings() }
        } label: {
            HStack(spacing: Space.xxs) {
                Image(systemName: "hammer")
                if !state.tools.isEmpty { Text(NativeFormat.count(state.tools.count)).font(Typo.caption.monospacedDigit()) }
            }
            .foregroundStyle((state.tools.isEmpty ? palette.textTertiary : palette.textSecondary).color)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("chat.tools"))
        .accessibilityLabel(tr("chat.tools"))
    }

    private var presetMenu: some View {
        Menu {
            Button(tr("chat.preset.none")) { actions.choosePreset(nil) }
            ForEach(state.presets, id: \.self) { name in
                Button {
                    actions.choosePreset(name)
                } label: {
                    if state.preset == name { Label(name, systemImage: "checkmark") } else { Text(verbatim: name) }
                }
            }
        } label: {
            HStack(spacing: Space.xxs) {
                Image(systemName: "slider.horizontal.3")
                if let preset = state.preset { Text(verbatim: preset).font(Typo.caption) }
            }
            .foregroundStyle(palette.textSecondary.color)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("chat.preset"))
        .accessibilityLabel(tr("chat.preset"))
    }

    @ViewBuilder
    private var sendButton: some View {
        if state.answering {
            Button(action: actions.stop) {
                Image(systemName: "stop.fill").font(Typo.caption).foregroundStyle(palette.onAccent.color)
                    .frame(width: 26, height: 26)
                    .background(palette.accentFill.color, in: .circle)
            }
            .buttonStyle(.plain)
            .help(tr("chat.stop"))
            .accessibilityLabel(tr("chat.stop"))
        } else {
            let enabled = state.sendBlocked == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: send) {
                Image(systemName: "arrow.up").font(Typo.callout.weight(.semibold))
                    .foregroundStyle((enabled ? palette.onAccent : palette.textTertiary).color)
                    .frame(width: 26, height: 26)
                    .background((enabled ? palette.accentFill : palette.surfaceRaised).color, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help(state.sendBlocked ?? tr("chat.send"))
            .accessibilityLabel(tr("chat.send"))
        }
    }

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, state.sendBlocked == nil, !state.answering else { return }
        actions.send(message)
        text = ""
    }
}

extension ChatMessageView {
    static func lines(_ count: Int) -> String {
        tr(count == 1 ? "chat.tool.lines.one" : "chat.tool.lines", NativeFormat.count(count))
    }
}
