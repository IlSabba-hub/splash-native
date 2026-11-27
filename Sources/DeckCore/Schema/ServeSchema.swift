import Foundation

public enum ValueKind: Codable, Sendable, Equatable {
    case flag
    case choice([String])
    case contextTokens(max: Int64?)
    case sizeOrAuto
    case sizeOrAutoOr(words: [String])
    case sizeAutoOrZero
    case sizeOrZero
    case size
    case duration
    case durationOrOff
    case integer(min: Int64?, max: Int64?)
    case nonnegativeNumber
    case path(directory: Bool)
    case modelID
    case draft
    case host
    case origin
    case servedName
    case samplingDefault(names: [String])
    case reasoningEffort([String])
    case port
    case secret
    case text
    case unknown(parser: String)

    static func from(parser: String?, action: String, choices: [String]?, secret: Bool, constants: [String: JSONValue]) -> ValueKind {
        if secret { return .secret }
        if action == "_StoreTrueAction" { return .flag }
        if let choices { return .choice(choices) }
        let constant = { (name: String) in constants[name]?.int }
        switch parser {
        case nil: return .text
        case "parse_max_context": return .contextTokens(max: constant("server.serve_options.MAX_YARN_CONTEXT_TOKENS"))
        case "parse_max_memory", "parse_sparse_kv_memory": return .sizeOrAuto
        case "parse_ple_memory", "parse_expert_memory": return .sizeOrAutoOr(words: ["off"])
        case "parse_max_cache_disk": return .sizeAutoOrZero
        case "parse_max_cache_disk_writes": return .sizeOrZero
        case "parse_request_size": return .size
        case "parse_request_timeout": return .duration
        case "parse_idle_release": return .durationOrOff
        case "parse_queue_size": return .integer(min: 1, max: nil)
        case "parse_concurrent_requests":
            return .integer(min: 1, max: constant("server.serve_options.MAX_CONCURRENT_REQUESTS"))
        case "parse_decode_share": return .nonnegativeNumber
        case "parse_max_image_pixels":
            return .integer(min: constant("server.images.MIN_PIXELS"), max: constant("server.images.MAX_PIXELS"))
        case "parse_thinking_token_budget": return .integer(min: 0, max: nil)
        case "parse_cache_dir": return .path(directory: true)
        case "parse_chat_template_file", "_local_path": return .path(directory: false)
        case "parse_model_id": return .modelID
        case "parse_draft_model": return .draft
        case "parse_host": return .host
        case "parse_allowed_origin": return .origin
        case "parse_served_model_name": return .servedName
        case "parse_sampling_default":
            return .samplingDefault(names: constants["server.protocol.SAMPLING_FIELDS"]?.strings ?? [])
        case "parse_reasoning_effort":
            return .reasoningEffort(constants["server.chat_format.REASONING_EFFORTS"]?.strings ?? [])
        case "_parse_port": return .port
        case let other?: return .unknown(parser: other)
        }
    }
}

public struct ServeParameter: Codable, Sendable, Equatable, Identifiable {
    public let flags: [String]
    public let dest: String
    public let group: String?
    public let kind: ValueKind
    public let repeatable: Bool
    public let required: Bool
    public let parserDefault: JSONValue
    public let helpDefault: String?
    public let metavar: String?
    public let help: String?
    public let environment: String?
    public let secret: Bool
    public let needs: String?
    public let engine: String?
    public let parser: String?
    public let helpLine: Int?

    public var flag: String { flags[0] }
    public var id: String { flag }
}

public struct ServeSchema: Codable, Sendable, Equatable {
    public let reportedVersion: String
    public let help: String
    public let parameters: [ServeParameter]
    public let constants: [String: JSONValue]

    public func parameter(_ flag: String) -> ServeParameter? {
        parameters.first { $0.flags.contains(flag) }
    }

    public var groups: [String] {
        var seen: [String] = []
        for parameter in parameters { if let group = parameter.group, !seen.contains(group) { seen.append(group) } }
        return seen
    }

    public static func decode(probe data: Data) throws -> ServeSchema {
        struct Raw: Decodable {
            struct Option: Decodable {
                struct Parser: Decodable { let name: String; let module: String? }
                let flags: [String]
                let dest: String
                let action: String
                let `default`: JSONValue?
                let required: Bool
                let choices: [JSONValue]?
                let metavar: JSONValue?
                let help: String?
                let group: String?
                let type: Parser?
            }
            struct Meta: Decodable {
                struct Engine: Decodable { let at: JSONValue }
                let environment: String?
                let secret: Bool?
                let needs: String?
                let engine: Engine?
            }
            let version: String?
            let help: String?
            let options: [Option]?
            let serve_options: [String: JSONValue]?
            let launcher_needs: [String: String]?
            let constants: [String: JSONValue]?
            let error: String?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        if let error = raw.error { throw DeckError.splash(error) }
        guard let options = raw.options, let help = raw.help else {
            throw DeckError.splash("serve --help")
        }
        let constants = raw.constants ?? [:]
        var meta: [String: Raw.Meta] = [:]
        for (flag, value) in raw.serve_options ?? [:] where flag != "__error__" {
            if let data = try? JSONEncoder().encode(value), let decoded = try? JSONDecoder().decode(Raw.Meta.self, from: data) {
                meta[flag] = decoded
            }
        }
        let lines = help.split(separator: "\n", omittingEmptySubsequences: false)
        let parameters = options.map { option -> ServeParameter in
            let flag = option.flags[0]
            let info = meta[flag]
            let secret = info?.secret ?? false
            let choices = option.choices?.compactMap(\.text)
            let engine: String? = switch info?.engine?.at {
            case .string(let name)?: name
            case .int(let slot)?: "posizionale \(slot)"
            default: nil
            }
            let line = lines.firstIndex { line in
                line.hasPrefix("  \(flag)") && {
                    let rest = line.dropFirst(2 + flag.count)
                    return rest.isEmpty || rest.first == " " || rest.first == ","
                }()
            }
            return ServeParameter(
                flags: option.flags, dest: option.dest, group: option.group,
                kind: ValueKind.from(parser: option.type?.name, action: option.action, choices: choices, secret: secret, constants: constants),
                repeatable: option.action == "_AppendAction", required: option.required,
                parserDefault: option.default ?? .null,
                helpDefault: option.help.flatMap(helpDefault(in:)),
                metavar: option.metavar?.text, help: option.help, environment: info?.environment, secret: secret,
                needs: info?.needs ?? raw.launcher_needs?[flag], engine: engine,
                parser: option.type.map { [$0.module, $0.name].compactMap { $0 }.joined(separator: ".") },
                helpLine: line.map { $0 + 1 })
        }
        return ServeSchema(reportedVersion: raw.version ?? "n/d", help: help, parameters: parameters, constants: constants)
    }

    static func helpDefault(in help: String) -> String? {
        guard let start = help.range(of: "(default: ") else { return nil }
        var depth = 1
        var end = start.upperBound
        while end < help.endIndex {
            if help[end] == "(" { depth += 1 }
            if help[end] == ")" { depth -= 1; if depth == 0 { break } }
            end = help.index(after: end)
        }
        let text = help[start.upperBound..<end].replacing(/\s+/, with: " ")
        return text.isEmpty ? nil : String(text)
    }

    public func changes(since older: ServeSchema) -> (added: [String], removed: [String], helpChanged: [String]) {
        let now = Set(parameters.map(\.flag)), before = Set(older.parameters.map(\.flag))
        let normalized = { (text: String?) in text?.replacing(/\s+/, with: " ") }
        let changed = parameters.filter { parameter in
            guard let old = older.parameter(parameter.flag) else { return false }
            return normalized(old.help) != normalized(parameter.help)
        }.map(\.flag)
        return (now.subtracting(before).sorted(), before.subtracting(now).sorted(), changed)
    }
}
