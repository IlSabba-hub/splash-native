import Foundation

public struct FamilyReport: Codable, Sendable, Equatable {
    public struct Family: Codable, Sendable, Equatable {
        public let unusable: [String]
        public let contextTokens: Int?
        public let maxContextTokens: Int?
        public let facts: [String: JSONValue]
    }

    public let families: [String: Family]

    public var names: [String] { families.keys.sorted() }

    public static func decode(probe data: Data) throws -> FamilyReport {
        struct Raw: Decodable {
            struct Entry: Decodable {
                let unusable: [String]
                let context_tokens: Int?
                let max_context_tokens: Int?
            }
            let report: [String: Entry]?
            let facts: [String: [String: JSONValue]]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        var families: [String: Family] = [:]
        for (name, facts) in raw.facts {
            let entry = raw.report?[name]
            families[name] = Family(unusable: entry?.unusable ?? [], contextTokens: entry?.context_tokens ?? facts["context_tokens"]?.int.map(Int.init),
                                    maxContextTokens: entry?.max_context_tokens ?? facts["max_context_tokens"]?.int.map(Int.init), facts: facts)
        }
        return FamilyReport(families: families)
    }
}

public enum Applicability: Sendable, Equatable {
    case applies
    case noEffect(family: String, needs: String?)
    case unknownFamily

    public static func of(_ parameter: ServeParameter, family: String?, in report: FamilyReport) -> Applicability {
        guard let family, let entry = report.families[family] else { return .unknownFamily }
        return entry.unusable.contains(parameter.flag) ? .noEffect(family: family, needs: parameter.needs) : .applies
    }

    public var reason: String? {
        switch self {
        case .applies: nil
        case .unknownFamily: DeckText.unknownFamily
        case .noEffect(let family, let needs): DeckText.noEffect(family: family, needs: needs)
        }
    }
}
