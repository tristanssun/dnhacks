import Combine
import Darwin
import Foundation
import QuartzCore
import os

/// Lock-protected counters, writable from any queue. ARKit delivers frames on
/// the main queue today, but nothing here depends on that staying true.
final class PerfCounters: Sendable {
    private struct State {
        var arFrames = 0
        var uiFrames = 0
        var publishes = 0
        var hops: [Double] = []
        var recenterSeconds: Double = 0
        var recenterCalls = 0
    }

    /// Hop samples are drained every tick; the cap only guards against a tick
    /// that never runs because the main thread is wedged.
    private static let hopSampleCap = 2000

    private let state = OSAllocatedUnfairLock(initialState: State())

    func recordARFrame() {
        state.withLock { $0.arFrames += 1 }
    }

    func recordUIFrame() {
        state.withLock { $0.uiFrames += 1 }
    }

    func recordPublish() {
        state.withLock { $0.publishes += 1 }
    }

    func recordHop(_ seconds: Double) {
        state.withLock {
            guard $0.hops.count < Self.hopSampleCap else { return }
            $0.hops.append(seconds)
        }
    }

    func recordRecenter(_ seconds: Double) {
        state.withLock {
            $0.recenterSeconds += seconds
            $0.recenterCalls += 1
        }
    }

    /// Returns the interval's totals and resets them.
    fileprivate func drain() -> (arFrames: Int, uiFrames: Int, publishes: Int, hops: [Double], recenterSeconds: Double, recenterCalls: Int) {
        state.withLock { current in
            let taken = current
            current = State()
            return (taken.arFrames, taken.uiFrames, taken.publishes, taken.hops, taken.recenterSeconds, taken.recenterCalls)
        }
    }
}

let perfCounters = PerfCounters()

/// A/B instrumentation for the progressive-slowdown investigation.
///
/// Emits one CSV row per second prefixed `LOCARPERF` so a run can be pasted
/// out of the Xcode console straight into a spreadsheet, and publishes a live
/// snapshot for the on-screen HUD.
@MainActor
final class PerfMonitor: ObservableObject {
    struct Snapshot {
        var elapsed: TimeInterval = 0
        var arHz: Double = 0
        var uiHz: Double = 0
        var publishHz: Double = 0
        var hopP50Ms: Double = 0
        var hopP95Ms: Double = 0
        var recenterMsPerSec: Double = 0
        var memoryMB: Double = 0
        /// 0 nominal, 1 fair, 2 serious, 3 critical. A sustained ARKit + UWB
        /// session heats the SoC, and the resulting downclock looks exactly
        /// like a code regression. Rule it out before chasing one.
        var thermal: Int = 0
    }

    static let thermalNames = ["nominal", "fair", "serious", "critical"]

    @Published private(set) var snapshot = Snapshot()

    /// Arm A (default true): display re-centering runs. Arm B: skipped.
    @Published var recentering = true {
        didSet { note("recentering=\(recentering)") }
    }

    private var timer: Timer?
    private var startedAt = CACurrentMediaTime()
    private var lastTick = CACurrentMediaTime()

    func start() {
        guard timer == nil else { return }
        startedAt = CACurrentMediaTime()
        lastTick = startedAt
        print("LOCARPERF,elapsed_s,ar_hz,ui_hz,publish_hz,hop_p50_ms,hop_p95_ms,recenter_ms_per_s,memory_mb,thermal,recentering")
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common so the HUD keeps logging while SwiftUI is tracking a gesture.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Marks a flag change in the log so arms can be split apart afterwards.
    private func note(_ text: String) {
        let elapsed = CACurrentMediaTime() - startedAt
        print(String(format: "LOCARMARK,%.1f,%@", elapsed, text))
    }

    private func tick() {
        let now = CACurrentMediaTime()
        // Real elapsed, not the nominal 1 s: a backlogged main thread delays
        // this timer, and dividing by the nominal interval would hide that.
        let interval = max(now - lastTick, 0.001)
        lastTick = now

        let drained = perfCounters.drain()
        let sorted = drained.hops.sorted()
        let next = Snapshot(
            elapsed: now - startedAt,
            arHz: Double(drained.arFrames) / interval,
            uiHz: Double(drained.uiFrames) / interval,
            publishHz: Double(drained.publishes) / interval,
            hopP50Ms: Self.percentile(sorted, 0.50) * 1000,
            hopP95Ms: Self.percentile(sorted, 0.95) * 1000,
            recenterMsPerSec: drained.recenterSeconds * 1000 / interval,
            memoryMB: Self.memoryMB(),
            thermal: Self.thermalLevel()
        )
        snapshot = next

        print(String(
            format: "LOCARPERF,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.1f,%.1f,%d,%d",
            next.elapsed,
            next.arHz,
            next.uiHz,
            next.publishHz,
            next.hopP50Ms,
            next.hopP95Ms,
            next.recenterMsPerSec,
            next.memoryMB,
            next.thermal,
            recentering ? 1 : 0
        ))
    }

    private static func thermalLevel() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    /// Resident footprint, the number Xcode's memory gauge shows.
    private static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
