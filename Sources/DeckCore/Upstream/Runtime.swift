import CryptoKit
import Foundation
import Synchronization

final class ShellSettings: Sendable {
    private let store = Mutex<[String: String]>([:])

    var values: [String: String] { store.withLock { $0 } }

    func set(_ values: [String: String]) {
        store.withLock { $0 = values }
    }
}

struct Runtime: Sendable {
    let root: URL
    let shellSettings = ShellSettings()

    static func locate() -> Runtime? {
        let candidates = [
            ProcessInfo.processInfo.environment["SPLASH_RUNTIME"].map { URL(filePath: $0) },
            Bundle.main.resourceURL?.appending(path: "splash"),
        ]
        return candidates.compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "install/launcher.py").path) }
            .map(Runtime.init)
    }

    var packaged: Bool { FileManager.default.fileExists(atPath: root.appending(path: "release.json").path) }

    var python: URL { root.appending(path: packaged ? "python/bin/python3" : ".venv/bin/python") }
    var engine: URL { root.appending(path: packaged ? "engine/splash" : "build/splash") }
    var suggestedModels: URL { root.appending(path: "install/suggested-models.tsv") }
    var markdownScripts: [URL] {
        ["markdown-it-15.0.2.min.js", "highlight-11.12.0.min.js", "markdown-links.js"]
            .map { root.appending(path: "server/chat-assets/\($0)") }
    }

    private var data: URL { packaged ? URL.applicationSupportDirectory.appending(path: "Splash") : root }
    var models: URL { data.appending(path: packaged ? "models" : "install/models") }
    var locks: URL { packaged ? data.appending(path: "runtime") : root.appending(path: "build/runtime") }

    func command(_ arguments: [String]) -> [String] {
        scriptCommand("install/launcher.py", arguments)
    }

    func installCommand(_ model: String, textOnly: Bool = false) -> [String] {
        scriptCommand("install/models.py",
                      ["--model", model] + sourceFlags(textOnly) + ["prepare", "--json-progress"])
    }

    func removeCommand(_ model: String, textOnly: Bool = false) -> [String] {
        scriptCommand("install/models.py", ["--model", model] + sourceFlags(textOnly) + ["remove"])
    }

    private func sourceFlags(_ textOnly: Bool) -> [String] {
        textOnly ? ["--language-only"] : []
    }

    func runsInstaller(_ pid: pid_t) -> Bool {
        guard let arguments = processArguments(pid), let flag = arguments.firstIndex(of: "--model"),
              flag + 1 < arguments.endIndex
        else { return false }
        return arguments.dropFirst()
            == installCommand(arguments[flag + 1], textOnly: arguments.contains("--language-only")).dropFirst()
    }

    var cachedInstallCommand: [String] {
        scriptCommand("install/cached.py", ["--models", models.path])
    }

    private func scriptCommand(_ script: String, _ arguments: [String]) -> [String] {
        [python.path, "-I", "-B", "-u", root.appending(path: script).path] + arguments
    }

    var environment: [String: String] {
        var environment = userEnvironment
        environment["HOME"] = URL.homeDirectory.path
        environment.merge(shellSettings.values) { $1 }
        environment["PYTHONNOUSERSITE"] = "1"
        return environment
    }

    @MainActor
    static func readShellSettings(_ shell: Shell, environment: [String: String] = ProcessInfo.processInfo.environment,
                                  limit: Duration = .seconds(5)) async -> [String: String] {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return [:] }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        let output = PipeOutput(ends[0])
        let marker = "SPLASH-SHELL-SETTINGS"
        let script = "printf '\\0\(marker)\\0'; \(shellSettingsCommand); printf '\(marker)\\0'"
        let (ended, end) = AsyncStream<Int32>.makeStream()
        let child = try? ChildProcess(command: [shell.path] + shell.arguments + ["-i", "-l", "-c", script],
                                      environment: environment, output: ends[1], exited: { end.yield($0); end.finish() })
        close(ends[1])
        guard let child else {
            _ = output.finish()
            return [:]
        }
        let timer = Task { @MainActor in
            try await Task.sleep(for: limit)
            child.stop(SIGKILL, killAfter: .zero)
        }
        var status: Int32?
        for await code in ended { status = code }
        timer.cancel()
        let data = output.finish()
        guard status == 0 else { return [:] }
        return shellSettings(in: data, between: marker)
    }

    nonisolated static func takesShellSetting(_ name: String) -> Bool {
        shellSettingPrefixes.contains { name.hasPrefix($0) } || shellSettingNames.contains(name)
    }

    private nonisolated static let shellSettingPrefixes = ["HF_", "HUGGINGFACE_"]
    private nonisolated static let shellSettingNames = ["HUGGING_FACE_HUB_TOKEN", "XDG_CACHE_HOME"]

    nonisolated static var shellSettingsCommand: String {
        let pattern = (shellSettingPrefixes + shellSettingNames.map { $0 + "=" }).joined(separator: "|")
        return #"/bin/zsh -f -c 'print -rN -- ${(M)${(0)"$(/usr/bin/env -0)"}:#("# + pattern + #")*}'"#
    }

    nonisolated static func shellSettings(in output: Data, between marker: String) -> [String: String] {
        let records = output.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard let start = records.firstIndex(of: marker),
              let end = records[(start + 1)...].firstIndex(of: marker)
        else { return [:] }
        var settings: [String: String] = [:]
        for record in records[(start + 1)..<end] {
            guard let equals = record.firstIndex(of: "=") else { continue }
            let name = String(record[..<equals])
            if takesShellSetting(name) { settings[name] = String(record[record.index(after: equals)...]) }
        }
        return settings
    }

    var userEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SPLASH_API_KEY")
        environment.removeValue(forKey: "SPLASH_RUNTIME")
        return environment
    }

    func installedModels() -> [InstalledModel] {
        struct Record: Decodable {
            struct File: Decodable { let path: String; let bytes: Int64 }
            let model: String
            let family: String?
            let files: [String: File]
            let visionFormat: String?
            let visionUnavailable: String?

            enum CodingKeys: String, CodingKey {
                case model, family, files, visionFormat = "vision_format", visionUnavailable = "vision_unavailable"
            }
        }
        let manager = FileManager.default
        let installed = { (link: URL) -> InstalledModel? in
            guard let data = try? Data(contentsOf: link.appending(path: "model.json")),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.files.values.allSatisfy({ manager.fileExists(atPath: $0.path) })
            else { return nil }
            let files = Dictionary(record.files.values.map { ($0.path, $0.bytes) }) { first, _ in first }
            return InstalledModel(id: record.model, bytes: files.values.reduce(0, +), family: record.family,
                                  towerless: record.visionFormat == "none" && record.visionUnavailable == nil)
        }
        let owners = (try? manager.contentsOfDirectory(at: models, includingPropertiesForKeys: nil)) ?? []
        let named = owners.filter { !$0.lastPathComponent.hasPrefix(".") }
            .flatMap { (try? manager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .compactMap(installed)
        let selections = (try? manager.contentsOfDirectory(at: models.appending(path: ".selections"),
                                                           includingPropertiesForKeys: nil)) ?? []
        let textOnly = selections.compactMap { link -> InstalledModel? in
            guard var model = installed(link), !model.local, link.lastPathComponent == Self.textOnlySelection(model.id),
                  !named.contains(where: { $0.id == model.id })
            else { return nil }
            model.textOnly = true
            return model
        }
        return (named + textOnly).sorted { $0.id < $1.id }
    }

    static func textOnlySelection(_ model: String) -> String {
        SHA256.hash(data: Data(#"["\#(model)",null,true,null]"#.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func preparedFamilies() -> [String: String] {
        struct Record: Decodable {
            let model: String
            let family: String
        }
        let links = (try? FileManager.default.contentsOfDirectory(at: models.appending(path: ".selections"),
                                                                   includingPropertiesForKeys: nil)) ?? []
        let records = links.compactMap { link in
            (try? Data(contentsOf: link.appending(path: "model.json"))).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        }
        return Dictionary(records.map { ($0.model, $0.family) }) { first, _ in first }
    }

    @MainActor
    func families() async -> [String: ModelFamily] {
        let output = FileManager.default.temporaryDirectory.appending(path: "splash-families-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        guard await ChildProcess.run(scriptCommand("install/families.py", []), environment: environment, log: output,
                                     timeout: .seconds(30)) == 0,
              let said = try? String(contentsOf: output, encoding: .utf8),
              let report = said.split(whereSeparator: \.isNewline).last
        else { return [:] }
        return (try? JSONDecoder().decode([String: ModelFamily].self, from: Data(report.utf8))) ?? [:]
    }

    func serveLockHolder(port: Int) -> pid_t? {
        let lock = locks.appending(path: "serve-\(port).lock")
        let descriptor = open(lock.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) != 0 else {
            flock(descriptor, LOCK_UN)
            return nil
        }
        struct Owner: Decodable { let pid: Int32 }
        guard errno == EWOULDBLOCK, let data = try? Data(contentsOf: lock) else { return nil }
        return (try? JSONDecoder().decode(Owner.self, from: data))?.pid
    }

    func serveRecord(port: Int) -> ServeRecord? {
        guard let data = try? Data(contentsOf: locks.appending(path: "serve-\(port).json")) else { return nil }
        return try? JSONDecoder().decode(ServeRecord.self, from: data)
    }

    @MainActor
    func unsupportedReason() async -> String? {
        let output = FileManager.default.temporaryDirectory.appending(path: "splash-device-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        guard let status = await ChildProcess.run([engine.path, "device-check"], environment: environment, log: output,
                                                   timeout: .seconds(30)),
              status != 0, let said = try? String(contentsOf: output, encoding: .utf8)
        else { return nil }
        let reason = said.trimmingCharacters(in: .whitespacesAndNewlines).replacing(#/^error: /#, with: "")
        return reason.isEmpty ? nil : reason
    }
}

private final class PipeOutput: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "PipeOutput")
    private let source: DispatchSourceRead
    private var data = Data()

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.read() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    func finish() -> Data {
        queue.sync {
            read()
            source.cancel()
            return data
        }
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while !source.isCancelled {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { source.cancel() }
            guard count > 0 else { return }
            data.append(contentsOf: buffer[..<count])
        }
    }
}

struct ServeRecord: Decodable, Equatable {
    enum Phase: String, Decodable {
        case starting, loading, warming, ready, recovering, failed
        case unknown

        init(from decoder: Decoder) throws {
            self = Phase(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        var started: Bool { self == .ready || self == .recovering }
    }

    struct Warmup: Decodable, Equatable {
        let steps_done: Int
        let steps: Int
    }

    struct Failure: Decodable, Equatable {
        let kind: String
        let message: String
        let bound: String?
        let required_bytes: Int64?
        let budget_bytes: Int64?
        let plan_context_tokens: Int?
    }

    let pid: Int32
    let phase: Phase
    let warmup: Warmup?
    let failure: Failure?
}

struct InstalledModel: Identifiable, Hashable, Sendable {
    let id: String
    var bytes: Int64?
    var missing = false
    var family: String?
    var textOnly = false
    var towerless = false

    var gguf = false

    var local: Bool { id.hasPrefix("/") }

    static func local(_ path: String) -> InstalledModel {
        let url = URL(filePath: path).resolvingSymlinksInPath()
        guard let kind = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return InstalledModel(id: path, missing: true) }
        let files = kind.isDirectory == true
            ? (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
            : [url]
        let bytes = files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var model = InstalledModel(id: path, bytes: bytes)
        model.gguf = files.contains {
            $0.pathExtension.lowercased() == "gguf" && !$0.lastPathComponent.localizedCaseInsensitiveContains("mmproj")
        }
        return model
    }
}
