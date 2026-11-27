import Foundation

public struct ParameterDescriptor: Sendable, Equatable, Identifiable {
    public var id: String { flag }
    public let title: String
    public let flag: String
    public let kind: ParameterKind
    public let splashDefault: String?
    public let help: String?
    public let provenance: Provenance?
    public let disabledReason: String?
    public let effect: String?

    public init(title: String, flag: String, kind: ParameterKind, splashDefault: String? = nil, help: String? = nil,
                provenance: Provenance? = nil, disabledReason: String? = nil, effect: String? = nil) {
        self.effect = effect
        self.title = title
        self.flag = flag
        self.kind = kind
        self.splashDefault = splashDefault
        self.help = help
        self.provenance = provenance
        self.disabledReason = disabledReason
    }

    public var defaultToken: String? {
        SettingDetails(flag: flag, source: nil, splashDefault: splashDefault, help: nil).shortDefault
    }

    public static func defaultEntry(word: String?, value: String?) -> String {
        let parenthesized = word?.contains(Character("(")) == true
        if let word { return tr(parenthesized ? "parameter.mode.wordDefaultPlain" : "parameter.mode.wordDefault", word) }
        return value.map { tr("parameter.mode.defaultValue", $0) } ?? tr("parameter.mode.default")
    }
}

public struct ParameterWord: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { token }
    public let token: String
    public let title: String

    public init(token: String, title: String) {
        self.token = token
        self.title = title
    }

    public static var auto: ParameterWord { ParameterWord(token: "auto", title: tr("parameter.word.auto")) }
    public static var off: ParameterWord { ParameterWord(token: "off", title: tr("parameter.word.off")) }
}

public struct ParameterChoice: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { token }
    public let token: String
    public let title: String?

    public init(token: String, title: String? = nil) {
        self.token = token
        self.title = title
    }
}

public enum ParameterUnit: Sendable, Equatable {
    case tokens, requests, pixels

    public var title: String {
        switch self {
        case .tokens: tr("unit.tokens")
        case .requests: tr("unit.requests")
        case .pixels: tr("unit.pixels")
        }
    }
}

public enum ParameterKind: Sendable, Equatable {
    case toggle
    case integer(range: ClosedRange<Int64>?, unit: ParameterUnit?, words: [ParameterWord])
    case number(range: ClosedRange<Double>?)
    case choice([ParameterChoice])
    case duration(words: [ParameterWord])
    case size(words: [ParameterWord])
    case text(placeholder: String?)
    case path(directory: Bool)
    case list(placeholder: String?)
    case secret
}

public enum ParameterValue: Sendable, Equatable, Hashable {
    case unset
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case choice(String)
    case word(String)
    case seconds(Int64)
    case bytes(Int64)
    case text(String)
    case list([String])
    case secret(String)
}
