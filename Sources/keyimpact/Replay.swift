import Foundation
import ClackwiseCore

/// A recorded session, loaded for replay through the same detector code the app uses.
struct Session {
    var samples: [Sample] = []
    var keys: [(phase: String, ts: UInt64, recv: UInt64)] = []
    var phases: [String: (start: UInt64, end: UInt64)] = [:]

    init(dir: URL) {
        for r in loadCSV(dir.appendingPathComponent("samples.csv")) where r.count == 5 {
            samples.append(Sample(t: UInt64(r[0])!, arrival: UInt64(r[1])!, x: Double(r[2])!, y: Double(r[3])!, z: Double(r[4])!))
        }
        for r in loadCSV(dir.appendingPathComponent("events.csv")) where r.count == 6 {
            let ts = UInt64(r[4])!, name = String(r[2])
            switch r[0] {
            case "key": keys.append((name, ts, UInt64(r[5])!))
            case "phase_start": phases[name, default: (0, 0)].start = ts
            case "phase_end": phases[name, default: (0, 0)].end = ts
            default: break
            }
        }
    }

    func lower(_ ts: UInt64) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi { let m = (lo + hi) / 2; if samples[m].t < ts { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// Impact exactly as the app computes it: only samples that had arrived by `recv + waitMs`.
    func impact(ts: UInt64, recv: UInt64, prev: UInt64?, mode: DetectMode, scratch: inout [Double]) -> Double? {
        let wait = mode == .peak ? ImpactWindow.peakWaitMs : 0
        let availableBy = recv &+ UInt64(msToTicks(wait))
        let a = lower(UInt64(max(0, Int64(ts) + msToTicks(ImpactWindow.gravFromMs))))
        let b = lower(availableBy &+ UInt64(msToTicks(50)))
        return ImpactMath.impact(samples[a..<b], keyTs: ts, searchFrom: ImpactMath.searchStart(keyTs: ts, prevKeyTs: prev),
                                 availableBy: availableBy, scratch: &scratch)
    }

    /// Per-phase impacts for real keys, plus virtual "keys" every 20 ms in the floor/noise phases.
    func impacts(mode: DetectMode) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        var scratch: [Double] = []
        var prev: UInt64?
        for k in keys {
            if let v = impact(ts: k.ts, recv: k.recv, prev: prev, mode: mode, scratch: &scratch) { out[k.phase, default: []].append(v) }
            prev = k.ts
        }
        for name in ["floor", "noise"] {
            guard let p = phases[name] else { continue }
            var t = p.start &+ UInt64(msToTicks(300))
            while t &+ UInt64(msToTicks(ImpactWindow.peakWaitMs + 50)) < p.end {
                if let v = impact(ts: t, recv: t &+ UInt64(msToTicks(0.7)), prev: nil, mode: mode, scratch: &scratch) {
                    out[name, default: []].append(v)
                }
                t &+= UInt64(msToTicks(20))
            }
        }
        return out
    }
}

func replay(dir: URL) {
    let s = Session(dir: dir)
    print("replay \(dir.path): \(s.samples.count) samples, \(s.keys.count) keys")
    for mode in DetectMode.allCases {
        let imp = s.impacts(mode: mode)
        print("\n[\(mode.rawValue)] impact g: p10 / p50 / p90  (min, max)")
        for p in ["soft", "normal", "hard", "floor", "noise"] {
            guard let v = imp[p] else { continue }
            print("  \(p.padding(toLength: 7, withPad: " ", startingAt: 0)) n=\(pad("\(v.count)", 3))  \(f(pct(v, 10), 4)) / \(f(pct(v, 50), 4)) / \(f(pct(v, 90), 4))   (\(f(v.min()!, 4)), \(f(v.max()!, 4)))  p99 \(f(pct(v, 99), 4))")
        }
        for p in ["soft", "normal", "hard"] { print("  \(p): " + (imp[p] ?? []).sorted().map { f($0, 4) }.joined(separator: " ")) }
    }
}

func calibrationFrom(_ s: Session, source: String) -> Calibration {
    var c = Calibration.builtIn
    c.source = source
    for mode in DetectMode.allCases {
        let imp = s.impacts(mode: mode)
        c[mode] = Calibration.derive(soft: imp["soft"] ?? [], normal: imp["normal"] ?? [], hard: imp["hard"] ?? [])
    }
    return c
}

/// v1 from a lab session, v2 from real-use stats (`--stats`). With `--stats` only, the v1 part of
/// the existing calibration file is kept as is (same source string, so the learned v1 adaptation stays valid).
func calibrate(dir: URL?, stats: URL?, base: URL, out: URL?) {
    var c: Calibration
    if let dir {
        c = calibrationFrom(Session(dir: dir), source: "keyimpact calibrate \(dir.resolvingSymlinksInPath().lastPathComponent)")
        c.v2 = Calibration.load(base)?.v2
    } else {
        c = Calibration.load(base) ?? .builtIn
    }
    if let stats {
        guard let data = try? Data(contentsOf: stats), let sf = try? JSONDecoder().decode(StatsFile.self, from: data) else {
            print("can't read \(stats.path)"); exit(1)
        }
        guard let v2 = Calibration.deriveV2(from: sf, source: "keyimpact calibrate --stats (\(sf.presses) presses, saved \(sf.savedOn))") else {
            print("not enough presses with sensor data in \(stats.path)"); exit(1)
        }
        c.v2 = v2
        let raw = sf.impactInstant.map(Double.init)
        print("v2 from \(sf.presses) presses: raw instant p10/p50/p90 \([0.1, 0.5, 0.9].map { f(exp(LogBins.quantile(raw, $0)!) * 1000, 1) }.joined(separator: " / ")) mg → corrected \(f(v2.instant.softG * 1000, 1)) / \(f(v2.instant.normalG * 1000, 1)) / \(f(v2.instant.hardG * 1000, 1)) mg")
        print("per-key offsets (\(v2.keyOffsets.count) keys with ≥ \(KeyCorrection.minPresses) presses): " +
              v2.keyOffsets.sorted { $0.value > $1.value }.map { "\($0.key) ×\(f(exp($0.value), 2))" }.joined(separator: ", "))
    }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let json = try! enc.encode(c)
    print(String(data: json, encoding: .utf8)!)
    if let out { try! json.write(to: out); print("wrote \(out.path)") }
}

/// Maps every recorded key through VelocityMapper, then simulates the adaptation.
func replayMapping(dir: URL, calibration: Calibration) {
    let s = Session(dir: dir)
    print("\ncalibration: \(calibration.source)")
    for mode in DetectMode.allCases {
        let imp = s.impacts(mode: mode)
        let m = VelocityMapper(calibration: calibration)
        let a = m.anchors(mode)
        print("\n[\(mode.rawValue)] anchors: soft \(f(exp(a.lo) * 1000, 1)) mg → \(Int(VelocityMapper.minDb)) dB, hard \(f(exp(a.hi) * 1000, 1)) mg → 0 dB, normal \(f(exp(a.normal) * 1000, 1)) mg → \(f(m.map(exp(a.normal), mode: mode).gainDb, 1)) dB")
        print("  phase    gain dB p10 / p50 / p90     brightness p50   low-pass p50")
        for p in ["soft", "normal", "hard"] {
            let v = (imp[p] ?? []).map { m.map($0, mode: mode) }
            let db = v.map(\.gainDb), br = v.map(\.brightness)
            print("  \(p.padding(toLength: 7, withPad: " ", startingAt: 0))  \(pad(f(pct(db, 10), 1), 6)) / \(pad(f(pct(db, 50), 1), 5)) / \(pad(f(pct(db, 90), 1), 5))        \(f(pct(br, 50), 2))         \(pad(f(lowpassHz(brightness: pct(br, 50)) / 1000, 1), 4)) kHz")
        }
        // Discrete check of "continuous": distinct gain values over all keys.
        let all = ["soft", "normal", "hard"].flatMap { imp[$0] ?? [] }.map { m.map($0, mode: mode).gainDb }
        m.version = .v2
        let lay = ["soft", "normal", "hard"].map { p in (imp[p] ?? []).map { m.map($0, mode: mode) } }
        print("  v2 (no key ids → no per-key correction): layer p50 soft \(f(pct(lay[0].map(\.layer), 50), 2)), normal \(f(pct(lay[1].map(\.layer), 50), 2)), hard \(f(pct(lay[2].map(\.layer), 50), 2));  dB p50 \(lay.map { f(pct($0.map(\.gainDb), 50), 1) }.joined(separator: " / "))")
        m.version = .v1
        print("  distinct gain values over \(all.count) keys: \(Set(all.map { f($0, 2) }).count)   (strength 0 → all \(f(VelocityMapper(calibration: calibration).with(strength: 0).map(0.1, mode: mode).gainDb, 1)) dB)")
        let hardDb = (imp["hard"] ?? []).map { m.map($0, mode: mode).gainDb }
        print("  hard keys at ≥ −1 dB: \(hardDb.filter { $0 >= -1 }.count)/\(hardDb.count);  soft keys at ≤ −10 dB: \((imp["soft"] ?? []).map { m.map($0, mode: mode).gainDb }.filter { $0 <= -10 }.count)/\(imp["soft"]?.count ?? 0)")
    }

    // Adaptation: replay the normal phase as if it were everyday typing, scaled.
    print("\nAdaptation simulation (instant): type the recorded normal keys over and over, scaled by k")
    print("    k     keys   shift      span×   normal-median → dB   soft → dB   hard → dB")
    let normal = s.impacts(mode: .instant)["normal"] ?? []
    let soft = pct(s.impacts(mode: .instant)["soft"] ?? [], 50), hard = pct(s.impacts(mode: .instant)["hard"] ?? [], 50)
    for k in [0.25, 0.5, 1.0, 2.0, 4.0] {
        let m = VelocityMapper(calibration: calibration)
        for n in [0, 200, 600, 3000] {
            while (m.anchors(.instant).state.keys) < n { _ = m.process(normal[m.anchors(.instant).state.keys % normal.count] * k, mode: .instant) }
            let st = m.anchors(.instant).state
            print("  \(pad(f(k, 2), 5))  \(pad("\(n)", 5))   \(pad(f(st.shift, 2), 5)) (×\(f(exp(st.shift), 2)))  \(f(st.spreadScale, 2))        \(pad(f(m.map(pct(normal, 50) * k, mode: .instant).gainDb, 1), 5))            \(pad(f(m.map(soft * k, mode: .instant).gainDb, 1), 5))       \(pad(f(m.map(hard * k, mode: .instant).gainDb, 1), 5))")
        }
    }
}

extension VelocityMapper {
    func with(strength s: Double) -> VelocityMapper { strength = s; return self }
}
