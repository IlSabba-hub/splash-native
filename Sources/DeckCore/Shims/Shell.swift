import Foundation

struct Shell {
    let path: String
    let arguments: [String]
    let name: String

    static var login: Shell {
        let named = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
        return login(named, environment: ProcessInfo.processInfo.environment)
    }

    static func login(_ path: String?, environment: [String: String]) -> Shell {
        let path = path ?? environment["SHELL"] ?? "/bin/zsh"
        return Shell(path: path, arguments: [], name: "-" + (path as NSString).lastPathComponent)
    }
}
