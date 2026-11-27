import Foundation

public enum SplashUpgrade {
    public static let formula = "incoai/tap/splash"
    public static let brew = URL(filePath: "/opt/homebrew/bin/brew")

    public enum Action: String, Sendable, Equatable {
        case install, upgrade
    }

    public static func action(for installations: [SplashInstallation]) -> Action {
        installations.contains { $0.kind == .keg } ? .upgrade : .install
    }

    public static func command(_ action: Action) -> [String] {
        [brew.path, action.rawValue, formula]
    }

    public static func display(_ action: Action) -> String {
        (["brew"] + command(action).dropFirst()).joined(separator: " ")
    }

    public static func environment(from process: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = process.filter { $0.key.hasPrefix("HOMEBREW_") }
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] { environment[key] = process[key] }
        environment["HOME"] = environment["HOME"] ?? URL.homeDirectory.path
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }

    public struct Outcome: Sendable, Equatable {
        public let status: Int32
        public let output: String
    }

    public static func run(_ action: Action) async throws -> Outcome {
        let result = try await Command.run(command(action), environment: environment(), timeout: .seconds(1800))
        let text = [result.text, result.errorText].filter { !$0.isEmpty }.joined(separator: "\n")
        return Outcome(status: result.status, output: text)
    }

    public static func tapFormulaDate(_ tap: URL = AvailableVersions.tap) -> Date? {
        try? tap.appending(path: "Formula/splash.rb").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    public static func newer(than installations: [SplashInstallation], offers: [AvailableVersions.Offer]) -> String? {
        let installed = installations.compactMap(\.version).map(SplashVersion.init).max()
        guard let best = offers.filter({ !$0.prerelease }).map({ SplashVersion($0.version) }).max() else { return nil }
        guard let installed else { return best.text }
        return best > installed ? best.text : nil
    }
}
