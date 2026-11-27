import Foundation

public struct ChatSamplingDefaults: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case family(String)
        case flag
        case splash
    }

    public struct Entry: Sendable, Equatable {
        public let value: Double
        public let source: Source
    }

    public let entries: [String: Entry]

    public init(entries: [String: Entry]) {
        self.entries = entries
    }

    public subscript(field: ChatField) -> Entry? { entries[field.rawValue] }

    public static let splashVersion = "1.7.3"

    public static let splash: [String: Double] = [
        "temperature": 1.0, "top_p": 1.0, "top_k": 0, "min_p": 0, "presence_penalty": 0, "frequency_penalty": 0, "repetition_penalty": 1.0,
    ]

    static let published: Set<String> = ["temperature", "top_p", "top_k"]

    public static func resolve(family: (name: String, sampling: [String: Double])?, flags: [String],
                               version: String? = splashVersion) -> ChatSamplingDefaults {
        var entries: [String: Entry] = [:]
        let splash = version == splashVersion ? splash : [:]
        for (name, value) in splash where !published.contains(name) {
            entries[name] = Entry(value: value, source: .splash)
        }
        if let family {
            for name in published {
                if let value = family.sampling[name] {
                    entries[name] = Entry(value: value, source: .family(family.name))
                } else if let value = splash[name] {
                    entries[name] = Entry(value: value, source: .splash)
                }
            }
        }
        for flag in flags {
            let parts = flag.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, Self.splash[parts[0]] != nil, let value = Double(parts[1]) else { continue }
            entries[parts[0]] = Entry(value: value, source: .flag)
        }
        return ChatSamplingDefaults(entries: entries)
    }
}

extension FamilyReport.Family {
    public var sampling: [String: Double]? {
        guard case let .object(object)? = facts["sampling"] else { return nil }
        var sampling: [String: Double] = [:]
        for (name, value) in object {
            switch value {
            case let .int(x): sampling[name] = Double(x)
            case let .double(x): sampling[name] = x
            default: continue
            }
        }
        return sampling
    }
}
