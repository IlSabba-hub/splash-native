import Foundation

public struct ServerRoute: Sendable, Equatable, Identifiable {
    public let method: String
    public let path: String
    public let pattern: String?
    public let open: Bool

    public var id: String { "\(method) \(path)" }

    public init(method: String, path: String, pattern: String? = nil, open: Bool = false) {
        self.method = method
        self.path = path
        self.pattern = pattern
        self.open = open
    }
}

public enum ServerRoutes {
    public static let file = "server/server.py"

    public static func read(root: URL) -> [ServerRoute]? {
        let server = root.appending(path: file)
        guard let text = try? String(contentsOf: server, encoding: .utf8) else { return nil }
        return parse(text) { module in
            try? String(contentsOf: root.appending(path: "server/\(module.replacing(".", with: "/")).py"), encoding: .utf8)
        }
    }

    public static func parse(_ text: String, module: (String) -> String?) -> [ServerRoute]? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("ROUTES = {") }),
              let end = lines[(start + 1)...].firstIndex(where: { $0 == "}" }) else { return nil }
        let block = lines[(start + 1) ..< end].joined(separator: "\n")
        let entry = /\(\s*"([A-Z]+)"\s*,\s*([^()]+?)\s*\)\s*:/
        let matches = block.matches(of: entry)
        var routes: [ServerRoute] = []
        for (index, match) in matches.enumerated() {
            let tail = index + 1 < matches.count ? matches[index + 1].range.lowerBound : block.endIndex
            let call = block[match.range.upperBound ..< tail]
            let method = String(match.output.1)
            let key = String(match.output.2)
            let open = call.contains("public=True")
            if key.hasPrefix("\"") && key.hasSuffix("\"") && key.count >= 2 {
                routes.append(ServerRoute(method: method, path: String(key.dropFirst().dropLast()), open: open))
            } else if let pattern = compiled(key, in: text, module: module) {
                routes.append(ServerRoute(method: method, path: display(pattern), pattern: pattern, open: open))
            }
        }
        return routes.isEmpty ? nil : routes
    }

    static func compiled(_ key: String, in text: String, module: (String) -> String?) -> String? {
        let parts = key.split(separator: ".").map(String.init)
        guard let name = parts.last, parts.allSatisfy({ $0.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil }) else { return nil }
        let source = parts.count == 1 ? text : module(parts.dropLast().joined(separator: "."))
        guard let source else { return nil }
        for line in source.components(separatedBy: "\n") where line.hasPrefix(name) {
            if let match = line.wholeMatch(of: /([A-Za-z_][A-Za-z0-9_]*)\s*=\s*re\.compile\(r?"([^"]*)"(?:,.*)?\)\s*/), match.output.1 == name {
                return String(match.output.2)
            }
        }
        return nil
    }

    static func display(_ pattern: String) -> String {
        var result = ""
        var depth = 0
        for character in pattern {
            switch character {
            case "(":
                if depth == 0 { result += "{…}" }
                depth += 1
            case ")":
                depth = max(0, depth - 1)
            default:
                if depth == 0 { result.append(character) }
            }
        }
        return result
    }
}
