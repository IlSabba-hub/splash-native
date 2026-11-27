import Darwin
import Foundation

public enum InstanceLock {
    public static let defaultFile = URL.applicationSupportDirectory.appending(path: "SplashDeck/instance.lock")

    public enum Outcome: Sendable, Equatable {
        case acquired(descriptor: Int32)
        case heldBy(pid: Int32?)
    }

    public static func acquire(_ file: URL = defaultFile) throws -> Outcome {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let holder = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            close(descriptor)
            return .heldBy(pid: holder)
        }
        let pid = Data("\(getpid())\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = pid.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, pid.count, 0) }
        return .acquired(descriptor: descriptor)
    }

    public static func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
