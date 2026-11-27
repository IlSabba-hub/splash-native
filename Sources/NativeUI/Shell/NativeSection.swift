import Foundation

public enum NativeSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case chat
    case servers
    case models
    case discover
    case system
    case versions

    public var id: String { rawValue }

    public enum RailGroup: Sendable { case top, bottom }

    public var railGroup: RailGroup {
        switch self {
        case .chat, .servers, .models, .discover: .top
        case .system, .versions: .bottom
        }
    }

    public var title: String {
        switch self {
        case .chat: tr("section.chat")
        case .servers: tr("section.servers")
        case .models: tr("section.models")
        case .discover: tr("section.discover")
        case .system: tr("section.system")
        case .versions: tr("section.versions")
        }
    }

    public var symbol: String {
        switch self {
        case .chat: "bubble.left"
        case .servers: "terminal"
        case .models: "folder"
        case .discover: "magnifyingglass"
        case .system: "memorychip"
        case .versions: "shippingbox"
        }
    }
}

public enum NativePreferences {
    public static let menuBarExtraShown = "menuBarExtraShown"
    public static let modelPort = "modelPort"
    public static let swapWithoutAsking = "swapWithoutAsking"
    public static let memoryAutoProbe = "memoryAutoProbe"
    public static let defaultModelPort = 8000
}

public enum NativeScene {
    public static let main = "main"
}
