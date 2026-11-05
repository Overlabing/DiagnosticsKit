import Foundation
import Testing

/// Measurement for the perf tests. Machine load (parallel builds, the rest of the suite) only adds time to a
/// measurement, so the best time over N repetitions is the steadiest estimate of the real cost; the median is not.
/// Under `OVERLABING_PERF_STRICT=1` (a dedicated machine, the perf tests run alone with `--filter`) the budget applies
/// as is to the best wall time. Otherwise it is widened ×4 and applies to the best CPU time of the thread that runs the
/// body: a preemption (the machine has more work than cores) does not count in it, memory and cache contention do, and
/// ×4 lets that through without letting an order-of-magnitude regression through.
/// The body is synchronous so that all its work runs on one thread.
enum PerfBudget {
    struct Timing: Sendable {
        /// Best wall time and median (printed only).
        var best: Duration
        var median: Duration
        /// Best CPU time of the thread; nil if the body could not be measured on one thread.
        var cpu: Duration?

        /// The figure compared with the limit: wall in strict mode, CPU otherwise.
        var checked: Duration { PerfBudget.isStrict ? best : cpu ?? best }
    }

    static var isStrict: Bool { ProcessInfo.processInfo.environment["OVERLABING_PERF_STRICT"] == "1" }

    static func limit(_ budget: Duration) -> Duration { isStrict ? budget : budget * 4 }

    /// Runs `body` `repetitions` times on the current thread.
    static func measure(_ repetitions: Int, _ body: () throws -> Void) rethrows -> Timing {
        let clock = ContinuousClock()
        var walls: [Duration] = []
        var cpus: [Duration] = []
        for _ in 0..<repetitions {
            let cpuStart = threadCPUTime()
            let start = clock.now
            try body()
            walls.append(clock.now - start)
            cpus.append(threadCPUTime() - cpuStart)
        }
        walls.sort()
        return Timing(best: walls[0], median: walls[walls.count / 2], cpu: cpus.min())
    }

    /// CPU time consumed by the calling thread since it was created.
    static func threadCPUTime() -> Duration {
        .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
    }

    /// The `[perf]` line: real figures, budget and applied limit.
    static func report(_ label: String, _ timing: Timing, budget: Duration) -> String {
        let cpu = timing.cpu.map { ", cpu \(ms($0))" } ?? ""
        let line = "[perf] \(label): min \(ms(timing.best))\(cpu), median \(ms(timing.median)), budget \(ms(budget)), "
            + "limit \(ms(limit(budget))) "
            + (isStrict ? "(strict, wall)" : "(wide ×4 on cpu, OVERLABING_PERF_STRICT=1 for strict)")
        print(line)
        return line
    }

    /// Prints the `[perf]` line and fails if the compared figure exceeds the limit.
    static func expect(
        _ label: String, _ timing: Timing, budget: Duration, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let line = report(label, timing, budget: budget)
        #expect(timing.checked < limit(budget), "\(line)", sourceLocation: sourceLocation)
    }

    static func ms(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.2f ms", value)
    }
}
