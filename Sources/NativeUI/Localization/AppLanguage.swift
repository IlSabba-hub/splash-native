import AppKit
import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case italian = "it"
    case english = "en"

    public var id: String { rawValue }

    static let key = "AppleLanguages"

    public var title: String {
        switch self {
        case .system: tr("settings.language.system")
        case .italian: tr("settings.language.italian")
        case .english: tr("settings.language.english")
        }
    }

    public static func systemLanguages(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String] ?? []
    }

    public static func stored(_ defaults: UserDefaults = .standard, domain: String = appDomain) -> AppLanguage {
        guard let languages = defaults.persistentDomain(forName: domain)?[key] as? [String], let first = languages.first else { return .system }
        return Self.of(first) ?? .system
    }

    static func of(_ code: String) -> AppLanguage? {
        switch Locale.Language(identifier: code).languageCode?.identifier {
        case "it": .italian
        case "en": .english
        default: nil
        }
    }

    public static func suggestion(stored: AppLanguage, system: [String]) -> AppLanguage? {
        guard stored == .system, system.count >= 2, of(system[0]) != .italian, of(system[1]) == .italian else { return nil }
        return .italian
    }

    public static func store(_ choice: AppLanguage, in defaults: UserDefaults = .standard) {
        switch choice {
        case .system: defaults.removeObject(forKey: key)
        case .italian, .english: defaults.set([choice.rawValue], forKey: key)
        }
    }

    public static var appDomain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    public static var displayed: String { Strings.language }

    @MainActor public private(set) static var atLaunch: AppLanguage?

    @MainActor public static func markLaunch() {
        atLaunch = stored()
    }

    public static func effective(_ choice: AppLanguage, system: [String]) -> AppLanguage {
        guard choice == .system else { return choice }
        return system.lazy.compactMap(of).first ?? .english
    }

    @MainActor public static func needsRelaunch(_ choice: AppLanguage) -> Bool {
        guard let atLaunch else { return false }
        let system = systemLanguages()
        return effective(choice, system: system) != effective(atLaunch, system: system)
    }

    public static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    @MainActor public static func relaunch() {
        guard canRelaunch else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "i=0; while /bin/kill -0 \(pid) 2>/dev/null; do i=$((i+1)); [ $i -gt 100 ] && exit 0; /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, Bundle.main.bundleURL.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
        }
    }
}
