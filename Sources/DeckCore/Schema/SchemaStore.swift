import CryptoKit
import Foundation

public struct VersionSchema: Codable, Sendable, Equatable {
    public let installation: SplashInstallation
    public let serve: ServeSchema
    public let families: FamilyReport?
    public let generated: Date
    public let key: String
}

public struct SchemaStore: Sendable {
    public let folder: URL

    public static let defaultFolder = URL.cachesDirectory.appending(path: "SplashDeck/schemas")

    public init(folder: URL = SchemaStore.defaultFolder) {
        self.folder = folder
    }

    static let sources = ["install/launcher.py", "server/serve_options.py", "install/families.py", "install/models.py",
                          "server/images.py", "server/chat_format.py", "server/protocol.py", "release.json", "engine/splash", "build/splash"]

    public static func key(for installation: SplashInstallation) -> String {
        var text = "\(installation.root.path)\n\(installation.version ?? "checkout")\n"
        if let probe = try? Data(contentsOf: Probe.script) {
            text += "probe " + SHA256.hash(data: probe).map { String(format: "%02x", $0) }.joined() + "\n"
        }
        for source in sources {
            let url = installation.root.appending(path: source)
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                text += "\(source) \(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)\n"
            }
        }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func schema(for installation: SplashInstallation) async throws -> VersionSchema {
        let key = Self.key(for: installation)
        let file = folder.appending(path: "\(key).json")
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: file), let cached = try? decoder.decode(VersionSchema.self, from: data),
           cached.key == key, cached.installation.root == installation.root {
            return cached
        }
        let serve = try ServeSchema.decode(probe: try await Probe.schemaJSON(installation))
        let families = try? FamilyReport.decode(probe: try await Probe.familiesJSON(installation))
        let schema = VersionSchema(installation: installation, serve: serve, families: families, generated: .now, key: key)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(schema).write(to: file, options: .atomic)
        return schema
    }
}

public struct ParserVerdict: Sendable, Equatable {
    public let accepted: Bool
    public let message: String?
    public let parsed: [String: JSONValue]
    public let serverArguments: [String]
    public let engineArguments: [String]

    public static func judge(_ arguments: [String], with installation: SplashInstallation,
                             secrets: [String: String] = [:]) async throws -> ParserVerdict {
        struct Raw: Decodable {
            let ok: Bool
            let message: String?
            let parsed: [String: JSONValue]?
            let server_argv: [String]?
            let engine_argv: [String]?
        }
        let data = try await Probe.run(installation, "validate", ["--"] + arguments, environment: secrets)
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return ParserVerdict(accepted: raw.ok, message: raw.message, parsed: raw.parsed ?? [:],
                             serverArguments: raw.server_argv ?? [], engineArguments: raw.engine_argv ?? [])
    }
}
