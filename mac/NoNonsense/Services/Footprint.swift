import Darwin
import Foundation
import Observation

/// What this app, and the server it started, use right now: CPU as a share of one core (as Activity Monitor and
/// `top` show it) and memory as Activity Monitor counts it. Settings › Footprint reads it once a second, only while
/// that page is open; nothing is measured otherwise.
@Observable
final class FootprintMeter {
    struct Reading: Equatable {
        var cpu: Double             // percent of one core, over the last reading
        var memory: UInt64          // bytes
        var processes: Int
    }

    private(set) var app: Reading?
    private(set) var server: Reading?
    @ObservationIgnored private var previous: [pid_t: (cpu: Double, at: Double)] = [:]

    /// Reads both. Call it about once a second: CPU is the time used since the last call.
    func update(serverPIDs: [pid_t]) {
        app = read([getpid()])
        server = serverPIDs.isEmpty ? nil : read(serverPIDs)
    }

    private func read(_ pids: [pid_t]) -> Reading? {
        let now = Date().timeIntervalSinceReferenceDate
        var cpu = 0.0, memory: UInt64 = 0, alive = 0
        for pid in pids {
            guard let sample = Self.sample(pid) else { continue }
            alive += 1
            memory += sample.memory
            if let before = previous[pid], now > before.at { cpu += (sample.cpu - before.cpu) / (now - before.at) * 100 }
            previous[pid] = (sample.cpu, now)
        }
        return alive == 0 ? nil : Reading(cpu: max(0, cpu), memory: memory, processes: alive)
    }

    /// CPU seconds used so far, and memory (the "physical footprint" Activity Monitor shows), for one process of
    /// this user. The kernel counts CPU in Mach clock units: 125/3 ns each on Apple silicon (checked 7 Oct against getrusage).
    private static func sample(_ pid: pid_t) -> (cpu: Double, memory: UInt64)? {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard status == 0 else { return nil }
        return (Double(info.ri_user_time + info.ri_system_time) * nanosecondsPerTick / 1e9, info.ri_phys_footprint)
    }

    private static let nanosecondsPerTick: Double = {
        var base = mach_timebase_info()
        mach_timebase_info(&base)
        return Double(base.numer) / Double(base.denom)
    }()
}
