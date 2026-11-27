import Foundation

public struct ServerReading: Sendable, Equatable {
    public let snapshot: StatusSnapshot
    public let detail: StatusDetail
    public let resources: ResourceStatus?
    public let at: Date
    public let plan: SplashPlanReading?
    public let expertsStreamed: Bool
    public let streaming: StreamingStatus

    public init(snapshot: StatusSnapshot, detail: StatusDetail, resources: ResourceStatus? = nil, at: Date,
                plan: SplashPlanReading? = nil, expertsStreamed: Bool = false, streaming: StreamingStatus = StreamingStatus()) {
        self.streaming = streaming
        self.snapshot = snapshot
        self.detail = detail
        self.resources = resources
        self.at = at
        self.plan = plan
        self.expertsStreamed = expertsStreamed
    }

    public static func decode(_ data: Data, at: Date = .now) throws -> ServerReading {
        let decoder = JSONDecoder()
        return ServerReading(snapshot: try decoder.decode(StatusSnapshot.self, from: data),
                             detail: try decoder.decode(StatusDetail.self, from: data),
                             resources: try? ResourceStatus.decode(data), at: at, plan: SplashPlanReading(status: data),
                             expertsStreamed: ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                                .map { $0["streamed_experts"].map { !($0 is NSNull) } ?? false } ?? false,
                             streaming: StreamingStatus.decode(data))
    }
}

public struct StatusDetail: Decodable, Sendable, Equatable {
    public struct ActiveRequest: Decodable, Sendable, Equatable, Identifiable {
        public let id: Int
        public let phase: String?
        public let priority: String?
        public let promptTokens: Int?
        public let promptProcessed: Int?
        public let generatedTokens: Int?
        public let maxNewTokens: Int?
        public let ageMilliseconds: Double?

        enum CodingKeys: String, CodingKey {
            case id, phase, priority, promptTokens = "prompt_tokens", promptProcessed = "prompt_processed"
            case generatedTokens = "generated_tokens", maxNewTokens = "max_new_tokens", ageMilliseconds = "age_ms"
        }
    }

    public struct Scheduler: Decodable, Sendable, Equatable {
        public let queued: Int?
        public let waitingResources: Int?
        public let prefilling: Int?
        public let decoding: Int?

        enum CodingKeys: String, CodingKey {
            case queued, waitingResources = "waiting_resources", prefilling, decoding
        }
    }

    public struct Requests: Decodable, Sendable, Equatable {
        public let submitted: Int?
        public let completed: Int?
        public let cancelled: Int?
        public let failed: Int?
    }

    public struct Metrics: Decodable, Sendable, Equatable {
        public let ttftMedianMilliseconds: Double?
        public let prefillTokensPerSecond: Double?
        public let decodeTokensPerSecond: Double?
        public let draftAcceptanceRate: Double?

        enum CodingKeys: String, CodingKey {
            case ttft = "ttft_ms", prefill = "prefill_tokens_per_second", decode = "decode_tokens_per_second"
            case acceptance = "draft_acceptance_rate"
        }

        private struct Percentiles: Decodable { let p50: Double? }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ttftMedianMilliseconds = try container.decodeIfPresent(Percentiles.self, forKey: .ttft)?.p50
            prefillTokensPerSecond = try container.decodeIfPresent(Double.self, forKey: .prefill)
            decodeTokensPerSecond = try container.decodeIfPresent(Double.self, forKey: .decode)
            draftAcceptanceRate = try container.decodeIfPresent(Double.self, forKey: .acceptance)
        }
    }

    public struct Disk: Decodable, Sendable, Equatable {
        public let limitBytes: Int64?
        public let usedBytes: Int64?
        public let writtenBytes: Int64?
        public let writtenLastDayBytes: Int64?
        public let persistent: Bool?
        public let offReason: String?
        public let takenBackBytes: Int64?

        enum CodingKeys: String, CodingKey {
            case limitBytes = "limit_bytes", usedBytes = "used_bytes", writtenBytes = "written_bytes"
            case writtenLastDayBytes = "written_last_day_bytes", persistent, offReason = "off_reason", takenBack = "taken_back"
        }

        private struct TakenBack: Decodable { let bytes: Int64? }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limitBytes = try container.decodeIfPresent(Int64.self, forKey: .limitBytes)
            usedBytes = try container.decodeIfPresent(Int64.self, forKey: .usedBytes)
            writtenBytes = try container.decodeIfPresent(Int64.self, forKey: .writtenBytes)
            writtenLastDayBytes = try container.decodeIfPresent(Int64.self, forKey: .writtenLastDayBytes)
            persistent = try container.decodeIfPresent(Bool.self, forKey: .persistent)
            offReason = try container.decodeIfPresent(String.self, forKey: .offReason)
            takenBackBytes = try container.decodeIfPresent(TakenBack.self, forKey: .takenBack)?.bytes
        }
    }

    public let maximumContextTokens: Int?
    public let memoryPressure: String?
    public let thermalState: String?
    public let governorLimitBytes: Int64?
    public let footprintBytes: Int64?
    public let restoreFailures: Int?
    public let kvFormat: String?
    public let verifyRows: String?
    public let vision: Bool?
    public let activeRequests: [ActiveRequest]
    public let scheduler: Scheduler?
    public let requests: Requests?
    public let metrics: Metrics?
    public let disk: Disk?

    enum CodingKeys: String, CodingKey {
        case maximumContextTokens = "maximum_context_tokens", memoryPressure = "memory_pressure", thermalState = "thermal_state"
        case governor = "memory_governor", weights, identity, verifyRows = "verify_rows", vision
        case activeRequests = "active_requests", scheduler, requests, metrics, disk
    }

    private struct Governor: Decodable {
        struct Telemetry: Decodable {
            let footprint: Int64?
            enum CodingKeys: String, CodingKey { case footprint = "phys_footprint_bytes" }
        }
        let limit: Int64?
        let telemetry: Telemetry?
        enum CodingKeys: String, CodingKey { case limit = "limit_bytes", telemetry = "host_telemetry" }
    }

    private struct Weights: Decodable {
        let failures: Int?
        enum CodingKeys: String, CodingKey { case failures = "restore_failures" }
    }

    private struct Identity: Decodable {
        struct KV: Decodable { let format: String? }
        let kv: KV?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maximumContextTokens = try container.decodeIfPresent(Int.self, forKey: .maximumContextTokens)
        memoryPressure = try container.decodeIfPresent(String.self, forKey: .memoryPressure)
        thermalState = try container.decodeIfPresent(String.self, forKey: .thermalState)
        let governor = try container.decodeIfPresent(Governor.self, forKey: .governor)
        governorLimitBytes = governor?.limit
        footprintBytes = governor?.telemetry?.footprint
        restoreFailures = try container.decodeIfPresent(Weights.self, forKey: .weights)?.failures
        kvFormat = try container.decodeIfPresent(Identity.self, forKey: .identity)?.kv?.format
        verifyRows = try? container.decodeIfPresent(String.self, forKey: .verifyRows)
        vision = try? container.decodeIfPresent(Bool.self, forKey: .vision)
        activeRequests = (try? container.decodeIfPresent([ActiveRequest].self, forKey: .activeRequests)) ?? []
        scheduler = try? container.decodeIfPresent(Scheduler.self, forKey: .scheduler)
        requests = try? container.decodeIfPresent(Requests.self, forKey: .requests)
        metrics = try? container.decodeIfPresent(Metrics.self, forKey: .metrics)
        disk = try? container.decodeIfPresent(Disk.self, forKey: .disk)
    }
}

extension StatusClient {
    public func reading() async throws -> ServerReading {
        try ServerReading.decode(try await get("/status"))
    }

    public func servedModels() async throws -> [String] {
        struct List: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        return try JSONDecoder().decode(List.self, from: try await get("/v1/models")).data.map(\.id)
    }
}
