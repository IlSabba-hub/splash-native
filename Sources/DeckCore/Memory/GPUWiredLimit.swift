import Darwin
import Foundation

public enum GPUWiredLimit {
    public static let sysctlName = "iogpu.wired_limit_mb"
    public static let sysctlProgram = "/usr/sbin/sysctl"
    public static let daemonLabel = "com.example.splash-deck.gpu-wired-limit"
    public static let daemonPath = "/Library/LaunchDaemons/\(daemonLabel).plist"

    static let mebibyte: UInt64 = 1 << 20
    static let gibibyte: UInt64 = 1 << 30

    public static func readActive() -> UInt64? {
        var size = 0
        guard sysctlbyname(sysctlName, nil, &size, nil, 0) == 0, size > 0, size <= MemoryLayout<UInt64>.size else { return nil }
        var raw: UInt64 = 0
        guard sysctlbyname(sysctlName, &raw, &size, nil, 0) == 0 else { return nil }
        return raw
    }

    public struct Limits: Sendable, Equatable {
        public let physicalBytes: UInt64

        public init(physicalBytes: UInt64) {
            self.physicalBytes = physicalBytes
        }

        public var reserveBytes: UInt64 { max(8 * gibibyte, physicalBytes / 100 * 15) }
        public var highestMiB: UInt64 { physicalBytes > reserveBytes ? (physicalBytes - reserveBytes) / mebibyte : 0 }
        public var lowestMiB: UInt64 { physicalBytes / 2 / mebibyte }
        public var allowsChoice: Bool { highestMiB > lowestMiB }

        public func validated(_ mib: UInt64) -> UInt64? {
            allowsChoice && mib >= lowestMiB && mib <= highestMiB ? mib : nil
        }
    }

    public enum SplashBudget {
        static let rules = SplashMemoryRules.splash173

        public static func margin(recommended: UInt64) -> UInt64 {
            rules.workingSetMargin(recommended: recommended)
        }

        public static func explicitCeiling(recommended: UInt64) -> UInt64 {
            rules.hardBudget(recommended: recommended, maxMemory: UInt64.max, physical: 0)
        }

        public static func automatic(recommended: UInt64, physical: UInt64) -> UInt64 {
            rules.hardBudget(recommended: recommended, maxMemory: nil, physical: physical)
        }

        public static func recommendation(limitMiB mib: UInt64) -> UInt64 {
            mib * mebibyte
        }
    }

    public enum DaemonState: Sendable, Equatable {
        case absent
        case installed(mib: UInt64)
        case unreadable
        case unexpected
    }

    public static func readDaemon(at path: String = daemonPath) -> DaemonState {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return .unreadable }
        guard plist["Label"] as? String == daemonLabel, plist["RunAtLoad"] as? Bool == true,
              let arguments = plist["ProgramArguments"] as? [String], arguments.count == 2, arguments[0] == sysctlProgram,
              let mib = mib(assignment: arguments[1])
        else { return .unexpected }
        return .installed(mib: mib)
    }

    static func mib(assignment: String) -> UInt64? {
        let prefix = "\(sysctlName)="
        guard assignment.hasPrefix(prefix) else { return nil }
        let digits = assignment.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt64(digits)
    }

    public static func daemonPlist(mib: UInt64) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(daemonLabel)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(sysctlProgram)</string>
        \t\t<string>\(sysctlName)=\(mib)</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        </dict>
        </plist>
        """
    }

    public struct PrivilegedCommand: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case apply(mib: UInt64)
            case reset
            case install(mib: UInt64)
            case remove
        }

        public let kind: Kind
        public let steps: [String]
        public let writes: (path: String, contents: String)?

        public var shell: String {
            switch kind {
            case .remove: steps.joined(separator: ";\n")
            default: steps.joined(separator: " &&\n")
            }
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.kind == rhs.kind && lhs.steps == rhs.steps && lhs.writes?.path == rhs.writes?.path
                && lhs.writes?.contents == rhs.writes?.contents
        }
    }

    public static func apply(_ mib: UInt64, limits: Limits) -> PrivilegedCommand? {
        guard let mib = limits.validated(mib) else { return nil }
        return PrivilegedCommand(kind: .apply(mib: mib), steps: [assignment(mib)], writes: nil)
    }

    public static var reset: PrivilegedCommand {
        PrivilegedCommand(kind: .reset, steps: [assignment(0)], writes: nil)
    }

    public static func install(_ mib: UInt64, limits: Limits, path: String = daemonPath) -> PrivilegedCommand? {
        guard let mib = limits.validated(mib) else { return nil }
        let contents = daemonPlist(mib: mib)
        precondition(!contents.contains("'"), "il plist del daemon contiene un apice")
        precondition(safePath(path), "percorso del daemon non valido")
        let staged = path + ".new"
        return PrivilegedCommand(kind: .install(mib: mib), steps: [
            "umask 022",
            "/usr/bin/printf '%s\\n' '\(contents)' > \(staged)",
            "/usr/bin/plutil -lint -s \(staged)",
            "/usr/sbin/chown root:wheel \(staged)",
            "/bin/chmod 644 \(staged)",
            "/bin/mv -f \(staged) \(path)",
        ], writes: (path, contents + "\n"))
    }

    public static func remove(path: String = daemonPath) -> PrivilegedCommand {
        precondition(safePath(path), "percorso del daemon non valido")
        return PrivilegedCommand(kind: .remove, steps: [
            "/bin/launchctl bootout system/\(daemonLabel) 2>/dev/null",
            "/bin/rm -f \(path)",
        ], writes: nil)
    }

    static func safePath(_ path: String) -> Bool {
        path.wholeMatch(of: /\/[A-Za-z0-9._\/-]+/) != nil && !path.contains("..")
    }

    static func assignment(_ mib: UInt64) -> String {
        "\(sysctlProgram) \(sysctlName)=\(mib)"
    }

    public static func osascriptArguments(_ command: PrivilegedCommand, prompt: String) -> [String] {
        osascript(shell: command.shell, prompt: prompt, privileged: true)
    }

    static func osascript(shell: String, prompt: String, privileged: Bool) -> [String] {
        let run = privileged
            ? "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges"
            : "do shell script (item 1 of argv)"
        return ["/usr/bin/osascript", "-e", "on run argv", "-e", run, "-e", "end run", shell, prompt]
    }

    public static func wasCancelled(_ errorText: String) -> Bool {
        errorText.contains("(-128)")
    }
}
