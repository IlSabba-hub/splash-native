import SwiftUI

public struct CapturedRequestsBlock: View {
    private let traffic: CapturedTraffic
    @State private var list: [CapturedRequest] = []
    @State private var open: Set<UInt64> = []
    @Environment(\.deckPalette) private var palette

    public init(_ traffic: CapturedTraffic, opened: Set<UInt64> = []) {
        self.traffic = traffic
        _list = State(initialValue: traffic.read())
        _open = State(initialValue: opened)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(tr("observe.title"), detail: detail)
            DeckCard {
                switch traffic.observation {
                case let .off(reason):
                    UnavailableState(title: tr("observe.title"), reason: reason)
                case .observed:
                    content
                }
            }
        }
        .task(id: traffic.observation) {
            guard case .observed = traffic.observation else { return }
            while !Task.isCancelled {
                list = traffic.read()
                let running = list.contains { $0.state == .running }
                try? await Task.sleep(for: running ? .milliseconds(250) : .seconds(2))
            }
        }
    }

    private var detail: String {
        switch traffic.observation {
        case let .observed(listen, splash): tr("observe.detail", DeckFormat.port(listen), DeckFormat.port(splash))
        case .off: tr("observe.detail.off")
        }
    }

    @ViewBuilder
    private var content: some View {
        if list.isEmpty {
            EmptyState(symbol: "eye", title: tr("observe.empty.title"), message: tr("observe.empty.message"))
        } else {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(tr("observe.memoryOnly")).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                ForEach(list) { request in
                    CapturedRequestRow(request: request, isOpen: open.contains(request.id)) {
                        if open.contains(request.id) { open.remove(request.id) } else { open.insert(request.id) }
                    }
                }
            }
        }
    }
}

struct CapturedRequestRow: View {
    let request: CapturedRequest
    let isOpen: Bool
    let toggle: () -> Void
    @Environment(\.deckPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withDeckAnimation(.settle, reduceMotion: reduceMotion) { toggle() }
            } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: "chevron.right").font(Typo.caption.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0)).accessibilityHidden(true)
                    Text(verbatim: DeckFormat.moment(request.started)).monospacedDigit()
                    Text(verbatim: "\(request.method) \(request.path)").font(Typo.code)
                    stateLabel
                    Spacer(minLength: Space.s)
                    Text(verbatim: figures.joined(separator: " · ")).monospacedDigit().foregroundStyle(palette.textSecondary.color)
                }
                .font(Typo.callout)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(tr(isOpen ? "observe.a11y.close" : "observe.a11y.open"))
            if isOpen {
                CapturedRequestDetail(request: request)
                    .padding(.leading, Space.l)
                    .transition(DeckMotion.comingAndGoing(reduceMotion: reduceMotion))
            }
        }
        .padding(.vertical, Space.xs)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch request.state {
        case .running: Label(tr("observe.state.running"), systemImage: "ellipsis").foregroundStyle(palette.starting.color)
        case .finished: Label(request.finishReason ?? request.status.map(String.init) ?? tr("observe.state.finished"), systemImage: "checkmark")
            .foregroundStyle(palette.ready.color)
        case .failed: Label(tr("observe.state.failed"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(palette.error.color)
        }
    }

    private var figures: [String] {
        var out: [String] = []
        if let prompt = request.promptTokens {
            out.append(tr("observe.tokens", DeckFormat.count(prompt), DeckFormat.count(request.cachedTokens ?? 0),
                          request.completionTokens.map { DeckFormat.count($0) } ?? tr("value.unavailable")))
        }
        if let ttft = request.ttftMs { out.append(tr("chat.summary.ttft", DeckFormat.latency(milliseconds: ttft))) }
        if let speed = request.tokensPerSecond {
            out.append(request.engineTokensPerSecond.map { tr("observe.speedBoth", DeckFormat.tokensPerSecond(speed), DeckFormat.number($0, fractionDigits: 1)) }
                       ?? DeckFormat.tokensPerSecond(speed))
        }
        if let duration = request.durationMs { out.append(DeckFormat.latency(milliseconds: duration)) }
        return out
    }
}

struct CapturedRequestDetail: View {
    let request: CapturedRequest
    @Environment(\.deckPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let error = request.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(Typo.callout).foregroundStyle(palette.error.color)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .topLeading)], alignment: .leading, spacing: Space.s) {
                ForEach(facts) { LabeledValueRow($0, compact: true) }
            }
            if !request.messages.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(tr(request.messages.count == 1 ? "observe.messages.one" : "observe.messages", DeckFormat.count(request.messages.count))).font(Typo.caption.weight(.semibold))
                    ForEach(Array(request.messages.enumerated()), id: \.offset) { _, message in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Text(verbatim: message.role).font(Typo.code).foregroundStyle(palette.accent.color).frame(width: 70, alignment: .leading)
                            Text(verbatim: message.excerpt).font(Typo.caption).lineLimit(3)
                            Spacer(minLength: 0)
                            Text(verbatim: messageNotes(message)).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
                        }
                    }
                }
            }
            if !request.reasoning.isEmpty { textBlock(tr("chat.line.thought"), request.reasoning, secondary: true) }
            if !request.content.isEmpty { textBlock(tr("observe.reply"), request.content, secondary: false) }
            ForEach(request.toolCalls) { call in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label(tr("chat.tool.call", call.name), systemImage: "wrench.and.screwdriver").font(Typo.caption.weight(.semibold))
                    Text(verbatim: call.arguments).font(Typo.code).textSelection(.enabled)
                }
            }
            if let raw = request.raw { textBlock(tr("observe.raw"), raw, secondary: true, code: true) }
            if request.truncated {
                Text(tr("observe.truncated")).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
            }
        }
    }

    private var facts: [Fact] {
        let proxy = Provenance(source: .deck(what: tr("observe.source.proxy")))
        func response(_ field: String) -> Provenance { Provenance(source: .response(field: field)) }
        let missing = tr("observe.notSent")
        var facts = [
            Fact(title: tr("observe.fact.ttft"), value: request.ttftMs.map { .value(DeckFormat.latency(milliseconds: $0)) }
                    ?? .unavailable(reason: tr("observe.ttftNotStreamed")), provenance: proxy),
            Fact(title: tr("observe.fact.speed"), value: request.tokensPerSecond.map { .value(DeckFormat.tokensPerSecond($0)) }
                    ?? .unavailable(reason: tr("observe.speedUnknown")), provenance: proxy),
            Fact(title: tr("observe.fact.engineSpeed"), value: request.engineTokensPerSecond.map { .value(DeckFormat.tokensPerSecond($0)) }
                    ?? .unavailable(reason: missing), provenance: response("timings.predicted_per_second")),
            Fact(title: tr("chat.fact.prompt"), value: request.promptTokens.map { .value(DeckFormat.count($0)) } ?? .unavailable(reason: missing),
                 provenance: response(request.tokensSource == "timings" ? "timings.prompt_n" : "usage.prompt_tokens")),
            Fact(title: tr("chat.fact.cached"), value: request.cachedTokens.map { .value(DeckFormat.count($0)) } ?? .unavailable(reason: missing),
                 provenance: response("usage.prompt_tokens_details.cached_tokens")),
            Fact(title: tr("chat.fact.completion"), value: request.completionTokens.map { .value(DeckFormat.count($0)) } ?? .unavailable(reason: missing),
                 provenance: response(request.tokensSource == "timings" ? "timings.predicted_n" : "usage.completion_tokens")),
            Fact(title: tr("observe.fact.duration"), value: request.durationMs.map { .value(DeckFormat.latency(milliseconds: $0)) }
                    ?? .unavailable(reason: tr("observe.state.running")), provenance: proxy),
            Fact(title: tr("observe.fact.bytes"), value: .value(DeckFormat.disk(Int64(request.requestBytes))), provenance: proxy),
        ]
        if let agent = request.userAgent { facts.append(Fact(title: tr("observe.fact.client"), value: .value(agent))) }
        if let key = request.authorization { facts.append(Fact(title: tr("observe.fact.key"), value: .value(key))) }
        if !request.tools.isEmpty { facts.append(Fact(title: tr("chat.tools"), value: .value(request.tools.joined(separator: ", ")))) }
        for parameter in request.parameters { facts.append(Fact(title: parameter.name, value: .value(parameter.value))) }
        return facts
    }

    private func messageNotes(_ message: CapturedMessage) -> String {
        var notes = [tr(message.characters == 1 ? "observe.characters.one" : "observe.characters", DeckFormat.count(message.characters))]
        if message.media > 0 { notes.append(tr(message.media == 1 ? "observe.media.one" : "observe.media", DeckFormat.count(message.media))) }
        if !message.toolCalls.isEmpty { notes.append(message.toolCalls.joined(separator: ", ")) }
        if let id = message.toolCallID { notes.append(id) }
        return notes.joined(separator: " · ")
    }

    private func textBlock(_ title: String, _ text: String, secondary: Bool, code: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(Typo.caption.weight(.semibold))
            ScrollView {
                Text(verbatim: text)
                    .font(code ? Typo.code : Typo.callout)
                    .foregroundStyle((secondary ? palette.textSecondary : palette.text).color)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(Space.s)
            .background(palette.surfaceRaised.color, in: .rect(cornerRadius: Radius.control))
        }
    }
}
