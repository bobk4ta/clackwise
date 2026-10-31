import Foundation

// MARK: - Log-spaced bins (shared by the adaptive tracker and the stats histogram)

public enum LogBins {
    public static let lnMin = log(0.0005)   // 0.5 mg
    public static let width = 0.05          // ln units (≈ 5 % per bin)
    public static let count = 150           // up to ≈ 0.9 g

    public static func index(_ g: Double) -> Int {
        guard g > 0 else { return 0 }
        return min(count - 1, max(0, Int((log(g) - lnMin) / width)))
    }
    public static func lowerG(_ i: Int) -> Double { exp(lnMin + Double(i) * width) }

    /// Quantile in ln(g), linear inside the bin. nil when empty.
    public static func quantile(_ w: [Double], _ q: Double) -> Double? {
        let total = w.reduce(0, +)
        guard total > 0 else { return nil }
        let target = q * total
        var acc = 0.0
        for (i, v) in w.enumerated() where v > 0 {
            if acc + v >= target { return lnMin + (Double(i) + (target - acc) / v) * width }
            acc += v
        }
        return lnMin + Double(w.count) * width
    }
}

// MARK: - Calibration

/// Anchors for one detection mode, in g (peak |a − g|).
public struct ModeCalibration: Codable, Equatable {
    public var softG: Double         // maps to minDb (v1) / the soft layer (v2)
    public var hardG: Double         // maps to 0 dB (v1) / the hard layer (v2)
    public var normalG: Double       // median of normal typing: the pivot
    public var normalSpread: Double  // ln(p90 / p10) of normal typing

    public init(softG: Double, hardG: Double, normalG: Double, normalSpread: Double) {
        self.softG = softG; self.hardG = hardG; self.normalG = normalG; self.normalSpread = normalSpread
    }
}

/// Velocity v2 calibration, rebased on real use (stats.json) instead of the 60-key lab session:
/// soft/normal/hard = p10/p50/p90 of the per-key corrected instant (and peak) impacts.
public struct V2Calibration: Codable, Equatable {
    public var instant: ModeCalibration
    public var peak: ModeCalibration
    /// ln-units added to a key's impact before mapping (partial, clamped; see KeyCorrection).
    public var keyOffsets: [String: Double]
    public var presses: Int
    public var source: String
}

public struct Calibration: Codable, Equatable {
    public var instant: ModeCalibration
    public var peak: ModeCalibration
    public var source: String
    public var v2: V2Calibration?

    public subscript(mode: DetectMode) -> ModeCalibration {
        get { mode == .instant ? instant : peak }
        set { if mode == .instant { instant = newValue } else { peak = newValue } }
    }

    /// Neutral starting prior (rounded global percentiles, no per-key offsets); Resources/calibration.json,
    /// bundled in the app, holds the same numbers. Each Mac then adapts and learns its own per-key correction.
    public static let builtIn = Calibration(
        instant: ModeCalibration(softG: 0.0067, hardG: 0.075, normalG: 0.012, normalSpread: 1.2),
        peak: ModeCalibration(softG: 0.016, hardG: 0.12, normalG: 0.018, normalSpread: 1.2),
        source: "Clackwise defaults 1", v2: nil)

    /// Soft median → minDb, hard median → 0 dB, normal median = pivot.
    public static func derive(soft: [Double], normal: [Double], hard: [Double]) -> ModeCalibration {
        ModeCalibration(softG: pct(soft, 50), hardG: pct(hard, 50), normalG: pct(normal, 50),
                        normalSpread: log(pct(normal, 90) / pct(normal, 10)))
    }

    /// v2 from real-use stats: per-key correction first, then p10 / p50 / p90 of the corrected
    /// instant distribution. Peak mode has no per-key histograms: its quantiles are shifted by
    /// what the correction did to the instant ones.
    public static func deriveV2(from s: StatsFile, source: String) -> V2Calibration? {
        let offsets = KeyCorrection.derive(from: s)
        var corrected = [Double](repeating: 0, count: LogBins.count)
        var n = 0
        for (name, k) in s.perKey {
            let shift = Int(((offsets[name] ?? 0) / LogBins.width).rounded())
            for (i, c) in k.impactBins {
                guard let i = Int(i) else { continue }
                corrected[max(0, min(LogBins.count - 1, i + shift))] += Double(c)
                n += c
            }
        }
        let raw = s.impactInstant.map(Double.init), peak = s.impactPeak.map(Double.init)
        guard n >= 500, let c10 = LogBins.quantile(corrected, 0.1), let c50 = LogBins.quantile(corrected, 0.5),
              let c90 = LogBins.quantile(corrected, 0.9), let r10 = LogBins.quantile(raw, 0.1),
              let r50 = LogBins.quantile(raw, 0.5), let r90 = LogBins.quantile(raw, 0.9),
              let p10 = LogBins.quantile(peak, 0.1), let p50 = LogBins.quantile(peak, 0.5),
              let p90 = LogBins.quantile(peak, 0.9) else { return nil }
        let inst = ModeCalibration(softG: exp(c10), hardG: exp(c90), normalG: exp(c50), normalSpread: c90 - c10)
        let pk = ModeCalibration(softG: exp(p10 + c10 - r10), hardG: exp(p90 + c90 - r90), normalG: exp(p50 + c50 - r50),
                                 normalSpread: (p90 + c90 - r90) - (p10 + c10 - r10))
        return V2Calibration(instant: inst, peak: pk, keyOffsets: offsets, presses: n, source: source)
    }

    public static func load(_ url: URL) -> Calibration? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Calibration.self, from: $0) }
    }
}

/// Per-key impact correction: keys far from the sensor read weaker for the same force. Offset (ln
/// units, added to the key's impact) = `partial` × n/(n + `shrinkPresses`) × (overall median − key
/// median), clamped to ±ln 2. Keys with fewer than `minPresses` get none. Partial on purpose: some
/// of a key's difference is how you really hit it (e.g. modifiers are pressed lightly).
public enum KeyCorrection {
    public static let partial = 0.5, shrinkPresses = 30.0, minPresses = 15
    public static let limit = log(2.0)

    public static func derive(from s: StatsFile) -> [String: Double] {
        guard let overall = LogBins.quantile(s.impactInstant.map(Double.init), 0.5) else { return [:] }
        var out: [String: Double] = [:]
        for (name, k) in s.perKey {
            var w = [Double](repeating: 0, count: LogBins.count)
            var n = 0
            for (i, c) in k.impactBins { if let i = Int(i), i < w.count { w[i] = Double(c); n += c } }
            guard n >= minPresses, let med = LogBins.quantile(w, 0.5) else { continue }
            let off = partial * Double(n) / (Double(n) + shrinkPresses) * (overall - med)
            out[name] = (max(-limit, min(limit, off)) * 1000).rounded() / 1000
        }
        return out
    }
}

// MARK: - Adaptive tracker

/// Running distribution of ln(impact) with exponential forgetting (memory ≈ `memory` keys).
/// Stores only histogram weights: no values, no order, no times.
public struct AdaptiveTracker: Codable, Equatable {
    public static let memory = 2000.0
    public var bins = [Double](repeating: 0, count: LogBins.count)
    public var increment = 1.0
    public var count = 0

    public init() {}

    public mutating func add(_ g: Double) {
        increment /= (1 - 1 / Self.memory)
        bins[LogBins.index(g)] += increment
        if increment > 1e12 {
            for i in bins.indices { bins[i] /= increment }
            increment = 1
        }
        count += 1
    }

    public func quantileLn(_ q: Double) -> Double? { LogBins.quantile(bins, q) }
}

// MARK: - Mapping

/// v1: loudness (−12 … 0 dB) plus a low-pass, lab calibration. v2: timbre (crossfade of the
/// soft / medium / hard layers), a few dB of loudness, calibration rebased on real use, per-key correction.
public enum MappingVersion: String, Codable, CaseIterable { case v1, v2 }

public struct Velocity: Equatable {
    public var gainDb: Double      // ≤ 0, before volume / random variation
    public var brightness: Double  // v1 low-pass: 0 = darkest, 1 = open
    public var layer: Double       // 0 = soft layer, 0.5 = the recording, 1 = hard layer
    public var noSensor: Bool      // sensor not streaming: played at the normal level

    /// Key-up: same loudness, layer halfway back to the recording (release force isn't measured).
    public var forRelease: Velocity { var v = self; v.layer = 0.5 + (layer - 0.5) / 2; return v }
}

public struct AdaptState: Equatable {
    public var keys: Int            // keys the tracker has seen (since Recalibrate)
    public var weight: Double       // 0 … 1, how much of the adaptation is applied
    public var shift: Double        // ln units the anchors moved (+ = you type harder than calibrated)
    public var spreadScale: Double  // span scale applied
}

public struct Anchors { public var lo, hi, normal: Double; public var state: AdaptState }

/// Impact → velocity, continuous on a log scale.
///
/// v1 at strength 1: ln(soft) → −12 dB, ln(hard) → 0 dB, linear in between, clamped; low-pass
/// 2.5 kHz → open. Strength s scales the distance from the normal level: dB = n + s·(dB₁ − n), where n
/// is where the normal-typing median lands. So s = 0 plays everything at the normal level and normal
/// typing stays at the same loudness at every strength.
///
/// v2: the impact (corrected per key) picks the layer on a piecewise log scale: ln(soft) → 0 (soft
/// layer), ln(normal) = your median → 0.5 (the recording), ln(hard) → 1 (hard layer); then
/// x = 0.5 + s·(t − 0.5). Loudness: `v2Level` + s·`v2SpanDb`·(t − 0.5), i.e. ±2 dB at 100 %.
///
/// Adaptation (slow, bounded, per version): the anchors move so the running median of your typing
/// maps to the same place the calibration's normal median did (shift clamped to ±maxShift), and the
/// span scales with your running p10–p90 spread, clamped to `spreadBounds`. The span is never fitted
/// to your typing, so normal typing can't get stretched over the full range.
public final class VelocityMapper {
    public static let minDb = -12.0
    public static let v2Level = -7.0, v2SpanDb = 4.0
    public static let maxShift = log(2.0)
    public static let spreadBounds = 0.8...1.25
    public static let warmupKeys = 200.0, fullKeys = 1000.0

    public var calibration: Calibration { get { locked { cal } } set { locked { cal = newValue; v2 = Self.v2(of: newValue) } } }
    public var strength: Double { get { locked { str } } set { locked { str = max(0, min(1.5, newValue)) } } }
    public var version: MappingVersion { get { locked { ver } } set { locked { ver = newValue } } }
    /// Per-key offsets for v2 (ln units), refreshed from the stats as they grow.
    public var keyOffsets: [String: Double] { get { locked { offsets } } set { locked { offsets = newValue } } }
    public var v2Calibration: V2Calibration { locked { v2 } }

    private var cal: Calibration
    private var v2: V2Calibration
    private var offsets: [String: Double]
    private var str = 1.0
    private var ver = MappingVersion.v1
    private var trackers: [DetectMode: AdaptiveTracker]
    private var trackers2: [DetectMode: AdaptiveTracker]
    private let lock = NSLock()

    public init(calibration: Calibration, trackers: [DetectMode: AdaptiveTracker] = [:],
                v2Trackers: [DetectMode: AdaptiveTracker] = [:]) {
        cal = calibration
        v2 = Self.v2(of: calibration)
        offsets = v2.keyOffsets
        self.trackers = trackers
        trackers2 = v2Trackers
    }

    /// Without a v2 section: the lab anchors, no per-key correction.
    static func v2(of c: Calibration) -> V2Calibration {
        c.v2 ?? V2Calibration(instant: c.instant, peak: c.peak, keyOffsets: [:], presses: 0, source: c.source)
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    public var savedTrackers: [DetectMode: AdaptiveTracker] { locked { trackers } }
    public var savedV2Trackers: [DetectMode: AdaptiveTracker] { locked { trackers2 } }

    public func recalibrate() { locked { trackers = [:]; trackers2 = [:] } }

    /// Current anchors in ln(g) for the active (or given) version.
    public func anchors(_ mode: DetectMode, version: MappingVersion? = nil) -> Anchors {
        locked { anchorsUnlocked(mode, version ?? ver) }
    }

    private func anchorsUnlocked(_ mode: DetectMode, _ v: MappingVersion) -> Anchors {
        let c = v == .v1 ? cal[mode] : (mode == .instant ? v2.instant : v2.peak)
        let lo = log(c.softG), hi = log(c.hardG), n = log(c.normalG)
        let t = (v == .v1 ? trackers[mode] : trackers2[mode]) ?? AdaptiveTracker()
        let w = max(0, min(1, (Double(t.count) - Self.warmupKeys) / (Self.fullKeys - Self.warmupKeys)))
        var shift = 0.0, scale = 1.0
        if w > 0, let med = t.quantileLn(0.5), let p10 = t.quantileLn(0.1), let p90 = t.quantileLn(0.9) {
            shift = max(-Self.maxShift, min(Self.maxShift, med - n)) * w
            let s = max(Self.spreadBounds.lowerBound, min(Self.spreadBounds.upperBound, (p90 - p10) / c.normalSpread))
            scale = 1 + (s - 1) * w
        }
        let st = AdaptState(keys: t.count, weight: w, shift: shift, spreadScale: scale)
        return Anchors(lo: n + shift - (n - lo) * scale, hi: n + shift + (hi - n) * scale, normal: n + shift, state: st)
    }

    /// Position on the soft→hard curve at strength 1, clamped to 0…1.
    private func position(_ lnG: Double, _ a: Anchors) -> Double {
        max(0, min(1, (lnG - a.lo) / (a.hi - a.lo)))
    }

    /// The impact v2 maps: corrected for the key's distance from the sensor.
    private func corrected(_ g: Double, _ key: String?) -> Double { g * exp(key.flatMap { offsets[$0] } ?? 0) }

    /// The mapping. `g == nil` (sensor not streaming) plays at the normal level.
    public func map(_ g: Double?, mode: DetectMode, key: String? = nil) -> Velocity {
        locked { mapUnlocked(g, mode: mode, key: key) }
    }

    private func mapUnlocked(_ g: Double?, mode: DetectMode, key: String?) -> Velocity {
        let a = anchorsUnlocked(mode, ver)
        let tN = position(a.normal, a)
        switch ver {
        case .v1:
            let dbN = Self.minDb * (1 - tN)
            guard let g, g > 0 else { return Velocity(gainDb: dbN, brightness: tN, layer: 0.5, noSensor: true) }
            let t1 = position(log(g), a)
            let db1 = Self.minDb * (1 - t1)
            return Velocity(gainDb: min(0, max(2 * Self.minDb, dbN + str * (db1 - dbN))),
                            brightness: max(0, min(1, tN + str * (t1 - tN))), layer: 0.5, noSensor: false)
        case .v2:
            guard let g, g > 0 else { return Velocity(gainDb: Self.v2Level, brightness: 1, layer: 0.5, noSensor: true) }
            let x = log(corrected(g, key))
            let t1 = x < a.normal ? 0.5 * max(0, (x - a.lo) / (a.normal - a.lo)) : 0.5 + 0.5 * min(1, (x - a.normal) / (a.hi - a.normal))
            let db = Self.v2Level + str * Self.v2SpanDb * (t1 - 0.5)
            return Velocity(gainDb: min(0, db), brightness: 1, layer: max(0, min(1, 0.5 + str * (t1 - 0.5))), noSensor: false)
        }
    }

    /// Maps a key and feeds the adaptation of both versions.
    public func process(_ g: Double?, mode: DetectMode, key: String? = nil) -> Velocity {
        locked {
            if let g { feed(g, mode, key) }
            return mapUnlocked(g, mode: mode, key: key)
        }
    }

    /// Feeds the other mode's trackers (peak mode also measures the instant impact).
    public func observe(_ g: Double?, mode: DetectMode, key: String? = nil) {
        locked { if let g { feed(g, mode, key) } }
    }

    private func feed(_ g: Double, _ mode: DetectMode, _ key: String?) {
        trackers[mode, default: AdaptiveTracker()].add(g)
        trackers2[mode, default: AdaptiveTracker()].add(corrected(g, key))
    }
}

/// Low-pass cutoff for a brightness: 2.5 kHz (soft) … 20 kHz (hard), log-spaced; ≥ 0.98 = bypass.
public func lowpassHz(brightness b: Double) -> Double { 2500 * pow(8, max(0, min(1, b))) }

/// Fixed per-key voicing, so the board sounds like many keys: a deterministic hash of the key code
/// gives each key its own small pitch (±30 cents), level (±0.7 dB) and tone (±0.06 layer/brightness)
/// offset, the same on every press.
public enum KeyVoicing {
    public static func offsets(_ code: UInt16) -> (cents: Double, db: Double, tone: Double) {
        func unit(_ salt: UInt64) -> Double {   // splitmix64 → −1 … 1
            var z = UInt64(code) &* 0x9E37_79B9_7F4A_7C15 &+ salt
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53) * 2 - 1
        }
        return (30 * unit(0x6B65_7973), 0.7 * unit(0x736F_756E), 0.06 * unit(0x7469_6D62))
    }
}
