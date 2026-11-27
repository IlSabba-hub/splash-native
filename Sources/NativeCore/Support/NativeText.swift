import Foundation

public enum NativeText {
    nonisolated(unsafe) static var override: Bundle?

    public static func use(language: String?) {
        override = bundle(language: language)
    }

    static func bundle(language: String?) -> Bundle? {
        language.flatMap { Bundle.module.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:))
    }

    static func text(_ value: String.LocalizationValue, in bundle: Bundle? = nil) -> String {
        String(localized: value, bundle: bundle ?? override ?? .module, locale: locale)
    }

    public static var locale: Locale {
        let language = override.map { URL(filePath: $0.bundlePath).deletingPathExtension().lastPathComponent }
            ?? Bundle.module.preferredLocalizations.first ?? "en"
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: language)
        return Locale(components: components)
    }

    public static func bytes(_ count: UInt64, locale: Locale = NativeText.locale) -> String {
        Int64(clamping: count).formatted(.byteCount(style: .memory, spellsOutZero: false).locale(locale))
    }

    public static var unknownFamily: String { text("family.unknown") }

    public static func hubStatus(_ code: Int) -> String { text("hub.status \(String(code))") }

    public static func noEffect(family: String, needs: String?) -> String {
        guard let needs else { return text("family.noEffect \(family)") }
        return text("family.noEffect.needs \(family) \(needs)")
    }

    public static func kind(_ kind: InstallationKind, linked: Bool) -> String {
        switch kind {
        case .keg: linked ? text("installation.keg.linked") : text("installation.keg")
        case .archive: text("installation.archive")
        case .app: text("installation.app")
        case .checkout: text("installation.checkout")
        }
    }

    public static var sourceCheckout: String { text("installation.sourceVersion") }

    public static func problem(_ problem: ConfigurationProblem) -> String {
        switch problem {
        case .invalidName(let name): text("problem.invalidName \(name)")
        case .invalidPort(let port): text("problem.invalidPort \(String(port))")
        case .missingAPIModelID: text("problem.missingAPIModelID")
        case .noInstallation(let version): text("problem.noInstallation \(version ?? "—")")
        case .managedFlag(let flag): text("problem.managedFlag \(flag)")
        case .unknownFlag(let flag, let version): text("problem.unknownFlag \(flag) \(version)")
        case .notASwitch(let flag): text("problem.notASwitch \(flag)")
        case .notAList(let flag): text("problem.notAList \(flag)")
        case .emptyValue(let flag): text("problem.emptyValue \(flag)")
        case .notAChoice(let flag, let value, let choices): text("problem.notAChoice \(flag) \(value) \(choices.joined(separator: ", "))")
        case .secretInConfiguration(let flag): text("problem.secret \(flag)")
        case .observedPortOutOfRange(let port): text("problem.observedPort \(String(port))")
        }
    }

    public static func error(_ error: NativeError) -> String {
        switch error {
        case .emptyCommand: text("error.emptyCommand")
        case .commandFailed(let program, let status, let detail): text("error.commandFailed \(program) \(String(status)) \(detail)")
        case .timedOut(let program, let seconds): text("error.timedOut \(program) \(String(seconds))")
        case .httpStatus(let path, let status): text("error.httpStatus \(path) \(String(status))")
        case .splash(let message): text("error.splash \(message)")
        case .portBusy(let port, let pid?): text("error.portBusy.pid \(String(port)) \(String(pid))")
        case .portBusy(let port, nil): text("error.portBusy \(String(port))")
        case .overBudget(let excess): text("error.overBudget \(bytes(excess))")
        case .vanished(let pid): text("error.vanished \(String(pid))")
        case .consentMismatch: text("error.consentMismatch")
        case .budgetUnknown: text("error.budgetUnknown")
        case .unlimitedNeighbours(let names): text("error.unlimitedNeighbours \(names.joined(separator: ", "))")
        case .memoryProbeBusy: text("error.memoryProbeBusy")
        case .memoryProbeUnknownModel: text("error.memoryProbeUnknownModel")
        case .memoryProbeRunning(let name): text("error.memoryProbeRunning \(name)")
        }
    }
}

public enum NativeError: Error, LocalizedError, Sendable, Equatable {
    case emptyCommand
    case commandFailed(program: String, status: Int32, detail: String)
    case timedOut(program: String, seconds: Int)
    case httpStatus(path: String, status: Int)
    case splash(String)
    case portBusy(port: Int, pid: Int32?)
    case overBudget(excess: UInt64)
    case vanished(pid: Int32)
    case consentMismatch
    case budgetUnknown
    case unlimitedNeighbours(names: [String])
    case memoryProbeBusy
    case memoryProbeUnknownModel
    case memoryProbeRunning(configuration: String)

    public var errorDescription: String? { NativeText.error(self) }
}

enum NativeTextBundle {
    static var bundle: Bundle { .module }
}
