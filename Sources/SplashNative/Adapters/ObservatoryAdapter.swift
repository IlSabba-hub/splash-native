import NativeCore
import NativeUI
import Foundation

@MainActor
enum ObservatoryAdapter {
    static func traffic(of server: ServerBoard.Server, in model: NativeModel) -> CapturedTraffic {
        let observation: ObservationState
        if let proxy = model.observatory.proxy(forSplashPort: server.port) {
            observation = .observed(listen: proxy.listenPort, splash: proxy.upstreamPort)
        } else if !server.managed {
            observation = .off(reason: tr("observe.off.outside"))
        } else if let listen = server.owned?.observedPort {
            observation = .off(reason: tr("observe.off.notOpen", NativeFormat.port(listen)))
        } else {
            observation = .off(reason: tr("observe.off.configuration"))
        }
        let recorder = model.observatory.recorder
        let listen = model.observatory.proxy(forSplashPort: server.port)?.listenPort
        return CapturedTraffic(observation: observation) {
            guard let listen else { return [] }
            return recorder.exchanges(port: listen).map(request)
        }
    }

    static func request(_ exchange: ObservedExchange) -> CapturedRequest {
        let state: CapturedRequest.State = switch exchange.state {
        case .running: .running
        case .finished: .finished
        case .failed: .failed
        }
        return CapturedRequest(
            id: exchange.id, started: exchange.startedAt, method: exchange.method, path: exchange.path, interpreted: exchange.interpreted,
            state: state, status: exchange.status, userAgent: exchange.userAgent, authorization: exchange.authorization,
            requestBytes: exchange.requestBytes,
            messages: exchange.messages.map {
                CapturedMessage(role: $0.role, characters: $0.characters, excerpt: $0.excerpt, media: $0.media, toolCalls: $0.toolCalls,
                                toolCallID: $0.toolCallID)
            },
            tools: exchange.tools, parameters: exchange.parameters.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
            reasoning: exchange.reasoning, content: exchange.content,
            toolCalls: exchange.toolCalls.map {
                ChatToolCallItem(id: $0.id, name: $0.name, arguments: ChatController.pretty($0.arguments), callID: $0.callID, answered: false)
            },
            finishReason: exchange.finishReason, ttftMs: exchange.ttftMs, durationMs: exchange.durationMs,
            promptTokens: exchange.promptTokens, cachedTokens: exchange.cachedTokens, completionTokens: exchange.completionTokens,
            tokensSource: exchange.tokensSource, tokensPerSecond: exchange.tokensPerSecond,
            engineTokensPerSecond: exchange.engineTokensPerSecond, error: exchange.error, truncated: exchange.truncated, raw: exchange.raw)
    }
}
