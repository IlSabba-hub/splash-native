import SwiftUI

public struct SliderScale: Sendable, Equatable {
    public let stops: [Double]
    public let step: Double?

    public init(stops: [Double]) {
        self.stops = Array(Set(stops)).sorted()
        step = nil
    }

    private init(range: ClosedRange<Double>, step: Double) {
        stops = [range.lowerBound, range.upperBound]
        self.step = step
    }

    public static func continuous(_ range: ClosedRange<Double>, step: Double) -> SliderScale {
        SliderScale(range: range, step: step)
    }

    public static func linear(_ range: ClosedRange<Double>, step: Double) -> SliderScale {
        guard step > 0 else { return SliderScale(stops: [range.lowerBound, range.upperBound]) }
        var stops: [Double] = []
        var value = range.lowerBound
        while value < range.upperBound {
            stops.append(value)
            value += step
        }
        return SliderScale(stops: stops + [range.upperBound])
    }

    public static func powersOfTwo(from lowest: Double, through highest: Double, including extra: [Double] = []) -> SliderScale {
        var stops: [Double] = []
        var value = pow(2, (log2(max(lowest, 1))).rounded(.up))
        while value < highest {
            stops.append(value)
            value *= 2
        }
        let inside = extra.filter { $0 >= lowest && $0 <= highest }
        return SliderScale(stops: stops + inside + [highest])
    }

    public var lowest: Double { stops.first ?? 0 }
    public var highest: Double { stops.last ?? 0 }

    public func index(nearest value: Double) -> Int {
        guard !stops.isEmpty else { return 0 }
        return stops.indices.min { abs(stops[$0] - value) < abs(stops[$1] - value) } ?? 0
    }

    public func fraction(of value: Double) -> Double {
        guard stops.count > 1, highest > lowest else { return 0 }
        if step != nil { return min(max((value - lowest) / (highest - lowest), 0), 1) }
        guard value > lowest else { return 0 }
        guard value < highest else { return 1 }
        let upper = stops.firstIndex { $0 >= value } ?? stops.count - 1
        let below = stops[upper - 1], above = stops[upper]
        let inside = above > below ? (value - below) / (above - below) : 0
        return (Double(upper - 1) + inside) / Double(stops.count - 1)
    }

    public func value(at index: Int) -> Double {
        stops[min(max(index, 0), stops.count - 1)]
    }

    static func snapped(_ x: Double, step: Double, digits: Int, range: ClosedRange<Double>) -> Double {
        let stepped = step > 0 ? (x / step).rounded() * step : x
        let scale = pow(10, Double(digits))
        return min(max((stepped * scale).rounded() / scale, range.lowerBound), range.upperBound)
    }

    static func digits(of step: Double) -> Int {
        step > 0 && step < 1 ? Int((-log10(step)).rounded(.up)) : 0
    }
}

public struct SliderRow: View {
    private let title: String
    @Binding private var value: Double?
    private let scale: SliderScale
    private let format: (Double) -> String
    private let parse: ((String) -> Double?)?
    private let automatic: String?
    private let placeholder: String
    private let resting: Double
    private let notes: [String]
    private let details: SettingDetails?
    private let help: String?
    private let problem: String?
    private let disabledReason: String?
    private let changed: Bool?
    private let onReset: (() -> Void)?
    private let mark: SliderMark?
    @State private var text = ""
    @State private var invalid = false
    @State private var shown = ""
    @FocusState private var editing: Bool
    @Environment(\.deckPalette) private var palette

    public init(_ title: String, value: Binding<Double?>, scale: SliderScale, format: @escaping (Double) -> String,
                parse: ((String) -> Double?)? = nil, automatic: String? = nil, splashDefault: String?, placeholder: String? = nil,
                resting: Double? = nil, notes: [String] = [], provenance: Provenance?, help: String? = nil, problem: String? = nil,
                disabledReason: String? = nil, mark: SliderMark? = nil, effect: String? = nil, fullHelp: String? = nil) {
        self.init(title, value: value, scale: scale, format: format, parse: parse, automatic: automatic,
                  placeholder: placeholder ?? automatic ?? splashDefault ?? "", resting: resting, notes: notes,
                  details: SettingDetails(provenance: provenance, splashDefault: splashDefault, help: fullHelp ?? help, effect: effect), help: help,
                  problem: problem, disabledReason: disabledReason, mark: mark)
    }

    public init(_ title: String, value: Binding<Double?>, scale: SliderScale, format: @escaping (Double) -> String,
                parse: ((String) -> Double?)?, automatic: String?, placeholder: String, resting: Double?, changed: Bool? = nil,
                reset: (() -> Void)? = nil, notes: [String] = [], details: SettingDetails?, help: String? = nil, problem: String? = nil,
                disabledReason: String? = nil, mark: SliderMark? = nil) {
        self.mark = mark
        self.title = title
        _value = value
        self.scale = scale
        self.format = format
        self.parse = parse
        self.automatic = automatic
        self.placeholder = placeholder
        self.resting = min(max(resting ?? scale.highest, scale.lowest), scale.highest)
        self.notes = notes
        self.details = details
        self.help = help
        self.problem = problem
        self.disabledReason = disabledReason
        self.changed = changed
        onReset = reset
    }

    public init(_ title: String, value: Binding<Double?>, range: ClosedRange<Double>, step: Double, digits: Int? = nil,
                defaultValue: Double?, placeholder: String, help: String, provenance: Provenance?, problem: String? = nil,
                disabledReason: String? = nil) {
        let digits = digits ?? SliderScale.digits(of: step)
        self.init(title, value: value, scale: .continuous(range, step: step),
                  format: { DeckFormat.number($0, fractionDigits: digits) }, parse: Self.decimal, automatic: nil,
                  placeholder: placeholder, resting: defaultValue ?? range.lowerBound,
                  details: SettingDetails(provenance: provenance, splashDefault: placeholder.isEmpty ? nil : placeholder, help: help), help: help, problem: problem,
                  disabledReason: disabledReason)
    }

    public var body: some View {
        SettingRow(title, changed: changed ?? (value != nil), reset: onReset ?? { value = nil }, resetHelp: tr("setting.reset", placeholder),
                   details: details,
                   help: help, disabledReason: disabledReason, problem: problem, notes: notes) {
            HStack(spacing: Space.s) {
                if automatic != nil {
                    Toggle(isOn: Binding(get: { value == nil }, set: { value = $0 ? nil : resting })) {
                        Text(tr("slider.auto")).font(Typo.small).foregroundStyle(palette.textSecondary.color)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(automatic.map { tr("slider.autoHelp", $0) } ?? "")
                }
                field
            }
        } below: {
            track
                .overlay(alignment: .bottomLeading) { markView }
                .labelsHidden()
                .controlSize(.small)
                .disabled(value == nil && automatic != nil)
                .opacity(value == nil && automatic != nil ? 0.45 : 1)
                .tint((value == nil ? palette.stroke : palette.accentFill).color)
                .accessibilityValue(value.map(format) ?? placeholder)
        }
        .onAppear { show(value) }
        .onChange(of: value) { _, now in
            invalid = false
            show(now)
        }
        .onChange(of: editing) { _, now in if !now { commit() } }
    }

    @ViewBuilder
    private var track: some View {
        if let step = scale.step {
            let range = scale.lowest ... scale.highest
            Slider(value: Binding(get: { min(max(value ?? resting, range.lowerBound), range.upperBound) },
                                  set: { value = SliderScale.snapped($0, step: step, digits: SliderScale.digits(of: step), range: range) }),
                   in: range) {
                Text(title)
            } minimumValueLabel: {
                Text(format(scale.lowest)).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
            } maximumValueLabel: {
                Text(format(scale.highest)).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
            }
        } else {
            Slider(value: Binding(get: { Double(scale.index(nearest: value ?? resting)) },
                                  set: { value = scale.value(at: Int($0.rounded())) }),
                   in: 0 ... Double(max(scale.stops.count - 1, 1)), step: 1) {
                Text(title)
            } minimumValueLabel: {
                Text(format(scale.lowest)).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
            } maximumValueLabel: {
                Text(format(scale.highest)).font(Typo.caption).foregroundStyle(palette.textTertiary.color)
            }
        }
    }

    @ViewBuilder
    private var markView: some View {
        if let mark {
            GeometryReader { geometry in
                let x = geometry.size.width * scale.fraction(of: mark.value)
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.ready.color.opacity(0.6)).frame(width: max(0, x), height: 2)
                    Capsule().fill((mark.beyond == .streams ? palette.starting : palette.error).color.opacity(0.6))
                        .frame(width: max(0, geometry.size.width - x), height: 2).offset(x: x)
                    Rectangle().fill(palette.text.color).frame(width: 1.5, height: 7).offset(x: x - 0.75, y: -2.5)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 7)
            .offset(y: 6)
            .help(mark.title)
            .accessibilityLabel(mark.title)
        }
    }

    private var field: some View {
        TextField(text: $text, prompt: Text(value == nil ? placeholder : "")) {
            Text(title)
        }
        .focused($editing)
        .onSubmit(commit)
        .disabled(parse == nil)
        .settingField(invalid: invalid)
        .help(invalid ? tr("slider.invalid", format(scale.lowest), format(scale.highest)) : tr("slider.fieldHelp"))
        .accessibilityLabel(title)
    }

    private func show(_ value: Double?) {
        text = value.map(format) ?? ""
        shown = text
    }

    private func commit() {
        guard let parse, text != shown else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if let onReset { onReset() } else { value = nil }
            invalid = false
            show(nil)
            return
        }
        guard let parsed = parse(trimmed) else {
            invalid = true
            return
        }
        invalid = parsed < scale.lowest || parsed > scale.highest
        let clamped = min(max(parsed, scale.lowest), scale.highest)
        let stored = scale.step.map { SliderScale.snapped(clamped, step: $0, digits: SliderScale.digits(of: $0),
                                                           range: scale.lowest ... scale.highest) } ?? clamped
        value = stored
        show(stored)
    }

    static func decimal(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacing(",", with: "."))
    }
}

public struct SegmentedRow: View {
    private let title: String
    @Binding private var value: String?
    private let choices: [ParameterChoice]
    private let defaultToken: String?
    private let provenance: Provenance?
    private let disabledReason: String?
    private let effect: String?
    private let about: String?
    private let fullHelp: String?

    public init(_ title: String, value: Binding<String?>, choices: [ParameterChoice], defaultToken: String?,
                provenance: Provenance?, disabledReason: String? = nil, effect: String? = nil, about: String? = nil,
                fullHelp: String? = nil) {
        self.fullHelp = fullHelp
        self.effect = effect
        self.about = about
        self.title = title
        _value = value
        self.choices = choices
        self.defaultToken = defaultToken
        self.provenance = provenance
        self.disabledReason = disabledReason
    }

    public var body: some View {
        SettingRow(title, changed: value != nil, reset: { value = nil },
                   details: SettingDetails(flag: provenance?.flag, source: provenance?.shortDescription, splashDefault: defaultToken,
                                           help: fullHelp, about: about, effect: effect),
                   help: defaultToken.map { tr("parameter.splashDefault", $0) } ?? tr("parameter.splashDefaultUnknown"),
                   disabledReason: disabledReason) {
            Picker(selection: selection) {
                ForEach(choices) { choice in
                    Text(choice.title ?? choice.token).tag(choice.token)
                }
            } label: {
                Text(title)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var selection: Binding<String> {
        Binding(get: { value ?? defaultToken ?? "" },
                set: { value = Self.stored($0, defaultToken: defaultToken) })
    }

    static func stored(_ token: String, defaultToken: String?) -> String? {
        token == defaultToken ? nil : token
    }
}
