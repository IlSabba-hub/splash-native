import AppKit
import SwiftUI

struct ParameterRow: View {
    let descriptor: ParameterDescriptor
    @Binding var value: ParameterValue

    var body: some View {
        SettingRow(descriptor.title, changed: value != .unset, reset: { value = .unset }, details: SettingDetails(descriptor),
                   disabledReason: descriptor.disabledReason, problem: ParameterValidation.problem(descriptor.kind, value)) {
            ParameterControl(descriptor: descriptor, value: $value)
        }
    }
}

enum ParameterValidation {
    static func problem(_ kind: ParameterKind, _ value: ParameterValue) -> String? {
        switch (kind, value) {
        case let (.integer(range?, _, _), .integer(number)) where !range.contains(number):
            tr("parameter.outOfRange", NativeFormat.count(Int(range.lowerBound)), NativeFormat.count(Int(range.upperBound)))
        case let (.number(range?), .number(number)) where !range.contains(number):
            tr("parameter.outOfRange", NativeFormat.number(range.lowerBound, fractionDigits: 2), NativeFormat.number(range.upperBound, fractionDigits: 2))
        case (.duration, .seconds(let seconds)) where seconds <= 0,
             (.size, .bytes(let seconds)) where seconds <= 0:
            tr("parameter.mustBePositive")
        case let (.list, .list(items)) where items.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }:
            tr("parameter.emptyItem")
        default:
            nil
        }
    }
}

struct ParameterControl: View {
    let descriptor: ParameterDescriptor
    @Binding var value: ParameterValue

    var body: some View {
        switch descriptor.kind {
        case .toggle:
            Toggle(descriptor.title, isOn: Binding(get: { value == .bool(true) }, set: { value = $0 ? .bool(true) : .unset }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        case let .choice(choices):
            let fallback = descriptor.defaultToken.flatMap { token in choices.first { $0.token == token } }
            Picker(descriptor.title, selection: Binding(get: { fallback.map { value == .choice($0.token) } == true ? .unset : value },
                                                        set: { value = $0 })) {
                Text(ParameterDescriptor.defaultEntry(word: fallback.map { $0.title ?? $0.token }, value: nil))
                    .tag(ParameterValue.unset)
                ForEach(choices.filter { $0 != fallback }) { choice in
                    Text(choice.title ?? choice.token).tag(ParameterValue.choice(choice.token))
                }
            }
            .labelsHidden()
            .fixedSize()
        case let .integer(_, unit, words):
            WordsOrValue(title: descriptor.title, words: words, defaultToken: descriptor.defaultToken, value: $value, isValue: { if case .integer = $0 { true } else { false } }) {
                HStack(spacing: Space.xs) {
                    TextField(descriptor.title, value: Binding<Int64?>(
                        get: { if case let .integer(n) = value { n } else { nil } },
                        set: { value = $0.map(ParameterValue.integer) ?? .unset }), format: .number, prompt: defaultPrompt)
                        .settingField(width: 110)
                    if let unit { Text(unit.title).font(Typo.callout).foregroundStyle(.secondary) }
                }
            }
        case .number:
            TextField(descriptor.title, value: Binding<Double?>(
                get: { if case let .number(n) = value { n } else { nil } },
                set: { value = $0.map(ParameterValue.number) ?? .unset }), format: .number, prompt: defaultPrompt)
                .settingField()
        case let .duration(words):
            WordsOrValue(title: descriptor.title, words: words, defaultToken: descriptor.defaultToken, value: $value, isValue: { if case .seconds = $0 { true } else { false } }) {
                UnitAmountField(title: descriptor.title, units: Array(DurationUnit.allCases), value: Binding(
                    get: { if case let .seconds(s) = value { s } else { nil } },
                    set: { value = $0.map(ParameterValue.seconds) ?? .unset }))
            }
        case let .size(words):
            WordsOrValue(title: descriptor.title, words: words, defaultToken: descriptor.defaultToken, value: $value, isValue: { if case .bytes = $0 { true } else { false } }) {
                UnitAmountField(title: descriptor.title, units: Array(SizeUnit.allCases), value: Binding(
                    get: { if case let .bytes(b) = value { b } else { nil } },
                    set: { value = $0.map(ParameterValue.bytes) ?? .unset }))
            }
        case let .text(placeholder):
            TextField(descriptor.title, text: textBinding(ParameterValue.text), prompt: placeholder.map { Text($0) })
                .settingTextField()
                .frame(minWidth: 160, maxWidth: 260)
        case .secret:
            SecureField(descriptor.title, text: textBinding(ParameterValue.secret))
                .settingTextField()
                .frame(minWidth: 160, maxWidth: 260)
        case let .path(directory):
            PathControl(title: descriptor.title, directory: directory, value: $value)
        case let .list(placeholder):
            ListControl(title: descriptor.title, placeholder: placeholder, value: $value)
        }
    }

    private var defaultPrompt: Text? {
        descriptor.splashDefault.map { Text(verbatim: String($0.prefix { !",; ".contains($0) })) }
    }

    private func textBinding(_ make: @escaping (String) -> ParameterValue) -> Binding<String> {
        Binding(
            get: {
                switch value {
                case let .text(text), let .secret(text): text
                default: ""
                }
            },
            set: { value = $0.isEmpty ? .unset : make($0) })
    }
}

private struct WordsOrValue<Field: View>: View {
    let title: String
    let words: [ParameterWord]
    let defaultToken: String?
    @Binding var value: ParameterValue
    let isValue: (ParameterValue) -> Bool
    @ViewBuilder let field: Field

    private enum Mode: Hashable { case unset, word(String), value }

    @State private var choosingValue = false

    private var defaultWord: ParameterWord? { words.first { $0.token == defaultToken } }

    private var mode: Mode {
        if isValue(value) || (choosingValue && value == .unset) { return .value }
        if case let .word(token) = value, token != defaultWord?.token { return .word(token) }
        return .unset
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Picker(title, selection: Binding<Mode>(get: { mode }, set: { newMode in
                switch newMode {
                case .unset: choosingValue = false; value = .unset
                case let .word(token): choosingValue = false; value = .word(token)
                case .value: choosingValue = true; if !isValue(value) { value = .unset }
                }
            })) {
                Text(ParameterDescriptor.defaultEntry(word: defaultWord?.title, value: defaultToken)).tag(Mode.unset)
                ForEach(words.filter { $0 != defaultWord }) { Text($0.title).tag(Mode.word($0.token)) }
                Text(tr("parameter.mode.manual")).tag(Mode.value)
            }
            .labelsHidden()
            .fixedSize()
            if mode == .value { field }
        }
    }
}

private protocol AmountUnit: Hashable, CaseIterable, Identifiable {
    var multiplier: Int64 { get }
    var title: String { get }
}

private enum DurationUnit: Int64, AmountUnit {
    case seconds = 1, minutes = 60, hours = 3600
    var id: Int64 { rawValue }
    var multiplier: Int64 { rawValue }
    var title: String {
        switch self {
        case .seconds: tr("unit.seconds")
        case .minutes: tr("unit.minutes")
        case .hours: tr("unit.hours")
        }
    }
}

private enum SizeUnit: Int64, AmountUnit {
    case mebibytes = 1_048_576, gibibytes = 1_073_741_824
    var id: Int64 { rawValue }
    var multiplier: Int64 { rawValue }
    var title: String {
        switch self {
        case .mebibytes: UnitInformationStorage.mebibytes.symbol
        case .gibibytes: UnitInformationStorage.gibibytes.symbol
        }
    }
}

private struct UnitAmountField<Unit: AmountUnit>: View {
    let title: String
    let units: [Unit]
    @Binding var value: Int64?
    @State private var unit: Unit?

    private var shownUnit: Unit {
        if let unit { return unit }
        let all = units
        if let value, value != 0, let exact = all.last(where: { value % $0.multiplier == 0 }) { return exact }
        return all[all.count > 1 ? 1 : 0]
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            TextField(title, value: Binding<Double?>(
                get: { value.map { Double($0) / Double(shownUnit.multiplier) } },
                set: { value = $0.map { Int64(($0 * Double(shownUnit.multiplier)).rounded()) } }), format: .number)
                .settingField(width: 80)
            Picker(title, selection: Binding(get: { shownUnit }, set: { unit = $0 })) {
                ForEach(units) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

private struct PathControl: View {
    let title: String
    let directory: Bool
    @Binding var value: ParameterValue
    @Environment(\.nativePalette) private var palette

    var body: some View {
        HStack(spacing: Space.s) {
            if case let .text(path) = value {
                Text(path)
                    .font(Typo.code)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(palette.textSecondary.color)
                    .help(path)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            Button(tr("parameter.choose")) { choose() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.message = title
        if panel.runModal() == .OK, let url = panel.url { value = .text(url.path) }
    }
}

private struct ListControl: View {
    let title: String
    let placeholder: String?
    @Binding var value: ParameterValue

    private var items: [String] {
        if case let .list(items) = value { items } else { [] }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: Space.xs) {
                    TextField(title, text: Binding(get: { items[safe: index] ?? "" }, set: { set(index, $0) }),
                              prompt: placeholder.map { Text($0) })
                        .settingTextField()
                        .frame(minWidth: 160, maxWidth: 240)
                    Button {
                        var list = items
                        list.remove(at: index)
                        value = list.isEmpty ? .unset : .list(list)
                    } label: {
                        Label(tr("parameter.removeItem"), systemImage: "minus.circle").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                value = .list(items + [""])
            } label: {
                Label(tr("parameter.addItem"), systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func set(_ index: Int, _ text: String) {
        var list = items
        guard list.indices.contains(index) else { return }
        list[index] = text
        value = .list(list)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

#Preview("Campi per tipo") {
    @Previewable @State var maxContext = ParameterValue.unset
    @Previewable @State var kvFormat = ParameterValue.unset
    @Previewable @State var idleRelease = ParameterValue.seconds(1800)
    @Previewable @State var maxMemory = ParameterValue.word("auto")
    @Previewable @State var languageOnly = ParameterValue.unset
    @Previewable @State var servedNames = ParameterValue.list(["qwen3.8:27B-uncensored-Q6K"])
    @Previewable @State var apiKey = ParameterValue.unset
    @Previewable @State var thinking = ParameterValue.unset
    @Previewable @State var cacheDir = ParameterValue.unset
    let help = Provenance.Source.help(version: "1.7.3", group: "memory and context")
    ScrollView {
        NativeCard {
            VStack(alignment: .leading, spacing: Space.l) {
                ParameterRow(descriptor: ParameterDescriptor(title: FlagLabels.title(for: "--max-context") ?? "", flag: "--max-context",
                    kind: .integer(range: 1 ... 1_010_000, unit: .tokens, words: [.auto]), splashDefault: "auto",
                    help: "context token limit, e.g. 100K or 1M (K = 1024 tokens, M = 1000000 tokens), up to the model's limit, at most 1010000",
                    provenance: Provenance(flag: "--max-context", source: help)), value: $maxContext)
                ParameterRow(descriptor: ParameterDescriptor(title: FlagLabels.title(for: "--kv-format") ?? "", flag: "--kv-format",
                    kind: .choice([.init(token: "int8"), .init(token: "bf16")]), splashDefault: "int8",
                    provenance: Provenance(flag: "--kv-format", source: help)), value: $kvFormat)
                ParameterRow(descriptor: ParameterDescriptor(title: FlagLabels.title(for: "--idle-release") ?? "", flag: "--idle-release",
                    kind: .duration(words: [.off]), splashDefault: "10m", provenance: Provenance(flag: "--idle-release", source: help)),
                    value: $idleRelease)
                ParameterRow(descriptor: ParameterDescriptor(title: FlagLabels.title(for: "--max-memory") ?? "", flag: "--max-memory",
                    kind: .size(words: [.auto]), splashDefault: "auto", provenance: Provenance(flag: "--max-memory", source: help)),
                    value: $maxMemory)
                ParameterRow(descriptor: ParameterDescriptor(title: FlagLabels.title(for: "--language-only") ?? "", flag: "--language-only",
                    kind: .toggle), value: $languageOnly)
                ParameterRow(descriptor: ParameterDescriptor(title: FlagLabels.title(for: "--served-model-name") ?? "", flag: "--served-model-name",
                    kind: .list(placeholder: nil)), value: $servedNames)
                ParameterRow(descriptor: ParameterDescriptor(title: FlagLabels.title(for: "--api-key") ?? "", flag: "--api-key",
                    kind: .secret, splashDefault: "SPLASH_API_KEY"), value: $apiKey)
                ParameterRow(descriptor: ParameterDescriptor(title: FlagLabels.title(for: "--cache-dir") ?? "", flag: "--cache-dir",
                    kind: .path(directory: true), splashDefault: "~/Library/Caches/Splash/prefix-cache"), value: $cacheDir)
                ParameterRow(descriptor: ParameterDescriptor(title: FlagLabels.title(for: "--thinking-token-budget") ?? "", flag: "--thinking-token-budget",
                    kind: .integer(range: 0 ... Int64.max, unit: .tokens, words: []),
                    disabledReason: tr("reason.inklingThinkingBudget")), value: $thinking)
            }
        }
        .padding(Space.xl)
    }
    .frame(width: 640, height: 760)
    .nativeTheme()
}
