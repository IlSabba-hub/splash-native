import Foundation

public struct ConfigurationHeader: Sendable, Equatable {
    public var name: String
    public var installation: String
    public var model: String
    public var apiModelID: String
    public var port: Int?
    public var principal: Bool
    public var usesAPIKey: Bool
    public var apiKey: String
    public var observe: Bool

    public init(name: String, installation: String, model: String, apiModelID: String, port: Int?, principal: Bool,
                usesAPIKey: Bool, apiKey: String, observe: Bool = false) {
        self.name = name
        self.installation = installation
        self.model = model
        self.apiModelID = apiModelID
        self.port = port
        self.principal = principal
        self.usesAPIKey = usesAPIKey
        self.apiKey = apiKey
        self.observe = observe
    }

    public var isLocal: Bool { model.hasPrefix("/") || model.hasPrefix("~/") }
}

public struct WeightsChoice: Sendable, Equatable, Identifiable {
    public enum Group: Sendable, Equatable, CaseIterable {
        case mac
        case hub

        public var title: String {
            switch self {
            case .mac: tr("weights.group.mac")
            case .hub: tr("weights.group.hub")
            }
        }
    }

    public var id: String { token }
    public let token: String
    public let name: String
    public let badges: [String]
    public let size: String?
    public let detail: String
    public let group: Group
    public let unavailable: String?

    public init(token: String, name: String, badges: [String] = [], size: String? = nil, detail: String, group: Group,
                unavailable: String? = nil) {
        self.token = token
        self.name = name
        self.badges = badges
        self.size = size
        self.unavailable = unavailable
        self.detail = detail
        self.group = group
    }
}

public enum SettingControl: Sendable, Equatable {
    case field
    case toggle
    case segmented([ParameterChoice], defaultToken: String?)
    case menu([ParameterChoice], defaultToken: String?)
    case stepper(ClosedRange<Int64>)
    case slider(SliderScale, unit: SettingUnit, automatic: ParameterWord?)
    case weights([WeightsChoice], current: WeightsChoice?, unset: String)
}

public enum SettingUnit: Sendable, Equatable {
    case tokens
    case bytes
    case pixels

    public var title: String {
        switch self {
        case .tokens: tr("unit.tokens")
        case .bytes: UnitInformationStorage.gibibytes.symbol
        case .pixels: tr("unit.pixels")
        }
    }

    public func format(_ value: Double) -> String {
        switch self {
        case .tokens, .pixels: NativeFormat.count(Int(value))
        case .bytes: NativeFormat.memory(Int64(value))
        }
    }

    static func decimal(_ text: String) -> Double? {
        let marks = text.filter { $0 == "," || $0 == "." }
        var number = text
        if let last = marks.last, Set(marks).count == 2 || marks.count == 1 {
            let thousands: Character = last == "," ? "." : ","
            number = String(text.filter { $0 != thousands }).replacing(String(last), with: ".")
        } else if marks.count > 1 {
            number = String(text.filter { $0 != marks.first })
        }
        return Double(number)
    }

    public func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch self {
        case .tokens, .pixels:
            let digits = trimmed.filter(\.isNumber)
            guard !digits.isEmpty, digits.count == trimmed.filter({ !".,' \u{00A0}\u{202F}".contains($0) }).count else { return nil }
            return Double(digits)
        case .bytes:
            let lower = trimmed.lowercased()
            let mebi = lower.hasSuffix("m") || lower.hasSuffix("mib") || lower.hasSuffix("mb")
            guard let value = Self.decimal(String(lower.prefix { $0.isNumber || $0 == "," || $0 == "." })), value > 0 else { return nil }
            return value * Double(mebi ? 1 << 20 : 1 << 30)
        }
    }
}

public struct EditorSetting: Sendable, Equatable, Identifiable {
    public var id: String { descriptor.flag }
    public let descriptor: ParameterDescriptor
    public let control: SettingControl
    public let applicable: Bool

    public init(_ descriptor: ParameterDescriptor, control: SettingControl = .field, applicable: Bool = true) {
        self.descriptor = descriptor
        self.control = control
        self.applicable = applicable
    }
}

public struct EditorPane: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let splashName: String?
    public let settings: [EditorSetting]

    public init(id: String, title: String, splashName: String?, settings: [EditorSetting]) {
        self.id = id
        self.title = title
        self.splashName = splashName
        self.settings = settings
    }
}

public struct ConfigurationEditorContent: Sendable {
    public let versions: [ParameterChoice]
    public let models: [WeightsChoice]
    public let model: WeightsChoice?
    public let panes: [EditorPane]
    public let facts: [Fact]
    public let problems: [String: String]
    public let notices: [String]
    public let isNew: Bool
    public let schemaUnavailable: String?
    public let modelPort: Int?

    public init(versions: [ParameterChoice], models: [WeightsChoice], model: WeightsChoice? = nil, panes: [EditorPane], facts: [Fact] = [],
                problems: [String: String] = [:], notices: [String] = [], isNew: Bool = false, schemaUnavailable: String? = nil,
                modelPort: Int? = nil) {
        self.modelPort = modelPort
        self.versions = versions
        self.models = models
        self.model = model
        self.panes = panes
        self.facts = facts
        self.problems = problems
        self.notices = notices
        self.isNew = isNew
        self.schemaUnavailable = schemaUnavailable
    }
}

public struct HistoryEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let date: Date
    public let message: String

    public init(id: String, date: Date, message: String) {
        self.id = id
        self.date = date
        self.message = message
    }
}

public struct ConfigurationVerdict: Sendable {
    public let accepted: Bool
    public let message: String?
    public let facts: [Fact]
    public let dropped: [String]
    public let notices: [String]
    public let date: Date

    public init(accepted: Bool, message: String?, facts: [Fact] = [], dropped: [String] = [], notices: [String] = [], date: Date) {
        self.accepted = accepted
        self.message = message
        self.facts = facts
        self.dropped = dropped
        self.notices = notices
        self.date = date
    }
}

public struct ConfigurationReview: Sendable {
    public let diff: [Fact]
    public let verdict: ConfigurationVerdict?
    public let verifying: Bool
    public let actions: [NativeAction]
    public let history: [HistoryEntry]
    public let selectedHistory: String?
    public let historyDiff: [Fact]
    public let historyActions: [NativeAction]
    public let onSelectHistory: @MainActor @Sendable (String) -> Void

    public init(diff: [Fact], verdict: ConfigurationVerdict?, verifying: Bool, actions: [NativeAction], history: [HistoryEntry],
                selectedHistory: String?, historyDiff: [Fact], historyActions: [NativeAction],
                onSelectHistory: @escaping @MainActor @Sendable (String) -> Void) {
        self.diff = diff
        self.verdict = verdict
        self.verifying = verifying
        self.actions = actions
        self.history = history
        self.selectedHistory = selectedHistory
        self.historyDiff = historyDiff
        self.historyActions = historyActions
        self.onSelectHistory = onSelectHistory
    }
}
