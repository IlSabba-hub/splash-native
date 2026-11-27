import Foundation

public struct ActiveServerSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let port: Int
    public let status: StatusKind
    public let statusDetail: String?
    public let managed: Bool
    public let version: Measured<String>
    public let memory: Measured<Int64>
    public let weightsReleased: Bool

    public init(id: String, name: String, port: Int, status: StatusKind, statusDetail: String? = nil, managed: Bool,
                version: Measured<String>, memory: Measured<Int64>, weightsReleased: Bool = false) {
        self.id = id
        self.name = name
        self.port = port
        self.status = status
        self.statusDetail = statusDetail
        self.managed = managed
        self.version = version
        self.memory = memory
        self.weightsReleased = weightsReleased
    }
}

public struct ActiveRequestSummary: Sendable, Equatable, Identifiable {
    public enum Phase: Sendable, Equatable {
        case queued, prefill, decode
        case other(String)

        public init(_ splash: String?) {
            switch splash {
            case "queued": self = .queued
            case "prefill": self = .prefill
            case "decode": self = .decode
            case let text?: self = .other(text)
            case nil: self = .other("")
            }
        }

        public var title: String {
            switch self {
            case .queued: tr("request.phase.queued")
            case .prefill: tr("request.phase.prefill")
            case .decode: tr("request.phase.decode")
            case let .other(text): text.isEmpty ? tr("value.unavailable") : text
            }
        }
    }

    public var id: String { "\(server)#\(request)" }
    public let server: String
    public let request: Int
    public let phase: Phase
    public let promptProcessed: Int?
    public let promptTokens: Int?
    public let generated: Int?
    public let maximumNew: Int?
    public let ageSeconds: Double?

    public init(server: String, request: Int, phase: Phase, promptProcessed: Int?, promptTokens: Int?, generated: Int?,
                maximumNew: Int?, ageSeconds: Double?) {
        self.server = server
        self.request = request
        self.phase = phase
        self.promptProcessed = promptProcessed
        self.promptTokens = promptTokens
        self.generated = generated
        self.maximumNew = maximumNew
        self.ageSeconds = ageSeconds
    }
}

public struct RequestCounts: Sendable, Equatable, Identifiable {
    public var id: String { server }
    public let server: String
    public let queued: Measured<Int>
    public let completed: Measured<Int>
    public let failed: Measured<Int>

    public init(server: String, queued: Measured<Int>, completed: Measured<Int>, failed: Measured<Int>) {
        self.server = server
        self.queued = queued
        self.completed = completed
        self.failed = failed
    }
}

public struct RequestsOverview: Sendable, Equatable {
    public let requests: [ActiveRequestSummary]
    public let counts: [RequestCounts]

    public init(requests: [ActiveRequestSummary], counts: [RequestCounts]) {
        self.requests = requests
        self.counts = counts
    }
}

public struct HermesSummary: Sendable, Equatable {
    public enum Serving: Sendable, Equatable {
        case servedBy(server: String)
        case modelNotServed(server: String, served: [String])
        case modelsUnknown(server: String, reason: String)
        case nobodyOnPort(port: Int)
        case notLocal

        public var text: String {
            switch self {
            case let .servedBy(server): tr("hermes.servedBy", server)
            case let .modelNotServed(server, served): tr("hermes.modelNotServed", server, served.joined(separator: ", "))
            case let .modelsUnknown(server, _): tr("hermes.modelsUnknown", server)
            case let .nobodyOnPort(port): tr("hermes.nobodyOnPort", DeckFormat.port(port))
            case .notLocal: tr("hermes.notLocal")
            }
        }
    }

    public let model: Measured<String>
    public let endpoint: Measured<String>
    public let serving: Serving?
    public let modelProvenance: Provenance
    public let endpointProvenance: Provenance

    public init(model: Measured<String>, endpoint: Measured<String>, serving: Serving?, modelProvenance: Provenance,
                endpointProvenance: Provenance) {
        self.model = model
        self.endpoint = endpoint
        self.serving = serving
        self.modelProvenance = modelProvenance
        self.endpointProvenance = endpointProvenance
    }
}
