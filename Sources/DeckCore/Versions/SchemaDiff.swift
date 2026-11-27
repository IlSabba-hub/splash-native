import Foundation

public struct SchemaDiff: Sendable, Equatable {
    public struct Change: Sendable, Equatable, Identifiable {
        public let flag: String
        public let before: String?
        public let after: String?
        public var id: String { flag }
    }

    public let from: String
    public let to: String
    public let added: [String]
    public let removed: [String]
    public let defaults: [Change]
    public let help: [Change]
    public let needs: [Change]
    public let parsers: [Change]
    public let environment: [Change]

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && defaults.isEmpty && help.isEmpty && needs.isEmpty && parsers.isEmpty && environment.isEmpty
    }

    public init(from old: ServeSchema, version oldVersion: String, to new: ServeSchema, version newVersion: String) {
        from = oldVersion
        to = newVersion
        let before = Set(old.parameters.map(\.flag)), after = Set(new.parameters.map(\.flag))
        added = new.parameters.map(\.flag).filter { !before.contains($0) }
        removed = old.parameters.map(\.flag).filter { !after.contains($0) }
        func changes(_ field: (ServeParameter) -> String?) -> [Change] {
            new.parameters.compactMap { parameter in
                guard let previous = old.parameter(parameter.flag) else { return nil }
                let (a, b) = (field(previous).map(Self.normalized), field(parameter).map(Self.normalized))
                return a == b ? nil : Change(flag: parameter.flag, before: a, after: b)
            }
        }
        defaults = changes(\.helpDefault)
        help = changes(\.help)
        needs = changes(\.needs)
        parsers = changes(\.parser)
        environment = changes(\.environment)
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension SchemaStore {
    public func cachedSchemas() -> [VersionSchema] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoded = files.filter { $0.pathExtension == "json" }.compactMap { file -> VersionSchema? in
            guard let data = try? Data(contentsOf: file), let schema = try? JSONDecoder().decode(VersionSchema.self, from: data),
                  schema.installation.version != nil else { return nil }
            return schema
        }
        let newest = Dictionary(grouping: decoded) { $0.installation.version ?? "" }.values.compactMap { group in
            group.max { $0.generated < $1.generated }
        }
        return newest.sorted { SplashVersion($0.installation.version ?? "") > SplashVersion($1.installation.version ?? "") }
    }
}
