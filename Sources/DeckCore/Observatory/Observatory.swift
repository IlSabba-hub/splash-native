import Foundation

@MainActor
public final class Observatory {
    public let recorder: TrafficRecorder
    public private(set) var proxies: [Int: ObservationProxy] = [:]

    public init(recorder: TrafficRecorder = TrafficRecorder()) {
        self.recorder = recorder
    }

    @discardableResult
    public func open(listen: Int, upstream: Int, observe: Bool = true) async throws -> ObservationProxy {
        if let open = proxies[listen] { return open }
        let proxy = try await ObservationProxy.start(listen: listen, upstream: upstream, recorder: recorder, observe: observe)
        proxies[listen] = proxy
        return proxy
    }

    public func close(listen: Int) {
        proxies.removeValue(forKey: listen)?.close()
    }

    public func proxy(forSplashPort splashPort: Int) -> ObservationProxy? {
        proxies.values.first { $0.upstreamPort == splashPort }
    }
}
