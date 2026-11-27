import Foundation

public struct ChatServer: Sendable, Equatable, Hashable, Identifiable {
    public enum Origin: Sendable, Equatable, Hashable {
        case owned(configuration: String)
        case outside(splashApp: Bool)
    }

    public let origin: Origin
    public let splashPort: Int
    public let chatPort: Int
    public let pid: Int32
    public let version: String?
    public let model: String?

    public var id: Int { splashPort }
    public var observed: Bool { chatPort != splashPort }
}

public struct ChatServerFacts: Sendable, Equatable {
    public let model: ChatModelInfo
    public let reasoningSwitch: Bool?
    public let serverEffort: String?
    public let maximumContextTokens: Int?

    public var promptSwitchesReasoning: Bool? {
        guard let reasoningSwitch, serverEffort == nil else { return nil }
        return reasoningSwitch
    }

    public var thinkingBudgetHasNoEffect: Bool { promptSwitchesReasoning == false }

    public init(model: ChatModelInfo, reasoningSwitch: Bool?, serverEffort: String?, maximumContextTokens: Int? = nil) {
        self.model = model
        self.reasoningSwitch = reasoningSwitch
        self.serverEffort = serverEffort
        self.maximumContextTokens = maximumContextTokens
    }

    public static func read(port: Int, apiKey: String? = nil, session: URLSession = .shared) async throws -> ChatServerFacts {
        let model = try await ChatModelInfo.read(port: port, apiKey: apiKey, session: session)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/status")!)
        request.timeoutInterval = 3
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        struct Status: Decodable { let reasoning_switch: Bool?; let reasoning_effort: String?; let maximum_context_tokens: Int? }
        let status = try? await session.data(for: request).0
        let decoded = status.flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
        return ChatServerFacts(model: model, reasoningSwitch: decoded?.reasoning_switch, serverEffort: decoded?.reasoning_effort,
                               maximumContextTokens: decoded?.maximum_context_tokens)
    }
}

extension DeckModel {
    public var chatServers: [ChatServer] {
        let owned = supervisor.alive.map { server in
            ChatServer(origin: .owned(configuration: server.configuration), splashPort: server.port,
                       chatPort: server.observedPort.flatMap { observatory.proxies[$0] != nil ? $0 : nil } ?? server.port,
                       pid: server.pid, version: server.version, model: configurations.first { $0.name == server.configuration }?.model)
        }
        let outside = found.map { server in
            ChatServer(origin: .outside(splashApp: server.startedBySplashApp), splashPort: server.port, chatPort: server.port,
                       pid: server.pid, version: server.version, model: server.model)
        }
        return (owned + outside).sorted { $0.splashPort < $1.splashPort }
    }
}
