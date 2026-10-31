import Foundation

/// How the force of a keystroke is read from the accelerometer.
public enum DetectMode: String, Codable, CaseIterable {
    /// Only samples already in the ring when the key event arrives. Adds no latency.
    case instant
    /// Waits `ImpactWindow.peakWaitMs` after the tap callback for the full peak. Debug comparison.
    case peak
}

/// Windows relative to the key event timestamp, in ms. Same method as step 1 (see NOTES.md):
/// gravity = per-axis median before the key, impact = max |a − g| from shortly before the key.
public enum ImpactWindow {
    public static let gravFromMs = -300.0, gravToMs = -80.0
    public static let searchFromMs = -40.0
    /// With fast typing the search starts `afterPrevKeyMs` after the previous key (to skip its
    /// main shock), but never later than `minSearchFromMs`: this key's own shock starts ~7–10 ms
    /// before its timestamp.
    public static let afterPrevKeyMs = 25.0
    public static let minSearchFromMs = -12.0
    public static let peakWaitMs = 20.0
    public static let minGravitySamples = 50
}

public enum ImpactMath {
    public static func searchStart(keyTs: UInt64, prevKeyTs: UInt64?) -> UInt64 {
        var start = Int64(keyTs) + msToTicks(ImpactWindow.searchFromMs)
        if let p = prevKeyTs, p < keyTs {
            start = max(start, Int64(p) + msToTicks(ImpactWindow.afterPrevKeyMs))
            start = min(start, Int64(keyTs) + msToTicks(ImpactWindow.minSearchFromMs))
        }
        return UInt64(max(start, 0))
    }

    /// Peak |a − g| in g. `samples` oldest first and covering at least the gravity window.
    /// Only samples with `t >= searchFrom` and `arrival <= availableBy` count as impact.
    /// nil when there isn't enough data for a gravity estimate or no sample in the search window.
    public static func impact(_ samples: ArraySlice<Sample>, keyTs: UInt64, searchFrom: UInt64,
                              availableBy: UInt64, scratch: inout [Double]) -> Double? {
        let g0 = UInt64(max(0, Int64(keyTs) + msToTicks(ImpactWindow.gravFromMs)))
        let g1 = UInt64(max(0, Int64(keyTs) + msToTicks(ImpactWindow.gravToMs)))
        func median(_ axis: (Sample) -> Double) -> Double? {
            scratch.removeAll(keepingCapacity: true)
            for s in samples where s.t >= g0 && s.t <= g1 { scratch.append(axis(s)) }
            guard scratch.count >= ImpactWindow.minGravitySamples else { return nil }
            scratch.sort()
            let n = scratch.count
            return n % 2 == 1 ? scratch[n / 2] : (scratch[n / 2 - 1] + scratch[n / 2]) / 2
        }
        guard let gx = median({ $0.x }), let gy = median({ $0.y }), let gz = median({ $0.z }) else { return nil }
        var peak = -1.0
        for s in samples where s.t >= searchFrom && s.arrival <= availableBy {
            let dx = s.x - gx, dy = s.y - gy, dz = s.z - gz
            peak = max(peak, (dx * dx + dy * dy + dz * dz).squareRoot())
        }
        return peak < 0 ? nil : peak
    }
}

/// Live impact detection on the sensor ring. Thread-safe.
public final class ImpactDetector {
    public let ring: Ring
    private var buf: [Sample] = []
    private var scratch: [Double] = []
    private var prevKeyTs: UInt64?
    private let lock = NSLock()

    public init(ring: Ring) {
        self.ring = ring
        buf.reserveCapacity(1024)
        scratch.reserveCapacity(512)
    }

    /// Call once per key press, in order. Returns where this key's impact search starts.
    public func beginKey(ts: UInt64) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let s = ImpactMath.searchStart(keyTs: ts, prevKeyTs: prevKeyTs)
        prevKeyTs = ts
        return s
    }

    /// Impact using the samples that arrived by `availableBy`. nil if the sensor isn't streaming.
    public func impact(keyTs: UInt64, searchFrom: UInt64, availableBy: UInt64) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let last = ring.latest(),
              ticksToMs(Int64(bitPattern: availableBy &- last.arrival)) < 100 else { return nil }
        ring.recent(since: UInt64(max(0, Int64(keyTs) + msToTicks(ImpactWindow.gravFromMs))), into: &buf)
        return ImpactMath.impact(buf[...], keyTs: keyTs, searchFrom: searchFrom, availableBy: availableBy, scratch: &scratch)
    }
}
