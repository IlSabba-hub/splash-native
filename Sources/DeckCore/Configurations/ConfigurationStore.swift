import Foundation

public struct ConfigurationStore: Sendable {
    public let folder: URL
    public let git: URL

    public static let defaultFolder = URL.homeDirectory.appending(path: ".config/splash-deck/configurations")

    public init(folder: URL = ConfigurationStore.defaultFolder, git: URL = URL(filePath: "/usr/bin/git")) {
        self.folder = folder
        self.git = git
    }

    public func file(_ name: String) -> URL { folder.appending(path: "\(name).json") }

    public func load() throws -> [Configuration] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return try files.filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.principal ? 0 : 1, $0.name) < ($1.principal ? 0 : 1, $1.name) }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public func save(_ configuration: Configuration, message: String) async throws {
        guard Configuration.validName(configuration.name) else { throw LaunchPlan.Problems(list: [.invalidName(configuration.name)]) }
        try prepare()
        let file = file(configuration.name)
        try Self.encoder.encode(configuration).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try await commit([file.lastPathComponent], message: message)
    }

    public func remove(_ name: String, message: String) async throws {
        try await run(["rm", "-q", "--", "\(name).json"])
        try await run(["commit", "-q", "-m", message])
    }

    public func keepCopy(of source: URL, as relativePath: String) throws -> URL {
        try prepare()
        let target = folder.appending(path: relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

    public struct Change: Sendable, Equatable {
        public let commit: String
        public let date: Date
        public let message: String
    }

    public func history(_ name: String) async throws -> [Change] {
        let result = try await run(["log", "--format=%H%x1f%aI%x1f%s", "--", "\(name).json"])
        let formatter = ISO8601DateFormatter()
        return result.text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let date = formatter.date(from: fields[1]) else { return nil }
            return Change(commit: fields[0], date: date, message: fields[2])
        }
    }

    public func configuration(_ name: String, at commit: String) async throws -> Configuration {
        let result = try await run(["show", "\(commit):\(name).json"])
        return try JSONDecoder().decode(Configuration.self, from: result.output)
    }

    func commit(_ paths: [String], message: String) async throws {
        try await run(["add", "--"] + paths)
        let staged = try await run(["diff", "--cached", "--quiet"], allowFailure: true)
        guard staged.status != 0 else { return }
        try await run(["commit", "-q", "-m", message])
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func ensureRepository() async throws {
        try prepare()
        if !FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) {
            try await Command.run([git.path, "init", "-q", folder.path], environment: Self.gitEnvironment)
                .checked("git init")
        }
    }

    static let gitEnvironment: [String: String] = [
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "HOME": URL.homeDirectory.path,
        "GIT_AUTHOR_NAME": "Splash Deck", "GIT_AUTHOR_EMAIL": "splash-deck@localhost",
        "GIT_COMMITTER_NAME": "Splash Deck", "GIT_COMMITTER_EMAIL": "splash-deck@localhost",
        "PATH": "/usr/bin:/bin",
    ]

    @discardableResult
    private func run(_ arguments: [String], allowFailure: Bool = false) async throws -> Command.Result {
        try await ensureRepository()
        let result = try await Command.run([git.path, "-C", folder.path] + arguments, environment: Self.gitEnvironment)
        return allowFailure ? result : try result.checked("git \(arguments.first ?? "")")
    }
}

extension Command.Result {
    @discardableResult
    func checked(_ what: String) throws -> Command.Result {
        guard status == 0 else { throw DeckError.commandFailed(program: what, status: status, detail: errorText) }
        return self
    }
}
