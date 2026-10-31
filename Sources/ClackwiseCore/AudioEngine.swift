import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os

/// What CoreAudio reports for the current output device.
public struct OutputDeviceInfo {
    public var id: AudioDeviceID = 0
    public var name = "?"
    public var transport = "?"
    public var transportType: UInt32 = 0
    public var sampleRate = 0.0
    public var bufferFrames: UInt32 = 0
    public var bufferRange = (min: 0.0, max: 0.0)
    public var deviceLatency: UInt32 = 0     // frames, kAudioDevicePropertyLatency (output)
    public var streamLatency: UInt32 = 0     // frames, kAudioStreamPropertyLatency of the first output stream
    public var safetyOffset: UInt32 = 0      // frames
    public var presentationLatency = 0.0     // s, AVAudioOutputNode
    /// Delay after the HAL output time until the sound leaves the device (device + stream latency).
    public var hardwareMs: Double { sampleRate > 0 ? Double(deviceLatency + streamLatency) / sampleRate * 1000 : 0 }
    public var bufferMs: Double { sampleRate > 0 ? Double(bufferFrames) / sampleRate * 1000 : 0 }
    public var safetyMs: Double { sampleRate > 0 ? Double(safetyOffset) / sampleRate * 1000 : 0 }
    /// Bluetooth and AirPlay: the codec / network adds 100 ms and more that CoreAudio's figures
    /// often don't include.
    public var isWireless: Bool {
        [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeAirPlay].contains(transportType)
    }
    /// Key event → sound out as CoreAudio reports it, with `frames` IO buffer (clamped to the device
    /// range): tap delivery 0.7 + pickup ≈ half a buffer + buffer + safety offset + device + stream.
    public init() {}

    public func estimateMs(frames: UInt32) -> Double {
        guard sampleRate > 0 else { return .nan }
        let f = bufferRange.max > 0 ? max(bufferRange.min, min(bufferRange.max, Double(frames))) : Double(frames)
        return 0.7 + 1.5 * f / sampleRate * 1000 + safetyMs + hardwareMs
    }
}

/// Latency of the last ≤ 512 sounds. Durations only, no timestamps.
public struct LatencyStats {
    public var count = 0
    /// Key event timestamp → HAL output time of the buffer the sound starts in.
    public var eventToOutput: [Double] = []
    /// play() call → render cycle that picked it up.
    public var enqueueToRender: [Double] = []
    /// HAL output time − render start (≈ IO buffer + safety offset).
    public var outputAhead: [Double] = []
    public var hardwareMs = 0.0
    /// Key event → sound leaving the device: eventToOutput + hardwareMs.
    public var endToEnd: [Double] { eventToOutput.map { $0 + hardwareMs } }
}

/// Low-latency polyphonic player. One AVAudioSourceNode renders a fixed voice pool directly from
/// preloaded PCM (no AVAudioPlayerNode scheduling). Per voice: crossfade between two adjacent
/// velocity layers, gain, one-pole low-pass and pitch (4-point Hermite resampling, which also
/// converts the clip's rate to the device rate).
/// play() hands a trigger to the render thread through a lock the render thread only try-locks,
/// so it never blocks; a missed try picks the trigger up one IO buffer later.
public final class KeyAudioEngine {
    public static let voiceCount = 16

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let st = RenderState()
    private var requestedFrames: UInt32 = 64
    /// Started by start() and not stopped since (AVAudioEngine itself stops on a configuration change).
    public private(set) var isRunning = false
    /// The output device the graph was built for.
    public private(set) var boundDevice: AudioDeviceID = 0
    private var boundRate = 0.0
    /// Called on main, debounced, when the default output device changes or the engine's
    /// configuration changes (device rate, device gone, …). The owner decides whether to restart.
    public var onOutputChange: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var pendingCheck = false

    public init() {
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.scheduleOutputCheck()
        }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.scheduleOutputCheck()
        }
    }

    /// Device switches arrive as bursts (default device, rate, configuration change): act once.
    private func scheduleOutputCheck() {
        guard !pendingCheck else { return }
        pendingCheck = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pendingCheck = false
            self?.onOutputChange?()
        }
    }

    /// Running, but not on the current default output at its current rate, or stopped by AVAudioEngine.
    public var needsRestart: Bool {
        guard isRunning else { return false }
        guard let d = Self.defaultOutputDevice() else { return false }
        return !engine.isRunning || d != boundDevice || Self.info(for: d).sampleRate != boundRate
    }

    /// Master volume 0…1 (smoothed per buffer).
    public var volume: Float {
        get { st.master }
        set { st.master = max(0, min(1, newValue)) }
    }

    /// (Re)builds the graph for the current default output device at its sample rate, asks for
    /// `bufferFrames` IO buffer (clamped to the device's range), starts.
    public func start(bufferFrames: UInt32 = 64) throws {
        requestedFrames = bufferFrames
        engine.stop()
        if let s = source { engine.detach(s); source = nil }
        st.reset()
        // Bind the output unit to the default device explicitly, so a switch (headphones,
        // AirPods, display) always lands on the new device.
        if let want = Self.defaultOutputDevice(), let au = outputUnit, want != deviceID() {
            var id = want
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        boundDevice = deviceID() ?? 0
        boundRate = Self.info(for: boundDevice).sampleRate

        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        st.outRate = rate > 0 ? rate : 48000
        let fmt = AVAudioFormat(standardFormatWithSampleRate: st.outRate, channels: 2)!
        let state = st
        let node = AVAudioSourceNode(format: fmt) { isSilence, ts, frameCount, abl -> OSStatus in
            let now = mach_absolute_time()
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(frameCount)
            guard bufs.count >= 2, let l = bufs[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = bufs[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            l.update(repeating: 0, count: n)
            r.update(repeating: 0, count: n)
            if !state.render(l, r, n, now: now, ts: ts.pointee) { isSilence.pointee = true }
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        setBufferFrames(bufferFrames)
        try engine.start()
        isRunning = true
    }

    public func stop() {
        engine.stop()
        isRunning = false
    }

    /// Plays `clip` now. `layer` 0 = soft, 0.5 = medium (the recording), 1 = hard, continuous in
    /// between. `eventTicks` (mach_absolute_time of the key event) is only used for the latency statistics.
    public func play(_ clip: Clip, gain: Float, brightness: Double, pitch: Double, layer: Double = 0.5, eventTicks: UInt64) {
        guard isRunning else { return }
        st.push(Trigger(clip, gain: gain, brightness: brightness, pitch: pitch, layer: layer, outRate: st.outRate,
                        eventTicks: eventTicks, enqueueTicks: mach_absolute_time()))
    }

    public func latencyStats() -> LatencyStats {
        var s = st.latency()
        s.hardwareMs = deviceInfo().hardwareMs
        return s
    }

    /// Forget the latency samples (e.g. after switching detection mode).
    public func resetLatency() { st.resetLatency() }

    public var maxActiveVoices: Int { st.maxVoices }
    public var renderCycles: Int { st.renders }

    // MARK: - CoreAudio device

    private var outputUnit: AudioUnit? { engine.outputNode.audioUnit }

    private func deviceID() -> AudioDeviceID? {
        guard let au = outputUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr, id != 0 else { return nil }
        return id
    }

    private static func get<T: BitwiseCopyable>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ v: T) -> T {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = v
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : v
    }

    @discardableResult
    private func setBufferFrames(_ want: UInt32) -> Bool {
        guard let au = outputUnit else { return false }
        let range = deviceID().map { Self.get($0, kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeGlobal, AudioValueRange()) }
        var frames = want
        if let r = range, r.mMaximum > 0 { frames = UInt32(max(r.mMinimum, min(r.mMaximum, Double(want)))) }
        return AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames,
                                    UInt32(MemoryLayout<UInt32>.size)) == noErr
    }

    /// The device the engine plays on.
    public func deviceInfo() -> OutputDeviceInfo {
        var info = deviceID().map(Self.info(for:)) ?? OutputDeviceInfo()
        info.presentationLatency = engine.outputNode.presentationLatency
        return info
    }

    public static func defaultOutputDevice() -> AudioDeviceID? {
        let id = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0))
        return id == 0 ? nil : id
    }

    /// Every device with output streams.
    public static func outputDevices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var n: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &n) == noErr && n > 0
        }
    }

    /// What CoreAudio reports for any device.
    public static func info(for id: AudioDeviceID) -> OutputDeviceInfo {
        var info = OutputDeviceInfo()
        info.id = id
        let out = kAudioObjectPropertyScopeOutput
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() { info.name = n as String }
        let transport = get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0))
        info.transportType = transport
        info.transport = [kAudioDeviceTransportTypeBuiltIn: "built-in", kAudioDeviceTransportTypeBluetooth: "Bluetooth",
                          kAudioDeviceTransportTypeBluetoothLE: "Bluetooth LE", kAudioDeviceTransportTypeUSB: "USB",
                          kAudioDeviceTransportTypeHDMI: "HDMI", kAudioDeviceTransportTypeDisplayPort: "DisplayPort",
                          kAudioDeviceTransportTypeAirPlay: "AirPlay", kAudioDeviceTransportTypeVirtual: "virtual",
                          kAudioDeviceTransportTypeAggregate: "aggregate", kAudioDeviceTransportTypeThunderbolt: "Thunderbolt",
                          kAudioDeviceTransportTypeContinuityCaptureWired: "Continuity (wired)",
                          kAudioDeviceTransportTypeContinuityCaptureWireless: "Continuity (wireless)"][transport] ?? String(format: "0x%08x", transport)
        info.sampleRate = get(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0))
        info.bufferFrames = get(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, UInt32(0))
        let r = get(id, kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeGlobal, AudioValueRange())
        info.bufferRange = (r.mMinimum, r.mMaximum)
        info.deviceLatency = get(id, kAudioDevicePropertyLatency, out, UInt32(0))
        info.safetyOffset = get(id, kAudioDevicePropertySafetyOffset, out, UInt32(0))
        let stream = get(id, kAudioDevicePropertyStreams, out, AudioStreamID(0))  // first output stream
        if stream != 0 { info.streamLatency = get(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, UInt32(0)) }
        return info
    }
}

// MARK: - render thread state

struct Trigger {
    var aL: UnsafePointer<Float>, aR: UnsafePointer<Float>   // lower layer
    var bL: UnsafePointer<Float>, bR: UnsafePointer<Float>   // upper layer
    var mix: Float                                           // 0 = a only … 1 = b only
    var frames: Int
    var step: Double
    var gain: Float, lpA: Float
    var eventTicks: UInt64, enqueueTicks: UInt64

    /// Everything the render thread needs, computed on the caller's thread.
    init(_ clip: Clip, gain: Float, brightness: Double, pitch: Double, layer: Double, outRate: Double,
         eventTicks: UInt64, enqueueTicks: UInt64) {
        let x = max(0, min(1, layer)) * 2              // 0 … 2 over soft, medium, hard
        let lo = min(1, Int(x))
        let a = clip.layer(lo), b = clip.layer(lo + 1)
        var m = Float(x - Double(lo))
        if m < 0.002 { m = 0 }
        (aL, aR) = a
        (bL, bR) = m == 0 ? a : b
        if m > 0.998 { (aL, aR) = b; m = 0 }
        mix = m
        frames = clip.frames
        step = clip.sampleRate / outRate * pitch
        self.gain = gain
        lpA = brightness >= 0.98 ? 1 : Float(1 - exp(-2 * Double.pi * lowpassHz(brightness: brightness) / outRate))
        self.eventTicks = eventTicks
        self.enqueueTicks = enqueueTicks
    }
}

struct Voice {
    var active = false
    var aL: UnsafePointer<Float>?, aR: UnsafePointer<Float>?
    var bL: UnsafePointer<Float>?, bR: UnsafePointer<Float>?
    var mix: Float = 0
    var frames = 0
    var pos = 0.0, step = 1.0
    var gain: Float = 0, lpA: Float = 1
    var zl: Float = 0, zr: Float = 0
}

struct LatencySample { var eventToOutput: Float, enqueueToRender: Float, outputAhead: Float }

final class RenderState {
    static let queueCap = 64, latCap = 512
    let voices = UnsafeMutablePointer<Voice>.allocate(capacity: KeyAudioEngine.voiceCount)
    let queue = UnsafeMutablePointer<Trigger>.allocate(capacity: queueCap)
    let lat = UnsafeMutablePointer<LatencySample>.allocate(capacity: latCap)
    var qHead = 0, qCount = 0
    var latHead = 0, latTotal = 0
    let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    var outRate = 48000.0
    var master: Float = 1, masterNow: Float = 1
    var renders = 0, maxVoices = 0

    init() { voices.initialize(repeating: Voice(), count: KeyAudioEngine.voiceCount) }

    /// Only while the engine is stopped.
    func reset() {
        os_unfair_lock_lock(lock)
        for i in 0..<KeyAudioEngine.voiceCount { voices[i].active = false }
        qCount = 0
        os_unfair_lock_unlock(lock)
    }

    func resetLatency() {
        os_unfair_lock_lock(lock)
        latHead = 0; latTotal = 0
        os_unfair_lock_unlock(lock)
    }

    func push(_ t: Trigger) {
        os_unfair_lock_lock(lock)
        if qCount < Self.queueCap {
            queue[(qHead + qCount) % Self.queueCap] = t
            qCount += 1
        }
        os_unfair_lock_unlock(lock)
    }

    func latency() -> LatencyStats {
        os_unfair_lock_lock(lock)
        let n = min(latTotal, Self.latCap)
        let s = (0..<n).map { lat[(latHead - n + $0 + Self.latCap) % Self.latCap] }
        let total = latTotal
        os_unfair_lock_unlock(lock)
        var out = LatencyStats()
        out.count = total
        out.eventToOutput = s.map { Double($0.eventToOutput) }
        out.enqueueToRender = s.map { Double($0.enqueueToRender) }
        out.outputAhead = s.map { Double($0.outputAhead) }
        return out
    }

    /// Real-time thread. Returns false when the output is silent.
    @inline(__always)
    func render(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int, now: UInt64, ts: AudioTimeStamp) -> Bool {
        renders &+= 1
        if qCount > 0, os_unfair_lock_trylock(lock) {
            let outHost = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : now
            while qCount > 0 {
                let t = queue[qHead]
                qHead = (qHead + 1) % Self.queueCap
                qCount -= 1
                startVoice(t)
                lat[latHead] = LatencySample(eventToOutput: Float(ticksToMs(Int64(bitPattern: outHost &- t.eventTicks))),
                                             enqueueToRender: Float(ticksToMs(Int64(bitPattern: now &- t.enqueueTicks))),
                                             outputAhead: Float(ticksToMs(Int64(bitPattern: outHost &- now))))
                latHead = (latHead + 1) % Self.latCap
                latTotal += 1
            }
            os_unfair_lock_unlock(lock)
        }
        var active = 0
        for i in 0..<KeyAudioEngine.voiceCount where voices[i].active {
            active += 1
            mix(&voices[i], l, r, n)
        }
        maxVoices = max(maxVoices, active)
        let target = master
        if active == 0 { masterNow = target; return false }
        var g = masterNow
        let dg = (target - g) / Float(n)
        for i in 0..<n {
            g += dg
            l[i] = softClip(l[i] * g)
            r[i] = softClip(r[i] * g)
        }
        masterNow = target
        return true
    }

    @inline(__always)
    private func startVoice(_ t: Trigger) {
        var idx = -1
        var most = -1.0
        for i in 0..<KeyAudioEngine.voiceCount {
            if !voices[i].active { idx = i; break }
            let done = voices[i].pos / Double(voices[i].frames)   // steal the most-finished voice
            if done > most { most = done; idx = i }
        }
        voices[idx] = Voice(active: true, aL: t.aL, aR: t.aR, bL: t.bL, bR: t.bR, mix: t.mix, frames: t.frames,
                            pos: 0, step: t.step, gain: t.gain, lpA: t.lpA, zl: 0, zr: 0)
    }

    @inline(__always)
    private func mix(_ v: inout Voice, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard let al = v.aL, let ar = v.aR, let bl = v.bL, let br = v.bR else { v.active = false; return }
        let fr = v.frames, step = v.step, g = v.gain, a = v.lpA, m = v.mix
        var pos = v.pos, zl = v.zl, zr = v.zr
        if m == 0 {
            for i in 0..<n {
                let ip = Int(pos)
                if ip >= fr - 1 { v.active = false; break }
                let f = Float(pos - Double(ip))
                zl += a * (hermite(al, ip, fr, f) - zl)
                zr += a * (hermite(ar, ip, fr, f) - zr)
                l[i] += zl * g
                r[i] += zr * g
                pos += step
            }
        } else {
            for i in 0..<n {
                let ip = Int(pos)
                if ip >= fr - 1 { v.active = false; break }
                let f = Float(pos - Double(ip))
                let xl = hermite(al, ip, fr, f) + m * (hermite(bl, ip, fr, f) - hermite(al, ip, fr, f))
                let xr = hermite(ar, ip, fr, f) + m * (hermite(br, ip, fr, f) - hermite(ar, ip, fr, f))
                zl += a * (xl - zl)
                zr += a * (xr - zr)
                l[i] += zl * g
                r[i] += zr * g
                pos += step
            }
        }
        v.pos = pos; v.zl = zl; v.zr = zr
    }
}

@inline(__always)
func hermite(_ s: UnsafePointer<Float>, _ i: Int, _ n: Int, _ t: Float) -> Float {
    let xm1 = s[max(i - 1, 0)], x0 = s[i], x1 = s[i + 1], x2 = s[min(i + 2, n - 1)]
    let c1 = 0.5 * (x1 - xm1)
    let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
    let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
    return ((c3 * t + c2) * t + c1) * t + x0
}

/// Transparent below 0.8, smooth knee to ±1 above.
@inline(__always)
func softClip(_ x: Float) -> Float {
    let a = abs(x)
    guard a > 0.8 else { return x }
    let y = 0.8 + 0.2 * tanh((a - 0.8) / 0.2)
    return x < 0 ? -y : y
}

// MARK: - offline self-test (no audio device)

public enum MixerSelfTest {
    /// Renders through the real render path and returns (name, passed, detail) per check.
    public static func run(clip: Clip, outRate: Double = 48000) -> [(String, Bool, String)] {
        func render(_ triggers: [(gain: Float, brightness: Double, pitch: Double)], layer: Double = 0.5, frames: Int = 48000) -> (l: [Float], voices: Int) {
            let st = RenderState()
            st.outRate = outRate
            for t in triggers {
                st.push(Trigger(clip, gain: t.gain, brightness: t.brightness, pitch: t.pitch, layer: layer, outRate: outRate,
                                eventTicks: mach_absolute_time(), enqueueTicks: mach_absolute_time()))
            }
            var l = [Float](repeating: 0, count: frames), r = l
            var ts = AudioTimeStamp()
            ts.mFlags = .hostTimeValid
            var off = 0
            while off < frames {
                let n = min(64, frames - off)
                l.withUnsafeMutableBufferPointer { lp in
                    r.withUnsafeMutableBufferPointer { rp in
                        ts.mHostTime = mach_absolute_time()
                        _ = st.render(lp.baseAddress! + off, rp.baseAddress! + off, n, now: ts.mHostTime, ts: ts)
                    }
                }
                off += n
            }
            return (l, st.maxVoices)
        }
        func rms(_ x: [Float]) -> Double { (x.reduce(0) { $0 + Double($1 * $1) } / Double(x.count)).squareRoot() }
        func hf(_ x: [Float]) -> Double { rms(zip(x.dropFirst(), x).map { $0 - $1 }) }   // first difference ≈ high band
        func length(_ x: [Float]) -> Int { (x.lastIndex { abs($0) > 1e-6 } ?? 0) + 1 }

        var out: [(String, Bool, String)] = []
        let unit = render([(0.1, 1, 1)]).l, quarter = render([(0.025, 1, 1)]).l
        let ratioDb = 20 * log10(rms(unit) / rms(quarter))
        out.append(("gain: 0.1 vs 0.025 = 12.04 dB", abs(ratioDb - 12.04) < 0.1, String(format: "%.2f dB", ratioDb)))
        let dark = render([(0.1, 0, 1)]).l
        let hfDrop = 20 * log10(hf(dark) / hf(unit)), lfDrop = 20 * log10(rms(dark) / rms(unit))
        out.append(("low-pass: soft (2.5 kHz) loses highs, keeps level", hfDrop < -3 && lfDrop > -6,
                    String(format: "high band %.1f dB, overall %.1f dB", hfDrop, lfDrop)))
        let up = length(render([(0.1, 1, 1.03)]).l), base = length(unit)
        out.append(("pitch +3 %: clip 3 % shorter", abs(Double(base) / Double(up) - 1.03) < 0.005, "\(base) → \(up) frames"))
        let many = render(Array(repeating: (Float(0.05), 1.0, 1.0), count: 20))
        out.append(("20 simultaneous triggers: pool of \(KeyAudioEngine.voiceCount), no crash", many.voices == KeyAudioEngine.voiceCount,
                    "max voices \(many.voices)"))
        let loud = render([(4, 1, 1)]).l
        out.append(("soft clipper keeps |x| ≤ 1", (loud.map(abs).max() ?? 0) <= 1, String(format: "peak %.3f", loud.map(abs).max() ?? 0)))

        // Velocity layers: soft → hard gets brighter at about the same level; the crossfade is continuous.
        let layers = [0.0, 0.25, 0.5, 0.75, 1.0].map { render([(0.1, 1, 1)], layer: $0).l }
        let tilt = layers.map { 20 * log10(hf($0) / rms($0)) }
        let level = layers.map { 20 * log10(rms($0) / rms(unit)) }
        out.append(("layers: brighter from soft to hard (high band re. level rises monotonically)",
                    zip(tilt, tilt.dropFirst()).allSatisfy { $0 < $1 } && tilt[4] - tilt[0] > 4,
                    tilt.map { String(format: "%.1f", $0) }.joined(separator: " ") + " dB"))
        // Layers are matched in K-weighted loudness (SoundBank); plain RMS differs because the soft layer keeps its lows.
        out.append(("layers: layer 0.5 renders the recording itself", abs(level[2]) < 0.01,
                    "RMS re. recording " + level.map { String(format: "%+.1f", $0) }.joined(separator: " ") + " dB"))
        let mid = render([(0.1, 1, 1)], layer: 0.25).l, s = layers[0], m = layers[2]
        let midErr = rms(zip(mid, zip(s, m)).map { $0 - 0.5 * ($1.0 + $1.1) }) / rms(mid)
        out.append(("crossfade: layer 0.25 = half soft + half medium", midErr < 1e-3, String(format: "rel. error %.1e", midErr)))
        return out
    }
}
