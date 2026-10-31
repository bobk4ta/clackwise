import Foundation

/// Shock-onset measurement counters (no audible effect). Aggregate only: no key identity, no
/// timestamps. Times are differences in ms, binned.
public struct OnsetStats: Codable, Equatable {
    /// Initial vertical deflection of an onset: Δz = z − baseline at the first sample over threshold.
    public struct Sign: Codable, Equatable { public var positive = 0, negative = 0 }

    public struct Threshold: Codable, Equatable {
        public var thresholdMg: Double
        public var onsets = 0
        /// Key-downs with an onset from 25 ms before to 15 ms after the key event.
        public var keyDownWithOnset = 0
        /// No onset in that window, detector armed: the shock stayed below the threshold.
        public var keyDownNoOnsetQuiet = 0
        /// No onset in that window, detector still inside an earlier shock (fast typing).
        public var keyDownNoOnsetBusy = 0
        /// Only an onset another key-down already took (rollover: two keys, one shock).
        public var keyDownSharedOnset = 0
        /// Tap callback time − onset detection time (sample arrival): what triggering the sound from
        /// the shock would gain. 0.5 ms bins, bin 0 = −20 ms … bin 119 = +39.5 ms (clamped).
        public var leadVsCallbackHalfMs = [Int](repeating: 0, count: 120)
        /// Key event timestamp − onset sample timestamp. Same bins.
        public var leadVsEventHalfMs = [Int](repeating: 0, count: 120)
        /// Onsets no key-down claimed, by what else happened nearby (first match in this order):
        /// key-up event within −30 … +40 ms, mouse/trackpad button event within −30 … +40 ms,
        /// a key-down 25–100 ms after the onset, a key-down 15–200 ms before it, nothing.
        public var orphanNearKeyUp = 0, orphanNearClick = 0, orphanBeforeKeyDown = 0, orphanAfterKeyDown = 0, orphanNothing = 0
        /// Onset − key-up / click event for the orphans near one, 1 ms bins, bin 0 = −40 ms … bin 79 = +39 ms.
        public var keyUpOffsetMs = [Int](repeating: 0, count: 80)
        public var clickOffsetMs = [Int](repeating: 0, count: 80)
        /// Keys: keyDown, keyUp, click, beforeKeyDown, afterKeyDown, nothing.
        public var sign: [String: Sign] = [:]

        public init(thresholdMg: Double) { self.thresholdMg = thresholdMg }

        mutating func add(_ o: Threshold) {
            onsets += o.onsets; keyDownWithOnset += o.keyDownWithOnset; keyDownNoOnsetQuiet += o.keyDownNoOnsetQuiet
            keyDownNoOnsetBusy += o.keyDownNoOnsetBusy; keyDownSharedOnset += o.keyDownSharedOnset
            for i in leadVsCallbackHalfMs.indices { leadVsCallbackHalfMs[i] += o.leadVsCallbackHalfMs[i]; leadVsEventHalfMs[i] += o.leadVsEventHalfMs[i] }
            orphanNearKeyUp += o.orphanNearKeyUp; orphanNearClick += o.orphanNearClick; orphanBeforeKeyDown += o.orphanBeforeKeyDown
            orphanAfterKeyDown += o.orphanAfterKeyDown; orphanNothing += o.orphanNothing
            for i in keyUpOffsetMs.indices { keyUpOffsetMs[i] += o.keyUpOffsetMs[i]; clickOffsetMs[i] += o.clickOffsetMs[i] }
            for (k, s) in o.sign { sign[k, default: Sign()].positive += s.positive; sign[k, default: Sign()].negative += s.negative }
        }
    }

    public var about = "Shock-onset measurement: counters only, no key identity, no timestamps. Detector per threshold on z: onset = |z − baseline| ≥ threshold after being re-armed (12.5 ms below threshold/2); baseline = 40 ms EMA while armed."
    public var monitoredSeconds = 0.0
    public var keyDowns = 0, keyUps = 0, clicks = 0
    public var thresholds = OnsetMonitor.thresholdsMg.map { Threshold(thresholdMg: $0) }

    public init() {}

    /// Median of a lead histogram (0.5 ms bins, bin 0 = −20 ms), linear inside the bin.
    public static func medianMs(_ h: [Int]) -> Double {
        let total = Double(h.reduce(0, +))
        guard total > 0 else { return .nan }
        var acc = 0.0
        for (i, v) in h.enumerated() where v > 0 {
            if acc + Double(v) >= total / 2 { return (Double(i) + (total / 2 - acc) / Double(v)) / 2 - 20 }
            acc += Double(v)
        }
        return .nan
    }

    public mutating func add(_ o: OnsetStats) {
        monitoredSeconds += o.monitoredSeconds
        keyDowns += o.keyDowns; keyUps += o.keyUps; clicks += o.clicks
        for t in o.thresholds {
            if let i = thresholds.firstIndex(where: { $0.thresholdMg == t.thresholdMg }) { thresholds[i].add(t) } else { thresholds.append(t) }
        }
    }
}

/// Watches the sensor stream for shock onsets and relates them to key and click events, to judge
/// whether the sound could be triggered by the shock itself (which starts 7–10 ms before macOS
/// registers the key). Measurement only: nothing here affects what plays.
///
/// Runs on the sensor thread (`feed`, 800 Hz) and the tap thread (events). Event times are held in
/// memory for at most a few hundred ms to pair them up; only binned differences are kept.
public final class OnsetMonitor {
    public static let thresholdsMg = [3.0, 5.0, 8.0, 13.0]
    static let matchBeforeMs = 25.0, matchAfterMs = 15.0   // onset window around a key-down
    static let nearFromMs = -30.0, nearToMs = 40.0           // key-up / click event − onset
    static let rearmSamples = 10                             // ≈ 12.5 ms below threshold/2
    static let maxActiveMs = 300.0                           // then re-baseline (Mac moved)
    static let baselineTauMs = 40.0

    struct Detector {
        var thr: Double
        var armed = true
        var base = 0.0, track = 0.0
        var quiet = 0
        var since: UInt64 = 0
        var busy: [(UInt64, UInt64)] = []    // recent active intervals; ongoing one ends at .max
    }
    struct Onset { var t: UInt64, arrival: UInt64, positive: Bool, det: Int, claimed: Bool }

    private var det: [Detector] = OnsetMonitor.thresholdsMg.map { Detector(thr: $0 / 1000) }
    private var onsets: [Onset] = []
    private var pendingKeys: [(ts: UInt64, recv: UInt64)] = []
    private var keyDowns: [UInt64] = [], keyUps: [UInt64] = [], clicks: [UInt64] = []
    private var delta = OnsetStats()
    private var lastT: UInt64 = 0
    private var started = false
    private var isPaused = true
    private let lock = NSLock()

    public init() {}

    /// Paused: nothing is counted (Clackwise off, no tap, secure input hides key events).
    public var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isPaused }
        set { lock.lock(); isPaused = newValue; if newValue { pendingKeys.removeAll(); onsets.removeAll() }; lock.unlock() }
    }

    /// Counters since the last call.
    public func take() -> OnsetStats {
        lock.lock(); defer { lock.unlock() }
        let d = delta
        delta = OnsetStats()
        return d
    }

    public func keyDown(ts: UInt64, recv: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !isPaused else { return }
        delta.keyDowns += 1
        pendingKeys.append((ts, recv))
        keyDowns.append(ts)
    }

    public func keyUp(ts: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !isPaused else { return }
        delta.keyUps += 1
        keyUps.append(ts)
    }

    public func click(ts: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !isPaused else { return }
        delta.clicks += 1
        clicks.append(ts)
    }

    public func feed(_ s: Sample) {
        lock.lock(); defer { lock.unlock() }
        let z = s.z
        if !started {
            for i in det.indices { det[i].base = z; det[i].track = z }
            started = true
        }
        let dtMs = lastT == 0 ? 0 : ticksToMs(Int64(bitPattern: s.t &- lastT))
        lastT = s.t
        if !isPaused, dtMs > 0, dtMs < 10 { delta.monitoredSeconds += dtMs / 1000 }
        let alpha = 1 - exp(-max(0.5, min(10, dtMs)) / Self.baselineTauMs)

        for i in det.indices {
            det[i].track += (z - det[i].track) * alpha
            let dev = z - det[i].base
            if det[i].armed {
                if abs(dev) >= det[i].thr {
                    det[i].armed = false
                    det[i].quiet = 0
                    det[i].since = s.t
                    det[i].busy.append((s.t, .max))
                    if det[i].busy.count > 8 { det[i].busy.removeFirst() }
                    if !isPaused {
                        delta.thresholds[i].onsets += 1
                        onsets.append(Onset(t: s.t, arrival: s.arrival, positive: dev > 0, det: i, claimed: false))
                    }
                } else {
                    det[i].base += (z - det[i].base) * alpha
                }
            } else {
                det[i].quiet = abs(dev) < det[i].thr / 2 ? det[i].quiet + 1 : 0
                let timedOut = ticksToMs(Int64(bitPattern: s.t &- det[i].since)) > Self.maxActiveMs
                if det[i].quiet >= Self.rearmSamples || timedOut {
                    det[i].armed = true
                    if timedOut { det[i].base = det[i].track }
                    if let last = det[i].busy.indices.last { det[i].busy[last].1 = s.t }
                }
            }
        }
        finalizeKeys(now: s.t)
        finalizeOnsets(now: s.t)
        let horizon = s.t &- UInt64(msToTicks(400))
        if s.t > UInt64(msToTicks(400)) {
            keyDowns.removeAll { $0 < horizon }; keyUps.removeAll { $0 < horizon }; clicks.removeAll { $0 < horizon }
        }
    }

    private func ms(_ a: UInt64, _ b: UInt64) -> Double { ticksToMs(Int64(bitPattern: a &- b)) }

    /// A key-down is decided once every onset up to 15 ms after it has been seen.
    private func finalizeKeys(now: UInt64) {
        while let k = pendingKeys.first, ms(now, k.ts) > Self.matchAfterMs {
            pendingKeys.removeFirst()
            for d in det.indices {
                var th = delta.thresholds[d]
                let inWindow = onsets.indices.filter {
                    onsets[$0].det == d && (-Self.matchAfterMs...Self.matchBeforeMs).contains(ms(k.ts, onsets[$0].t))
                }
                if let j = inWindow.first(where: { !onsets[$0].claimed }) {
                    onsets[j].claimed = true
                    let o = onsets[j]
                    th.keyDownWithOnset += 1
                    th.leadVsCallbackHalfMs[halfBin(ms(k.recv, o.arrival))] += 1
                    th.leadVsEventHalfMs[halfBin(ms(k.ts, o.t))] += 1
                    count(&th, "keyDown", o.positive)
                } else if !inWindow.isEmpty {
                    th.keyDownSharedOnset += 1
                } else {
                    let from = k.ts &- UInt64(msToTicks(Self.matchBeforeMs))
                    let busy = det[d].busy.contains { $0.0 < from && $0.1 >= from }
                    if busy { th.keyDownNoOnsetBusy += 1 } else { th.keyDownNoOnsetQuiet += 1 }
                }
                delta.thresholds[d] = th
            }
        }
    }

    /// An onset nobody claimed is classified 110 ms later (key-downs up to 100 ms after it are known).
    private func finalizeOnsets(now: UInt64) {
        while let o = onsets.first, ms(now, o.t) > 110 {
            onsets.removeFirst()
            guard !o.claimed else { continue }
            var th = delta.thresholds[o.det]
            let near = { (ev: [UInt64]) -> Double? in
                ev.map { self.ms(o.t, $0) }.filter { (-Self.nearToMs...(-Self.nearFromMs)).contains($0) }.min { abs($0) < abs($1) }
            }
            if let off = near(keyUps) {
                th.orphanNearKeyUp += 1; th.keyUpOffsetMs[msBin(off)] += 1; count(&th, "keyUp", o.positive)
            } else if let off = near(clicks) {
                th.orphanNearClick += 1; th.clickOffsetMs[msBin(off)] += 1; count(&th, "click", o.positive)
            } else if keyDowns.contains(where: { (Self.matchBeforeMs...100).contains(ms($0, o.t)) }) {
                th.orphanBeforeKeyDown += 1; count(&th, "beforeKeyDown", o.positive)
            } else if keyDowns.contains(where: { (Self.matchAfterMs...200).contains(ms(o.t, $0)) }) {
                th.orphanAfterKeyDown += 1; count(&th, "afterKeyDown", o.positive)
            } else {
                th.orphanNothing += 1; count(&th, "nothing", o.positive)
            }
            delta.thresholds[o.det] = th
        }
    }

    private func count(_ th: inout OnsetStats.Threshold, _ k: String, _ positive: Bool) {
        if positive { th.sign[k, default: .init()].positive += 1 } else { th.sign[k, default: .init()].negative += 1 }
    }
    private func halfBin(_ v: Double) -> Int { max(0, min(119, Int(((v + 20) * 2).rounded(.down)))) }
    private func msBin(_ v: Double) -> Int { max(0, min(79, Int((v + 40).rounded(.down)))) }
}
