import Foundation

public enum ConfigurationProblem: Sendable, Hashable {
    case invalidName(String)
    case invalidPort(Int)
    case missingAPIModelID
    case noInstallation(version: String?)
    case managedFlag(String)
    case unknownFlag(String, version: String)
    case notASwitch(String)
    case notAList(String)
    case emptyValue(String)
    case notAChoice(String, value: String, choices: [String])
    case secretInConfiguration(String)
    case observedPortOutOfRange(Int)

    public var field: String {
        switch self {
        case .invalidName: "name"
        case .invalidPort, .observedPortOutOfRange: "port"
        case .missingAPIModelID: "apiModelID"
        case .noInstallation: "splashVersion"
        case .managedFlag(let flag), .unknownFlag(let flag, _), .notASwitch(let flag), .notAList(let flag),
             .emptyValue(let flag), .notAChoice(let flag, _, _), .secretInConfiguration(let flag): flag
        }
    }

    public var message: String { NativeText.problem(self) }
}

public struct DroppedParameter: Sendable, Equatable {
    public let flag: String
    public let applicability: Applicability
}

public struct LaunchPlan: Sendable, Equatable {
    public let configuration: Configuration
    public let installation: SplashInstallation
    public let serveArguments: [String]
    public let argv: [String]
    public let dropped: [DroppedParameter]
    public let mayContactHub: Bool

    public static func make(_ configuration: Configuration, schema: VersionSchema, family: String?) -> Result<LaunchPlan, Problems> {
        var problems: [ConfigurationProblem] = []
        if !Configuration.validName(configuration.name) { problems.append(.invalidName(configuration.name)) }
        if !(1024...65535).contains(configuration.port) || Configuration.reservedPorts.contains(configuration.port) {
            problems.append(.invalidPort(configuration.port))
        } else if configuration.observe, configuration.splashPort > 65535 {
            problems.append(.observedPortOutOfRange(configuration.port))
        }
        if configuration.isLocal && (configuration.apiModelID ?? "").isEmpty { problems.append(.missingAPIModelID) }
        let version = schema.installation.version ?? schema.serve.reportedVersion
        var dropped: [DroppedParameter] = []
        var flags: [String] = []
        for parameter in schema.serve.parameters {
            guard let value = parameter.flags.lazy.compactMap({ configuration.parameters[$0] }).first else { continue }
            if Configuration.managedFlags.contains(parameter.flag) {
                problems.append(.managedFlag(parameter.flag))
                continue
            }
            if parameter.secret {
                problems.append(.secretInConfiguration(parameter.flag))
                continue
            }
            switch (parameter.kind, value) {
            case (.flag, .on): break
            case (.flag, _): problems.append(.notASwitch(parameter.flag)); continue
            case (_, .on): problems.append(.emptyValue(parameter.flag)); continue
            case (_, .values) where !parameter.repeatable: problems.append(.notAList(parameter.flag)); continue
            default: break
            }
            let words: [String] = switch value {
            case .on: []
            case .value(let text): [text]
            case .values(let texts): texts
            }
            if words.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) || (words.isEmpty && value != .on) {
                problems.append(.emptyValue(parameter.flag))
                continue
            }
            if case .choice(let choices) = parameter.kind, let bad = words.first(where: { !choices.contains($0) }) {
                problems.append(.notAChoice(parameter.flag, value: bad, choices: choices))
                continue
            }
            if let report = schema.families {
                let applicability = Applicability.of(parameter, family: family, in: report)
                if case .noEffect = applicability {
                    dropped.append(DroppedParameter(flag: parameter.flag, applicability: applicability))
                    continue
                }
            }
            let expand: Bool = switch parameter.kind {
            case .path, .draft: true
            default: false
            }
            if words.isEmpty { flags.append(parameter.flag) }
            for word in words.map({ expand ? expandTilde($0) : $0 }) {
                flags += word.hasPrefix("-") ? [parameter.flag + "=" + word] : [parameter.flag, word]
            }
        }
        let known = Set(schema.serve.parameters.flatMap(\.flags))
        for flag in configuration.parameters.keys.sorted() where !known.contains(flag) {
            problems.append(Configuration.managedFlags.contains(flag) ? .managedFlag(flag) : .unknownFlag(flag, version: version))
        }
        guard problems.isEmpty else { return .failure(Problems(list: problems)) }
        var serve = ["serve"]
        if configuration.isLocal {
            serve += ["--model", configuration.apiModelID!, "--model-dir", expandTilde(configuration.model)]
        } else {
            serve += ["--model", configuration.model]
        }
        serve += ["--port", String(configuration.splashPort), "--host", "127.0.0.1"] + flags
        let offline = configuration.parameters["--offline"] == .on
        return .success(LaunchPlan(configuration: configuration, installation: schema.installation, serveArguments: serve,
                                   argv: schema.installation.command(serve), dropped: dropped,
                                   mayContactHub: !offline && !configuration.isLocal))
    }

    public var port: Int { configuration.splashPort }
    public var observedPort: Int? { configuration.observe ? configuration.port : nil }

    public struct Problems: Error, Sendable, Equatable {
        public let list: [ConfigurationProblem]
    }

    public func environment(shellSettings: [String: String], apiKey: String?) -> [String: String] {
        let runtime = installation.runtime
        runtime.shellSettings.set(shellSettings)
        var environment = runtime.environment.filter { !$0.key.hasPrefix("SPLASH_") }
        if configuration.usesAPIKey, let apiKey { environment["SPLASH_API_KEY"] = apiKey }
        return environment
    }

    public func judge(apiKey: String?) async throws -> ParserVerdict {
        try await ParserVerdict.judge(serveArguments, with: installation,
                                      secrets: configuration.usesAPIKey ? apiKey.map { ["SPLASH_API_KEY": $0] } ?? [:] : [:])
    }
}
