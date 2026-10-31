import Foundation
import ClackwiseCore

/// CPU cost of each always-on part, measured in this process (getrusage) plus coreaudiod (ps), so
/// idle strategies can be judged: sensor stream alone, sensor + onset monitor, audio engine
/// running silent at several IO buffer sizes.
func idleCost(seconds: Double) {
    func selfCPU() -> (Double, Int) {
        var r = rusage(); getrusage(RUSAGE_SELF, &r)
        let s = Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
        return (s, Int(r.ru_nvcsw + r.ru_nivcsw))
    }
    func run(_ exe: String, _ args: [String]) -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    let caPID = run("/usr/bin/pgrep", ["-x", "coreaudiod"]).split(separator: "\n").first.map(String.init) ?? ""
    func coreaudiodCPU() -> Double {
        // [[h:]m:]s.cc
        let t = run("/bin/ps", ["-o", "time=", "-p", caPID]).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? .nan : t.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    }
    func measure(_ name: String, _ body: () -> Void) {
        let (c0, w0) = selfCPU(), a0 = coreaudiodCPU(), t0 = Date()
        body()
        let dt = Date().timeIntervalSince(t0)
        let (c1, w1) = selfCPU(), a1 = coreaudiodCPU()
        print("  \(name.padding(toLength: 44, withPad: " ", startingAt: 0)) this process \(pad(f((c1 - c0) / dt * 100, 2), 5)) % CPU, \(pad(String(Int(Double(w1 - w0) / dt)), 5)) context switches/s;  coreaudiod +\(pad(f((a1 - a0) / dt * 100, 2), 5)) % CPU")
    }
    func idle() { Thread.sleep(forTimeInterval: seconds) }
    print("each \(Int(seconds)) s; coreaudiod's figure includes whatever else is playing (Clackwise.app's own engine, if on, is constant):")
    measure("nothing (baseline)", idle)

    let ring = Ring(cap: 2048)
    wakeAccelDriver()
    let acc = Accelerometer(ring: ring)
    let monitor = OnsetMonitor()
    var withMonitor = false
    acc.sampleHook = { s in if withMonitor { monitor.feed(s) } }
    guard acc.open().0 == kIOReturnSuccess else { print("accelerometer open failed"); exit(1) }
    acc.start()
    wakeAccelDriver()
    Thread.sleep(forTimeInterval: 0.5)
    let n0 = ring.total
    measure("sensor stream (800 Hz HID callbacks + ring)", idle)
    print("    (\(Int(Double(ring.total - n0) / seconds)) samples/s)")
    monitor.paused = false
    withMonitor = true
    measure("sensor stream + onset monitor", idle)
    withMonitor = false
    acc.close()
    Thread.sleep(forTimeInterval: 0.3)

    for frames: UInt32 in [64, 128, 256, 512] {
        let eng = KeyAudioEngine()
        eng.volume = 0
        do { try eng.start(bufferFrames: frames) } catch { print("engine start failed: \(error)"); return }
        Thread.sleep(forTimeInterval: 0.3)
        let d = eng.deviceInfo()
        measure("audio engine, silent, \(d.bufferFrames)-frame buffer (\(f(d.bufferMs, 2)) ms)", idle)
        eng.stop()
        Thread.sleep(forTimeInterval: 0.3)
    }
    // How late is a sound that starts the engine (the cost of stopping it when idle)?
    var startMs: [Double] = []
    for _ in 0..<5 {
        let packs = SoundPackLoader.discover(in: [packsRoot()])
        guard let b = packs.first.flatMap({ SoundBank(pack: $0) }), let clip = b.clip(for: 0, up: false) else { break }
        let eng = KeyAudioEngine()
        eng.volume = 0
        let t = mach_absolute_time()
        try? eng.start(bufferFrames: 64)
        eng.play(clip, gain: 0.1, brightness: 1, pitch: 1, eventTicks: t)
        Thread.sleep(forTimeInterval: 0.4)
        if let e = eng.latencyStats().endToEnd.first { startMs.append(e) }
        eng.stop()
        Thread.sleep(forTimeInterval: 1.0)
    }
    print("  engine stopped → start + play: key → sound out \(startMs.map { f($0, 1) }.joined(separator: ", ")) ms (vs ≈ 16.5 ms with the engine running)")
}
