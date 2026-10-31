import Foundation
import CoreGraphics
import ClackwiseCore

/// How much of Clackwise's own playback reaches the accelerometer. Plays press + key-up pairs of the
/// app's current pack through the normal output path (KeyAudioEngine, app volume and the v2 median
/// level), in alternating blocks at full volume and at volume 0 (identical timing, no sound), with
/// no typing. Per sound: peak |Δz| after the sound leaves the device, when it first crosses each
/// onset threshold, and how often the onset detector (same rules as OnsetMonitor) fires or is
/// held busy by the sound.
func selfShake(trials: Int, volume: Double?) {
    let app = UserDefaults(suiteName: "io.github.bobk4ta.clackwise")
    let packs = SoundPackLoader.discover(in: [packsRoot()])
    let id = app?.string(forKey: "pack")
    guard let pack = packs.first(where: { $0.id == id }) ?? packs.first, let bank = SoundBank(pack: pack) else { print("no pack"); exit(1) }
    let vol = volume ?? (app?.object(forKey: "volume") as? Double ?? 0.8)

    var samples: [Sample] = []
    samples.reserveCapacity(800 * 120)
    let sLock = NSLock()
    wakeAccelDriver()
    let acc = Accelerometer(ring: Ring(cap: 1024))
    acc.sampleHook = { s in sLock.lock(); samples.append(s); sLock.unlock() }
    guard acc.open().0 == kIOReturnSuccess else { print("accelerometer open failed"); exit(1) }
    acc.start()
    wakeAccelDriver()

    let eng = KeyAudioEngine()
    eng.volume = 0
    do { try eng.start(bufferFrames: 64) } catch { print("engine start failed: \(error)"); exit(1) }
    Thread.sleep(forTimeInterval: 1.0)
    let d = eng.deviceInfo()
    print("pack \(pack.id), app volume \(f(vol * 100, 0)) %, output \(d.name) [\(d.transport)], device+stream \(f(d.hardwareMs, 2)) ms")
    print("\(trials) trials (press, key-up 110 ms later), blocks of 10 alternating loud / silent; don't touch the Mac…")

    struct Sound { var t: UInt64; var loud: Bool; var up: Bool }
    var sounds: [Sound] = []
    let gain = bank.gain * Float(pow(10, VelocityMapper.v2Level / 20))
    let codes: [CGKeyCode] = [0x00, 0x01, 0x02, 0x03, 0x0C, 0x0D, 0x06, 0x07, 0x31, 0x24]
    for i in 0..<trials {
        let loud = (i / 10) % 2 == 0
        eng.volume = loud ? Float(vol) : 0
        Thread.sleep(forTimeInterval: Double.random(in: 0.35...0.5))
        let code = codes[i % codes.count]
        for up in [false, true] {
            if up { Thread.sleep(forTimeInterval: 0.11) }
            let now = mach_absolute_time()
            eng.play(bank.clip(for: code, up: up)!, gain: gain, brightness: 1, pitch: 1, layer: 0.5, eventTicks: now)
            sounds.append(Sound(t: now, loud: loud, up: up))
        }
    }
    Thread.sleep(forTimeInterval: 0.6)
    let lat = eng.latencyStats()
    eng.stop()
    acc.close()
    sLock.lock(); let s = samples; sLock.unlock()
    guard s.count > 1000, lat.eventToOutput.count == sounds.count else {
        print("not enough data: \(s.count) samples, \(lat.eventToOutput.count)/\(sounds.count) sounds rendered"); exit(1)
    }
    // play() → sound out, per sound (render pickup + HAL output time + device/stream latency).
    let outMs = lat.endToEnd
    print("play() → sound out: p50 \(f(pct(outMs, 50), 2)) ms; \(s.count) sensor samples")

    let ts = s.map(\.t), z = s.map(\.z)
    func idx(_ t: UInt64) -> Int {   // first sample with ts >= t
        var lo = 0, hi = ts.count
        while lo < hi { let m = (lo + hi) / 2; if ts[m] < t { lo = m + 1 } else { hi = m } }
        return lo
    }
    func at(_ base: UInt64, _ ms: Double) -> UInt64 { UInt64(Int64(base) + msToTicks(ms)) }

    // Per sound: baseline = median z over [−100, −5] ms before play(); trace relative to sound out.
    let thr = OnsetMonitor.thresholdsMg
    struct Row { var loud: Bool; var up: Bool; var peak: Double; var first: [Double?]; var pre: Double }
    var rows: [Row] = []
    for (k, snd) in sounds.enumerated() {
        let out = at(snd.t, outMs[k])
        var pre = Array(z[idx(at(snd.t, -100))..<idx(at(snd.t, -5))])
        guard pre.count > 50 else { continue }
        pre.sort()
        let base = pre[pre.count / 2]
        let preDev = max(abs(pre.first! - base), abs(pre.last! - base))
        var peak = 0.0
        var first = [Double?](repeating: nil, count: thr.count)
        for j in idx(at(out, -10))..<idx(at(out, 100)) {
            let dev = abs(z[j] - base)
            peak = max(peak, dev)
            for (n, t) in thr.enumerated() where first[n] == nil && dev >= t / 1000 { first[n] = ticksToMs(Int64(ts[j]) - Int64(out)) }
        }
        rows.append(Row(loud: snd.loud, up: snd.up, peak: peak, first: first, pre: preDev))
    }

    // The onset detector as in OnsetMonitor, over the whole stream: onsets within [−10, +100] ms of
    // sound out, and the fraction of time it is busy (not armed) in loud vs silent blocks.
    var detOnsets = [[UInt64]](repeating: [], count: thr.count)
    var busy = [(loud: Double, silent: Double)](repeating: (0, 0), count: thr.count)
    var total = (loud: 0.0, silent: 0.0)
    var block = 0, lastT = ts[0]
    for (n, t) in thr.enumerated() {
        var armed = true, base = z[0], track = z[0], quiet = 0, since: UInt64 = 0
        lastT = ts[0]; block = 0
        for j in 1..<s.count {
            let dt = ticksToMs(Int64(ts[j]) - Int64(lastT)); lastT = ts[j]
            while block + 1 < sounds.count, sounds[block + 1].t <= ts[j] { block += 1 }
            let loud = sounds[block].loud && ts[j] >= sounds[0].t
            if n == 0, dt < 10 { if loud { total.loud += dt } else { total.silent += dt } }
            let alpha = 1 - exp(-max(0.5, min(10, dt)) / 40)
            track += (z[j] - track) * alpha
            let dev = z[j] - base
            if armed {
                if abs(dev) >= t / 1000 { armed = false; quiet = 0; since = ts[j]; detOnsets[n].append(ts[j]) }
                else { base += (z[j] - base) * alpha }
            } else {
                if dt < 10 { if loud { busy[n].loud += dt } else { busy[n].silent += dt } }
                quiet = abs(dev) < t / 2000 ? quiet + 1 : 0
                let timedOut = ticksToMs(Int64(ts[j]) - Int64(since)) > 300
                if quiet >= 10 || timedOut { armed = true; if timedOut { base = track } }
            }
        }
    }

    for up in [false, true] {
        print("\n\(up ? "key-up" : "press") sounds:              peak |Δz| after sound out (mg)        crosses threshold (share of sounds, median ms after sound out)")
        print("                              p50    p90    max      " + thr.map { "\(pad(f($0, 0), 2)) mg          " }.joined())
        for loud in [true, false] {
            let r = rows.filter { $0.loud == loud && $0.up == up }
            let p = r.map { $0.peak * 1000 }
            let label = loud ? "loud  " : "silent", count = pad("\(r.count)", 3)
            var line = "  \(label) (n=\(count))          \(pad(f(pct(p, 50), 2), 5))  \(pad(f(pct(p, 90), 2), 5))  \(pad(f(p.max() ?? .nan, 2), 5))    "
            for n in thr.indices {
                let hits = r.compactMap { $0.first[n] }
                let share = pad(f(100 * Double(hits.count) / Double(max(1, r.count)), 0), 3)
                let when = hits.isEmpty ? "    —    " : "@ " + pad(f(pct(hits, 50), 1), 5) + "  "
                line += share + "% " + when
            }
            print(line)
        }
    }
    let noisy = rows.filter { $0.pre > 0.013 }.count
    print("\n(\(noisy) sounds had a > 13 mg disturbance in the 100 ms before play(): touched or moved)")

    print("\nonset detector (OnsetMonitor rules) over the stream:")
    print("  thr    onsets near loud sounds  near silent sounds    busy (not armed) loud / silent blocks")
    for (n, t) in thr.enumerated() {
        func near(_ loud: Bool) -> Int {
            sounds.enumerated().filter { $0.element.loud == loud }.reduce(0) { acc, e in
                let out = at(e.element.t, outMs[e.offset])
                return acc + detOnsets[n].filter { $0 >= at(out, -10) && $0 <= at(out, 100) }.count
            }
        }
        print("  \(pad(f(t, 0), 2)) mg  \(pad("\(near(true))", 10))               \(pad("\(near(false))", 10))          \(pad(f(100 * busy[n].loud / max(1, total.loud), 1), 5)) % / \(pad(f(100 * busy[n].silent / max(1, total.silent), 1), 5)) %")
    }
}

/// How wrong a sound started from the shock onset would be before the key is known. Model: the
/// guessed clip plays from the onset; when the key event arrives `lead` ms later the voice
/// crossfades (1 ms) to the right key's clip at the same position. Error = what differs from playing
/// the right clip from the start, i.e. (guess − right) over the first `lead` ms (best of ±2 ms lag
/// and gain, to give the handover the benefit of the doubt). Reported re. the right clip's energy
/// in that window and re. the whole clip.
func keyGuessReport() {
    let packs = SoundPackLoader.discover(in: [packsRoot()]).filter { $0.rowMapped }
    let targets: [(String, CGKeyCode)] = [("Space", 0x31), ("Return", 0x24), ("Delete", 0x33), ("1 (R1)", 0x12), ("Q (R2)", 0x0C), ("Z (R4)", 0x06)]
    let leads = [3.0, 7.5, 11.0]
    print("guess = the A-row sample (R3, the most frequent row). Error of the first `lead` ms, dB re. the right clip's energy in that window / re. the whole clip:")
    print("pack                    " + targets.map { $0.0.padding(toLength: 22, withPad: " ", startingAt: 0) }.joined())
    print("                        " + targets.map { _ in leads.map { "\(f($0, 1))".padding(toLength: 7, withPad: " ", startingAt: 0) }.joined() + " " }.joined() + "(lead ms)")
    for p in packs {
        guard let b = SoundBank(pack: p), let g = b.clip(for: 0x00, up: false, rotate: false) else { continue }
        var line = p.id.padding(toLength: 24, withPad: " ", startingAt: 0)
        for (_, code) in targets {
            guard let t = b.clip(for: code, up: false, rotate: false) else { line += "      —       "; continue }
            var cells: [String] = []
            for lead in leads {
                let n = Int(lead / 1000 * t.sampleRate)
                var whole = 0.0
                for i in 0..<t.frames { whole += Double(t.left[i] * t.left[i] + t.right[i] * t.right[i]) }
                var win = 0.0
                for i in 0..<min(n, t.frames) { win += Double(t.left[i] * t.left[i] + t.right[i] * t.right[i]) }
                var best = Double.infinity
                let maxLag = Int(0.002 * t.sampleRate)
                for lag in -maxLag...maxLag {
                    var gt = 0.0, gg = 0.0
                    func gs(_ i: Int) -> (Float, Float) { let j = i + lag; return j >= 0 && j < g.frames ? (g.left[j], g.right[j]) : (0, 0) }
                    for i in 0..<min(n, t.frames) { let (l, r) = gs(i); gt += Double(l * t.left[i] + r * t.right[i]); gg += Double(l * l + r * r) }
                    let k = gg > 0 ? max(0.5, min(2, gt / gg)) : 1
                    var e = 0.0
                    for i in 0..<min(n, t.frames) {
                        let (l, r) = gs(i)
                        let dl = Double(t.left[i]) - k * Double(l), dr = Double(t.right[i]) - k * Double(r)
                        e += dl * dl + dr * dr
                    }
                    best = min(best, e)
                }
                cells.append("\(f(10 * log10(best / win), 0))/\(f(10 * log10(best / whole), 0))")
            }
            line += cells.map { $0.padding(toLength: 7, withPad: " ", startingAt: 0) }.joined() + " "
        }
        print(line)
    }
    print("0 dB re. window = as different as an unrelated sound; the right clip's own energy share in the first lead ms is the second number's ceiling.")
}

/// The shock-onset analysis of step 4 from stats.json: per threshold, detection rate, lead, false
/// onsets per hour, initial-direction filter.
func onsetReport(stats url: URL) {
    guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(StatsFile.self, from: data), let o = s.onsets else {
        print("no onset counters in \(url.path)"); exit(1)
    }
    let hrs = o.monitoredSeconds / 3600, kd = Double(o.keyDowns)
    print("monitored \(f(o.monitoredSeconds / 60, 1)) min, \(o.keyDowns) key-downs (\(Int(kd / hrs))/h), \(o.keyUps) key-ups, \(o.clicks) clicks")
    func q(_ h: [Int], _ p: Double) -> Double {
        let tot = Double(h.reduce(0, +)); var acc = 0.0
        for (i, v) in h.enumerated() { acc += Double(v); if acc >= p * tot { return Double(i) / 2 - 20 } }
        return .nan
    }
    for t in o.thresholds {
        let d = Double(t.keyDownWithOnset)
        let orphans = t.orphanNearKeyUp + t.orphanNearClick + t.orphanBeforeKeyDown + t.orphanAfterKeyDown + t.orphanNothing
        func pos(_ k: String) -> Int { t.sign[k]?.positive ?? 0 }
        func share(_ k: String) -> String { let n = (t.sign[k]?.positive ?? 0) + (t.sign[k]?.negative ?? 0); return n == 0 ? "—" : "\(Int(100 * Double(pos(k)) / Double(n)))%" }
        let orphanPos = ["keyUp", "click", "beforeKeyDown", "afterKeyDown", "nothing"].map(pos).reduce(0, +)
        let h = t.leadVsCallbackHalfMs
        print("\n\(f(t.thresholdMg, 0)) mg: with onset \(Int(100 * d / kd))%, quiet \(Int(100 * Double(t.keyDownNoOnsetQuiet) / kd))%, busy \(Int(100 * Double(t.keyDownNoOnsetBusy) / kd))%, shared \(t.keyDownSharedOnset)")
        print("  lead vs tap callback p10 / p50 / p90: \(f(q(h, 0.1), 1)) / \(f(q(h, 0.5), 1)) / \(f(q(h, 0.9), 1)) ms;  vs event p50 \(f(q(t.leadVsEventHalfMs, 0.5), 1)) ms;  mean gain over all keys \(f(d / kd * q(h, 0.5), 1)) ms")
        print("  false onsets \(orphans) = \(Int(Double(orphans) / hrs))/h = \(f(Double(orphans) / max(1, d), 2)) per detection (key-up \(t.orphanNearKeyUp), click \(t.orphanNearClick), before key-down \(t.orphanBeforeKeyDown), after key-down \(t.orphanAfterKeyDown), nothing \(t.orphanNothing))")
        print("  Δz > 0 share: key-down \(share("keyDown")), key-up \(share("keyUp")), click \(share("click")), before \(share("beforeKeyDown")), after \(share("afterKeyDown")), nothing \(share("nothing"));  positive-only: \(Int(100 * Double(pos("keyDown")) / kd))% of key-downs, \(Int(Double(orphanPos) / hrs)) false/h")
    }
}
