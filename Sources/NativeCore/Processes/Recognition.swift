import Darwin
import Foundation

public struct ProcessArguments: Sendable, Equatable {
    public let executable: String
    public let argv: [String]
    public let environmentNames: [String]

    public init(executable: String, argv: [String], environmentNames: [String] = []) {
        self.executable = executable
        self.argv = argv
        self.environmentNames = environmentNames
    }

    public static func parse(_ buffer: [UInt8]) -> ProcessArguments? {
        guard buffer.count > 4 else { return nil }
        let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        let fields = buffer[4...].split(separator: 0, omittingEmptySubsequences: false)
        guard let first = fields.first else { return nil }
        let executable = String(decoding: first, as: UTF8.self)
        let rest = fields.dropFirst().drop(while: \.isEmpty)
        let argv = rest.prefix(count).map { String(decoding: $0, as: UTF8.self) }
        guard argv.count == count else { return nil }
        let environment = rest.dropFirst(count).prefix { !$0.isEmpty }.compactMap { field -> String? in
            guard let equals = field.firstIndex(of: UInt8(ascii: "=")) else { return nil }
            return String(decoding: field[field.startIndex..<equals], as: UTF8.self)
        }
        return ProcessArguments(executable: executable, argv: argv, environmentNames: environment)
    }

    public static func read(_ pid: pid_t) -> ProcessArguments? {
        var name = [CTL_KERN, KERN_ARGMAX]
        var largest: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&name, u_int(name.count), &largest, &size, nil, 0) == 0 else { return nil }
        name = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(largest))
        size = buffer.count
        guard sysctl(&name, u_int(name.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    public func value(of flag: String) -> String? {
        for (index, argument) in argv.enumerated() {
            if argument == flag, index + 1 < argv.count { return argv[index + 1] }
            if argument.hasPrefix(flag + "=") { return String(argument.dropFirst(flag.count + 1)) }
        }
        return nil
    }
}

public enum SplashRole: Sendable, Equatable {
    case server(root: URL, port: Int, model: String?, serveRecord: String)
    case launcher(root: URL, port: Int?)
    case engine(root: URL)

    public var root: URL {
        switch self {
        case .server(let root, _, _, _), .launcher(let root, _), .engine(let root): root
        }
    }

    public static func recognize(_ arguments: ProcessArguments,
                                 isSplashRoot: (URL) -> Bool = SplashRole.isSplashRoot) -> SplashRole? {
        let executable = URL(filePath: arguments.executable).standardizedFileURL
        let argv = arguments.argv
        if executable.lastPathComponent == "splash", argv.count > 1, argv[1] == "serve-native" {
            let root = canonical(executable.deletingLastPathComponent().deletingLastPathComponent())
            let folder = executable.deletingLastPathComponent().lastPathComponent
            guard folder == "engine" || folder == "build", isSplashRoot(root) else { return nil }
            return .engine(root: root)
        }
        guard let root = pythonRoot(executable), isSplashRoot(root) else { return nil }
        if let module = argv.firstIndex(of: "-m"), module + 1 < argv.count, argv[module + 1] == "server.server" {
            guard let record = arguments.value(of: "--serve-record"),
                  let port = arguments.value(of: "--port").flatMap(Int.init)
            else { return nil }
            return .server(root: root, port: port, model: arguments.value(of: "--model"), serveRecord: record)
        }
        let launcher = root.appending(path: "install/launcher.py").path
        if let script = argv.dropFirst().first(where: { !$0.hasPrefix("-") }),
           URL(filePath: script).standardizedFileURL.path == launcher,
           let index = argv.firstIndex(of: script), argv.dropFirst(index + 1).first == "serve" {
            return .launcher(root: root, port: arguments.value(of: "--port").flatMap(Int.init))
        }
        return nil
    }

    static func pythonRoot(_ executable: URL) -> URL? {
        let parts = executable.pathComponents
        guard parts.count > 3 else { return nil }
        let tail = parts.suffix(3)
        guard Array(tail) == ["python", "bin", "python3"] || Array(tail) == [".venv", "bin", "python"] else { return nil }
        return canonical(executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    }

    static func canonical(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        return URL(filePath: path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path)
    }

    public static func isSplashRoot(_ root: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: root.appending(path: "install/launcher.py").path)
            && manager.fileExists(atPath: root.appending(path: "server/server.py").path)
    }
}

public enum KnownEngine: String, Sendable, Codable, Equatable {
    case splash, inkEngine = "ink_engine", llamaServer = "llama_server", omlx, mlxVLM = "mlx_vlm", mlxLM = "mlx_lm"

    public static func recognize(_ arguments: ProcessArguments, isSplashRoot: (URL) -> Bool = SplashRole.isSplashRoot) -> KnownEngine? {
        if SplashRole.recognize(arguments, isSplashRoot: isSplashRoot) != nil { return .splash }
        let executable = URL(filePath: arguments.executable).lastPathComponent
        if executable == "ink-engine" || executable.hasPrefix("ink-engine-") { return .inkEngine }
        if executable == "llama-server" { return .llamaServer }
        if arguments.argv.first == "omlx-server" { return .omlx }
        guard executable.lowercased().hasPrefix("python") else { return nil }
        switch pythonTarget(arguments.argv).map({ URL(filePath: $0).lastPathComponent }) {
        case "mlx_vlm.server": return .mlxVLM
        case "mlx_lm.server": return .mlxLM
        default: return nil
        }
    }

    static func pythonTarget(_ argv: [String]) -> String? {
        var index = 1
        while index < argv.count {
            let argument = argv[index]
            switch argument {
            case "-m": return index + 1 < argv.count ? argv[index + 1] : nil
            case "-c": return nil
            case "-X", "-W": index += 2
            default:
                if argument.hasPrefix("-") { index += 1 } else { return argument }
            }
        }
        return nil
    }
}
