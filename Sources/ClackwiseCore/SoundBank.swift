import Foundation
import AVFoundation
import CoreGraphics
import os

/// One preloaded sound: stereo Float32 PCM at the file's sample rate, in three velocity layers of
/// equal length (soft, medium = the recording, hard). The memory is owned by its SoundBank and never
/// freed while the process runs, so the render thread can hold the pointers.
public struct Clip {
    public let left: UnsafePointer<Float>       // medium layer: the recording itself
    public let right: UnsafePointer<Float>
    public let softLeft: UnsafePointer<Float>, softRight: UnsafePointer<Float>
    public let hardLeft: UnsafePointer<Float>, hardRight: UnsafePointer<Float>
    public let frames: Int
    public let sampleRate: Double

    /// 0 = soft, 1 = medium, 2 = hard.
    public func layer(_ i: Int) -> (l: UnsafePointer<Float>, r: UnsafePointer<Float>) {
        i <= 0 ? (softLeft, softRight) : i == 1 ? (left, right) : (hardLeft, hardRight)
    }
}

/// A decoded pack, ready for the audio thread.
///
/// Preprocessing per clip: leading silence trimmed (onset at −30 dB re. the clip peak, minus
/// 0.5 ms); optionally the quiet lead-in before the main transient too (see `trimLeadIn`); trailing
/// silence trimmed, 3 ms fade-out. Loudness: BS.1770 K-weighting, the loudest 50 ms window of each
/// press clip; the pack gain brings the median press to `targetLoudness`. Clips whose peak would then
/// exceed `peakCeiling` are scaled down individually (per layer), so hard hits at full volume don't
/// drive the output clipper.
///
/// Velocity layers (pre-rendered here, crossfaded by the mixer): soft = softened attack and darker,
/// medium = the recording, hard = sharper attack, brighter, a bit more body. Filters run forwards and
/// backwards (zero phase), so the layers stay time-aligned with the recording and crossfade without
/// comb filtering. Each layer is matched to the recording's loudness: velocity changes timbre here,
/// loudness is the mapper's job.
///
/// Packs without key-up recordings get a key-up synthesized from each press: from 1 ms before the
/// main transient, high-passed (no bottom-out thump), a little brighter, decaying in ~50 ms, 8 dB
/// below the press (real kbsim releases: median −4.6 dB, MX switches −8 … −11 dB).
public final class SoundBank {
    public static let targetLoudness = -20.0
    public static let peakCeiling: Float = 0.708   // −3 dBFS
    public static let synthUpDb = -8.0

    public let pack: SoundPack
    public let gain: Float
    public let loudness: Double         // median press loudness before normalization
    public let peakAfterGain: Float     // loudest sample of any medium clip after normalization, before limiting
    public let limitedClips: Int        // layers scaled down to stay under peakCeiling
    public let leadTrimMs: (median: Double, max: Double)
    /// Press clips: time from clip start to the main transient (first sample ≥ −12 dB re. peak).
    public let attackMs: (median: Double, p90: Double, max: Double)
    public let leadInCutMs: (median: Double, max: Double)
    public let trimLeadIn: Bool
    public let clipCount: Int
    public let bytes: Int
    public let loadMs: Double
    /// Keys that rotate between several recordings (own variants or borrowed from neighbours).
    public let rotatingKeys: Int

    let down: [String: [Clip]], downDefault: [Clip]
    /// Recordings of nearby keys, used as alternates for keys with a single recording.
    let borrowed: [String: [Clip]]
    let up: [String: [Clip]], upDefault: [Clip]
    /// Synthesized key-up per press clip (keyed by the press clip's left pointer).
    let synthUp: [UnsafePointer<Float>: Clip]
    public var hasKeyUp: Bool { true }
    public var keyUpSynthesized: Bool { !pack.hasKeyUp }

    // Rotation state (tap thread and peak queue).
    private var turn = [UInt32](repeating: 0, count: 256)
    private var lastIndex = [Int](repeating: -1, count: 256)
    private var lastPress = [Clip?](repeating: nil, count: 256)
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)

    /// Raw prepared PCM before layering.
    struct Raw { var l: [Float]; var r: [Float]; var rate: Double; var loud: Double; var peak: Float
                 var trimMs: Double; var leadCutMs: Double; var attackMs: Double }

    public init?(pack: SoundPack, trimLeadIn: Bool = true) {
        let t0 = Date()
        self.pack = pack
        self.trimLeadIn = trimLeadIn
        lock.initialize(to: os_unfair_lock())
        var decoded: [URL: (ch: [[Float]], rate: Double)] = [:]
        var raws: [SoundPack.Source: Raw] = [:]

        func raw(_ src: SoundPack.Source) -> Raw? {
            if let r = raws[src] { return r }
            let url: URL
            switch src { case .slice(let f, _, _): url = f; case .file(let f): url = f }
            if decoded[url] == nil { decoded[url] = Self.decode(url) }
            guard let (ch, rate) = decoded[url], !ch.isEmpty else { return nil }
            var a = 0, b = ch[0].count
            if case let .slice(_, s, l) = src {
                a = min(b, Int(s * rate / 1000)); b = min(b, a + Int(l * rate / 1000))
            }
            guard let p = Self.prepare(ch.map { Array($0[a..<b]) }, rate: rate, trimLeadIn: trimLeadIn) else { return nil }
            raws[src] = p
            return p
        }
        let pressSources = Set(pack.down.values.flatMap { $0 } + pack.downDefault)
        let upSources = Set(pack.up.values.flatMap { $0 } + pack.upDefault)
        let press = pressSources.compactMap(raw)
        _ = upSources.compactMap(raw)
        guard !press.isEmpty else { return nil }

        loudness = pct(press.map(\.loud), 50)
        let gain = Float(pow(10, (Self.targetLoudness - loudness) / 20))
        self.gain = gain
        peakAfterGain = (raws.values.map(\.peak).max() ?? 0) * gain
        leadTrimMs = (pct(press.map(\.trimMs), 50), press.map(\.trimMs).max() ?? 0)
        attackMs = (pct(press.map(\.attackMs), 50), pct(press.map(\.attackMs), 90), press.map(\.attackMs).max() ?? 0)
        leadInCutMs = (pct(press.map(\.leadCutMs), 50), press.map(\.leadCutMs).max() ?? 0)

        var limited = 0, bytes = 0
        var made: [SoundPack.Source: Clip] = [:]
        for (src, r) in raws {
            let c = Self.layered(r, gain: gain, limited: &limited)
            bytes += c.frames * 8 * 3
            made[src] = c
        }
        func clips(_ s: [SoundPack.Source]) -> [Clip] { s.compactMap { made[$0] } }
        down = pack.down.mapValues(clips).filter { !$0.value.isEmpty }
        downDefault = clips(pack.downDefault)
        up = pack.up.mapValues(clips).filter { !$0.value.isEmpty }
        upDefault = clips(pack.upDefault)

        var synth: [UnsafePointer<Float>: Clip] = [:]
        if !pack.hasKeyUp {
            for src in pressSources {
                guard let r = raws[src], let c = made[src], let u = Self.synthesizeKeyUp(r) else { continue }
                let uc = Self.layered(u, gain: gain, limited: &limited)
                bytes += uc.frames * 8 * 3
                synth[c.left] = uc
            }
        }
        synthUp = synth
        let downClips = pack.down.mapValues(clips).filter { !$0.value.isEmpty }
        let alts = Self.neighbours(downClips)
        borrowed = alts
        rotatingKeys = downClips.filter { $0.value.count > 1 || alts[$0.key] != nil }.count
        limitedClips = limited
        clipCount = made.count + synth.count
        self.bytes = bytes
        loadMs = Date().timeIntervalSince(t0) * 1000
    }

    /// The sound for a key. Keys with several recordings never repeat the same one twice in a row;
    /// keys with one recording alternate it with nearby keys' recordings (own, alt 1, own, alt 2, …)
    /// when `rotate` is on. Key-up: the pack's recording, or the one synthesized from the press this
    /// key last played. nil = nothing to play.
    public func clip(for code: CGKeyCode, up isUp: Bool, rotate: Bool = true) -> Clip? {
        let k = KeycodeMap.mechvibesKey(for: code)
        let i = Int(code) & 0xFF
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        if isUp {
            if keyUpSynthesized {
                let p = lastPress[i] ?? (k.flatMap { down[$0]?.first } ?? downDefault.first)
                return p.flatMap { synthUp[$0.left] }
            }
            return pickVariant(k.flatMap { up[$0] } ?? upDefault, i, rotate)
        }
        let own = k.flatMap { down[$0] } ?? downDefault
        var c: Clip?
        if own.count == 1, rotate, let k, let alts = borrowed[k] {
            let n = turn[i]; turn[i] &+= 1
            c = n % 2 == 0 ? own[0] : alts[Int(n / 2) % alts.count]
        } else {
            c = pickVariant(own, i, rotate)
        }
        lastPress[i] = c
        return c
    }

    /// Random variant, never the same as last time for this key (when rotating).
    private func pickVariant(_ v: [Clip], _ i: Int, _ rotate: Bool) -> Clip? {
        guard v.count > 1 else { return v.first }
        var j = Int.random(in: 0..<v.count)
        if rotate {
            if j == lastIndex[i] { j = (j + 1 + Int.random(in: 0..<(v.count - 1))) % v.count }
            lastIndex[i] = j
        }
        return v[j]
    }

    /// All press clips (each once), for tests and loudness checks.
    public var pressClips: [Clip] {
        var seen = Set<UnsafePointer<Float>>()
        return (Array(down.values.joined()) + downDefault).filter { seen.insert($0.left).inserted }
    }
    /// Variants a key can play (own first, then borrowed), for tests.
    public func variants(for code: CGKeyCode) -> [Clip] {
        guard let k = KeycodeMap.mechvibesKey(for: code), let own = down[k] else { return downDefault }
        return own + (borrowed[k] ?? [])
    }

    /// For each 1u key with a single recording: the two nearest keys with a different recording,
    /// same row first, then the rows above/below (kbsim row samples). Max distance 3 key units.
    static func neighbours(_ down: [String: [Clip]]) -> [String: [Clip]] {
        var out: [String: [Clip]] = [:]
        let keys = down.keys.filter { KeyboardLayout.positions[$0] != nil && !KeyboardLayout.wideKeys.contains($0) }
        for k in keys {
            guard let own = down[k], own.count == 1, let p = KeyboardLayout.positions[k] else { continue }
            let cands = keys.compactMap { o -> (Double, String, Clip)? in
                guard o != k, let q = KeyboardLayout.positions[o], let c = down[o]?.first, c.left != own[0].left else { return nil }
                let d = abs(q.col - p.col) + 1.5 * Double(abs(q.row - p.row))
                return d <= 3 ? (d, o, c) : nil
            }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            var picked: [Clip] = []
            for (_, _, c) in cands where !picked.contains(where: { $0.left == c.left }) {
                picked.append(c)
                if picked.count == 2 { break }
            }
            if !picked.isEmpty { out[k] = picked }
        }
        return out
    }

    // MARK: - processing

    static func decode(_ url: URL) -> (ch: [[Float]], rate: Double)? {
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let data = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        let chans = (0..<Int(buf.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
        return (chans, file.processingFormat.sampleRate)
    }

    /// First frame at or above `fraction` of the peak (either channel).
    static func firstAbove(_ l: [Float], _ r: [Float], _ level: Float, from: Int = 0) -> Int? {
        (from..<l.count).first { abs(l[$0]) >= level || abs(r[$0]) >= level }
    }

    /// Trims silence (and, with `trimLeadIn`, the quiet lead-in: everything more than 2 ms before
    /// the first sample within −12 dB of the peak, when that is more than 3 ms after the onset; the
    /// cut point gets a 0.5 ms fade-in). Many slices carry 10–15 ms of tactile-bump/pre-travel noise
    /// at −25 … −35 dB before the clack, which only delays the sound.
    static func prepare(_ ch: [[Float]], rate: Double, trimLeadIn: Bool) -> Raw? {
        let l = ch[0], r = ch.count > 1 ? ch[1] : ch[0]
        let n = l.count
        guard n > 0 else { return nil }
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(l[i]), abs(r[i])) }
        guard peak > 1e-5 else { return nil }
        let onset = firstAbove(l, r, peak * 0.03) ?? 0
        var start = max(0, onset - Int(rate * 0.0005))
        let main = firstAbove(l, r, peak * 0.25) ?? onset
        var fadeIn = 0
        if trimLeadIn, main - onset > Int(rate * 0.003) {
            start = main - Int(rate * 0.002)
            fadeIn = Int(rate * 0.0005)
        }
        let last = (0..<n).last { abs(l[$0]) > peak * 0.002 || abs(r[$0]) > peak * 0.002 } ?? (n - 1)
        let end = min(n, last + Int(rate * 0.002) + 1)
        let frames = end - start
        guard frames > 16 else { return nil }

        var ol = [Float](repeating: 0, count: frames), or = ol
        let fade = min(frames / 4, Int(rate * 0.003))
        for i in 0..<frames {
            var g: Float = i >= frames - fade ? Float(frames - 1 - i) / Float(fade) : 1
            if i < fadeIn { g *= Float(i) / Float(fadeIn) }
            ol[i] = l[start + i] * g
            or[i] = r[start + i] * g
        }
        let lead = Double(max(0, start - max(0, onset - Int(rate * 0.0005)))) / rate * 1000
        return Raw(l: ol, r: or, rate: rate, loud: loudness(ol, or, rate: rate), peak: peak,
                   trimMs: Double(start) / rate * 1000, leadCutMs: lead, attackMs: Double(main - start) / rate * 1000)
    }

    static func loudness(_ l: [Float], _ r: [Float], rate: Double) -> Double {
        l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in loudness(lp, rp, rate: rate) } }
    }

    /// Builds the three layers (soft and hard matched to the recording's loudness), applies the
    /// pack gain ceiling per layer, and copies them into memory the render thread can keep.
    static func layered(_ r: Raw, gain: Float, limited: inout Int) -> Clip {
        let medium = (r.l, r.r)
        func matched(_ x: ([Float], [Float])) -> ([Float], [Float]) {
            let k = Float(pow(10, (r.loud - loudness(x.0, x.1, rate: r.rate)) / 20))
            return (x.0.map { $0 * k }, x.1.map { $0 * k })
        }
        let soft = matched(DSP.soft(medium, rate: r.rate)), hard = matched(DSP.hard(medium, rate: r.rate))
        func store(_ x: ([Float], [Float])) -> (UnsafePointer<Float>, UnsafePointer<Float>) {
            var pk: Float = 0
            for i in 0..<x.0.count { pk = max(pk, abs(x.0[i]), abs(x.1[i])) }
            let k: Float = pk * gain > peakCeiling ? peakCeiling / (pk * gain) : 1
            if k < 1 { limited += 1 }
            let pl = UnsafeMutablePointer<Float>.allocate(capacity: x.0.count)
            let pr = UnsafeMutablePointer<Float>.allocate(capacity: x.1.count)
            for i in 0..<x.0.count { pl[i] = x.0[i] * k; pr[i] = x.1[i] * k }
            return (UnsafePointer(pl), UnsafePointer(pr))
        }
        let m = store(medium), s = store(soft), h = store(hard)
        return Clip(left: m.0, right: m.1, softLeft: s.0, softRight: s.1, hardLeft: h.0, hardRight: h.1,
                    frames: r.l.count, sampleRate: r.rate)
    }

    /// Key-up from a press: starts 1 ms before the main transient, high-pass 400 Hz, +4 dB above
    /// 3 kHz, exponential decay (τ 10 ms) from the transient, ≤ 50 ms, `synthUpDb` below the press.
    static func synthesizeKeyUp(_ p: Raw) -> Raw? {
        var pk: Float = 0
        for i in 0..<p.l.count { pk = max(pk, abs(p.l[i]), abs(p.r[i])) }
        guard let main = firstAbove(p.l, p.r, pk * 0.25) else { return nil }
        let rate = p.rate
        let start = max(0, main - Int(rate * 0.001))
        let n = min(p.l.count - start, main - start + Int(rate * 0.05))
        guard n > 64 else { return nil }
        let tau = rate * 0.010, fade = Int(rate * 0.003)
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            let t = Double(max(0, start + i - main))
            var g = Float(exp(-t / tau))
            if i >= n - fade { g *= Float(n - 1 - i) / Float(fade) }
            l[i] = p.l[start + i] * g
            r[i] = p.r[start + i] * g
        }
        var x = DSP.filtfilt((l, r), DSP.highpass(400, q: 0.707, rate: rate))
        x = DSP.filtfilt(x, DSP.highShelf(3000, db: 2, rate: rate))   // ×2 passes = +4 dB
        let target = p.loud + synthUpDb
        let k = Float(pow(10, (target - loudness(x.0, x.1, rate: rate)) / 20))
        let ul = x.0.map { $0 * k }, ur = x.1.map { $0 * k }
        return Raw(l: ul, r: ur, rate: rate, loud: target, peak: pk, trimMs: 0, leadCutMs: 0, attackMs: 1)
    }

    /// Loudest 50 ms window (5 ms hop), K-weighted, summed over both channels, in LUFS-style dB.
    public static func loudness(_ l: UnsafeBufferPointer<Float>, _ r: UnsafeBufferPointer<Float>, rate: Double) -> Double {
        let kl = kWeight(l, rate: rate), kr = kWeight(r, rate: rate)
        let win = max(1, Int(rate * 0.05)), hop = max(1, Int(rate * 0.005))
        var cum = [Double](repeating: 0, count: kl.count + 1)
        for i in 0..<kl.count { cum[i + 1] = cum[i] + kl[i] * kl[i] + kr[i] * kr[i] }
        var best = 0.0
        var i = 0
        repeat {
            let j = min(kl.count, i + win)
            best = max(best, (cum[j] - cum[i]) / Double(win))
            i += hop
        } while i + win <= kl.count
        return -0.691 + 10 * log10(max(best, 1e-12))
    }

    /// BS.1770 K-weighting (high shelf + high pass), RBJ biquads for any sample rate
    /// (same parameters as pyloudnorm).
    static func kWeight(_ x: UnsafeBufferPointer<Float>, rate: Double) -> [Double] {
        func biquad(_ x: [Double], _ b: [Double], _ a: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<x.count {
                let v = (b[0] * x[i] + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2) / a[0]
                x2 = x1; x1 = x[i]; y2 = y1; y1 = v; y[i] = v
            }
            return y
        }
        var w0 = 2 * Double.pi * 1681.974450955533 / rate
        let A = pow(10, 3.999843853973347 / 40), q1 = 0.7071752369554196
        var al = sin(w0) / (2 * q1), c = cos(w0), sA = A.squareRoot()
        let shelfB = [A * ((A + 1) + (A - 1) * c + 2 * sA * al), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - 2 * sA * al)]
        let shelfA = [(A + 1) - (A - 1) * c + 2 * sA * al, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - 2 * sA * al]
        w0 = 2 * Double.pi * 38.13547087602444 / rate
        al = sin(w0) / (2 * 0.5003270373238773); c = cos(w0); sA = 0
        let hpB = [(1 + c) / 2, -(1 + c), (1 + c) / 2], hpA = [1 + al, -2 * c, 1 - al]
        return biquad(biquad(x.map(Double.init), shelfB, shelfA), hpB, hpA)
    }
}

/// Offline filters for the velocity layers and synthesized key-ups (load time only).
public enum DSP {
    public typealias Stereo = ([Float], [Float])
    /// Normalized biquad: b0 b1 b2 a1 a2.
    public struct Biquad { var b0, b1, b2, a1, a2: Double }

    static func rbj(_ b: [Double], _ a: [Double]) -> Biquad {
        Biquad(b0: b[0] / a[0], b1: b[1] / a[0], b2: b[2] / a[0], a1: a[1] / a[0], a2: a[2] / a[0])
    }
    public static func lowpass(_ f: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * f / rate, c = cos(w), al = sin(w) / (2 * q)
        return rbj([(1 - c) / 2, 1 - c, (1 - c) / 2], [1 + al, -2 * c, 1 - al])
    }
    public static func highpass(_ f: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * f / rate, c = cos(w), al = sin(w) / (2 * q)
        return rbj([(1 + c) / 2, -(1 + c), (1 + c) / 2], [1 + al, -2 * c, 1 - al])
    }
    public static func peaking(_ f: Double, q: Double, db: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * f / rate, c = cos(w), al = sin(w) / (2 * q), A = pow(10, db / 40)
        return rbj([1 + al * A, -2 * c, 1 - al * A], [1 + al / A, -2 * c, 1 - al / A])
    }
    public static func highShelf(_ f: Double, db: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * f / rate, c = cos(w), A = pow(10, db / 40), al = sin(w) / 2 * 2.0.squareRoot(), sA = A.squareRoot()
        return rbj([A * ((A + 1) + (A - 1) * c + 2 * sA * al), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - 2 * sA * al)],
                   [(A + 1) - (A - 1) * c + 2 * sA * al, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - 2 * sA * al])
    }

    static func run(_ x: [Float], _ f: Biquad, reverse: Bool) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for k in 0..<x.count {
            let i = reverse ? x.count - 1 - k : k
            let xi = Double(x[i])
            let v = f.b0 * xi + f.b1 * x1 + f.b2 * x2 - f.a1 * y1 - f.a2 * y2
            x2 = x1; x1 = xi; y2 = y1; y1 = v; y[i] = Float(v)
        }
        return y
    }
    /// Forwards then backwards: zero phase, squared magnitude (so shelf/peak dB count twice).
    public static func filtfilt(_ x: Stereo, _ f: Biquad) -> Stereo {
        (run(run(x.0, f, reverse: false), f, reverse: true), run(run(x.1, f, reverse: false), f, reverse: true))
    }

    /// Transient shaper: gain = (slow / fast envelope)^amount, envelopes of max(|l|, |r|) with
    /// 0.1 ms (fast) / 6 ms (slow) attack and the same 30 ms release, so only the first few ms of
    /// each hit change and the tail is untouched. amount > 0 softens the attack, < 0 sharpens it.
    public static func shapeTransients(_ x: Stereo, rate: Double, amount: Double) -> Stereo {
        let n = x.0.count
        var pk: Float = 0
        for i in 0..<n { pk = max(pk, abs(x.0[i]), abs(x.1[i])) }
        let eps = Double(pk) * 1e-3
        func coef(_ ms: Double) -> Double { 1 - exp(-1 / (ms / 1000 * rate)) }
        let fa = coef(0.1), sa = coef(6), rel = coef(30), sm = coef(0.3)
        var fast = 0.0, slow = 0.0, g = 1.0
        var l = x.0, r = x.1
        for i in 0..<n {
            let e = Double(max(abs(x.0[i]), abs(x.1[i])))
            fast += (e - fast) * (e > fast ? fa : rel)
            slow += (e - slow) * (e > slow ? sa : rel)
            let target = min(3, max(0.2, pow((slow + eps) / (fast + eps), amount)))
            g += (target - g) * sm
            l[i] *= Float(g); r[i] *= Float(g)
        }
        return (l, r)
    }

    /// Soft layer: softer attack, darker (−8 dB above ~2 kHz, gentle roll-off above 7 kHz).
    public static func soft(_ x: Stereo, rate: Double) -> Stereo {
        var y = shapeTransients(x, rate: rate, amount: 0.6)
        y = filtfilt(y, highShelf(2000, db: -4, rate: rate))
        y = filtfilt(y, lowpass(min(7000, rate * 0.45), q: 0.707, rate: rate))
        return fadeIn(y, rate: rate)
    }
    /// Hard layer: sharper attack, brighter (+6 dB above ~2 kHz), a bit more body (+3 dB at 200 Hz).
    public static func hard(_ x: Stereo, rate: Double) -> Stereo {
        var y = shapeTransients(x, rate: rate, amount: -0.5)
        y = filtfilt(y, highShelf(2000, db: 3, rate: rate))
        y = filtfilt(y, peaking(200, q: 0.7, db: 1.5, rate: rate))
        return fadeIn(y, rate: rate)
    }
    /// 0.3 ms fade-in: the zero-phase filters ring slightly ahead of the clip start.
    static func fadeIn(_ x: Stereo, rate: Double) -> Stereo {
        var (l, r) = x
        let n = min(l.count, Int(rate * 0.0003))
        for i in 0..<n { let g = Float(i) / Float(max(1, n)); l[i] *= g; r[i] *= g }
        return (l, r)
    }
}
