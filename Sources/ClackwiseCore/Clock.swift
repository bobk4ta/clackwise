import Foundation

// MARK: - mach_absolute_time ticks (1 tick = 41.67 ns on M4, never assume 1 ns)

public let timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

@inline(__always) public func ticksToNs(_ t: UInt64) -> Double { Double(t) * Double(timebase.numer) / Double(timebase.denom) }
@inline(__always) public func ticksToMs(_ t: Int64) -> Double { Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }
@inline(__always) public func msToTicks(_ ms: Double) -> Int64 { Int64(ms * 1e6 * Double(timebase.denom) / Double(timebase.numer)) }

// MARK: - CGEvent timestamps

/// Which clock CGEventGetTimestamp uses, decided from the first event.
public enum EventClock: String { case absTicks = "mach_absolute_time ticks", contTicks = "mach_continuous_time ticks", absNs = "nanoseconds (absolute)" }

/// Picks the clock that puts `raw` closest before now, returns it and `raw` in mach_absolute_time ticks.
public func classifyEventClock(raw: UInt64) -> (EventClock, UInt64) {
    let now = mach_absolute_time()
    let nowC = mach_continuous_time()
    let cands: [(EventClock, Double, UInt64)] = [
        (.absTicks, ticksToMs(Int64(bitPattern: now &- raw)), raw),
        (.contTicks, ticksToMs(Int64(bitPattern: nowC &- raw)), raw &- (nowC &- now)),
        (.absNs, (ticksToNs(now) - Double(raw)) / 1e6, UInt64(Double(raw) * Double(timebase.denom) / Double(timebase.numer))),
    ]
    let ok = cands.filter { $0.1 > -1 && $0.1 < 5000 }.sorted { $0.1 < $1.1 }
    let pick = ok.first ?? cands[0]
    return (pick.0, pick.2)
}

/// Converts CGEvent timestamps to mach_absolute_time ticks. Classifies once, re-classifies
/// if a converted value stops being plausible (e.g. after sleep).
public struct EventClockConverter {
    public private(set) var clock: EventClock?
    public init() {}

    public mutating func convert(_ raw: UInt64) -> UInt64 {
        if let c = clock {
            let ts: UInt64
            switch c {
            case .absTicks: ts = raw
            case .contTicks: ts = raw &- (mach_continuous_time() &- mach_absolute_time())
            case .absNs: ts = UInt64(Double(raw) * Double(timebase.denom) / Double(timebase.numer))
            }
            let age = ticksToMs(Int64(bitPattern: mach_absolute_time() &- ts))
            if age > -1 && age < 5000 { return ts }
        }
        let (c, ts) = classifyEventClock(raw: raw)
        clock = c
        return ts
    }
}

// MARK: - small stats helpers

public func pct(_ a: [Double], _ p: Double) -> Double {
    guard !a.isEmpty else { return .nan }
    let s = a.sorted()
    let idx = p / 100 * Double(s.count - 1)
    let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
    return s[lo] + (s[hi] - s[lo]) * (idx - Double(lo))
}
