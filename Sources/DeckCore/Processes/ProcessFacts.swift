import Darwin
import Foundation

public enum ProcessFacts {
    public static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    public static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public struct Identity: Sendable, Equatable {
        public let pid: pid_t
        public let parent: pid_t
        public let group: pid_t
        public let user: uid_t
        public let name: String
        public let started: Int
    }

    public static func identity(_ pid: pid_t) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return Identity(pid: pid, parent: pid_t(info.pbi_ppid), group: pid_t(info.pbi_pgid), user: info.pbi_uid, name: name,
                        started: Int(info.pbi_start_tvsec) * 1_000_000 + Int(info.pbi_start_tvusec))
    }

    public struct Usage: Sendable, Equatable, Codable {
        public let footprint: UInt64
        public let resident: UInt64
        public let lifetimeMax: UInt64

        public init(footprint: UInt64, resident: UInt64, lifetimeMax: UInt64) {
            self.footprint = footprint
            self.resident = resident
            self.lifetimeMax = lifetimeMax
        }
    }

    public static func usage(_ pid: pid_t) -> Usage? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        return Usage(footprint: info.ri_phys_footprint, resident: info.ri_resident_size,
                     lifetimeMax: info.ri_lifetime_max_phys_footprint)
    }

    public struct MappedFile: Sendable, Equatable, Codable {
        public let path: String
        public let mappedBytes: UInt64
        public let residentBytes: UInt64
        public let fileBytes: UInt64
    }

    public static func mappedFiles(_ pid: pid_t) -> [MappedFile]? {
        let page = UInt64(max(4096, sysconf(_SC_PAGESIZE)))
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var byPath: [String: (mapped: UInt64, resident: UInt64, file: UInt64)] = [:]
        var address: UInt64 = 0
        var first = true
        while true {
            var region = proc_regionwithpathinfo()
            let read = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region, size)
            if read != size {
                if first && kill(pid, 0) != 0 { return nil }
                break
            }
            first = false
            let path = withUnsafeBytes(of: region.prp_vip.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty && !path.contains("dyld_shared_cache") {
                var entry = byPath[path] ?? (0, 0, UInt64(max(0, region.prp_vip.vip_vi.vi_stat.vst_size)))
                entry.mapped += region.prp_prinfo.pri_size
                entry.resident += UInt64(region.prp_prinfo.pri_pages_resident) * page
                byPath[path] = entry
            }
            let next = region.prp_prinfo.pri_address &+ region.prp_prinfo.pri_size
            if next <= address { break }
            address = next
        }
        return byPath.map { path, entry in
            var mapped = entry.mapped
            var resident = entry.resident
            if entry.file > 0 {
                mapped = min(mapped, (entry.file + page - 1) / page * page)
                resident = min(resident, mapped)
            }
            return MappedFile(path: path, mappedBytes: mapped, residentBytes: resident, fileBytes: entry.file)
        }.sorted { $0.path < $1.path }
    }

    public static func listeningPorts(_ pid: pid_t) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, bytes)
        guard filled > 0 else { return [] }
        var ports: Set<Int> = []
        for descriptor in descriptors.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == SOCKINFO_TCP,
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN
            else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }
}
