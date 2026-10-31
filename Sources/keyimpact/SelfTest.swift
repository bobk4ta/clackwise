import Foundation
import ClackwiseCore
import CoreGraphics
import CoreAudio

/// Checks that need no permissions and no audio device.
func selfTest() -> Bool {
    var ok = true
    func check(_ name: String, _ pass: Bool, _ detail: String = "") {
        print("  \(pass ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        ok = ok && pass
    }
    func loud(_ c: Clip, _ layer: Int = 1) -> Double {
        let (l, r) = c.layer(layer)
        return SoundBank.loudness(UnsafeBufferPointer(start: l, count: c.frames), UnsafeBufferPointer(start: r, count: c.frames), rate: c.sampleRate)
    }
    /// High band (first difference) re. level, dB: higher = brighter.
    func tilt(_ c: Clip, _ layer: Int = 1) -> Double {
        let l = c.layer(layer).l
        var e = 0.0, d = 0.0
        for i in 1..<c.frames { e += Double(l[i] * l[i]); d += Double((l[i] - l[i - 1]) * (l[i] - l[i - 1])) }
        return 10 * log10(d / e)
    }

    print("packs:")
    let packs = SoundPackLoader.discover(in: [packsRoot()])
    check("17 bundled packs found (5 Mechvibes + 12 kbsim)", packs.count == 17, packs.map(\.id).joined(separator: ", "))
    var banks: [SoundBank] = []
    let codes: [CGKeyCode] = [0x00, 0x31, 0x24, 0x33, 0x38, 0x37, 0x3A, 0x3B, 0x39, 0x3F, 0x7E]
    for p in packs {
        guard let b = SoundBank(pack: p) else { check("\(p.id) loads", false); continue }
        banks.append(b)
        let missing = codes.filter { b.clip(for: $0, up: false) == nil }
        let noUp = codes.filter { b.clip(for: $0, up: true) == nil }
        let louds = b.pressClips.prefix(12).map { c in [0, 2].map { loud(c, $0) - loud(c) } }.flatMap { $0 }
        let tilts = b.pressClips.prefix(12).map { c in (tilt(c, 0), tilt(c), tilt(c, 2)) }
        check("\(p.id): press + key-up (\(b.keyUpSynthesized ? "synthesized" : "recorded")) for letters, space, return, delete, modifiers, caps, fn, arrows; layers soft < medium < hard in brightness, loudness-matched",
              missing.isEmpty && noUp.isEmpty && b.keyUpSynthesized == !p.hasKeyUp
                && tilts.allSatisfy { $0.0 < $0.1 && $0.1 < $0.2 } && abs(pct(louds, 50)) < 0.5,
              (missing.isEmpty ? "" : "missing \(missing) ") + (noUp.isEmpty ? "" : "no up \(noUp) ")
                + "layer loudness re. recording p50 \(f(pct(louds, 50), 2)) dB, tilt soft/med/hard \(f(pct(tilts.map(\.0), 50), 1))/\(f(pct(tilts.map(\.1), 50), 1))/\(f(pct(tilts.map(\.2), 50), 1)) dB")
    }
    let real = packs.filter(\.hasKeyUp).map(\.id)
    check("recorded key-ups: Holy Pandas + all 12 kbsim packs", real.count == 13 && real.allSatisfy { $0 == "holy-pandas" || $0.hasPrefix("kbsim-") },
          "synthesized: " + packs.filter { !$0.hasKeyUp }.map(\.id).joined(separator: ", "))

    if let hp = banks.first(where: { $0.pack.id == "holy-pandas" }) {
        let own = { (c: CGKeyCode) in hp.variants(for: c).first?.left }
        check("holy-pandas: kbsim rows (Q = W ≠ A ≠ Z, 1 ≠ Q)", hp.pack.rowMapped && own(0x0C) == own(0x0D) && own(0x0C) != own(0x00)
              && own(0x00) != own(0x06) && own(0x12) != own(0x0C))
        check("holy-pandas: own sound for Space", hp.clip(for: 0x31, up: false)?.left != hp.clip(for: 0x00, up: false)?.left)
        check("holy-pandas: A rotates with the rows above/below", hp.variants(for: 0x00).count == 3, "\(hp.variants(for: 0x00).count) variants")
    }
    let mx = banks.first { $0.pack.id == "cherrymx-brown-pbt" }!
    check("sprite pack: per-key sounds (A ≠ S)", mx.variants(for: 0x00).first?.left != mx.variants(for: 0x01).first?.left)
    let seq = (0..<8).compactMap { _ in mx.clip(for: 0x00, up: false)?.left }
    let ownA = mx.variants(for: 0x00).first?.left
    check("rotation: A alternates its own recording with 2 neighbours', never twice in a row",
          zip(seq, seq.dropFirst()).allSatisfy { $0 != $1 } && Set(seq).count == 3 && seq.filter { $0 == ownA }.count == 4,
          "\(Set(seq).count) distinct in 8 presses, own \(seq.filter { $0 == ownA }.count)×")
    check("rotation off: always the key's own recording", Set((0..<6).compactMap { _ in mx.clip(for: 0x00, up: false, rotate: false)?.left }).count == 1)
    check("wide keys don't borrow (Space, Return)", mx.variants(for: 0x31).count == 1 && mx.variants(for: 0x24).count == 1)

    // Synthesized key-up vs its press.
    let press = mx.clip(for: 0x01, up: false, rotate: false)!
    let up = mx.clip(for: 0x01, up: true)!
    let dDb = loud(up) - loud(press)
    check("synthesized key-up: shorter, ~8 dB quieter, brighter than its press",
          up.frames < press.frames / 2 && abs(dDb - SoundBank.synthUpDb) < 1 && tilt(up) > tilt(press),
          "\(f(Double(up.frames) / up.sampleRate * 1000, 0)) vs \(f(Double(press.frames) / press.sampleRate * 1000, 0)) ms, \(f(dDb, 1)) dB, tilt \(f(tilt(up) - tilt(press), 1)) dB")
    let untrimmed = SoundBank(pack: mx.pack, trimLeadIn: false)!
    check("lead-in trim: the clack starts ≤ 3 ms into every clip", mx.attackMs.max <= 3.05,
          "MX Brown (PBT) clack at p50/p90/max \(f(untrimmed.attackMs.median, 1))/\(f(untrimmed.attackMs.p90, 1))/\(f(untrimmed.attackMs.max, 1)) ms → \(f(mx.attackMs.median, 1))/\(f(mx.attackMs.p90, 1))/\(f(mx.attackMs.max, 1)) ms")

    let louds = banks.map { b in pct(b.pressClips.map { loud($0) + 20 * log10(Double(b.gain)) }, 50) }
    check("loudness normalized: median press within ±1 dB of target", louds.allSatisfy { abs($0 - SoundBank.targetLoudness) < 1 },
          louds.map { f($0, 1) }.joined(separator: " "))

    print("mixer (offline render through the real render path):")
    for (name, pass, detail) in MixerSelfTest.run(clip: mx.clip(for: 0x00, up: false, rotate: false)!) { check(name, pass, detail) }

    print("mapping:")
    let cal = Calibration.load(URL(fileURLWithPath: "Resources/calibration.json")) ?? .builtIn
    let m = VelocityMapper(calibration: cal)
    m.version = .v1
    let gs = stride(from: -7.0, through: -1.0, by: 0.05).map { exp($0) }
    let dbs = gs.map { m.map($0, mode: .instant).gainDb }
    check("v1: monotonic, continuous (no tiers)", zip(dbs, dbs.dropFirst()).allSatisfy { $0 <= $1 } && Set(dbs.map { f($0, 2) }).count > 40,
          "\(Set(dbs.map { f($0, 2) }).count) distinct values over \(gs.count) inputs")
    check("v1: clamped to −12 … 0 dB, recording layer only", dbs.min()! == -12 && dbs.max()! == 0 && gs.allSatisfy { m.map($0, mode: .instant).layer == 0.5 })
    check("no sensor → normal level", m.map(nil, mode: .instant).noSensor)
    let quiet = (0..<10).map { _ in m.process(0.0012, mode: .instant) }
    check("no external-keyboard rule: 10 quiet keys in a row stay soft keys", quiet.allSatisfy { !$0.noSensor && $0.gainDb == quiet[0].gainDb && $0.gainDb < -11 },
          "\(f(quiet.last!.gainDb, 1)) dB")
    m.version = .v2
    let hasDate = { (t: String) in t.range(of: "[0-9]{6,}|20[0-9]{2}-[0-9]{2}", options: .regularExpression) != nil }
    check("bundled calibration is the neutral prior: v2 present, no per-key offsets, no timestamps, rounded global percentiles",
          cal.v2 != nil && cal.v2!.keyOffsets.isEmpty && cal.v2!.presses == 0 && !hasDate(cal.source) && !hasDate(cal.v2!.source)
            && cal.v2!.instant.normalG == 0.035 && cal.instant == Calibration.builtIn.instant && cal.v2!.source == cal.source,
          cal.v2.map { "\($0.keyOffsets.count) key offsets, soft/median/hard \(f($0.instant.softG * 1000, 1))/\(f($0.instant.normalG * 1000, 1))/\(f($0.instant.hardG * 1000, 1)) mg, source \"\(cal.source)\"" } ?? "")
    let v2 = gs.map { m.map($0, mode: .instant) }
    let lays = v2.map(\.layer), v2db = v2.map(\.gainDb)
    check("v2: layer continuous soft → hard, 0 … 1", zip(lays, lays.dropFirst()).allSatisfy { $0 <= $1 } && lays.first! == 0 && lays.last! == 1
          && Set(lays.map { f($0, 3) }).count > 30, "\(Set(lays.map { f($0, 3) }).count) distinct layers")
    check("v2: loudness moves only ±\(f(VelocityMapper.v2SpanDb / 2, 0)) dB at 100 %", abs(v2db.max()! - VelocityMapper.v2Level - 2) < 0.01 && abs(v2db.min()! - VelocityMapper.v2Level + 2) < 0.01,
          "\(f(v2db.min()!, 1)) … \(f(v2db.max()!, 1)) dB")
    let med = m.v2Calibration.instant.normalG
    check("v2: your median → the recording (layer 0.5)", abs(m.map(med, mode: .instant).layer - 0.5) < 0.05, f(m.map(med, mode: .instant).layer, 3))
    m.keyOffsets = ["C": log(1.5)]
    check("v2: per-key correction lifts a far key", m.map(med, mode: .instant, key: "C").layer > m.map(med, mode: .instant, key: "A").layer)
    m.strength = 0
    check("strength 0 → one level and one layer", Set(gs.map { f(m.map($0, mode: .instant).gainDb, 3) + f(m.map($0, mode: .instant).layer, 3) }).count == 1)
    let vo = (0..<128).map { KeyVoicing.offsets(UInt16($0)) }
    check("per-key voicing: fixed, different per key, within ±30 cents / ±0.7 dB / ±0.06",
          KeyVoicing.offsets(5) == KeyVoicing.offsets(5) && Set(vo.map { f($0.cents, 2) }).count > 120
            && vo.allSatisfy { abs($0.cents) <= 30 && abs($0.db) <= 0.7 && abs($0.tone) <= 0.06 })

    print("no motion sensor (M1 Air, 13\" M1 Pro, Intel, desktops):")
    func spu(_ page: Int, _ usage: Int) -> [String: Any] { ["PrimaryUsagePage": page, "PrimaryUsage": usage] }
    let withSensor = [spu(0xFF00, 3), spu(0xFF00, 9), spu(0xFF00, 255), spu(0x20, 138)]   // accel, gyro, wakehint, lid angle
    let withoutSensor = [spu(0xFF00, 255), spu(0x20, 138)]
    check("sensor detection: accelerometer entry present → yes; SPU without one, no SPU, wrong page → no",
          SensorSupport.hasAccelerometer(devices: withSensor) && !SensorSupport.hasAccelerometer(devices: withoutSensor)
            && !SensorSupport.hasAccelerometer(devices: []) && !SensorSupport.hasAccelerometer(devices: [spu(0x20, 3)]))
    let noSensorMapper = VelocityMapper(calibration: cal)
    var levels = Set<String>(), allFlagged = true
    for ver in MappingVersion.allCases {
        for strength in [0.0, 1.0, 1.5] {
            noSensorMapper.version = ver; noSensorMapper.strength = strength
            for mode in DetectMode.allCases {
                let v = noSensorMapper.map(nil, mode: mode)
                levels.insert("\(ver)/\(mode)/\(f(v.gainDb, 3))/\(f(v.layer, 3))/\(f(v.brightness, 3))")
                allFlagged = allFlagged && v.noSensor
            }
        }
    }
    check("no sensor: every key plays at the normal level whatever the strength (one level per version and mode)",
          allFlagged && levels.count == MappingVersion.allCases.count * DetectMode.allCases.count, "\(levels.count) levels")
    noSensorMapper.version = .v2; noSensorMapper.strength = 1
    let normalKey = noSensorMapper.map(nil, mode: .instant), softKey = noSensorMapper.map(0.0067, mode: .instant)
    let medianKey = noSensorMapper.map(noSensorMapper.v2Calibration.instant.normalG, mode: .instant)
    check("no sensor: normal level, not the soft end (v2: recording layer at the median's level; a soft key is darker and quieter)",
          normalKey.layer == 0.5 && abs(normalKey.gainDb - medianKey.gainDb) < 0.05 && softKey.layer < 0.1 && softKey.gainDb < normalKey.gainDb - 1.5,
          "normal \(f(normalKey.gainDb, 1)) dB layer \(f(normalKey.layer, 2)), soft \(f(softKey.gainDb, 1)) dB layer \(f(softKey.layer, 2))")
    noSensorMapper.version = .v1
    let normalV1 = noSensorMapper.map(nil, mode: .instant), softV1 = noSensorMapper.map(0.0067, mode: .instant)
    check("no sensor, v1: normal level is above the soft end", normalV1.gainDb > softV1.gainDb + 1 && normalV1.brightness > softV1.brightness)
    let emptyRing = ImpactDetector(ring: Ring(cap: 64))
    let nowTicks = mach_absolute_time()
    check("no sensor: an empty ring yields no impact (so no key can read as soft)",
          emptyRing.impact(keyTs: nowTicks, searchFrom: nowTicks - UInt64(msToTicks(40)), availableBy: nowTicks) == nil)
    for _ in 0..<400 { _ = noSensorMapper.process(nil, mode: .instant, key: "A") }
    check("no sensor: nothing is learned from keys without a reading", noSensorMapper.anchors(.instant).state.keys == 0)

    print("permission: Deny on macOS's Keystroke Receiving alert (default button):")
    func replay(_ steps: [(t: Double, alert: Bool, ui: Bool, access: Bool)]) -> [Bool] {
        var d = DenialTracker(); let t0 = Date()
        return steps.map { d.update(alertVisible: $0.alert, systemUI: $0.ui || $0.alert, hasAccess: $0.access, now: t0.addingTimeInterval($0.t)) }
    }
    let deny = replay([(0, true, true, false), (3, false, false, false), (5, false, false, false), (6, false, false, false)])
    check("alert answered with Deny: not flagged during the 2.5 s grace, flagged afterwards", deny == [false, false, false, true], "\(deny)")
    let open = replay([(0, true, true, false), (3, false, false, false), (3.6, false, true, false), (9, false, true, false)])
    check("alert answered with Open System Settings (Settings on screen 0.6 s later): never flagged", !open.contains(true), "\(open)")
    let granted = replay([(0, true, true, false), (3, false, false, false), (4, false, false, true), (9, false, false, true)])
    check("access granted after the alert: never flagged", !granted.contains(true), "\(granted)")
    check("no alert ever: never flagged", !replay([(0, false, false, false), (10, false, false, false)]).contains(true))
    let recover = replay([(0, true, true, false), (3, false, false, false), (6.5, false, false, false), (8, false, true, false)])
    check("after Deny, opening System Settings by hand clears the flag", recover == [false, false, true, false], "\(recover)")

    print("onset monitor (synthetic sensor stream):")
    for (name, pass, detail) in onsetSelfTest() { check(name, pass, detail) }

    print("outputs:")
    var spk = OutputDeviceInfo()
    spk.sampleRate = 48000; spk.bufferRange = (15, 4096); spk.deviceLatency = 60; spk.streamLatency = 556; spk.safetyOffset = 48
    spk.transportType = kAudioDeviceTransportTypeBuiltIn
    check("latency estimate matches the measured speaker path (16.5 ms at 64 frames)", abs(spk.estimateMs(frames: 64) - 16.5) < 0.1, f(spk.estimateMs(frames: 64), 2))
    var bt = spk
    bt.bufferRange = (256, 4096)
    check("64-frame request is clamped to the device's minimum", abs(bt.estimateMs(frames: 64) - (0.7 + 1.5 * 256 / 48 + 1 + 12.83)) < 0.05, f(bt.estimateMs(frames: 64), 2))
    let wireless = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeAirPlay]
    let wired = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt]
    check("Bluetooth / BLE / AirPlay are muted by default, wired outputs and displays play",
          wireless.allSatisfy { bt.transportType = $0; return bt.isWireless } && wired.allSatisfy { bt.transportType = $0; return !bt.isWireless })
    return ok
}

/// Feeds a synthetic 800 Hz stream (rest at −1 g + 0.5 mg noise, decaying 100 Hz rings) with
/// known events and checks the counters.
func onsetSelfTest() -> [(String, Bool, String)] {
    let mon = OnsetMonitor()
    mon.paused = false
    let dt = msToTicks(1.245)
    var t = UInt64(msToTicks(10_000))
    var shocks: [(at: UInt64, amp: Double)] = []
    func run(_ ms: Double, events: [(Double, (UInt64) -> Void)] = []) {
        let end = t + UInt64(msToTicks(ms))
        var pending = events.map { (t + UInt64(msToTicks($0.0)), $0.1) }
        while t < end {
            var z = -1.0 + Double.random(in: -0.0005...0.0005)
            for s in shocks where t >= s.at {
                let age = ticksToMs(Int64(t - s.at))
                z += s.amp * exp(-age / 15) * cos(2 * Double.pi * 100 * age / 1000)
            }
            mon.feed(Sample(t: t, arrival: t + UInt64(msToTicks(0.2)), x: 0, y: 0, z: z))
            while let p = pending.first, p.0 <= t { p.1(p.0); pending.removeFirst() }
            t += UInt64(dt)
        }
    }
    run(500)
    // Key-down 8 ms after a −40 mg shock; callback 0.7 ms after the event.
    shocks.append((t + UInt64(msToTicks(100)), -0.040))
    run(300, events: [(108, { mon.keyDown(ts: $0, recv: $0 + UInt64(msToTicks(0.7))) })])
    // A +20 mg shock with a key-up 3 ms later, and a 6 mg shock with nothing.
    shocks.append((t + UInt64(msToTicks(100)), 0.020))
    run(400, events: [(103, { mon.keyUp(ts: $0) })])
    shocks.append((t + UInt64(msToTicks(100)), 0.006))
    run(400)
    // A key-down without any shock.
    run(300, events: [(100, { mon.keyDown(ts: $0, recv: $0 + UInt64(msToTicks(0.7))) })])
    let d = mon.take()
    let t3 = d.thresholds[0], t13 = d.thresholds[3]
    let lead = OnsetStats.medianMs(t3.leadVsCallbackHalfMs)
    return [
        ("key-down with a shock 8 ms before: onset found, lead ≈ 8.7 ms before the callback (3 mg)",
         t3.keyDownWithOnset == 1 && abs(lead - 8.7) < 1.3, "lead \(f(lead, 2)) ms, with onset \(t3.keyDownWithOnset)"),
        ("key-down without a shock: counted as quiet", t3.keyDownNoOnsetQuiet == 1 && d.keyDowns == 2, "quiet \(t3.keyDownNoOnsetQuiet)"),
        ("orphans: one near the key-up, one with nothing (3 mg)", t3.orphanNearKeyUp == 1 && t3.orphanNothing == 1,
         "keyUp \(t3.orphanNearKeyUp), nothing \(t3.orphanNothing), other \(t3.orphanNearClick + t3.orphanBeforeKeyDown + t3.orphanAfterKeyDown)"),
        ("initial direction: key-down negative, key-up positive", t3.sign["keyDown"]?.negative == 1 && t3.sign["keyUp"]?.positive == 1, ""),
        ("13 mg threshold misses the 6 mg shock", t13.onsets == 2, "\(t13.onsets) onsets"),
        ("monitored time counted", abs(d.monitoredSeconds - 1.9) < 0.05, "\(f(d.monitoredSeconds, 2)) s"),
    ]
}
