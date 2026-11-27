import Darwin
import Foundation

final class ChildProcess: @unchecked Sendable {
    let pid: pid_t
    let started: Int?
    private let exitSource: DispatchSourceProcess
    private var ended = false
    private var stopping = false

    convenience init(
        command: [String],
        environment: [String: String],
        log: URL,
        exited: @escaping @MainActor (Int32) -> Void
    ) throws {
        let output = open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard output >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(output) }
        try self.init(command: command, environment: environment, output: output, exited: exited)
    }

    init(
        command: [String],
        environment: [String: String],
        output: Int32,
        exited: @escaping @MainActor (Int32) -> Void
    ) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var signals = sigset_t()
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)

        let argv = command.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, command[0], &actions, &attributes, argv, envp)
        guard status == 0 else { throw POSIXError(.init(rawValue: status) ?? .EIO) }
        self.pid = pid
        started = processStart(pid)

        exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { [self, exitSource] in
            exitSource.cancel()
            ended = true
            var status: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, 0) } while reaped == -1 && errno == EINTR
            let code = reaped != pid ? -1 : (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            MainActor.assumeIsolated { exited(code) }
        }
        exitSource.resume()
    }

    @MainActor
    func stop(_ signal: Int32, killAfter: Duration) {
        guard !stopping, !ended else { return }
        stopping = true
        killpg(pid, signal)
        Task { @MainActor [self] in
            try? await Task.sleep(for: killAfter)
            if !ended { killpg(pid, SIGKILL) }
        }
    }

    @MainActor
    static func run(_ command: [String], environment: [String: String], log: URL, timeout: Duration) async -> Int32? {
        let (statuses, end) = AsyncStream.makeStream(of: Int32.self)
        guard let child = try? ChildProcess(command: command, environment: environment, log: log, exited: {
            end.yield($0)
            end.finish()
        }) else { return nil }
        let deadline = Task {
            try await Task.sleep(for: timeout)
            child.stop(SIGKILL, killAfter: .zero)
        }
        let status: Int32? = await withTaskCancellationHandler {
            for await status in statuses { return status }
            return nil
        } onCancel: {
            Task { @MainActor in child.stop(SIGKILL, killAfter: .zero) }
        }
        deadline.cancel()
        return (try? await deadline.value) == nil ? status : nil
    }
}

struct LogLines {
    private var pending = Data()
    private var midLine: Bool

    init(inside: Bool = false) {
        midLine = inside
    }

    mutating func take(_ data: Data) -> Data {
        pending.append(data)
        if midLine {
            guard let end = pending.firstIndex(of: 0x0A) else {
                pending.removeAll()
                return Data()
            }
            pending.removeSubrange(...end)
            midLine = false
        }
        guard let end = pending.lastIndex(of: 0x0A) else { return Data() }
        defer { pending.removeSubrange(...end) }
        return pending[...end]
    }

    mutating func rest() -> Data {
        defer { pending.removeAll() }
        return pending
    }

    var unfinished: Data {
        guard !midLine else { return Data() }
        let bytes = [UInt8](pending)
        guard let lead = bytes.indices.reversed().prefix(4).first(where: { bytes[$0] & 0xC0 != 0x80 }) else { return pending }
        let length = bytes[lead] >= 0xF0 ? 4 : bytes[lead] >= 0xE0 ? 3 : bytes[lead] >= 0xC0 ? 2 : 1
        return bytes.count - lead < length ? Data(bytes[..<lead]) : pending
    }
}

@MainActor
final class LogTail {
    private let handle: FileHandle
    private let source: DispatchSourceFileSystemObject
    private let line: (String) -> Void
    private var lines = LogLines()

    init?(_ url: URL, from offset: UInt64 = 0, line: @escaping (String) -> Void) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try? handle.seek(toOffset: offset)
        self.line = line
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.extend, .write], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    func finish() {
        read()
        let last = lines.rest()
        if !last.isEmpty { line(String(decoding: last, as: UTF8.self)) }
        source.cancel()
    }

    private func read() {
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        for text in lines.take(data).split(separator: 0x0A) { line(String(decoding: text, as: UTF8.self)) }
    }
}

enum Supervision {
    static let stop = Duration.seconds(15)
}

@MainActor
struct ChildRecord {
    let defaults: UserDefaults
    let key: String
    let stop: Int32
    let killAfter: Duration

    func start(_ command: [String], environment: [String: String], log: URL, from offset: UInt64 = 0,
               line: @escaping (String) -> Void, exited: @escaping @MainActor (Int32) -> Void) throws -> ChildProcess {
        var tail: LogTail?
        let child = try ChildProcess(command: command, environment: environment, log: log) { status in
            tail?.finish()
            forget()
            exited(status)
        }
        tail = LogTail(log, from: offset, line: line)
        keep(child)
        return child
    }

    func keep(_ child: ChildProcess) {
        guard let started = child.started else { return forget() }
        defaults.set([Int(child.pid), started], forKey: key)
    }

    func forget() {
        defaults.removeObject(forKey: key)
    }

    func stopLeftover(olderApps: (pid_t) -> Bool, stopping: () -> Void = {}) async {
        if let older = defaults.object(forKey: key) as? Int, let pid = pid_t(exactly: older) {
            if olderApps(pid) {
                stopping()
                await stopProcessGroup(pid, with: stop, killAfter: killAfter)
            }
            return forget()
        }
        guard let kept = defaults.array(forKey: key) as? [Int], kept.count == 2,
              let pid = pid_t(exactly: kept[0])
        else { return forget() }
        if processStart(pid) == kept[1] {
            stopping()
            await stopProcessGroup(pid, with: stop, killAfter: killAfter)
        }
        if processStart(pid) != kept[1] { forget() }
    }
}

func processStart(_ pid: pid_t) -> Int? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Int(info.pbi_start_tvsec) * 1_000_000 + Int(info.pbi_start_tvusec)
}

func processArguments(_ pid: pid_t) -> [String]? {
    var name = [CTL_KERN, KERN_ARGMAX]
    var largest: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctl(&name, u_int(name.count), &largest, &size, nil, 0) == 0 else { return nil }
    name = [CTL_KERN, KERN_PROCARGS2, pid]
    var buffer = [UInt8](repeating: 0, count: Int(largest))
    size = buffer.count
    guard sysctl(&name, u_int(name.count), &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
    else { return nil }
    let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
    let arguments = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: false)
        .dropFirst().drop(while: \.isEmpty).prefix(count)
    guard arguments.count == count else { return nil }
    return arguments.map { String(decoding: $0, as: UTF8.self) }
}

func stopProcessGroup(_ pid: pid_t, with signal: Int32, killAfter: Duration) async {
    killpg(pid, signal)
    let killAt = ContinuousClock.now + killAfter
    var killed = false
    while kill(pid, 0) == 0, ContinuousClock.now < killAt + .seconds(10) {
        if !killed, ContinuousClock.now >= killAt {
            killpg(pid, SIGKILL)
            killed = true
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
}

func portInUse(_ port: Int) -> Bool {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    func attempt(_ operation: (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                operation(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
    return !attempt(bind) || attempt(connect)
}

func resetLog(_ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
}

@discardableResult
func beginLog(_ url: URL, heading: String, kept: Int = 8 << 20) -> UInt64 {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let file = try? FileHandle(forUpdating: url)
    defer { try? file?.close() }
    let size = (try? file?.seekToEnd()) ?? 0
    let trims = size > UInt64(kept)
    var tail = Data()
    if let file, size > 0 {
        try? file.seek(toOffset: trims ? size - UInt64(kept) : size - 1)
        tail = (try? file.readToEnd()) ?? Data()
        if trims, let newline = tail.firstIndex(of: 0x0A) { tail = Data(tail[tail.index(after: newline)...]) }
    }
    var added = Data()
    if !tail.isEmpty {
        if tail.last != 0x0A { added.append(0x0A) }
        added.append(0x0A)
    }
    added.append(Data((heading + "\n").utf8))
    guard let file, !trims else {
        let log = (trims ? tail : Data()) + added
        try? log.write(to: url, options: .atomic)
        return UInt64(log.count)
    }
    _ = try? file.seekToEnd()
    try? file.write(contentsOf: added)
    return size + UInt64(added.count)
}

func appendLog(_ url: URL, _ line: String) {
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data((line + "\n").utf8))
}
