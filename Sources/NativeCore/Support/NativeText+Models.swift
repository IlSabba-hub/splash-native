import Foundation

extension NativeText {
    public static func disk(_ count: Int64, locale: Locale = NativeText.locale) -> String {
        count.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    public static func removalRefusal(_ refusal: RemovalRefusal) -> String {
        switch refusal {
        case .localFiles: text("removal.localFiles")
        case .package: text("removal.package")
        case .broken: text("removal.broken")
        case .optionsSelection: text("removal.optionsSelection")
        case .wouldFreeFiles(let count, let bytes): text("removal.wouldFreeFiles \(String(count)) \(disk(bytes))")
        case .held: text("removal.held")
        case .otherUnlinked(let count): text("removal.otherUnlinked \(String(count))")
        }
    }

    public static var deletionChanged: String { text("deletion.changed") }
    public static var deletionCancelled: String { text("deletion.cancelled") }
    public static func deletionAuthUnavailable(_ reason: String) -> String { text("deletion.authUnavailable \(reason)") }
    public static func deletionAuthFailed(_ reason: String) -> String { text("deletion.authFailed \(reason)") }
    public static func deletionTrashFailed(_ path: String, _ reason: String) -> String { text("deletion.trashFailed \(path) \(reason)") }
    public static func deletionConfigurationFailed(_ name: String, _ reason: String) -> String {
        text("deletion.configurationFailed \(name) \(reason)")
    }
    public static func deletionCommit(_ configuration: String, _ model: String) -> String {
        text("deletion.commit \(configuration) \(model)")
    }
}
