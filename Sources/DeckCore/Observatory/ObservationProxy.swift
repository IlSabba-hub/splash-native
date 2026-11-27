import Foundation
import Network
import Synchronization

public final class ObservationProxy: Sendable {
    public var listenPort: Int { listener.port.map { Int($0.rawValue) } ?? requestedPort }
    private let requestedPort: Int
    public let upstreamPort: Int
    public let observe: Bool
    private let listener: NWListener
    private let recorder: TrafficRecorder
    private let queue: DispatchQueue
    private let open = Mutex(0)

    public static let chunk = 64 << 10

    public static func upstreamPort(for port: Int) -> Int { port + 10_000 }

    private init(listen: Int, upstream: Int, observe: Bool, recorder: TrafficRecorder, listener: NWListener) {
        requestedPort = listen
        upstreamPort = upstream
        self.observe = observe
        self.recorder = recorder
        self.listener = listener
        queue = DispatchQueue(label: "SplashDeck.proxy.\(listen)")
    }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = false
        return parameters
    }

    public static func start(listen: Int, upstream: Int, recorder: TrafficRecorder, observe: Bool = true) async throws -> ObservationProxy {
        let parameters = parameters()
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(listen))!)
        let listener = try NWListener(using: parameters)
        let proxy = ObservationProxy(listen: listen, upstream: upstream, observe: observe, recorder: recorder, listener: listener)
        listener.newConnectionHandler = { [weak proxy] connection in
            guard let proxy else { return connection.cancel() }
            proxy.serve(connection)
        }
        let started = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                let resume: Result<Void, Error>? = switch state {
                case .ready: .success(())
                case .failed(let error), .waiting(let error): .failure(error)
                case .cancelled: .failure(DeckError.portBusy(port: listen, pid: nil))
                default: nil
                }
                guard let resume, started.withLock({ was in defer { was = true }; return !was }) else { return }
                if case .failure = resume { listener.cancel() }
                continuation.resume(with: resume)
            }
            listener.start(queue: proxy.queue)
        }
        return proxy
    }

    public func close() {
        listener.cancel()
    }

    public var connections: Int { open.withLock { $0 } }

    private func serve(_ client: NWConnection) {
        let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(upstreamPort))!, using: Self.parameters())
        let connectionQueue = DispatchQueue(label: "SplashDeck.proxy.\(listenPort).connection", target: queue)
        let link = Link(client: client, upstream: upstream, recorder: recorder, port: listenPort, upstreamPort: upstreamPort, observe: observe)
        open.withLock { $0 += 1 }
        link.onEnd = { [weak self] in self?.open.withLock { $0 -= 1 } }
        upstream.stateUpdateHandler = { state in
            switch state {
            case .ready: link.upstreamReady()
            case .waiting(let error), .failed(let error): link.upstreamFailed(error)
            default: break
            }
        }
        client.start(queue: connectionQueue)
        upstream.start(queue: connectionQueue)
    }
}

private final class Link: @unchecked Sendable {
    let client: NWConnection
    let upstream: NWConnection
    let recorder: TrafficRecorder
    let port: Int
    let upstreamPort: Int
    let observe: Bool
    var onEnd: (() -> Void)?
    private var started = false
    private var closedDirections = 0
    private var finished = false
    private var request = RequestTap()
    private var response = ResponseTap()
    private var pending: [(id: UInt64?, method: String)] = []

    init(client: NWConnection, upstream: NWConnection, recorder: TrafficRecorder, port: Int, upstreamPort: Int, observe: Bool) {
        self.client = client
        self.upstream = upstream
        self.recorder = recorder
        self.port = port
        self.upstreamPort = upstreamPort
        self.observe = observe
    }

    func upstreamReady() {
        guard !started else { return }
        started = true
        pump(from: client, to: upstream, clientSide: true)
        pump(from: upstream, to: client, clientSide: false)
    }

    func upstreamFailed(_ error: NWError) {
        guard !finished else { return }
        if !started, observe {
            let id = recorder.begin(port: port, method: "—", path: "—", authorization: nil, userAgent: nil, at: .now)
            recorder.finish(id, error: DeckText.proxyUnreachable(port: upstreamPort, detail: error.localizedDescription),
                            at: .now)
        }
        end()
    }

    private func end() {
        guard !finished else { return }
        finished = true
        upstream.stateUpdateHandler = nil
        client.cancel()
        upstream.cancel()
        if observe {
            let now = ContinuousClock.now
            response.close(recorder: recorder, pending: &pending, at: now)
        }
        onEnd?()
    }

    private func pump(from source: NWConnection, to destination: NWConnection, clientSide: Bool) {
        source.receive(minimumIncompleteLength: 1, maximumLength: ObservationProxy.chunk) { [self] data, _, complete, error in
            if let data, !data.isEmpty {
                let bytes = [UInt8](data)
                let now = ContinuousClock.now
                if observe, clientSide { request.before(bytes, at: now, link: self) }
                destination.send(content: data, completion: .contentProcessed { [self] sendError in
                    if sendError != nil { return end() }
                    if observe {
                        if clientSide { request.after(recorder: recorder) } else { response.after(bytes, at: now, link: self) }
                    }
                    if complete { halfClose(destination) } else { pump(from: source, to: destination, clientSide: clientSide) }
                })
            } else if complete {
                halfClose(destination)
            } else if error != nil {
                end()
            } else {
                pump(from: source, to: destination, clientSide: clientSide)
            }
        }
    }

    private func halfClose(_ destination: NWConnection) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        closedDirections += 1
        if closedDirections == 2 { end() }
    }

    struct RequestTap {
        var framer = HTTPTap.Framer()
        var t0: ContinuousClock.Instant?
        var current: UInt64?
        var body: [UInt8] = []
        var total: UInt64 = 0
        var over = false
        var ready: [(UInt64, [UInt8]?, UInt64)] = []

        mutating func before(_ bytes: [UInt8], at now: ContinuousClock.Instant, link: Link) {
            guard !framer.stopped else { return }
            if framer.inHead, t0 == nil { t0 = now }
            var events: [HTTPTap.Event] = []
            framer.feed(bytes, decide: HTTPTap.requestFraming) { events.append($0) }
            for event in events {
                switch event {
                case .head(let head):
                    let method = head.start[0]
                    var id: UInt64?
                    if method.uppercased() == "POST" {
                        id = link.recorder.begin(port: link.port, method: method, path: head.start[1], authorization: head.value("authorization"),
                                                 userAgent: head.value("user-agent"), at: t0 ?? now)
                    }
                    t0 = nil
                    current = id
                    body = []
                    total = 0
                    over = false
                    link.pending.append((id, method))
                case .body(let chunk):
                    total += UInt64(chunk.count)
                    if current != nil, !over {
                        if body.count + chunk.count > TrafficRecorder.maxBody { over = true; body = [] } else { body += chunk }
                    }
                case .end:
                    if let id = current {
                        ready.append((id, over ? nil : body, total))
                        current = nil
                    }
                }
            }
        }

        mutating func after(recorder: TrafficRecorder) {
            for (id, body, total) in ready { recorder.request(id, body: body, total: total) }
            ready = []
        }
    }

    struct ResponseTap {
        var framer = HTTPTap.Framer()
        var current: (id: UInt64, interpreted: Bool)?
        var sse: HTTPTap.SSEParser?
        var body: [UInt8] = []
        var over = false

        mutating func after(_ bytes: [UInt8], at now: ContinuousClock.Instant, link: Link) {
            guard !framer.stopped else { return }
            var events: [HTTPTap.Event] = []
            var answered = 0
            let pending = link.pending
            framer.feed(bytes, decide: { head in
                let framing = HTTPTap.responseFraming(head, method: pending.dropFirst(answered).first?.method ?? "")
                if case .interim = framing {} else { answered += 1 }
                return framing
            }) { events.append($0) }
            for event in events {
                switch event {
                case .head(let head):
                    let status = head.status ?? 0
                    if (100...199).contains(status), status != 101 { continue }
                    let id = link.pending.isEmpty ? nil : link.pending.removeFirst().id
                    current = nil
                    sse = nil
                    body = []
                    over = false
                    if let id {
                        let type = head.value("content-type")
                        link.recorder.responseHead(id, status: status, contentType: type)
                        let interpreted = link.recorder.interpreted(id)
                        if interpreted, type?.contains("text/event-stream") == true { sse = HTTPTap.SSEParser() }
                        current = (id, interpreted)
                    }
                case .body(let chunk):
                    guard let current else { continue }
                    if sse != nil {
                        var out: [String] = []
                        sse!.feed(chunk, into: &out)
                        Self.events(out, id: current.id, recorder: link.recorder, at: now)
                    } else if !current.interpreted {
                        link.recorder.raw(current.id, chunk)
                    } else if !over {
                        if body.count + chunk.count > TrafficRecorder.maxBody { over = true; body = [] } else { body += chunk }
                    }
                case .end:
                    complete(recorder: link.recorder, error: nil, at: now)
                }
            }
        }

        static func events(_ list: [String], id: UInt64, recorder: TrafficRecorder, at now: ContinuousClock.Instant) {
            for data in list {
                let payload = data.trimmingCharacters(in: .whitespaces)
                if payload.isEmpty || payload == "[DONE]" { continue }
                if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) {
                    recorder.piece(id, .from(value), at: now)
                } else {
                    recorder.raw(id, Array((payload + "\n").utf8))
                }
            }
        }

        mutating func complete(recorder: TrafficRecorder, error: String?, at now: ContinuousClock.Instant) {
            guard let current else { return }
            if sse != nil {
                var out: [String] = []
                sse!.finish(into: &out)
                Self.events(out, id: current.id, recorder: recorder, at: now)
            } else if current.interpreted, !body.isEmpty {
                if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(body)) {
                    recorder.piece(current.id, .from(value), at: now)
                } else {
                    recorder.raw(current.id, body)
                }
            } else if current.interpreted, over {
                recorder.raw(current.id, Array(DeckText.proxyBodyOver.utf8))
            }
            body = []
            sse = nil
            recorder.finish(current.id, error: error, at: now)
            self.current = nil
        }

        mutating func close(recorder: TrafficRecorder, pending: inout [(id: UInt64?, method: String)], at now: ContinuousClock.Instant) {
            var ended = false
            _ = framer.close { if $0 == .end { ended = true } }
            if ended { complete(recorder: recorder, error: nil, at: now) }
            else if current != nil { complete(recorder: recorder, error: DeckText.proxyCut, at: now) }
            for request in pending { if let id = request.id { recorder.finish(id, error: DeckText.proxyNoResponse, at: now) } }
            pending = []
        }
    }
}
