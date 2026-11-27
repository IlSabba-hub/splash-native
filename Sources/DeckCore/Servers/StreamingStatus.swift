import Foundation

public struct StreamingStatus: Sendable, Equatable {
    public struct Latency: Decodable, Sendable, Equatable {
        public let p50: Double?
        public let p95: Double?
        public let p99: Double?
        public let max: Double?
        public let total: Double?
        public let samples: Int?
    }

    public struct HostSteps: Decodable, Sendable, Equatable {
        public let pickup: Latency?
        public let work: Latency?
        public let resume: Latency?

        enum CodingKeys: String, CodingKey { case pickup = "pickup_ms", work = "work_ms", resume = "resume_ms" }
    }

    public struct Experts: Decodable, Sendable, Equatable {
        public struct Use: Decodable, Sendable, Equatable {
            public let loads: Int64?
            public let routed: Int64?
            public let read: Int64?
            public let prefetched: Int64?
            public let readAhead: Int64?
            public let hitRate: Double?
            public let readBytes: Int64?
            public let hostSteps: HostSteps?

            enum CodingKeys: String, CodingKey {
                case loads, routed, read, prefetched, readAhead = "read_ahead", hitRate = "hit_rate", readBytes = "read_bytes"
                case hostSteps = "host_steps"
            }
        }

        public let capBytes: Int64?
        public let floorBytes: Int64?
        public let chunks: Int?
        public let capChunks: Int?
        public let shrinks: Int?
        public let regrows: Int?
        public let arenaBytes: Int64?
        public let stagingBytes: Int64?
        public let slots: Int?
        public let experts: Int?
        public let resident: Int?
        public let prefill: Use?
        public let decode: Use?
        public let failure: String?

        enum CodingKeys: String, CodingKey {
            case capBytes = "cap_bytes", floorBytes = "floor_bytes", chunks, capChunks = "cap_chunks", shrinks, regrows
            case arenaBytes = "arena_bytes", stagingBytes = "staging_bytes", slots, experts, resident, prefill, decode, failure
        }
    }

    public struct Table: Decodable, Sendable, Equatable {
        public struct Use: Decodable, Sendable, Equatable {
            public let stages: Int64?
            public let requestedRows: Int64?
            public let uniqueRows: Int64?
            public let hitRows: Int64?
            public let readRows: Int64?
            public let hitRate: Double?
            public let stage: Latency?

            enum CodingKeys: String, CodingKey {
                case stages, requestedRows = "requested_rows", uniqueRows = "unique_rows", hitRows = "hit_rows", readRows = "read_rows"
                case hitRate = "hit_rate", stage = "stage_ms"
            }
        }

        public let table: String?
        public let tableBytes: Int64?
        public let cacheBytes: Int64?
        public let cacheCapacityRows: Int64?
        public let cachedRows: Int64?
        public let evictions: Int64?
        public let prefill: Use?
        public let decode: Use?
        public let readBytes: Int64?
        public let readRetries: Int64?
        public let readErrors: Int64?
        public let read: Latency?
        public let prefetchRequestedRows: Int64?
        public let prefetchReadRows: Int64?
        public let prefetchDroppedRows: Int64?
        public let poisoned: Bool?
        public let failure: String?

        enum CodingKeys: String, CodingKey {
            case table, tableBytes = "table_bytes", cacheBytes = "cache_bytes", cacheCapacityRows = "cache_capacity_rows"
            case cachedRows = "cached_rows", evictions, prefill, decode, readBytes = "read_bytes", readRetries = "read_retries"
            case readErrors = "read_errors", read = "read_ms", prefetchRequestedRows = "prefetch_requested_rows"
            case prefetchReadRows = "prefetch_read_rows", prefetchDroppedRows = "prefetch_dropped_rows", poisoned, failure
        }
    }

    public struct KVSpill: Decodable, Sendable, Equatable {
        public struct Requests: Decodable, Sendable, Equatable {
            public let spill: Int64?
            public let resident: Int64?
            public let converted: Int64?
        }

        public struct Pages: Decodable, Sendable, Equatable {
            public let index: Int64?
            public let indexBytes: Int64?
            public let spilled: Int64?
            public let spilledBytes: Int64?

            enum CodingKeys: String, CodingKey { case index, indexBytes = "index_bytes", spilled, spilledBytes = "spilled_bytes" }
        }

        public struct WriteThrough: Decodable, Sendable, Equatable {
            public let pages: Int64?
            public let bytes: Int64?
            public let failures: Int64?
        }

        public struct BlockCache: Decodable, Sendable, Equatable {
            public let bytes: Int64?
            public let targetBytes: Int64?
            public let floorBytes: Int64?
            public let resolves: Int64?
            public let hits: Int64?
            public let read: Int64?
            public let hitRate: Double?
            public let readBytes: Int64?
            public let readFailures: Int64?
            public let readLatency: Latency?

            enum CodingKeys: String, CodingKey {
                case bytes, targetBytes = "target_bytes", floorBytes = "floor_bytes", resolves, hits, read, hitRate = "hit_rate"
                case readBytes = "read_bytes", readFailures = "read_failures", readLatency = "read_ms"
            }
        }

        public struct HistoryStream: Decodable, Sendable, Equatable {
            public let commands: Int64?
            public let layers: Int64?
            public let pages: Int64?
            public let bytes: Int64?
            public let readLatency: Latency?

            enum CodingKeys: String, CodingKey { case commands, layers, pages, bytes, readLatency = "read_ms" }
        }

        public let requests: Requests?
        public let pages: Pages?
        public let writeThrough: WriteThrough?
        public let blockCache: BlockCache?
        public let historyStream: HistoryStream?

        enum CodingKeys: String, CodingKey {
            case requests, pages, writeThrough = "write_through", blockCache = "block_cache", historyStream = "history_stream"
        }
    }

    public let experts: Experts?
    public let table: Table?
    public let kvSpill: KVSpill?

    public init(experts: Experts? = nil, table: Table? = nil, kvSpill: KVSpill? = nil) {
        self.experts = experts
        self.table = table
        self.kvSpill = kvSpill
    }

    public var isEmpty: Bool { experts == nil && table == nil && kvSpill == nil }

    public var readBytes: Int64? {
        guard !isEmpty else { return nil }
        let parts: [Int64?] = [experts?.prefill?.readBytes, experts?.decode?.readBytes, table?.readBytes,
                               kvSpill?.blockCache?.readBytes, kvSpill?.historyStream?.bytes]
        return parts.compactMap { $0 }.reduce(0, +)
    }

    var expertCounts: (routed: Int64, read: Int64)? {
        guard let experts else { return nil }
        let uses = [experts.prefill, experts.decode].compactMap { $0 }
        guard !uses.isEmpty else { return nil }
        return (uses.compactMap(\.routed).reduce(0, +), uses.compactMap(\.read).reduce(0, +))
    }

    private struct Sections: Decodable {
        let experts: Experts?
        let table: Table?
        let kvSpill: KVSpill?

        enum CodingKeys: String, CodingKey { case experts = "streamed_experts", table = "streamed_table", kvSpill = "kv_spill" }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            experts = (try? c.decodeIfPresent(Experts.self, forKey: .experts)) ?? nil
            table = (try? c.decodeIfPresent(Table.self, forKey: .table)) ?? nil
            kvSpill = (try? c.decodeIfPresent(KVSpill.self, forKey: .kvSpill)) ?? nil
        }
    }

    public static func decode(_ data: Data) -> StreamingStatus {
        guard let sections = try? JSONDecoder().decode(Sections.self, from: data) else { return StreamingStatus() }
        return StreamingStatus(experts: sections.experts, table: sections.table, kvSpill: sections.kvSpill)
    }
}
