import Foundation

public enum ModelTools {
    static var script: URL {
        Bundle.module.url(forResource: "splash_models", withExtension: "py")!
    }

    static func run(_ installation: SplashInstallation, _ command: String, _ arguments: [String], input: Data? = nil,
                    timeout: Duration = .seconds(60)) async throws -> Data {
        let argv = [installation.python.path, "-I", "-B", script.path, command, installation.root.path] + arguments
        let result = try await Command.run(argv, environment: ["HOME": URL.homeDirectory.path], input: input, timeout: timeout)
        guard result.status == 0 else {
            throw DeckError.commandFailed(program: "splash_models.py \(command)", status: result.status,
                                          detail: String(result.errorText.suffix(2000)))
        }
        return result.output
    }

    public static func selectionLinks(_ lines: [[String]], with installation: SplashInstallation,
                                      models: URL) async throws -> [URL?] {
        struct Raw: Decodable {
            struct Entry: Decodable { let link: String?; let error: String? }
            let links: [Entry]
        }
        guard !lines.isEmpty else { return [] }
        let data = try await run(installation, "links", [models.path], input: try JSONEncoder().encode(lines))
        return try JSONDecoder().decode(Raw.self, from: data).links.map { $0.link.map { URL(filePath: $0) } }
    }

    public struct Verification: Sendable, Equatable {
        public let full: Bool
        public let passed: Bool
        public let message: String?
        public let seconds: Double
        public let date: Date
    }

    public static func verify(_ link: URL, full: Bool, with installation: SplashInstallation) async throws -> Verification {
        struct Raw: Decodable { let ok: Bool; let message: String?; let seconds: Double }
        let data = try await run(installation, "verify", [link.path] + (full ? ["--full"] : []), timeout: .seconds(600))
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return Verification(full: full, passed: raw.ok, message: raw.message, seconds: raw.seconds, date: .now)
    }

    public struct GGUFHeader: Sendable, Equatable {
        public let architecture: String?
        public let name: String?
        public let contextLength: Int?
        public let types: [String: Int64]
        public let error: String?
        public var sizeLabel: String? = nil

        public var parameters: Int64? {
            let total = types.values.reduce(0, +)
            return total > 0 ? total : nil
        }

        public var dominant: (type: String, share: Double)? {
            let total = types.values.reduce(0, +)
            guard total > 0, let top = types.max(by: { $0.value < $1.value }) else { return nil }
            return (top.key, Double(top.value) / Double(total))
        }
    }

    public static func ggufHeaders(_ files: [String], with installation: SplashInstallation) async throws -> [String: GGUFHeader] {
        struct Raw: Decodable {
            struct Entry: Decodable {
                let architecture: String?
                let name: String?
                let context_length: Int?
                let types: [String: Int64]?
                let error: String?
                let size_label: String?
            }
            let files: [String: Entry]
        }
        guard !files.isEmpty else { return [:] }
        let data = try await run(installation, "gguf", files, timeout: .seconds(120))
        return try JSONDecoder().decode(Raw.self, from: data).files.mapValues {
            GGUFHeader(architecture: $0.architecture, name: $0.name, contextLength: $0.context_length, types: $0.types ?? [:], error: $0.error,
                       sizeLabel: $0.size_label)
        }
    }
}
