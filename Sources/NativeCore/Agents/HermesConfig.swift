import Foundation

public struct HermesConfig: Sendable, Equatable {
    public static let defaultFile = URL.homeDirectory.appending(path: ".hermes/config.yaml")
    public static let fields = ["model.default", "model.provider", "providers.<provider>.base_url"]

    public let file: URL
    public let model: String?
    public let provider: String?
    public let baseURL: String?

    public var localPort: Int? { baseURL.flatMap(Self.localPort) }

    public static func read(_ file: URL = defaultFile) -> HermesConfig? {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text, file: file)
    }

    public static func parse(_ text: String, file: URL = defaultFile) -> HermesConfig {
        let model = scalar(in: text, at: ["model", "default"])
        let provider = scalar(in: text, at: ["model", "provider"])
        let base = provider.flatMap { scalar(in: text, at: ["providers", $0, "base_url"]) }
        return HermesConfig(file: file, model: model, provider: provider, baseURL: base)
    }

    static func scalar(in text: String, at path: [String]) -> String? {
        var stack: [(indent: Int, key: String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let body = line.drop { $0 == " " }
            if body.isEmpty || body.hasPrefix("#") || body.hasPrefix("- ") || body == "-" { continue }
            let indent = line.count - body.count
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = body[..<colon].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if key.isEmpty || key.contains(" ") { continue }
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            stack.append((indent, key))
            if stack.map(\.key) == path { return value(String(body[body.index(after: colon)...])) }
        }
        return nil
    }

    private static func value(_ rest: String) -> String? {
        let rest = rest.trimmingCharacters(in: .whitespaces)
        guard let first = rest.first else { return nil }
        let value: String
        if first == "\"" || first == "'" {
            value = String(rest.dropFirst().prefix { $0 != first })
        } else {
            value = (rest.components(separatedBy: " #").first ?? "").trimmingCharacters(in: .whitespaces)
        }
        guard !value.isEmpty, !"{[&*|>".contains(value.first!) else { return nil }
        return value
    }

    static func localPort(_ url: String) -> Int? {
        guard let components = URLComponents(string: url), let host = components.host, let port = components.port,
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else { return nil }
        return port
    }
}
