import Foundation

extension DeckText {
    public static func downloadFailure(kind: String?, message: String, model: String, needed: Int64?, available: Int64?) -> String {
        let name = String(model.split(separator: ":").first ?? Substring(model))
        switch kind {
        case "disk":
            if let needed, let available {
                return text("download.failure.diskFigures \(disk(needed)) \(disk(max(0, needed - available)))")
            }
            return text("download.failure.disk")
        case "not_found": return text("download.failure.notFound \(name)")
        case "offline": return text("download.failure.offline")
        case "interrupted": return text("download.failure.interrupted")
        case "auth": return text("download.failure.auth \(name)")
        default: return text("download.failure.other \(message)")
        }
    }

    public static var downloadStoppedUnexpectedly: String { text("download.failure.unexpected") }
}
