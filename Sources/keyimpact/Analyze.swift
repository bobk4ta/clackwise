import Foundation
import ClackwiseCore

// Analysis window, relative to the key event timestamp (ms).
let GRAV_FROM = -300.0, GRAV_TO = -80.0     // gravity estimate (per-axis median)
let SEARCH_FROM = -40.0, SEARCH_TO = 120.0  // where to look for the impact peak

struct SampleData {
    var t: [UInt64] = [], arr: [UInt64] = []
    var x: [Double] = [], y: [Double] = [], z: [Double] = []
    var dt: Double = 1.245  // ms

    func lower(_ ts: UInt64) -> Int {
        var lo = 0, hi = t.count
        while lo < hi { let m = (lo + hi) / 2; if t[m] < ts { lo = m + 1 } else { hi = m } }
        return lo
    }
    func idx(_ ts: UInt64, _ fromMs: Double, _ toMs: Double) -> Range<Int> {
        let a = lower(UInt64(Int64(ts) + msToTicks(fromMs)))
        let b = lower(UInt64(Int64(ts) + msToTicks(toMs)) + 1)
        return a..<max(a, b)
    }
}

struct Ev { let kind: String; let phase: Int; let name: String; let ts: UInt64; let recv: UInt64 }

struct Impact {
    var peak = 0.0, peakT = 0.0          // g, ms rel. to key ts
    var jerk = 0.0, jerkT = 0.0          // g/s
    var peakArrival: UInt64 = 0          // when the peak sample reached user space
    var pre = 0.0                        // max |a-g| in gravity window (noise before key)
}

func median(_ a: [Double]) -> Double { pct(a, 50) }

/// Summary output: printed and collected for summary.txt.
var summaryLines: [String] = []
func emit(_ s: String = "") { print(s); summaryLines.append(s) }

/// Impact around `ts`. If `availableBy` is set, only samples that had arrived by then are used.
func impact(_ d: SampleData, at ts: UInt64, availableBy: UInt64? = nil) -> Impact? {
    let g = d.idx(ts, GRAV_FROM, GRAV_TO)
    guard g.count > 50 else { return nil }
    let gx = median(Array(d.x[g])), gy = median(Array(d.y[g])), gz = median(Array(d.z[g]))
    var r = Impact()
    for i in g { r.pre = max(r.pre, sqrt(pow(d.x[i] - gx, 2) + pow(d.y[i] - gy, 2) + pow(d.z[i] - gz, 2))) }
    let w = d.idx(ts, SEARCH_FROM, SEARCH_TO)
    guard w.count > 10 else { return nil }
    for i in w {
        if let lim = availableBy, d.arr[i] > lim { break }
        let m = sqrt(pow(d.x[i] - gx, 2) + pow(d.y[i] - gy, 2) + pow(d.z[i] - gz, 2))
        if m > r.peak { r.peak = m; r.peakT = ticksToMs(Int64(d.t[i]) - Int64(ts)); r.peakArrival = d.arr[i] }
        let dtS = ticksToMs(Int64(d.t[i]) - Int64(d.t[i - 1])) / 1000
        let j = sqrt(pow(d.x[i] - d.x[i - 1], 2) + pow(d.y[i] - d.y[i - 1], 2) + pow(d.z[i] - d.z[i - 1], 2)) / max(dtS, 1e-4)
        if j > r.jerk { r.jerk = j; r.jerkT = ticksToMs(Int64(d.t[i]) - Int64(ts)) }
    }
    return r
}

func loadCSV(_ url: URL) -> [[Substring]] {
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { emit("cannot read \(url.path)"); exit(1) }
    return s.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) }
}

func f(_ v: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", v) }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

func analyze(dir: URL) {
    summaryLines = []
    var d = SampleData()
    for r in loadCSV(dir.appendingPathComponent("samples.csv")) where r.count == 5 {
        d.t.append(UInt64(r[0])!); d.arr.append(UInt64(r[1])!)
        d.x.append(Double(r[2])!); d.y.append(Double(r[3])!); d.z.append(Double(r[4])!)
    }
    let evs = loadCSV(dir.appendingPathComponent("events.csv")).compactMap { r -> Ev? in
        r.count == 6 ? Ev(kind: String(r[0]), phase: Int(r[1])!, name: String(r[2]), ts: UInt64(r[4])!, recv: UInt64(r[5])!) : nil
    }
    let meta = (try? String(contentsOf: dir.appendingPathComponent("meta.txt"), encoding: .utf8)) ?? ""
    let span = ticksToMs(Int64(d.t.last!) - Int64(d.t.first!))
    var gaps = 0
    for i in 1..<d.t.count where ticksToMs(Int64(d.t[i]) - Int64(d.t[i - 1])) > 5 { gaps += 1 }

    emit("════════ KEYSTROKE IMPACT SUMMARY ════════")
    emit("data: \(dir.lastPathComponent)   \(meta.split(separator: "\n").first ?? "")")
    emit("accelerometer: \(d.t.count) samples, \(f(Double(d.t.count - 1) / span * 1000, 1)) Hz, gaps>5ms: \(gaps)")
    emit("window: gravity = median of [\(Int(GRAV_FROM)),\(Int(GRAV_TO))] ms, impact searched in [\(Int(SEARCH_FROM)),+\(Int(SEARCH_TO))] ms around key event")

    let keyPhases = ["soft", "normal", "hard"]
    var byPhase: [String: [(Ev, Impact)]] = [:]
    let keys = evs.filter { $0.kind == "key" }
    var crowded = 0
    var perKey = "phase,n,t_s,peak_g,peak_offset_ms,jerk_gps,jerk_offset_ms,pre_noise_g,event_delivery_ms,peak_after_recv_ms,crowded\n"
    var nInPhase: [String: Int] = [:]
    for (i, e) in keys.enumerated() {
        let near = keys.enumerated().contains { j, o in j != i && abs(ticksToMs(Int64(o.ts) - Int64(e.ts))) < 150 }
        if near { crowded += 1 }
        guard let im = impact(d, at: e.ts) else { continue }
        byPhase[e.name, default: []].append((e, im))
        nInPhase[e.name, default: 0] += 1
        perKey += [e.name, "\(nInPhase[e.name]!)", f(ticksToMs(Int64(e.ts) - Int64(d.t[0])) / 1000, 3),
                   f(im.peak, 5), f(im.peakT, 2), f(im.jerk, 2), f(im.jerkT, 2), f(im.pre, 5),
                   f(ticksToMs(Int64(e.recv) - Int64(e.ts)), 3), f(ticksToMs(Int64(im.peakArrival) - Int64(e.recv)), 2),
                   near ? "1" : "0"].joined(separator: ",") + "\n"
    }
    try? perKey.write(to: dir.appendingPathComponent("keys.csv"), atomically: true, encoding: .utf8)

    // ── Per-phase table
    emit("\nPer-phase impact (n keystrokes; p10 / median / p90)")
    emit("phase    n   peak |a-g| (g)               jerk (g/s)                 pre-key noise (g)")
    for p in keyPhases {
        let v = byPhase[p] ?? []
        let pk = v.map(\.1.peak), jk = v.map(\.1.jerk), pre = v.map(\.1.pre)
        emit("\(p.padding(toLength: 7, withPad: " ", startingAt: 0)) \(pad("\(v.count)", 2))   "
              + "\(pad(f(pct(pk, 10)), 6)) / \(pad(f(pct(pk, 50)), 6)) / \(pad(f(pct(pk, 90)), 6))    "
              + "\(pad(f(pct(jk, 10), 1), 6)) / \(pad(f(pct(jk, 50), 1), 6)) / \(pad(f(pct(jk, 90), 1), 6))    "
              + "\(f(pct(pre, 50)))")
    }
    if crowded > 0 { emit("(\(crowded) keystrokes had another key within 150 ms; their windows overlap)") }

    // ── Separation
    func sep(_ m: KeyPath<Impact, Double>) -> (ratio: Double, auc: Double, dprime: Double, levels: Double) {
        let s = (byPhase["soft"] ?? []).map { $0.1[keyPath: m] }, h = (byPhase["hard"] ?? []).map { $0.1[keyPath: m] }
        guard !s.isEmpty, !h.isEmpty else { return (.nan, .nan, .nan, .nan) }
        var wins = 0.0
        for a in h { for b in s { wins += a > b ? 1 : (a == b ? 0.5 : 0) } }
        func stats(_ a: [Double]) -> (Double, Double) {
            let l = a.map { log(max($0, 1e-6)) }; let mu = l.reduce(0, +) / Double(l.count)
            return (mu, sqrt(l.map { pow($0 - mu, 2) }.reduce(0, +) / Double(max(l.count - 1, 1))))
        }
        let phasesStats = keyPhases.compactMap { byPhase[$0].map { stats($0.map { $0.1[keyPath: m] }) } }
        let sd = phasesStats.map(\.1).reduce(0, +) / Double(phasesStats.count)
        let (ms, _) = stats(s), (mh, _) = stats(h)
        return (pct(h, 10) / pct(s, 90), wins / Double(s.count * h.count), (mh - ms) / sd, 1 + (mh - ms) / (2 * sd))
    }
    let sp = sep(\.peak), sj = sep(\.jerk)
    emit("\nSeparation hard vs soft        p10(hard)/p90(soft)   P(hard>soft)   d' (log)   ~levels (2σ apart)")
    emit("  peak |a-g|                    \(pad(f(sp.ratio, 2), 6)) \(sp.ratio > 1 ? "CLEAN " : "overlap")        \(f(sp.auc, 3))        \(pad(f(sp.dprime, 2), 5))      \(f(sp.levels, 1))")
    emit("  jerk                          \(pad(f(sj.ratio, 2), 6)) \(sj.ratio > 1 ? "CLEAN " : "overlap")        \(f(sj.auc, 3))        \(pad(f(sj.dprime, 2), 5))      \(f(sj.levels, 1))")
    let best = sp.dprime >= sj.dprime ? "peak" : "jerk"
    emit("  → better metric: \(best)")
    // Also normal vs neighbours
    func ratio(_ lo: String, _ hi: String, _ m: KeyPath<Impact, Double>) -> Double {
        pct((byPhase[hi] ?? []).map { $0.1[keyPath: m] }, 10) / pct((byPhase[lo] ?? []).map { $0.1[keyPath: m] }, 90)
    }
    let bm: KeyPath<Impact, Double> = best == "peak" ? \.peak : \.jerk
    emit("  \(best): p10(normal)/p90(soft) = \(f(ratio("soft", "normal", bm), 2))   p10(hard)/p90(normal) = \(f(ratio("normal", "hard", bm), 2))   (>1 = clean)")

    // ── Timing
    let good = (byPhase["normal"] ?? []) + (byPhase["hard"] ?? [])
    let all = keyPhases.flatMap { byPhase[$0] ?? [] }
    let evLat = all.map { ticksToMs(Int64($0.0.recv) - Int64($0.0.ts)) }
    let pkT = good.map(\.1.peakT), jkT = good.map(\.1.jerkT)
    let need = good.map { ticksToMs(Int64($0.1.peakArrival) - Int64($0.0.recv)) }
    emit("\nTiming (normal+hard keys, ms; 0 = key event timestamp)")
    emit("  event clock: \(meta.split(separator: "\n").first.map(String.init) ?? "?")")
    emit("  key event delivery to tap (recv - ts):    p50 \(f(pct(evLat, 50), 2))  p90 \(f(pct(evLat, 90), 2))  max \(f(evLat.max() ?? .nan, 2))")
    emit("  peak |a-g| offset:  p10 \(f(pct(pkT, 10), 1))  p50 \(f(pct(pkT, 50), 1))  p90 \(f(pct(pkT, 90), 1))  min \(f(pkT.min() ?? .nan, 1))  max \(f(pkT.max() ?? .nan, 1))")
    emit("  peak jerk offset:   p10 \(f(pct(jkT, 10), 1))  p50 \(f(pct(jkT, 50), 1))  p90 \(f(pct(jkT, 90), 1))")
    emit("  peak sample in user space, after tap callback: p50 \(f(pct(need, 50), 1))  p90 \(f(pct(need, 90), 1))  p95 \(f(pct(need, 95), 1))  max \(f(need.max() ?? .nan, 1))")

    // Mean envelope of |a-g| around the key, 5 ms bins.
    let bars = Array("▁▂▃▄▅▆▇█")
    for p in keyPhases {
        guard let v = byPhase[p], !v.isEmpty else { continue }
        var bins = [Double](repeating: 0, count: 32)
        for (e, _) in v {
            let g = d.idx(e.ts, GRAV_FROM, GRAV_TO)
            let gx = median(Array(d.x[g])), gy = median(Array(d.y[g])), gz = median(Array(d.z[g]))
            for i in d.idx(e.ts, -40, 120) {
                let b = Int((ticksToMs(Int64(d.t[i]) - Int64(e.ts)) + 40) / 5)
                if b >= 0 && b < 32 { bins[b] = max(bins[b], 0) + sqrt(pow(d.x[i] - gx, 2) + pow(d.y[i] - gy, 2) + pow(d.z[i] - gz, 2)) / Double(v.count) }
            }
        }
        let mx = bins.max()!
        let s = String(bins.map { bars[min(7, Int($0 / mx * 7.99))] })
        emit("  mean |a-g| \(p.padding(toLength: 6, withPad: " ", startingAt: 0)) -40ms \(s) +120ms  (peak bin \(Int(bins.firstIndex(of: mx)!) * 5 - 40)…\(Int(bins.firstIndex(of: mx)!) * 5 - 35) ms)")
    }

    // Separation if we stop waiting W ms after the tap callback.
    emit("\nIf the app waits W ms after receiving the key event (only data that had arrived by then):")
    emit("    W   \(best) p10(hard)/p90(soft)   P(hard>soft)  P(normal>soft)  P(hard>normal)  d'(log s→h)  ~levels   keys within 10% of full value")
    func auc(_ lo: [Double], _ hi: [Double]) -> Double {
        var w = 0.0
        for a in hi { for b in lo { w += a > b ? 1 : (a == b ? 0.5 : 0) } }
        return w / Double(max(lo.count * hi.count, 1))
    }
    func logStats(_ a: [Double]) -> (Double, Double) {
        let l = a.map { log(max($0, 1e-6)) }; let mu = l.reduce(0, +) / Double(max(l.count, 1))
        return (mu, sqrt(l.map { pow($0 - mu, 2) }.reduce(0, +) / Double(max(l.count - 1, 1))))
    }
    var recommended: Double?
    for w in [0.0, 2, 5, 10, 15, 20, 25, 30, 40, 50, 70, 100] {
        var vals: [String: [Double]] = [:]; var within = 0, n = 0
        for p in keyPhases {
            for (e, full) in byPhase[p] ?? [] {
                guard let im = impact(d, at: e.ts, availableBy: e.recv &+ UInt64(msToTicks(w))) else { continue }
                let v = im[keyPath: bm], fv = full[keyPath: bm]
                vals[p, default: []].append(v)
                n += 1; if v >= 0.9 * fv { within += 1 }
            }
        }
        let s = vals["soft"] ?? [], nm = vals["normal"] ?? [], h = vals["hard"] ?? []
        let st = [s, nm, h].map(logStats)
        let sd = st.map(\.1).reduce(0, +) / 3, dp = (st[2].0 - st[0].0) / sd
        let frac = Double(within) / Double(max(n, 1))
        if recommended == nil && frac >= 0.95 { recommended = w }
        emit("  \(pad(f(w, 0), 3))   \(pad(f(pct(h, 10) / pct(s, 90), 2), 10))              \(f(auc(s, h), 3))         \(f(auc(s, nm), 3))           \(f(auc(nm, h), 3))          \(pad(f(dp, 2), 5))       \(f(1 + dp / 2, 1))         \(pad(f(frac * 100, 0), 3))%")
    }
    emit("  → wait for the full peak ≈ \(recommended.map { f($0, 0) } ?? ">100") ms (first W where ≥95% of keys reach ≥90% of their full impact)")
    emit("  → but compare the W=0 row: the impact starts before the keyDown timestamp (keyboard debounce), so")
    emit("    the separation available at W=0 may already be as good; pick the W with the best separation.")

    // ── Noise
    emit("\nNoise (impact computed at virtual key events every 20 ms, same windows)")
    for name in ["floor", "noise"] {
        guard let s = evs.first(where: { $0.kind == "phase_start" && $0.name == name }),
              let e = evs.first(where: { $0.kind == "phase_end" && $0.name == name }) else { continue }
        var pk: [Double] = [], jk: [Double] = []
        var t = s.ts &+ UInt64(msToTicks(300))
        while t &+ UInt64(msToTicks(SEARCH_TO)) < e.ts {
            if let im = impact(d, at: t) { pk.append(im.peak); jk.append(im.jerk) }
            t &+= UInt64(msToTicks(20))
        }
        let stray = evs.filter { $0.kind == "stray" && $0.name == name }.count
        emit("  \(name.padding(toLength: 6, withPad: " ", startingAt: 0)) peak g: p50 \(f(pct(pk, 50))) p99 \(f(pct(pk, 99))) max \(f(pk.max() ?? .nan))   "
              + "jerk g/s: p50 \(f(pct(jk, 50), 1)) p99 \(f(pct(jk, 99), 1)) max \(f(jk.max() ?? .nan, 1))"
              + (stray > 0 ? "   (\(stray) stray keys typed!)" : ""))
        if name == "noise", let soft = byPhase["soft"], let hard = byPhase["hard"] {
            let sm = median(soft.map { $0.1[keyPath: bm] }), hm = median(hard.map { $0.1[keyPath: bm] })
            let nm = (best == "peak" ? pk : jk).max() ?? .nan
            emit("         palm/trackpad max \(best) = \(f(nm / sm, 2))× soft median, \(f(nm / hm, 2))× hard median")
        }
    }
    emit("══════════════════════════════════════════")
    try? summaryLines.joined(separator: "\n").appending("\n").write(to: dir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    print("Wrote \(dir.appendingPathComponent("summary.txt").path) and keys.csv")
}
