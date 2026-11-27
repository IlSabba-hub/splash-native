import SwiftUI

public struct SettingStepperControl: View {
    private let title: String
    @Binding private var value: Int64?
    private let minimum: Int64
    private let maximum: Int64?
    private let defaultValue: Int64?
    private let placeholder: String

    public init(_ title: String, value: Binding<Int64?>, minimum: Int64, maximum: Int64?, defaultValue: Int64?, placeholder: String) {
        self.title = title
        _value = value
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = defaultValue
        self.placeholder = placeholder
    }

    public var body: some View {
        HStack(spacing: Space.xs) {
            TextField(title, value: Binding(get: { value }, set: { value = $0.map { min(max($0, minimum), maximum ?? .max) } }),
                      format: IntegerFormatStyle<Int64>(locale: NativeFormat.locale).grouping(.never), prompt: Text(placeholder))
                .settingField()
            Stepper(title) {
                value = Self.stepped(value ?? defaultValue, by: 1, minimum: minimum, maximum: maximum)
            } onDecrement: {
                value = Self.stepped(value ?? defaultValue, by: -1, minimum: minimum, maximum: maximum)
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    static func stepped(_ current: Int64?, by delta: Int64, minimum: Int64, maximum: Int64?) -> Int64 {
        guard let current else { return minimum }
        let (next, overflow) = current.addingReportingOverflow(delta)
        let upper = maximum ?? .max
        return overflow ? (delta > 0 ? upper : minimum) : min(max(next, minimum), upper)
    }
}

public struct SettingStepper: View {
    private let title: String
    @Binding private var value: Int64?
    private let minimum: Int64
    private let maximum: Int64?
    private let defaultValue: Int64?
    private let placeholder: String
    private let help: String
    private let provenance: Provenance?
    private let problem: String?
    private let disabledReason: String?

    public init(_ title: String, value: Binding<Int64?>, minimum: Int64, maximum: Int64?, defaultValue: Int64?, placeholder: String,
                help: String, provenance: Provenance?, problem: String? = nil, disabledReason: String? = nil) {
        self.title = title
        _value = value
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.help = help
        self.provenance = provenance
        self.problem = problem
        self.disabledReason = disabledReason
    }

    public var body: some View {
        SettingRow(title, changed: value != nil, reset: { value = nil }, resetHelp: tr("setting.reset", placeholder),
                   details: SettingDetails(provenance: provenance, splashDefault: placeholder.isEmpty ? nil : placeholder, help: help), help: help, disabledReason: disabledReason,
                   problem: problem) {
            SettingStepperControl(title, value: $value, minimum: minimum, maximum: maximum, defaultValue: defaultValue,
                                  placeholder: placeholder)
        }
    }
}

public struct SettingNumberField: View {
    private let title: String
    @Binding private var value: Double?
    private let placeholder: String
    private let help: String
    private let provenance: Provenance?
    private let problem: String?
    private let disabledReason: String?

    public init(_ title: String, value: Binding<Double?>, placeholder: String, help: String, provenance: Provenance?, problem: String? = nil,
                disabledReason: String? = nil) {
        self.title = title
        _value = value
        self.placeholder = placeholder
        self.help = help
        self.provenance = provenance
        self.problem = problem
        self.disabledReason = disabledReason
    }

    public var body: some View {
        SettingRow(title, changed: value != nil, reset: { value = nil }, resetHelp: tr("setting.reset", placeholder),
                   details: SettingDetails(provenance: provenance, splashDefault: placeholder.isEmpty ? nil : placeholder, help: help), help: help, disabledReason: disabledReason,
                   problem: problem) {
            TextField(title, value: $value, format: FloatingPointFormatStyle<Double>(locale: NativeFormat.locale).precision(.fractionLength(0 ... 3)),
                      prompt: Text(placeholder))
                .settingField()
        }
    }
}
