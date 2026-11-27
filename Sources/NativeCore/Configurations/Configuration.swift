import Foundation

public enum ParameterValue: Codable, Sendable, Equatable, Hashable {
    case on
    case value(String)
    case values([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            guard flag else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "un interruttore spento si omette")
            }
            self = .on
        } else if let list = try? container.decode([String].self) {
            self = .values(list)
        } else {
            self = .value(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .on: try container.encode(true)
        case .value(let value): try container.encode(value)
        case .values(let values): try container.encode(values)
        }
    }
}

public struct Configuration: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var splashVersion: String?
    public var installationRoot: String?
    public var model: String
    public var apiModelID: String?
    public var port: Int
    public var principal: Bool
    public var parameters: [String: ParameterValue]
    public var usesAPIKey: Bool
    public var origin: String?
    public var observe: Bool

    public var id: String { name }

    public init(name: String, splashVersion: String?, installationRoot: String? = nil, model: String, apiModelID: String? = nil,
                port: Int, principal: Bool = false, parameters: [String: ParameterValue] = [:], usesAPIKey: Bool = false,
                origin: String? = nil, observe: Bool = false) {
        self.name = name
        self.splashVersion = splashVersion
        self.installationRoot = installationRoot
        self.model = model
        self.apiModelID = apiModelID
        self.port = port
        self.principal = principal
        self.parameters = parameters
        self.usesAPIKey = usesAPIKey
        self.origin = origin
        self.observe = observe
    }

    private enum CodingKeys: String, CodingKey {
        case name, splashVersion, installationRoot, model, apiModelID, port, principal, parameters, usesAPIKey, origin, observe
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        splashVersion = try c.decodeIfPresent(String.self, forKey: .splashVersion)
        installationRoot = try c.decodeIfPresent(String.self, forKey: .installationRoot)
        model = try c.decode(String.self, forKey: .model)
        apiModelID = try c.decodeIfPresent(String.self, forKey: .apiModelID)
        port = try c.decode(Int.self, forKey: .port)
        principal = try c.decode(Bool.self, forKey: .principal)
        parameters = try c.decode([String: ParameterValue].self, forKey: .parameters)
        usesAPIKey = try c.decode(Bool.self, forKey: .usesAPIKey)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        observe = try c.decodeIfPresent(Bool.self, forKey: .observe) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(splashVersion, forKey: .splashVersion)
        try c.encodeIfPresent(installationRoot, forKey: .installationRoot)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(apiModelID, forKey: .apiModelID)
        try c.encode(port, forKey: .port)
        try c.encode(principal, forKey: .principal)
        try c.encode(parameters, forKey: .parameters)
        try c.encode(usesAPIKey, forKey: .usesAPIKey)
        try c.encodeIfPresent(origin, forKey: .origin)
        if observe { try c.encode(observe, forKey: .observe) }
    }

    public var splashPort: Int { observe ? ObservationProxy.upstreamPort(for: port) : port }

    public var isLocal: Bool { model.hasPrefix("/") || model.hasPrefix("~/") }

    public static let managedFlags: Set<String> = ["--model", "--model-dir", "--port", "--host", "--api-key"]

    public static let reservedPorts: Set<Int> = [5000, 7000]

    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public func installation(among installations: [SplashInstallation]) -> SplashInstallation? {
        if let root = installationRoot {
            return installations.first { $0.root.path == URL(filePath: root).standardizedFileURL.path }
        }
        guard let version = splashVersion else { return nil }
        let matching = installations.filter { $0.version.map(SplashVersion.init) == SplashVersion(version) }
        return matching.first { $0.linked } ?? matching.first
    }
}

func expandTilde(_ path: String) -> String {
    path.hasPrefix("~/") ? URL.homeDirectory.path + String(path.dropFirst(1)) : path
}
