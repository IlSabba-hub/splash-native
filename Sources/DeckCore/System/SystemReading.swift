import Darwin
import Foundation
import IOKit

public struct SystemReading: Sendable, Equatable {
    public let time: Date
    public let memory: SystemMemory
    public let gpu: [GPUReading]
    public let thermal: ThermalLevel?

    public static func read(at time: Date = .now) -> SystemReading {
        SystemReading(time: time, memory: .read(), gpu: GPUReading.read(), thermal: ThermalLevel(ProcessInfo.processInfo.thermalState))
    }

    public init(time: Date, memory: SystemMemory, gpu: [GPUReading], thermal: ThermalLevel?) {
        self.time = time
        self.memory = memory
        self.gpu = gpu
        self.thermal = thermal
    }
}

public enum ThermalLevel: String, Sendable, Equatable, Codable {
    case nominal, fair, serious, critical

    public init?(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: return nil
        }
    }
}

public struct SystemMemory: Sendable, Equatable {
    public enum Pressure: String, Sendable, Equatable, Codable {
        case normal, warning, critical

        public init?(level: Int32) {
            switch level {
            case 1: self = .normal
            case 2: self = .warning
            case 4: self = .critical
            default: return nil
            }
        }
    }

    public let physicalBytes: UInt64?
    public let pressure: Pressure?
    public let swapTotalBytes: UInt64?
    public let swapUsedBytes: UInt64?
    public let compressedBytes: UInt64?

    public init(physicalBytes: UInt64?, pressure: Pressure?, swapTotalBytes: UInt64?, swapUsedBytes: UInt64?, compressedBytes: UInt64?) {
        self.physicalBytes = physicalBytes
        self.pressure = pressure
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.compressedBytes = compressedBytes
    }

    public static func read() -> SystemMemory {
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let physical = sysctlbyname("hw.memsize", &memsize, &size, nil, 0) == 0 ? memsize : nil

        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Pressure(level: level) : nil

        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        let swapRead = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0

        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let statistics = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let compressed = statistics == KERN_SUCCESS ? UInt64(info.compressor_page_count) * UInt64(getpagesize()) : nil

        return SystemMemory(physicalBytes: physical, pressure: pressure,
                            swapTotalBytes: swapRead ? swap.xsu_total : nil, swapUsedBytes: swapRead ? swap.xsu_used : nil,
                            compressedBytes: compressed)
    }
}

public struct GPUReading: Sendable, Equatable {
    public let accelerator: String
    public let deviceUtilization: Int?
    public let rendererUtilization: Int?
    public let tilerUtilization: Int?
    public let inUseSystemMemory: Int64?

    public init(accelerator: String, statistics: [String: Any]) {
        func int(_ key: String) -> Int64? { (statistics[key] as? NSNumber)?.int64Value }
        self.accelerator = accelerator
        deviceUtilization = int("Device Utilization %").map(Int.init)
        rendererUtilization = int("Renderer Utilization %").map(Int.init)
        tilerUtilization = int("Tiler Utilization %").map(Int.init)
        inUseSystemMemory = int("In use system memory")
    }

    public static func read() -> [GPUReading] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var readings: [GPUReading] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &name)
            let property = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
            guard let statistics = property?.takeRetainedValue() as? [String: Any] else { continue }
            let className = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            readings.append(GPUReading(accelerator: className, statistics: statistics))
        }
        return readings
    }
}
