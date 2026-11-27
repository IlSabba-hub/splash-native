import Foundation

public struct StatusSnapshot: Decodable, Sendable, Equatable {
    public struct Instance: Decodable, Sendable, Equatable {
        public let id: String?
        public let pid: Int32?
        public let model: String?
        public let host: String?
        public let port: Int?
        public let startedAt: Double?

        enum CodingKeys: String, CodingKey { case id, pid, model, host, port, startedAt = "started_at" }
    }

    public struct Budget: Decodable, Sendable, Equatable {
        public let hardBudgetBytes: Int64?
        public let configuredMemoryLimitBytes: Int64?
        public let recommendedWorkingSetBytes: Int64?

        enum CodingKeys: String, CodingKey {
            case hardBudgetBytes = "hard_budget_bytes", configuredMemoryLimitBytes = "configured_memory_limit_bytes"
            case recommendedWorkingSetBytes = "recommended_working_set_bytes"
        }
    }

    public struct MemoryActual: Decodable, Sendable, Equatable {
        public let currentBytes: Int64?
        public let peakBytes: Int64?

        enum CodingKeys: String, CodingKey { case currentBytes = "current_bytes", peakBytes = "peak_bytes" }
    }

    public struct Weights: Decodable, Sendable, Equatable {
        public let idleReleaseSeconds: Double?
        public let released: Bool?
        public let restoring: Bool?
        public let restores: Int?

        enum CodingKeys: String, CodingKey {
            case idleReleaseSeconds = "idle_release_seconds", released, restoring, restores
        }
    }

    public let schemaVersion: Int?
    public let ready: Bool?
    public let instance: Instance?
    public let budget: Budget?
    public let memoryActual: MemoryActual?
    public let weights: Weights?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", ready, instance, memoryPlan = "memory_plan", memoryActual = "memory_actual", weights
    }

    private struct MemoryPlan: Decodable { let budget: Budget? }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        ready = try container.decodeIfPresent(Bool.self, forKey: .ready)
        instance = try container.decodeIfPresent(Instance.self, forKey: .instance)
        budget = try container.decodeIfPresent(MemoryPlan.self, forKey: .memoryPlan)?.budget
        memoryActual = try container.decodeIfPresent(MemoryActual.self, forKey: .memoryActual)
        weights = try container.decodeIfPresent(Weights.self, forKey: .weights)
    }
}

public struct StatusClient: Sendable {
    public let port: Int
    public let apiKey: String?
    public let session: URLSession

    public init(port: Int, apiKey: String? = nil, session: URLSession = .shared) {
        self.port = port
        self.apiKey = apiKey
        self.session = session
    }

    private func request(_ path: String, method: String = "GET", timeout: TimeInterval = 2) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func get(_ path: String) async throws -> Data {
        let (data, response) = try await session.data(for: request(path))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DeckError.httpStatus(path: path, status: status) }
        return data
    }

    public func status() async throws -> StatusSnapshot {
        try JSONDecoder().decode(StatusSnapshot.self, from: try await get("/status"))
    }

    public enum ReleaseOutcome: Sendable, Equatable {
        case released
        case busy(message: String)
        case refused(status: Int, code: String?, message: String?)
    }

    public static func releaseOutcome(status: Int, body: Data) -> ReleaseOutcome {
        struct Released: Decodable { let released: Bool }
        struct Refusal: Decodable {
            struct Failure: Decodable { let message: String?; let code: String? }
            let error: Failure
        }
        if status == 200, (try? JSONDecoder().decode(Released.self, from: body))?.released == true { return .released }
        let refusal = try? JSONDecoder().decode(Refusal.self, from: body)
        if status == 409, refusal?.error.code == "engine_busy" { return .busy(message: refusal?.error.message ?? "") }
        return .refused(status: status, code: refusal?.error.code, message: refusal?.error.message)
    }

    public func releaseMemory() async throws -> ReleaseOutcome {
        var release = request("/v1/memory/release", method: "POST", timeout: 10)
        release.httpBody = Data("{}".utf8)
        release.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: release)
        return Self.releaseOutcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
