import Foundation

extension NativeText {
    static func chatFailure(_ failure: ChatFailure) -> String {
        switch failure {
        case let .refused(status, _, message?): text("chat.failure.refused \(String(status)) \(message)")
        case let .refused(status, _, nil): text("chat.failure.refusedNoMessage \(String(status))")
        case let .server(message): text("chat.failure.server \(message)")
        case .closedEarly: text("chat.failure.closedEarly")
        case let .unreachable(detail): text("chat.failure.unreachable \(detail)")
        case .toolsNotAnArray: text("chat.failure.tools")
        case let .invalidFields(fields): text("chat.failure.fields \(fields.map(\.rawValue).joined(separator: ", "))")
        }
    }

    static var chatCut: String { text("chat.failure.cut") }
}

extension NativeText {
    static func proxyUnreachable(port: Int, detail: String) -> String { text("observe.unreachable \(String(port)) \(detail)") }
    static var proxyBodyOver: String { text("observe.bodyOver") }
    static var proxyCut: String { text("observe.cut") }
    static var proxyNoResponse: String { text("observe.noResponse") }
}
