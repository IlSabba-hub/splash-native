import Foundation

public enum EditorValue: Sendable, Equatable, Hashable {
    case unset
    case on
    case integer(Int64)
    case number(Double)
    case choice(String)
    case word(String)
    case seconds(Int64)
    case bytes(Int64)
    case text(String)
    case list([String])
}

public enum ParameterText {
    public static func words(_ kind: ValueKind) -> [String] {
        switch kind {
        case .contextTokens, .sizeOrAuto: ["auto"]
        case .sizeOrAutoOr(let words): ["auto"] + words
        case .sizeAutoOrZero: ["auto", "0"]
        case .sizeOrZero: ["0"]
        case .durationOrOff: ["off"]
        default: []
        }
    }

    public static func read(_ value: ParameterValue?, kind: ValueKind) -> EditorValue {
        guard let value else { return .unset }
        switch value {
        case .on: return .on
        case .values(let list): return .list(list)
        case .value(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if words(kind).contains(trimmed.lowercased()) { return .word(trimmed.lowercased()) }
            switch kind {
            case .choice, .reasoningEffort: return .choice(trimmed)
            case .contextTokens: return tokens(trimmed).map(EditorValue.integer) ?? .text(text)
            case .sizeOrAuto, .sizeOrAutoOr, .sizeAutoOrZero, .sizeOrZero, .size: return bytes(trimmed).map(EditorValue.bytes) ?? .text(text)
            case .duration, .durationOrOff: return seconds(trimmed).map(EditorValue.seconds) ?? .text(text)
            case .integer, .port: return Int64(trimmed).map(EditorValue.integer) ?? .text(text)
            case .nonnegativeNumber: return Double(trimmed).map(EditorValue.number) ?? .text(text)
            case .samplingDefault: return .list([text])
            default: return .text(text)
            }
        }
    }

    public static func write(_ value: EditorValue, kind: ValueKind) -> ParameterValue? {
        switch value {
        case .unset: return nil
        case .on: return .on
        case .list(let list): return list.isEmpty ? nil : .values(list)
        case .text(let text): return text.isEmpty ? nil : .value(text)
        case .choice(let text), .word(let text): return .value(text)
        case .integer(let number): return .value(String(number))
        case .number(let number): return .value(number.rounded() == number ? String(Int64(number)) : String(number))
        case .seconds(let seconds): return .value(String(seconds))
        case .bytes(let bytes):
            for (suffix, unit) in [("G", Int64(1) << 30), ("M", Int64(1) << 20), ("K", Int64(1) << 10)] where bytes % unit == 0 && bytes != 0 {
                return .value("\(bytes / unit)\(suffix)")
            }
            return .value(String(bytes))
        }
    }

    static func tokens(_ text: String) -> Int64? {
        guard let match = text.uppercased().wholeMatch(of: /(\d+)([KM]?)/), let count = Int64(match.1) else { return nil }
        return count * (match.2 == "K" ? 1024 : match.2 == "M" ? 1_000_000 : 1)
    }

    static func bytes(_ text: String) -> Int64? {
        let upper = text.uppercased()
        if let whole = Int64(upper) { return whole }
        guard let match = upper.wholeMatch(of: /(\d+(?:\.\d+)?)([KMG])/), let amount = Double(match.1) else { return nil }
        let unit: Double = match.2 == "G" ? 1_073_741_824 : match.2 == "M" ? 1_048_576 : 1024
        return Int64((amount * unit).rounded())
    }

    static func seconds(_ text: String) -> Int64? {
        let lower = text.lowercased()
        if let whole = Double(lower) { return Int64(whole.rounded()) }
        guard let match = lower.wholeMatch(of: /(\d+(?:\.\d+)?)([smh])/), let amount = Double(match.1) else { return nil }
        let unit: Double = match.2 == "h" ? 3600 : match.2 == "m" ? 60 : 1
        return Int64((amount * unit).rounded())
    }
}

public struct EditorField: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case active
        case noEffect(reason: String)
        case absent(otherVersions: [String])
        case unknown
    }

    public let parameter: ServeParameter?
    public let flag: String
    public let group: String
    public let state: State
    public let value: EditorValue
    public let original: ParameterValue?

    public var id: String { flag }
}

public struct EditorGroup: Sendable, Equatable, Identifiable {
    public let name: String
    public let fields: [EditorField]
    public var id: String { name }
}

public enum ConfigurationEditor {
    public static func groups(for configuration: Configuration, schema: VersionSchema, family: String?,
                              others: [VersionSchema] = []) -> [EditorGroup] {
        var groups: [EditorGroup] = []
        for name in schema.serve.groups {
            let fields = schema.serve.parameters.filter { $0.group == name && !Configuration.managedFlags.contains($0.flag) }.map { parameter in
                let original = parameter.flags.lazy.compactMap { configuration.parameters[$0] }.first
                var state = EditorField.State.active
                if let report = schema.families, case .noEffect = Applicability.of(parameter, family: family, in: report) {
                    state = .noEffect(reason: Applicability.of(parameter, family: family, in: report).reason ?? "")
                }
                return EditorField(parameter: parameter, flag: parameter.flag, group: name, state: state,
                                   value: ParameterText.read(original, kind: parameter.kind), original: original)
            }
            if !fields.isEmpty { groups.append(EditorGroup(name: name, fields: fields)) }
        }
        let known = Set(schema.serve.parameters.flatMap(\.flags))
        var absent: [String: (ServeParameter, [String])] = [:]
        for other in others where other.installation.root != schema.installation.root {
            for parameter in other.serve.parameters where !known.contains(parameter.flag) && !Configuration.managedFlags.contains(parameter.flag) {
                absent[parameter.flag, default: (parameter, [])].1.append(other.installation.version ?? other.serve.reportedVersion)
            }
        }
        var extra: [EditorField] = absent.sorted { $0.key < $1.key }.map { flag, entry in
            let original = configuration.parameters[flag]
            return EditorField(parameter: entry.0, flag: flag, group: entry.0.group ?? "", state: .absent(otherVersions: entry.1.sorted()),
                               value: ParameterText.read(original, kind: entry.0.kind), original: original)
        }
        for (flag, value) in configuration.parameters.sorted(by: { $0.key < $1.key })
        where !known.contains(flag) && absent[flag] == nil && !Configuration.managedFlags.contains(flag) {
            extra.append(EditorField(parameter: nil, flag: flag, group: "", state: .unknown, value: ParameterText.read(value, kind: .text),
                                     original: value))
        }
        if !extra.isEmpty { groups.append(EditorGroup(name: "", fields: extra)) }
        return groups
    }

    public static func parameters(_ values: [String: EditorValue], fields: [EditorField]) -> [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [:]
        for field in fields {
            let value = values[field.flag] ?? field.value
            if value == field.value, let original = field.original {
                parameters[field.flag] = original
            } else if let written = ParameterText.write(value, kind: field.parameter?.kind ?? .text) {
                parameters[field.flag] = written
            }
        }
        return parameters
    }

    public static func freeName(_ base: String, among names: [String]) -> String {
        let clean = String(base.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" }.prefix(56))
        let start = clean.isEmpty ? "configurazione" : clean
        var candidate = start
        var index = 2
        while names.contains(candidate) {
            candidate = "\(start)-\(index)"
            index += 1
        }
        return candidate
    }

    public static func freePort(schema: VersionSchema, among configurations: [Configuration]) -> Int? {
        guard let first = schema.serve.constants["server.serve_options.DEFAULT_PORT"]?.int.map(Int.init) else { return nil }
        let used = Set(configurations.map(\.port))
        var port = first
        while used.contains(port) || Configuration.reservedPorts.contains(port) { port += 1 }
        return port <= 65535 ? port : nil
    }
}

public enum APIKeys {
    static func keychain(_ name: String) -> Keychain { Keychain(service: "Splash Native", account: name) }

    public static func read(_ configuration: String) throws -> String? { try keychain(configuration).read() }

    public static func write(_ key: String?, for configuration: String) throws { try keychain(configuration).write(key) }
}
