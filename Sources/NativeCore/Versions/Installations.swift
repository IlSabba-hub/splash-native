import Foundation

public enum InstallationKind: String, Codable, Sendable, CaseIterable {
    case keg
    case archive
    case app
    case checkout
}

public struct SplashInstallation: Codable, Sendable, Hashable, Identifiable {
    public let kind: InstallationKind
    public let root: URL
    public let version: String?
    public let linked: Bool

    public var id: String { root.path }

    public init(kind: InstallationKind, root: URL, version: String?, linked: Bool = false) {
        self.kind = kind
        self.root = root
        self.version = version
        self.linked = linked
    }

    var runtime: Runtime { Runtime(root: root) }

    public var python: URL { runtime.python }

    public func command(_ arguments: [String]) -> [String] { runtime.command(arguments) }

    public var serveRecords: URL { runtime.locks }

    public var models: URL { runtime.models }

    public var label: String {
        "\(version ?? NativeText.sourceCheckout) (\(NativeText.kind(kind, linked: linked)))"
    }
}

public struct InstallationLocations: Sendable {
    public var cellar: URL
    public var opt: URL
    public var archives: URL
    public var apps: [URL]
    public var checkouts: [URL]

    public init(cellar: URL = URL(filePath: "/opt/homebrew/Cellar/splash"),
                opt: URL = URL(filePath: "/opt/homebrew/opt/splash"),
                archives: URL = URL.applicationSupportDirectory.appending(path: "Splash/app"),
                apps: [URL] = [URL(filePath: "/Applications/Splash.app"), URL.homeDirectory.appending(path: "Applications/Splash.app")],
                checkouts: [URL] = []) {
        self.cellar = cellar
        self.opt = opt
        self.archives = archives
        self.apps = apps
        self.checkouts = checkouts
    }
}

public enum InstallationScanner {
    public static func scan(_ locations: InstallationLocations = InstallationLocations()) -> [SplashInstallation] {
        let manager = FileManager.default
        let linkedRoot = SplashRole.canonical(locations.opt.appending(path: "libexec").resolvingSymlinksInPath())
        var found: [SplashInstallation] = []

        func release(_ root: URL, _ kind: InstallationKind, linked: Bool = false) {
            let root = SplashRole.canonical(root.resolvingSymlinksInPath())
            guard manager.fileExists(atPath: root.appending(path: "install/launcher.py").path),
                  manager.fileExists(atPath: root.appending(path: "python/bin/python3").path),
                  let version = ReleaseFile.version(in: root),
                  !found.contains(where: { $0.root == root })
            else { return }
            found.append(SplashInstallation(kind: kind, root: root, version: version, linked: linked))
        }

        for keg in children(of: locations.cellar) {
            let root = SplashRole.canonical(keg.appending(path: "libexec").resolvingSymlinksInPath())
            release(root, .keg, linked: root == linkedRoot)
        }
        for archive in children(of: locations.archives) where archive.lastPathComponent != "current" {
            release(archive, .archive)
        }
        for app in locations.apps {
            release(app.appending(path: "Contents/Resources/splash"), .app)
        }
        for checkout in locations.checkouts {
            let root = SplashRole.canonical(checkout.resolvingSymlinksInPath())
            guard manager.fileExists(atPath: root.appending(path: "install/launcher.py").path),
                  !manager.fileExists(atPath: root.appending(path: "release.json").path),
                  manager.fileExists(atPath: root.appending(path: ".venv/bin/python").path),
                  manager.fileExists(atPath: root.appending(path: "build/splash").path)
            else { continue }
            found.append(SplashInstallation(kind: .checkout, root: root, version: nil))
        }
        return found.sorted { a, b in
            switch (a.version, b.version) {
            case let (x?, y?) where x != y: return SplashVersion(x) > SplashVersion(y)
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let order = InstallationKind.allCases
                let (x, y) = (order.firstIndex(of: a.kind)!, order.firstIndex(of: b.kind)!)
                return x != y ? x < y : a.root.path < b.root.path
            }
        }
    }

    private static func children(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    public static func reportedVersion(_ installation: SplashInstallation) async throws -> String {
        let result = try await Command.run(installation.command(["--version"]), timeout: .seconds(30))
        guard result.status == 0 else {
            throw NativeError.commandFailed(program: "launcher.py --version", status: result.status, detail: result.errorText)
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SplashVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let text: String
    let parts: [Int]

    public init(_ text: String) {
        self.text = text
        parts = text.split(separator: ".").map { Int($0) ?? 0 }
    }

    public var description: String { text }

    public static func < (a: SplashVersion, b: SplashVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let x = index < a.parts.count ? a.parts[index] : 0
            let y = index < b.parts.count ? b.parts[index] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: SplashVersion, b: SplashVersion) -> Bool { !(a < b) && !(b < a) }

    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}
