import AppKit
import Carbon
import ClackwiseCore
import os
import ServiceManagement

let log = Logger(subsystem: "io.github.bobk4ta.clackwise", category: "app")

/// Owns sensor, detector, mapper, audio engine, event tap, hot key and the UI model.
/// Privacy: key events are used to play a sound and update aggregate counters, nothing else.
/// Nothing here logs or stores key codes in order, typed text or per-keystroke times.
final class AppController: NSObject, NSApplicationDelegate, AppActions {
    let model = AppModel()
    private let ring = Ring(cap: 2048)            // ≈ 2.5 s of samples
    private var acc: Accelerometer?
    /// False on Macs without the motion sensor (M1 Air, 13" M1 Pro, Intel, desktops): every key plays
    /// at the normal level and Dynamics is disabled. `--simulate-no-sensor` forces it for testing.
    private let sensorPresent = !CommandLine.arguments.contains("--simulate-no-sensor") && SensorSupport.detect()
    private lazy var detector = ImpactDetector(ring: ring)
    private let mapper: VelocityMapper
    private let engine = KeyAudioEngine()
    private let stats = Stats()
    private lazy var tap = KeyTap { [unowned self] type, event, recv in self.onEvent(type, event, recv) }
    /// Mouse/trackpad buttons, only for the onset measurement. Separate tap: if it can't be created,
    /// the key tap is unaffected.
    private lazy var clickTap = KeyTap(types: KeyTap.buttons) { [unowned self] _, event, _ in self.onClick(event) }
    private let monitor = OnsetMonitor()
    private let peakQueue = DispatchQueue(label: "clackwise.peak", qos: .userInteractive)
    private let defaults = UserDefaults.standard

    private var packs: [SoundPack] = []
    private var banks: [String: SoundBank] = [:]     // "<pack id>#<trim lead-in>"
    private var bundledOffsets: [String: Double] = [:]

    // State read on the tap thread; written on main.
    private struct Live {
        var enabled = true; var mode = DetectMode.instant; var bank: SoundBank?
        var keyUp = true; var variation = true; var version = MappingVersion.v2
        /// Sensor paused (no keys for `sensorIdleAfter`, or Clackwise off); the next key resumes it.
        var sensorIdle = false
        /// Another app is recording from a microphone and "pause while the microphone is in use" is on.
        var micBusy = false
    }
    private var live = Live()
    private let liveLock = NSLock()
    private func current() -> Live { liveLock.lock(); defer { liveLock.unlock() }; return live }
    private func update(_ body: (inout Live) -> Void) { liveLock.lock(); body(&live); liveLock.unlock() }

    // Tap thread / peak queue only (guarded by keyLock).
    private var clock = EventClockConverter()
    private var lastVelocity = [Velocity?](repeating: nil, count: 256)
    private var modsDown = Set<CGKeyCode>()
    private var lastShown: (g: Double?, v: Velocity)?
    private var lastKeyAt = mach_absolute_time()
    private let keyLock = NSLock()

    // Health.
    private var lastSampleCount = 0
    private var sensorHz = 0.0
    private var sensorStale = 0
    private var secureInput = false
    private var requestedPermission = false
    private var engineError: String?
    private var latencyIngested = 0
    /// Output muted because it is Bluetooth / AirPlay (name), unless allowed in the menu.
    private var mutedOutput: String?
    /// Every output used this session: name → CoreAudio figures, for the Debug menu.
    private var outputsSeen: [String: String] = [:]
    private var wakes = 0, sensorReopens = 0, sensorResumes = 0, outputChanges = 0
    /// No keys for this long → the sensor stream is paused until the next key (battery: the
    /// 800 Hz HID callbacks are about 1.6 % CPU). That key plays on time at the median velocity.
    static let sensorIdleAfter = 30.0

    /// Fresh installs start on this pack (existing settings are kept).
    static let defaultPack = "kbsim-mxbrown"

    private let hotKey = HotKey()
    private lazy var settingsWindow = SettingsWindowController(model: model)
    private lazy var onboardingWindow = OnboardingWindowController(model: model)
    /// Onboarding / permission: when access was first seen granted while the tap still didn't work.
    private var grantedAt: Date?
    private var denial = DenialTracker()
    private var accessDenied = false
    private var accessTimer: Timer?
    private var previewGeneration = 0
    private let guide = SetupGuide()

    override init() {
        let bundled = Bundle.main.url(forResource: "calibration", withExtension: "json").flatMap(Calibration.load)
        let cal = bundled ?? .builtIn
        let saved = AdaptationFile.load()
        var trackers: [DetectMode: AdaptiveTracker] = [:], trackers2: [DetectMode: AdaptiveTracker] = [:]
        // The trackers are histograms of measured impacts, so they stay valid when the bundled starting
        // prior changes: the mapper recomputes the anchors from them (bounded shift and spread).
        if let s = saved {
            trackers[.instant] = s.instant
            trackers[.peak] = s.peak
            trackers2[.instant] = s.v2Instant
            trackers2[.peak] = s.v2Peak
        }
        mapper = VelocityMapper(calibration: cal, trackers: trackers, v2Trackers: trackers2)
        bundledOffsets = mapper.keyOffsets
        selfCheck = CommandLine.arguments.contains("--selfcheck")
        super.init()
        model.actions = self
    }

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Installs from before onboarding existed (a pack was already chosen) count as onboarded (before register: it would mask nil).
        if defaults.object(forKey: "onboarded") == nil && defaults.string(forKey: "pack") != nil { defaults.set(true, forKey: "onboarded") }
        defaults.register(defaults: ["enabled": true, "volume": 0.8, "strength": 1.0, "mode": DetectMode.instant.rawValue,
                                     "mapping": MappingVersion.v2.rawValue, "keyUp": true, "variation": true, "trimLeadIn": true,
                                     "allowWireless": false, "onsetMeasurement": false, "pauseForMic": true,
                                     "onboarded": false, "shortcut": Shortcut.standard.stored])
        mapper.strength = defaults.double(forKey: "strength")
        mapper.version = MappingVersion(rawValue: defaults.string(forKey: "mapping") ?? "") ?? .v2
        refreshKeyOffsets()
        engine.volume = Float(defaults.double(forKey: "volume"))
        update {
            $0.enabled = defaults.bool(forKey: "enabled")
            $0.mode = DetectMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .instant
            $0.keyUp = defaults.bool(forKey: "keyUp")
            $0.variation = defaults.bool(forKey: "variation")
            $0.version = mapper.version
        }
        let roots = [Bundle.main.resourceURL!.appendingPathComponent("SoundPacks"), SoundPackLoader.userPacksDirectory]
        packs = SoundPackLoader.discover(in: roots)
        model.packs = packs.map { PackItem(id: $0.id, name: $0.name, type: $0.type, color: $0.color, classic: $0.classic, synthesizedKeyUp: !$0.hasKeyUp) }
        let packID = [defaults.string(forKey: "pack"), Self.defaultPack].compactMap { $0 }.first { id in packs.contains { $0.id == id } } ?? packs.first?.id
        if let packID { selectPack(packID) }

        if current().enabled || selfCheck { startSensor() } else { update { $0.sensorIdle = true } }
        engine.onOutputChange = { [weak self] in self?.outputChanged() }
        if current().enabled { startAudio() }
        installTapOrAsk()
        if !selfCheck && defaults.bool(forKey: "onsetMeasurement") { _ = clickTap.install() }
        hotKey.action = { [weak self] in self?.toggleEnabled() }
        guide.isGranted = { [weak self] in self?.hasAccess ?? false }
        if !selfCheck { registerShortcut() }
        refreshModel()
        if !selfCheck && !defaults.bool(forKey: "onboarded") { showOnboarding() }

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.healthTick() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.saveState() }
        // After sleep, lid open, display wake, login / fast user switch: re-wake the sensor, check
        // the tap and the output. Nothing should need a relaunch.
        let ws = NSWorkspace.shared.notificationCenter
        for (name, why) in [(NSWorkspace.didWakeNotification, "wake"), (NSWorkspace.screensDidWakeNotification, "screens wake"),
                            (NSWorkspace.sessionDidBecomeActiveNotification, "session active")] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.recover(why) }
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.saveState() }
        if selfCheck { runSelfCheck() }
    }

    func applicationWillTerminate(_ notification: Notification) { saveState() }

    /// Opening the app again (Finder, Spotlight, a second `open`) shows Settings: there is no
    /// other window, and the menu bar icon may be hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !selfCheck { showSettings() }
        return false
    }

    /// `Clackwise --selfcheck`: start everything, push 20 synthetic presses through the real press
    /// path at volume 0 (real sensor data, detector, mapper, engine), print the status, exit.
    /// Doesn't touch the stats or adaptation files.
    var selfCheck = false
    private var callbackCostMs: [Double] = []
    private var selfCheckGains: [Velocity] = []
    private func runSelfCheck() {
        engine.volume = 0
        let mode: DetectMode = CommandLine.arguments.contains("--peak") ? .peak : .instant
        update { $0.enabled = true; $0.mode = mode }
        if !engine.isRunning { startAudio() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
            let q = DispatchQueue(label: "selfcheck", qos: .userInteractive)
            q.async { [self] in
                for i in 0..<20 {
                    Thread.sleep(forTimeInterval: 0.08)
                    let now = mach_absolute_time()
                    // Synthetic event 0.7 ms old, raw timestamp in ns like CGEvent on this macOS.
                    let ts = now &- UInt64(msToTicks(0.7))
                    press(CGKeyCode([0x00, 0x01, 0x31, 0x38][i % 4]), raw: UInt64(ticksToNs(ts)), recv: now)
                }
                Thread.sleep(forTimeInterval: 0.4)
                DispatchQueue.main.async { [self] in
                    let d = engine.deviceInfo(), s = engine.latencyStats()
                    keyLock.lock(); let last = lastShown; keyLock.unlock()
                    let b = current().bank
                    print("""
                    selfcheck (\(current().mode.rawValue) detection)
                      sensor: \(sensorPresent ? "\(Int(sensorHz.rounded())) Hz, ring \(ring.total) samples" : "none in this Mac: Dynamics off, normal level for every key")
                      tap working (Input Monitoring): \(tap.isWorking)   secure input: \(IsSecureEventInputEnabled())
                      packs: \(packs.map(\.id).joined(separator: ", "))   current: \(current().bank?.pack.id ?? "none")
                      calibration: \(mapper.calibration.source); velocity \(mapper.version.rawValue) (v2: \(mapper.v2Calibration.source), \(mapper.keyOffsets.count) key offsets)
                      bank: \(b.map { "\($0.clipCount) clips × 3 layers, key-up \($0.keyUpSynthesized ? "synthesized" : "recorded"), attack median \(String(format: "%.1f", $0.attackMs.median)) ms, loaded in \(Int($0.loadMs)) ms" } ?? "none")
                      audio: running \(engine.isRunning) on \(d.name) [\(d.transport)] \(Int(d.sampleRate)) Hz, buffer \(d.bufferFrames) frames, device+stream \(String(format: "%.2f", d.hardwareMs)) ms\(mutedOutput.map { " — muted: \($0) is Bluetooth/AirPlay" } ?? "")
                      login item: \(loginItemStatus)   tap recoveries: \(tap.recoveries.reenabled) re-enabled, \(tap.recoveries.reinstalled) recreated
                      synthetic presses played: \(s.count), last impact \(last?.g.map { String(format: "%.1f mg", $0 * 1000) } ?? "nil") → \(String(format: "%.1f", last?.v.gainDb ?? .nan)) dB, layer \(String(format: "%.2f", last?.v.layer ?? .nan))
                      tap callback → sound queued (detect + map + enqueue): p50 \(String(format: "%.3f", pct(callbackCostMs, 50))) ms, max \(String(format: "%.3f", callbackCostMs.max() ?? .nan)) ms
                      key event → sound out: p50 \(String(format: "%.2f", pct(s.endToEnd, 50))) ms, p90 \(String(format: "%.2f", pct(s.endToEnd, 90))) ms, max \(String(format: "%.2f", s.endToEnd.max() ?? .nan)) ms
                    """)
                    // Without the sensor every press must have come out identical, at the normal level.
                    keyLock.lock(); let gains = selfCheckGains; keyLock.unlock()
                    let flat = Set(gains.map { "\($0.gainDb)/\($0.layer)/\($0.brightness)" }).count == 1 && gains.allSatisfy(\.noSensor)
                    print("  no-sensor path: \(sensorPresent ? "not active" : flat ? "20 presses, one level, none treated as soft" : "FAILED: levels differ")")
                    exit((s.count == 20 || mutedOutput != nil) && (sensorPresent ? sensorHz > 700 : flat) && (engine.isRunning || mutedOutput != nil) ? 0 : 1)
                }
            }
        }
    }

    private func saveState() {
        guard !selfCheck else { return }
        ingestLatency()
        if defaults.bool(forKey: "onsetMeasurement") { stats.addOnsets(monitor.take()) }
        stats.save()
        refreshKeyOffsets()
        let t = mapper.savedTrackers, t2 = mapper.savedV2Trackers
        writeJSON(AdaptationFile(calibrationSource: mapper.calibration.source, instant: t[.instant], peak: t[.peak],
                                 v2Source: mapper.v2Calibration.source, v2Instant: t2[.instant], v2Peak: t2[.peak]),
                  to: AdaptationFile.url)
    }

    /// v2 per-key offsets: the bundled table, overridden by what your own stats say once a key has
    /// enough presses (KeyCorrection.minPresses).
    private func refreshKeyOffsets() {
        mapper.keyOffsets = bundledOffsets.merging(KeyCorrection.derive(from: stats.snapshot)) { _, own in own }
    }

    private func ingestLatency() {
        let s = engine.latencyStats()
        let new = s.count - latencyIngested
        if new > 0 { stats.recordLatency(Array(s.endToEnd.suffix(new))) }
        latencyIngested = s.count
    }

    // MARK: - sensor / audio / tap

    private func startSensor() {
        guard sensorPresent else { return }
        wakeAccelDriver()
        let a = Accelerometer(ring: ring)
        if defaults.bool(forKey: "onsetMeasurement") { a.sampleHook = { [monitor] in monitor.feed($0) } }
        let (r, msg) = a.open()
        update { $0.sensorIdle = false }
        guard r == kIOReturnSuccess else { log.error("accelerometer open failed: \(msg, privacy: .public)"); return }
        a.start()
        wakeAccelDriver()
        acc = a
    }

    private func stopSensor() {
        acc?.close()
        acc = nil
    }

    /// Next key after an idle pause: the sound is already queued (at the median velocity); bring
    /// the stream back for the keys that follow.
    private func resumeSensor() {
        guard acc == nil, current().enabled else { return }
        sensorResumes += 1
        let t0 = mach_absolute_time(), n0 = ring.total
        startSensor()
        sensorStale = 0
        lastSampleCount = ring.total
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            log.notice("sensor resumed on a key: \(self.ring.total - n0) samples in \(Int(ticksToMs(Int64(mach_absolute_time() - t0)))) ms")
        }
    }

    /// Plays on the default output unless it is Bluetooth / AirPlay and that isn't allowed; then
    /// the engine stays stopped (muted) until the output changes.
    private func startAudio() {
        let out = KeyAudioEngine.defaultOutputDevice().map(KeyAudioEngine.info(for:))
        if let o = out, o.isWireless, !defaults.bool(forKey: "allowWireless") {
            if engine.isRunning { engine.stop() }
            if mutedOutput != o.name { log.notice("output \(o.name, privacy: .public) [\(o.transport, privacy: .public)]: muted (Bluetooth/AirPlay)") }
            mutedOutput = o.name
            engineError = nil
            noteOutput(o, muted: true)
            return
        }
        mutedOutput = nil
        do {
            try engine.start(bufferFrames: 64)
            engineError = nil
            let d = engine.deviceInfo()
            noteOutput(d, muted: false)
            log.notice("output \(d.name, privacy: .public) [\(d.transport, privacy: .public)] \(Int(d.sampleRate)) Hz, buffer \(d.bufferFrames) frames, device+stream \(String(format: "%.2f", d.hardwareMs), privacy: .public) ms")
        } catch {
            engineError = error.localizedDescription
            log.error("audio engine: \(error.localizedDescription, privacy: .public)")
        }
        engine.resetLatency(); latencyIngested = 0
    }

    private func noteOutput(_ d: OutputDeviceInfo, muted: Bool) {
        outputsSeen[d.name] = String(format: "%@ [%@]: %.0f Hz, buffer %d (%d–%d), device %d + stream %d + safety %d frames → reported key → sound ≈ %.1f ms%@",
                                     d.name, d.transport, d.sampleRate, Int(d.bufferFrames), Int(d.bufferRange.min), Int(d.bufferRange.max),
                                     Int(d.deviceLatency), Int(d.streamLatency), Int(d.safetyOffset), d.estimateMs(frames: 64),
                                     muted ? " · muted" : "")
    }

    /// Default output changed or the engine was reconfigured (debounced by the engine).
    private func outputChanged() {
        outputChanges += 1
        let l = current()
        guard l.enabled else { return }
        let d = KeyAudioEngine.defaultOutputDevice().map(KeyAudioEngine.info(for:))
        let wantMuted = d?.isWireless == true && !defaults.bool(forKey: "allowWireless")
        if wantMuted || !engine.isRunning || engine.needsRestart || (mutedOutput != nil) != wantMuted { startAudio() }
        refreshModel()
    }

    /// After wake / display wake / login: the sensor may have been powered down and the tap disabled.
    private func recover(_ why: String) {
        wakes += 1
        log.notice("recover after \(why, privacy: .public)")
        if acc != nil {
            wakeAccelDriver()
            sensorStale = 0
            lastSampleCount = ring.total
            // Reopen quickly if re-waking didn't bring the stream back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.acc != nil, self.ring.total == self.lastSampleCount else { return }
                log.notice("sensor silent after \(why, privacy: .public): reopening")
                self.sensorReopens += 1
                self.stopSensor(); self.startSensor()
            }
        }
        if !tapAlive() { installTapOrAsk() }
        if current().enabled, !engine.isRunning || engine.needsRestart { startAudio() }
        refreshModel()
    }

    /// Creating the tap without access is what makes macOS show its "Keystroke Receiving" alert
    /// (onboarding test 2: at launch, before anything was explained). So until onboarding has asked,
    /// the tap is only created once access is already there.
    private var mayCreateTap: Bool {
        selfCheck || CGPreflightListenEventAccess() || requestedPermission || defaults.bool(forKey: "onboarded")
    }

    private func tapAlive() -> Bool { mayCreateTap && tap.ensureAlive() }

    /// Keys reach Clackwise: the tap is valid and enabled. Not CGPreflightListenEventAccess: it is
    /// answered from a per-process cache and was still "no" a second after access was granted
    /// (onboarding test 4), while a tap created after the grant is enabled at once.
    private var hasAccess: Bool { tap.isWorking }

    private func installTapOrAsk() {
        if selfCheck || (mayCreateTap && tap.install() && tap.isWorking) { return }
        // First run: onboarding asks, at the moment it explains why.
        if !requestedPermission && defaults.bool(forKey: "onboarded") {
            requestedPermission = true
            _ = CGRequestListenEventAccess()   // adds Clackwise to Input Monitoring and shows the system prompt
        }
    }

    private func healthTick() {
        let l = current()
        // Sensor idle: paused when Clackwise is off or no key for `sensorIdleAfter`; the next key resumes it.
        keyLock.lock(); let idleFor = ticksToMs(Int64(bitPattern: mach_absolute_time() &- lastKeyAt)) / 1000; keyLock.unlock()
        if acc != nil, !selfCheck, !l.enabled || idleFor > Self.sensorIdleAfter {
            stopSensor()
            update { $0.sensorIdle = true }
            log.notice("sensor paused (\(l.enabled ? "no keys for \(Int(Self.sensorIdleAfter)) s" : "Clackwise off", privacy: .public))")
        } else if sensorPresent, acc == nil, !l.sensorIdle, l.enabled {
            startSensor()   // open failed earlier: retry
        }
        // Sensor: re-wake if it stopped, reopen if re-waking didn't help.
        let total = ring.total
        sensorHz = Double(total - lastSampleCount) / 2
        lastSampleCount = total
        if acc != nil, sensorHz < 100 {
            sensorStale += 1
            if sensorStale == 1 { wakeAccelDriver() }
            if sensorStale == 3 { sensorReopens += 1; stopSensor(); startSensor(); sensorStale = 0 }
        } else { sensorStale = 0 }
        if !tapAlive() { installTapOrAsk() }
        if defaults.bool(forKey: "onsetMeasurement") { _ = clickTap.ensureAlive() }
        if l.enabled, mutedOutput == nil, !engine.isRunning || engine.needsRestart { startAudio() }
        secureInput = IsSecureEventInputEnabled()
        let mic = l.enabled && defaults.bool(forKey: "pauseForMic") && !selfCheck && MicActivity.inUse()
        if mic != l.micBusy {
            update { $0.micBusy = mic }
            log.notice("\(mic ? "paused: microphone in use" : "microphone free: playing", privacy: .public)")
        }
        // Secure input hides key events, so every keystroke shock would look like an orphan.
        monitor.paused = selfCheck || !l.enabled || !tap.isWorking || secureInput || sensorHz < 100 || !defaults.bool(forKey: "onsetMeasurement")
        refreshModel()
    }

    // MARK: - key events (tap thread)

    private func onEvent(_ type: CGEventType, _ e: CGEvent, _ recv: UInt64) {
        let code = CGKeyCode(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            guard e.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            press(code, raw: e.timestamp, recv: recv)
        case .keyUp:
            guard e.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            release(code, raw: e.timestamp)
        case .flagsChanged:
            if code == Modifier.capsLock { press(code, raw: e.timestamp, recv: recv); return }
            guard let down = Modifier.isDown(code: code, flags: e.flags) else { return }
            keyLock.lock()
            let was = modsDown.contains(code)
            if down { modsDown.insert(code) } else { modsDown.remove(code) }
            keyLock.unlock()
            if down && !was { press(code, raw: e.timestamp, recv: recv) } else if !down && was { release(code, raw: e.timestamp) }
        default:
            break
        }
    }

    private func press(_ code: CGKeyCode, raw: UInt64, recv: UInt64) {
        let l = current()
        guard l.enabled, !l.micBusy else { return }
        keyLock.lock()
        let ts = clock.convert(raw)
        lastKeyAt = recv
        keyLock.unlock()
        defer { if l.sensorIdle { DispatchQueue.main.async { [self] in resumeSensor() } } }
        guard sensorPresent else {
            // No sensor in this Mac: the normal level for every key, nothing to detect or learn.
            let v = mapper.map(nil, mode: .instant)
            play(code, up: false, v, eventTs: ts, live: l)
            if selfCheck { callbackCostMs.append(ticksToMs(Int64(mach_absolute_time() - recv))) }
            finishPress(code, instant: nil, v)
            return
        }
        let from = detector.beginKey(ts: ts)
        let key = KeycodeMap.name(for: code)
        // Instant: only the samples already in the ring now, at the tap callback.
        let instant = detector.impact(keyTs: ts, searchFrom: from, availableBy: recv)
        let peakAt = DispatchTime(uptimeNanoseconds: UInt64(ticksToNs(recv) + ImpactWindow.peakWaitMs * 1e6))
        switch l.mode {
        case .instant:
            let v = mapper.process(instant, mode: .instant, key: key)
            play(code, up: false, v, eventTs: ts, live: l)
            if selfCheck { callbackCostMs.append(ticksToMs(Int64(mach_absolute_time() - recv))) }
            finishPress(code, instant: instant, v)
            // The full peak only feeds the peak-mode tracker and stats; nothing waits for it.
            peakQueue.asyncAfter(deadline: peakAt) { [self] in
                let peak = detector.impact(keyTs: ts, searchFrom: from, availableBy: mach_absolute_time())
                mapper.observe(peak, mode: .peak, key: key)
                if !selfCheck { stats.recordPeak(peak) }
            }
        case .peak:
            peakQueue.asyncAfter(deadline: peakAt) { [self] in
                let peak = detector.impact(keyTs: ts, searchFrom: from, availableBy: mach_absolute_time())
                mapper.observe(instant, mode: .instant, key: key)
                let v = mapper.process(peak, mode: .peak, key: key)
                play(code, up: false, v, eventTs: ts, live: l)
                finishPress(code, instant: instant, v)
                stats.recordPeak(peak)
            }
        }
        // Measurement only, after the sound is queued.
        if !selfCheck && !l.sensorIdle { monitor.keyDown(ts: ts, recv: recv) }
    }

    private func finishPress(_ code: CGKeyCode, instant: Double?, _ v: Velocity) {
        if selfCheck { keyLock.lock(); selfCheckGains.append(v); keyLock.unlock() }
        if !selfCheck && sensorPresent { stats.recordPress(code: code, instant: instant, velocity: v, v2: mapper.version == .v2) }
        keyLock.lock()
        lastVelocity[Int(code) & 0xFF] = v
        lastShown = (instant, v)
        keyLock.unlock()
    }

    /// Key-up sound (recorded, or synthesized from the press for packs without one), at the
    /// loudness of that key's press, layer halfway back to the recording.
    private func release(_ code: CGKeyCode, raw: UInt64) {
        let l = current()
        guard l.enabled, !l.micBusy else { return }
        keyLock.lock()
        let ts = clock.convert(raw)
        keyLock.unlock()
        if l.keyUp, l.bank != nil {
            let go = { [self] in
                keyLock.lock()
                let v = lastVelocity[Int(code) & 0xFF] ?? mapper.map(nil, mode: l.mode)
                keyLock.unlock()
                play(code, up: true, v.forRelease, eventTs: ts, live: l)
            }
            if l.mode == .peak { peakQueue.asyncAfter(deadline: .now() + ImpactWindow.peakWaitMs / 1000, execute: go) } else { go() }
        }
        if !selfCheck { monitor.keyUp(ts: ts) }
    }

    /// Mouse / trackpad button: only counted by the onset monitor.
    private func onClick(_ e: CGEvent) {
        keyLock.lock()
        let ts = clock.convert(e.timestamp)
        keyLock.unlock()
        monitor.click(ts: ts)
    }

    /// Variation on: rotation between recordings (SoundBank), the key's fixed voicing (KeyVoicing)
    /// plus small per-press jitter (triangular: ±0.6 dB, ±20 cents, ±0.05 tone). Off: the earlier
    /// behaviour, ±0.8 dB and ±25 cents uniform, no rotation, no voicing.
    private func play(_ code: CGKeyCode, up: Bool, _ v: Velocity, eventTs: UInt64, live l: Live) {
        guard let bank = l.bank, let clip = bank.clip(for: code, up: up, rotate: l.variation) else { return }
        var db = v.gainDb, cents: Double, tone = 0.0
        if l.variation {
            func tri() -> Double { Double.random(in: 0...1) + Double.random(in: 0...1) - 1 }
            let k = KeyVoicing.offsets(code)
            db += k.db + 0.6 * tri()
            cents = k.cents + 20 * tri()
            tone = k.tone + 0.05 * tri()
        } else {
            db += Double.random(in: -0.8...0.8)
            cents = Double.random(in: -25...25)
        }
        // Tone jitter moves the layer (v2) or the low-pass (v1; an open filter stays open).
        let v2 = l.version == .v2
        engine.play(clip, gain: bank.gain * Float(pow(10, db / 20)),
                    brightness: v2 || v.brightness >= 0.98 ? v.brightness : max(0, min(0.97, v.brightness + tone)),
                    pitch: pow(2, cents / 1200), layer: v2 ? v.layer + tone : 0.5, eventTicks: eventTs)
    }

    // MARK: - actions (AppActions: called by the panel, Settings and onboarding)

    /// Loads the pack in the background on first use (decoded PCM, 3 layers, kept for the app's
    /// lifetime), then switches to it; `then` runs once it is the live bank.
    private func selectPack(_ id: String, then: (() -> Void)? = nil) {
        guard let pack = packs.first(where: { $0.id == id }) else { return }
        defaults.set(id, forKey: "pack")
        let trim = defaults.bool(forKey: "trimLeadIn")
        let cacheKey = "\(id)#\(trim)"
        if let b = banks[cacheKey] {
            update { $0.bank = b }
            model.loadingPackID = nil
            refreshModel()
            then?()
            return
        }
        model.loadingPackID = id
        refreshModel()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let b = SoundBank(pack: pack, trimLeadIn: trim)
            DispatchQueue.main.async { [self] in
                if let b { banks[cacheKey] = b } else { log.error("pack \(id, privacy: .public) failed to load") }
                if defaults.string(forKey: "pack") == id, defaults.bool(forKey: "trimLeadIn") == trim {
                    update { $0.bank = b }
                    model.loadingPackID = nil
                    then?()
                }
                refreshModel()
            }
        }
    }

    /// "keys sound" typed on the current pack (~1 s) through the normal play path at your median
    /// level; picking another pack cuts it short. Silent when Clackwise is off, muted or paused.
    private func playPreview() {
        previewGeneration += 1
        let gen = previewGeneration
        let codes: [CGKeyCode] = [0x28, 0x0E, 0x10, 0x01, 0x31, 0x01, 0x1F, 0x20, 0x2D, 0x02]
        var t = 0.0
        for c in codes {
            let hold = 0.065 + Double.random(in: 0...0.03)
            for (at, up) in [(t, false), (t + hold, true)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [self] in
                    if gen == previewGeneration { previewKey(c, up: up) }
                }
            }
            t += c == 0x31 ? 0.15 : 0.08 + Double.random(in: 0...0.05)
        }
    }

    private func previewKey(_ code: CGKeyCode, up: Bool) {
        let l = current()
        guard l.enabled, !l.micBusy, mutedOutput == nil, engine.isRunning, !up || l.keyUp else { return }
        let v = mapper.map(nil, mode: l.mode)
        play(code, up: up, up ? v.forRelease : v, eventTs: mach_absolute_time(), live: l)
    }

    func pickPack(_ id: String) {
        model.packID = id
        selectPack(id) { [weak self] in self?.playPreview() }
    }

    func setEnabled(_ on: Bool) { if on != current().enabled { toggleEnabled() } }

    /// Also the global shortcut. No animation, no sound: the menu bar icon is the feedback.
    private func toggleEnabled() {
        let on = !current().enabled
        update { $0.enabled = on }
        defaults.set(on, forKey: "enabled")
        if on {
            keyLock.lock(); lastKeyAt = mach_absolute_time(); keyLock.unlock()
            startSensor(); startAudio()
        } else {
            previewGeneration += 1
            engine.stop(); stopSensor(); update { $0.sensorIdle = true; $0.micBusy = false }
        }
        refreshModel()
    }

    func setVolume(_ v: Double) {
        engine.volume = Float(v)
        defaults.set(v, forKey: "volume")
        model.volume = v
    }

    func setOpenAtLogin(_ on: Bool) {
        if let e = Self.setLoginItem(on) { log.error("login item: \(e, privacy: .public)") }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        refreshModel()
    }

    func setAllowWireless(_ on: Bool) {
        defaults.set(on, forKey: "allowWireless")
        if current().enabled { startAudio() }
        refreshModel()
    }

    func setPauseForMic(_ on: Bool) {
        defaults.set(on, forKey: "pauseForMic")
        let busy = on && current().enabled && MicActivity.inUse()
        update { $0.micBusy = busy }
        refreshModel()
    }

    private func registerShortcut() {
        let s = Shortcut(stored: defaults.array(forKey: "shortcut"))
        model.shortcut = s
        model.shortcutTaken = !hotKey.register(s)
        if model.shortcutTaken { log.error("shortcut \(s?.display ?? "", privacy: .public) is taken by another app") }
    }

    func setShortcut(_ s: Shortcut?) {
        defaults.set(s?.stored ?? [], forKey: "shortcut")   // [] = none (the default only applies when unset)
        registerShortcut()
    }

    /// While the recorder listens, the current shortcut must not fire.
    func setRecordingShortcut(_ recording: Bool) {
        if recording { hotKey.register(nil) } else { registerShortcut() }
    }

    func setStrength(_ v: Double) {
        let s = v < 0.03 ? 0 : v
        mapper.strength = s
        defaults.set(s, forKey: "strength")
        model.strength = s
    }

    func setKeyUp(_ on: Bool) {
        update { $0.keyUp = on }
        defaults.set(on, forKey: "keyUp")
        refreshModel()
    }

    func setVariation(_ on: Bool) {
        update { $0.variation = on }
        defaults.set(on, forKey: "variation")
        refreshModel()
    }

    func setTrim(_ on: Bool) {
        defaults.set(on, forKey: "trimLeadIn")
        if let id = defaults.string(forKey: "pack") { selectPack(id) }
        refreshModel()
    }

    func setVersion(_ raw: String) {
        let v = MappingVersion(rawValue: raw) ?? .v2
        mapper.version = v
        update { $0.version = v }
        defaults.set(v.rawValue, forKey: "mapping")
        refreshModel()
    }

    func setMode(_ raw: String) {
        let m = DetectMode(rawValue: raw) ?? .instant
        update { $0.mode = m }
        defaults.set(m.rawValue, forKey: "mode")
        engine.resetLatency(); latencyIngested = 0
        refreshModel()
    }

    func setOnsetMeasurement(_ on: Bool) {
        defaults.set(on, forKey: "onsetMeasurement")
        if on { _ = clickTap.install() }
        if acc != nil { stopSensor(); startSensor() }   // (un)hooks the monitor
        refreshModel()
    }

    func recalibrate() {
        mapper.recalibrate()
        saveState()
        refreshModel()
    }

    func showStatsFile() {
        saveState()
        NSWorkspace.shared.activateFileViewerSelecting([stats.url])
    }

    /// Onboarding's Continue (and the panel's notice): asks macOS, whose "Keystroke Receiving" alert
    /// is the only way onto the Input Monitoring list and whose own button opens System Settings
    /// there. If macOS shows nothing (asked before), opens that pane directly. One thing at a time;
    /// the floating guide points at each macOS step as it appears.
    func requestAccess() {
        requestedPermission = true
        // The request may block while its alert is up; afterwards, open the pane only if macOS showed
        // nothing within 2 s (no alert, no System Settings).
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = CGRequestListenEventAccess()
            DispatchQueue.main.async { [self] in openPaneUnlessMacOSDid(checks: 8) }
        }
        if !defaults.bool(forKey: "onboarded") || onboardingWindow.window?.isVisible == true { guide.start() }
        watchAccess()
    }

    /// Opens the Input Monitoring pane directly (onboarding's button after the user chose Deny).
    func showInputMonitoring() {
        requestedPermission = true
        openInputMonitoring()
        if !defaults.bool(forKey: "onboarded") || onboardingWindow.window?.isVisible == true { guide.start() }
        watchAccess()
    }

    private func trackDenial() {
        let was = denial.denied
        let denied = denial.update(alertVisible: SetupGuide.alertVisible(), systemUI: SetupGuide.systemUIVisible(), hasAccess: hasAccess)
        if denied && !was { log.notice("keystroke receiving: denied by the user") }
        accessDenied = denied
    }

    private func openPaneUnlessMacOSDid(checks: Int) {
        if hasAccess || SetupGuide.systemUIVisible() { return }
        if checks == 0 { openInputMonitoring(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in openPaneUnlessMacOSDid(checks: checks - 1) }
    }

    private func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    /// Polls twice a second while access is missing or onboarding is open. macOS may grant the
    /// permission without the running process' tap ever starting; then offer a relaunch (System
    /// Settings itself may also offer "Quit & Reopen", which lands back in onboarding at step 2).
    private func watchAccess() {
        guard accessTimer == nil else { return }
        accessTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let working = tapAlive()
            trackDenial()
            if working, grantedAt != nil || !model.tapWorking { log.notice("input monitoring: tap working") }
            grantedAt = !working && CGPreflightListenEventAccess() ? (grantedAt ?? Date()) : nil
            refreshModel()
            if working && onboardingWindow.window?.isVisible != true { t.invalidate(); accessTimer = nil }
        }
    }

    @objc func relaunch() {
        saveState()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    func showSettings() { settingsWindow.show() }

    func showOnboarding() {
        onboardingWindow.show()
        watchAccess()
    }

    func finishOnboarding() {
        defaults.set(true, forKey: "onboarded")
        guide.stop()
        onboardingWindow.close()
    }

    func refresh() { refreshModel() }

    // MARK: - launch at login (SMAppService)

    var loginItemStatus: String { Self.loginItemStatus }
    static var loginItemStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "on"
        case .notRegistered: return "off"
        case .requiresApproval: return "needs approval in System Settings → General → Login Items"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    /// `Clackwise --login-item on|off|status` from a script, or the Settings toggle.
    static func setLoginItem(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch { return error.localizedDescription }
    }

    // MARK: - UI model

    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if model[keyPath: key] != value { model[keyPath: key] = value }
    }

    private func refreshModel() {
        let l = current()
        let tapOK = selfCheck || hasAccess
        set(\.enabled, l.enabled)
        set(\.volume, defaults.double(forKey: "volume"))
        set(\.packID, defaults.string(forKey: "pack"))
        set(\.tapWorking, tapOK)
        set(\.accessGranted, CGPreflightListenEventAccess())
        set(\.needsRelaunch, grantedAt.map { Date().timeIntervalSince($0) > 2 } ?? false)
        set(\.accessDenied, accessDenied)
        let notice: Notice? = !tapOK ? .needsAccess
            : engineError.map { .audio($0) } ?? mutedOutput.map { .wireless($0) }
            ?? (secureInput ? .secureInput : l.micBusy ? .microphone : nil)
        set(\.notice, notice)
        set(\.icon, !l.enabled ? .off : !tapOK ? .needsAccess : secureInput ? .secure
            : (mutedOutput != nil || l.micBusy || engineError != nil) ? .muted : .on)
        let login = SMAppService.mainApp.status
        set(\.openAtLogin, login == .enabled || login == .requiresApproval)
        set(\.loginNeedsApproval, login == .requiresApproval)
        set(\.allowWireless, defaults.bool(forKey: "allowWireless"))
        set(\.pauseForMic, defaults.bool(forKey: "pauseForMic"))
        set(\.strength, mapper.strength)
        set(\.hasSensor, sensorPresent)
        set(\.keyUp, l.keyUp)
        set(\.variation, l.variation)
        set(\.trim, defaults.bool(forKey: "trimLeadIn"))
        set(\.version, l.version.rawValue)
        set(\.mode, l.mode.rawValue)
        set(\.onsetMeasurement, defaults.bool(forKey: "onsetMeasurement"))
        set(\.debugLines, debugLines(l))
        set(\.outputs, outputsSeen.keys.sorted().compactMap { outputsSeen[$0] })
    }

    /// Settings → Advanced (hold Option): the former Debug menu.
    private func debugLines(_ l: Live) -> [String] {
        let a = mapper.anchors(l.mode)
        var lines: [String] = []
        lines.append(!sensorPresent ? "No motion sensor in this Mac: Dynamics off, every key at the normal level"
            : l.sensorIdle ? "Sensor idle (no keys for \(Int(Self.sensorIdleAfter)) s) · resumes on the next key"
            : sensorHz < 100 ? "Sensor not streaming: normal level"
            : "Sensor \(Int(sensorHz.rounded())) Hz · " + (a.state.keys < Int(VelocityMapper.warmupKeys) ? "factory calibration" : "adapted to your typing"))
        let e2e = engine.latencyStats().endToEnd
        lines.append(e2e.isEmpty ? "Key → sound: no sounds yet"
            : String(format: "Key → sound: %.1f ms median, %.1f p90 (last %d)", pct(e2e, 50), pct(e2e, 90), e2e.count))
        let d = engine.deviceInfo()
        lines.append(mutedOutput.map { "Output: \($0) · muted (Bluetooth/AirPlay)" }
            ?? String(format: "Output: %@ [%@] · %d-frame buffer (%.2f ms) · device+stream %.1f ms", d.name, d.transport, Int(d.bufferFrames), d.bufferMs, d.hardwareMs))
        keyLock.lock(); let last = lastShown; keyLock.unlock()
        lines.append(last.map { s in
            String(format: "Last key: %@ → %.1f dB", s.g.map { String(format: "%.1f mg", $0 * 1000) } ?? "no sensor", s.v.gainDb)
                + (l.version == .v2 ? String(format: ", layer %.2f (0 soft · 0.5 recording · 1 hard)", s.v.layer) : "")
        } ?? "Last key: —")
        lines.append(l.version == .v1
            ? String(format: "Mapping v1 (%@): %.1f mg → −12 dB … %.1f mg → 0 dB, normal %.1f mg",
                     l.mode.rawValue, exp(a.lo) * 1000, exp(a.hi) * 1000, exp(a.normal) * 1000)
            : String(format: "Mapping v2 (%@): ≤ %.1f mg soft layer … ≥ %.1f mg hard, median %.1f mg, %d key offsets",
                     l.mode.rawValue, exp(a.lo) * 1000, exp(a.hi) * 1000, exp(a.normal) * 1000, mapper.keyOffsets.count))
        lines.append(String(format: "Adaptation: %d keys, weight %.0f %%, shift ×%.2f, span ×%.2f",
                            a.state.keys, a.state.weight * 100, exp(a.state.shift), a.state.spreadScale))
        lines.append(l.bank.map { b in
            String(format: "Pack: %d clips × 3 layers, clack %.1f ms into the clip (median), key-up %@, %d keys rotate",
                   b.clipCount, b.attackMs.median, b.keyUpSynthesized ? "synthesized" : "recorded", b.rotatingKeys)
        } ?? "Pack: loading…")
        if defaults.bool(forKey: "onsetMeasurement") { stats.addOnsets(monitor.take()) }
        if let o = stats.snapshot.onsets, let t = o.thresholds.first(where: { $0.thresholdMg == 5 }), o.keyDowns > 0 {
            lines.append(String(format: "Shock onsets (5 mg, measured): %d key-downs, %.0f %% with onset, median %.1f ms before the tap",
                                o.keyDowns, 100 * Double(t.keyDownWithOnset) / Double(o.keyDowns), OnsetStats.medianMs(t.leadVsCallbackHalfMs)))
        }
        let rec = tap.recoveries
        lines.append("Since launch: \(wakes) wake/login events, tap re-enabled \(rec.reenabled)× / recreated \(rec.reinstalled)×, sensor reopened \(sensorReopens)×, resumed from idle \(sensorResumes)×, \(outputChanges) output changes")
        return lines
    }
}
