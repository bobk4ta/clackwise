import Foundation
import AVFoundation
import ClackwiseCore

func packsRoot() -> URL {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    for base in [URL(fileURLWithPath: FileManager.default.currentDirectoryPath), exe.deletingLastPathComponent().appendingPathComponent("../../..")] {
        let u = base.appendingPathComponent("Resources/SoundPacks").standardized
        if FileManager.default.fileExists(atPath: u.path) { return u }
    }
    print("Resources/SoundPacks not found (run from the repo root)"); exit(1)
}

/// Loads every pack like the app does, reports preprocessing and loudness normalization, and
/// optionally writes one WAV per pack (all press clips at the normalized gain) for an
/// independent loudness check (ffmpeg ebur128).
func packsReport(wavDir: URL?) {
    let packs = SoundPackLoader.discover(in: [packsRoot()])
    print("pack                         kind   keys clips rot key-up  silence trim ms  clack ms untrimmed → trimmed (p50/p90/max)  loudness gain dB  peak (limited layers)   PCM ×3 layers")
    for p in packs {
        guard let b = SoundBank(pack: p), let u = SoundBank(pack: p, trimLeadIn: false) else { print("  \(p.id): FAILED to load"); continue }
        print("\(p.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(p.kind.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(pad("\(p.down.count)", 4)) \(pad("\(b.clipCount)", 5)) \(pad("\(b.rotatingKeys)", 3)) \(b.keyUpSynthesized ? "synth " : "rec   ")  \(pad(f(b.leadTrimMs.median, 1), 4)) / \(pad(f(b.leadTrimMs.max, 1), 5))    \(pad(f(u.attackMs.median, 1), 5))/\(pad(f(u.attackMs.p90, 1), 5))/\(pad(f(u.attackMs.max, 1), 5)) → \(f(b.attackMs.median, 1))/\(f(b.attackMs.p90, 1))/\(f(b.attackMs.max, 1))          \(pad(f(b.loudness, 1), 6)) \(pad(f(20 * log10(Double(b.gain)), 1), 6))  \(pad(f(20 * log10(Double(b.peakAfterGain)), 1), 5)) dBFS (\(b.limitedClips))   \(b.bytes / 1024) KB (\(Int(b.loadMs)) ms)")
        guard let wavDir else { continue }
        // Clips 150 ms apart at the pack gain, 48 kHz stereo.
        let clips = b.pressClips
        let rate = clips[0].sampleRate, gap = Int(rate * 0.15)
        var l = [Float](repeating: 0, count: gap * clips.count + Int(rate)), r = l
        for (i, c) in clips.enumerated() {
            for j in 0..<min(c.frames, l.count - i * gap) {
                l[i * gap + j] += c.left[j] * b.gain; r[i * gap + j] += c.right[j] * b.gain
            }
        }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(l.count))!
        buf.frameLength = AVAudioFrameCount(l.count)
        l.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: l.count) }
        r.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: r.count) }
        let url = wavDir.appendingPathComponent("\(p.id).wav")
        var settings = fmt.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let out = try! AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try! out.write(from: buf)
    }
}

/// Starts the real audio engine, plays `n` sounds from a background thread at random intervals,
/// reports the CoreAudio device figures and the measured trigger → output timing.
func latencyTest(n: Int, bufferFrames: UInt32, silent: Bool) {
    let packs = SoundPackLoader.discover(in: [packsRoot()])
    guard let pack = packs.first, let bank = SoundBank(pack: pack) else { print("no pack"); exit(1) }
    let eng = KeyAudioEngine()
    eng.volume = silent ? 0 : 0.5
    do { try eng.start(bufferFrames: bufferFrames) } catch { print("engine start failed: \(error)"); exit(1) }
    Thread.sleep(forTimeInterval: 0.3)
    let d = eng.deviceInfo()
    print("output device: \(d.name) [\(d.transport)]  \(f(d.sampleRate, 0)) Hz")
    print("IO buffer: \(d.bufferFrames) frames = \(f(d.bufferMs, 2)) ms  (asked \(bufferFrames), device range \(Int(d.bufferRange.min))–\(Int(d.bufferRange.max)))")
    print("device latency \(d.deviceLatency) + stream latency \(d.streamLatency) frames = \(f(d.hardwareMs, 2)) ms;  safety offset \(d.safetyOffset) frames = \(f(Double(d.safetyOffset) / d.sampleRate * 1000, 2)) ms")
    print("AVAudioOutputNode.presentationLatency: \(f(d.presentationLatency * 1000, 2)) ms")
    print("playing \(n) sounds\(silent ? " at volume 0" : "")…")
    let codes: [CGKeyCode] = [0x00, 0x01, 0x02, 0x03, 0x31, 0x24, 0x0E, 0x0F]
    for i in 0..<n {
        Thread.sleep(forTimeInterval: Double.random(in: 0.04...0.12))
        // A real key event reaches the tap ~0.7 ms after its timestamp (NOTES.md); model that.
        let event = mach_absolute_time() &- UInt64(msToTicks(0.7))
        let clip = bank.clip(for: codes[i % codes.count], up: false)!
        eng.play(clip, gain: bank.gain * 0.5, brightness: Double(i % 5) / 4, pitch: 1, eventTicks: event)
    }
    Thread.sleep(forTimeInterval: 0.5)
    let s = eng.latencyStats()
    func row(_ name: String, _ v: [Double]) { print("  \(name.padding(toLength: 46, withPad: " ", startingAt: 0)) p50 \(pad(f(pct(v, 50), 2), 6))  p90 \(pad(f(pct(v, 90), 2), 6))  max \(pad(f(v.max() ?? .nan, 2), 6)) ms") }
    print("measured over \(s.count) sounds (render cycles: \(eng.renderCycles), max voices: \(eng.maxActiveVoices)):")
    row("play() → render cycle picks it up", s.enqueueToRender)
    row("render start → HAL output time of that buffer", s.outputAhead)
    row("key event → HAL output time", s.eventToOutput)
    row("key event → sound out (+ device/stream latency)", s.endToEnd)
    eng.stop()
}

/// Every output device CoreAudio knows right now, with its reported latency figures and the
/// key → sound estimate for Clackwise's 64-frame request. Touches nothing.
func listOutputDevices() {
    let def = KeyAudioEngine.defaultOutputDevice()
    print("output devices (CoreAudio's own figures; Bluetooth/AirPlay codec delay is usually not included):")
    for id in KeyAudioEngine.outputDevices() {
        let d = KeyAudioEngine.info(for: id)
        print("  \(id == def ? "*" : " ") \(d.name) [\(d.transport)]\(d.isWireless ? " — Clackwise mutes this by default" : "")")
        print("      \(f(d.sampleRate, 0)) Hz, buffer now \(d.bufferFrames) (range \(Int(d.bufferRange.min))–\(Int(d.bufferRange.max))), device latency \(d.deviceLatency) + stream \(d.streamLatency) frames = \(f(d.hardwareMs, 2)) ms, safety offset \(d.safetyOffset) = \(f(d.safetyMs, 2)) ms")
        print("      → key → sound with a 64-frame request ≈ \(f(d.estimateMs(frames: 64), 1)) ms")
    }
    print("(* = default output)")
    print("microphone in use by another app: \(MicActivity.inUse() ? "yes — Clackwise pauses (default)" : "no")")
}
