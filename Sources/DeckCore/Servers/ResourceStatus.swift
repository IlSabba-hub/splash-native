import Foundation

public struct ResourceStatus: Decodable, Sendable, Equatable {
    public struct Instance: Decodable, Sendable, Equatable {
        public let id: String?
        public let pid: Int32?
        public let model: String?
        public let port: Int?
        public let startedAt: Double?
    }

    public struct Device: Decodable, Sendable, Equatable {
        public let physicalMemoryBytes: Int64?
        public let recommendedMaxWorkingSetBytes: Int64?
    }

    public struct Budget: Decodable, Sendable, Equatable {
        public let recommendedWorkingSetBytes: Int64?
        public let workingSetMarginBytes: Int64?
        public let configuredMemoryLimitBytes: Int64?
        public let hardBudgetBytes: Int64?
        public let fixedRuntimeBytes: Int64?
        public let laneStateBytes: Int64?
        public let kvCapacityBytes: Int64?
        public let kvCapacityTokens: Int64?
        public let kvExtentPages: Int64?
        public let kvPageBytes: Int64?
        public let kvPageTokens: Int64?
        public let kvWindow: Window?

        public struct Window: Decodable, Sendable, Equatable {
            public let slimPageBytes: Int64?
            public let floorPages: Int64?
        }
    }

    public struct Plan: Decodable, Sendable, Equatable {
        public let device: Device?
        public let budget: Budget?
    }

    public struct MemoryActual: Decodable, Sendable, Equatable {
        public let currentBytes: Int64?
        public let peakBytes: Int64?
    }

    public struct Governor: Decodable, Sendable, Equatable {
        public struct Telemetry: Decodable, Sendable, Equatable {
            public let physFootprintBytes: Int64?
        }
        public let limitBytes: Int64?
        public let headroomBytes: Int64?
        public let hostTelemetry: Telemetry?
    }

    public struct Disk: Decodable, Sendable, Equatable {
        public struct TakenBack: Decodable, Sendable, Equatable {
            public let states: Int64?
            public let kvBlocks: Int64?
            public let bytes: Int64?
            public let leftBehind: Int64?
        }
        public struct WriteBehind: Decodable, Sendable, Equatable {
            public let waiting: Int64?
            public let durable: Int64?
            public let unneeded: Int64?
            public let refused: Int64?
        }
        public let capacityBytes: Int64?
        public let limitBytes: Int64?
        public let usedBytes: Int64?
        public let fileBytes: Int64?
        public let volumeAvailableBytes: Int64?
        public let writesGated: String?
        public let writeBudgetBytes: Int64?
        public let readBytes: Int64?
        public let writtenBytes: Int64?
        public let writtenLastHourBytes: Int64?
        public let writtenLastDayBytes: Int64?
        public let kvBlocks: Int64?
        public let kvBytes: Int64?
        public let kvRestores: Int64?
        public let persistent: Bool?
        public let takenBack: TakenBack?
        public let writeBehind: WriteBehind?
        public let offReason: String?
    }

    public struct Requests: Decodable, Sendable, Equatable {
        public let submitted: Int64?
        public let completed: Int64?
        public let cancelled: Int64?
        public let failed: Int64?
    }

    public struct Counters: Decodable, Sendable, Equatable {
        public let prefillInputTokens: Int64?
        public let prefillWallMs: Double?
        public let prefillTokensPerSecond: Double?
        public let decodeOutputTokens: Int64?
        public let decodeWallMs: Double?
        public let decodeTokensPerSecond: Double?
    }

    public struct Weights: Decodable, Sendable, Equatable {
        public let released: Bool?
        public let restoring: Bool?
    }

    public let schemaVersion: Int?
    public let ready: Bool?
    public let memoryPressure: String?
    public let thermalState: String?
    public let instance: Instance?
    public let memoryPlan: Plan?
    public let memoryActual: MemoryActual?
    public let memoryGovernor: Governor?
    public let disk: Disk?
    public let requests: Requests?
    public let metrics: Counters?
    public let weights: Weights?
    public let maximumContextTokens: Int64?

    public var peakBytes: Int64? {
        guard let b = memoryPlan?.budget, let fixed = b.fixedRuntimeBytes, let lane = b.laneStateBytes,
              let bytes = b.kvCapacityBytes, let tokens = b.kvCapacityTokens, let context = maximumContextTokens,
              let kv = SplashPlanReading.contextKVBytes(
                  context: UInt64(clamping: context), pageTokens: UInt64(clamping: b.kvPageTokens ?? 0),
                  pageBytes: UInt64(clamping: b.kvPageBytes ?? 0), extentPages: UInt64(clamping: b.kvExtentPages ?? 0),
                  slimPageBytes: UInt64(clamping: b.kvWindow?.slimPageBytes ?? 0), floorPages: UInt64(clamping: b.kvWindow?.floorPages ?? 0),
                  capacityBytes: UInt64(clamping: bytes), capacityTokens: UInt64(clamping: tokens))
        else { return nil }
        return fixed + lane + Int64(clamping: kv)
    }

    public static func decode(_ data: Data) throws -> ResourceStatus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ResourceStatus.self, from: data)
    }
}

extension StatusClient {
    public func resourceStatus() async throws -> ResourceStatus {
        try ResourceStatus.decode(try await get("/status"))
    }
}
