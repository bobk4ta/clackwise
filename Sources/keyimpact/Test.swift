import Foundation
import ApplicationServices
import ClackwiseCore

// MARK: - Terminal (no echo, no line buffering)

var savedTermios = termios()
var termiosSaved = false

func setRawTerminal() {
    guard isatty(STDIN_FILENO) != 0, tcgetattr(STDIN_FILENO, &savedTermios) == 0 else { return }
    termiosSaved = true
    var t = savedTermios
    t.c_lflag &= ~tcflag_t(ECHO | ICANON)
    tcsetattr(STDIN_FILENO, TCSANOW, &t)
    atexit { restoreTerminal() }
    signal(SIGINT) { _ in restoreTerminal(); print("\naborted"); exit(130) }
}

func restoreTerminal() {
    if termiosSaved { tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios) }
}

// MARK: - Key events

struct KeyEvent {
    var raw: UInt64     // CGEventGetTimestamp as delivered
    var ts: UInt64      // converted to mach_absolute_time ticks
    var recv: UInt64    // mach_absolute_time() in our tap callback
}

var eventClock: EventClock?

final class Recorder {
    enum State { case idle, waitingEnter(next: Int), recording(phase: Int), done }

    struct Phase { let name: String; let instruction: String; let keys: Int; let seconds: Double }
    let phases: [Phase] = [
        Phase(name: "floor", instruction: "Hands OFF the laptop. Don't touch anything for 3 seconds.", keys: 0, seconds: 3),
        Phase(name: "soft", instruction: "Type SOFTLY: barely press the keys, letters at a relaxed pace (~2 per second).", keys: 20, seconds: 0),
        Phase(name: "normal", instruction: "Type NORMALLY: your usual force, letters at a relaxed pace (~2 per second).", keys: 20, seconds: 0),
        Phase(name: "hard", instruction: "Type HARD: strike the keys firmly, letters at a relaxed pace (~2 per second).", keys: 20, seconds: 0),
        Phase(name: "noise", instruction: "Do NOT type. For 10 seconds tap the palm rest (both sides) and click the trackpad, firmly, varied.", keys: 0, seconds: 10),
    ]

    let ring = Ring(cap: 800 * 900)   // 15 min of history
    lazy var acc = Accelerometer(ring: ring)
    var state: State = .idle
    var events: [(kind: String, phase: Int, ev: KeyEvent)] = []
    var phaseStart: UInt64 = 0
    var phaseKeys = 0
    var sessionStart: UInt64 = 0
    var dir: URL!

    func run() {
        print(permissionLine())
        let wake = wakeAccelDriver()
        if let bad = wake.first(where: { $0.1 != kIOReturnSuccess }) { print("wake \(bad.0) failed: \(ioretStr(bad.1))") }
        let (r, msg) = acc.open()
        guard r == kIOReturnSuccess else { print("cannot open accelerometer: \(msg)"); exit(1) }
        acc.start()
        wakeAccelDriver()
        Thread.sleep(forTimeInterval: 0.5)
        guard ring.total > 100 else { print("accelerometer opened but not streaming (\(ring.total) reports)"); exit(1) }

        guard installTap() else {
            print("""

            Could not create the keyboard event tap (listen-only).
            Turn on: System Settings → Privacy & Security → Input Monitoring → your terminal app
            (Terminal / iTerm / …). Then QUIT and reopen the terminal app and run this again.
            """)
            _ = CGRequestListenEventAccess()
            exit(1)
        }

        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("data/\(df.string(from: Date()))")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        setRawTerminal()
        sessionStart = mach_absolute_time()
        print("""

        Keystroke impact test — \(phases.count) phases. Nothing you type is shown or saved (only timestamps).
        Keep the MacBook on a table, lid open, as you normally type. Ctrl-C aborts.
        """)
        prompt(0)
        startStdinReader()
        RunLoop.main.run()
    }

    // MARK: tap

    func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, ctx in
            let rec = Unmanaged<Recorder>.fromOpaque(ctx!).takeUnretainedValue()
            rec.onEvent(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    var tap: CFMachPort?

    func onEvent(_ type: CGEventType, _ e: CGEvent) {
        let recv = mach_absolute_time()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown, e.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        let raw = e.timestamp
        let (clk, ts) = classifyEventClock(raw: raw)
        if eventClock == nil { eventClock = clk }
        let ev = KeyEvent(raw: raw, ts: ts, recv: recv)
        guard case .recording(let p) = state else { return }
        // Ignore the Enter that started the phase.
        guard ticksToMs(Int64(ts) - Int64(phaseStart)) > 300 else { return }
        if phases[p].keys > 0 {
            events.append(("key", p, ev))
            phaseKeys += 1
            print("\r  \(phases[p].name): \(phaseKeys)/\(phases[p].keys)   ", terminator: "")
            fflush(stdout)
            if phaseKeys == phases[p].keys {
                state = .done   // stop counting while the post-window fills
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.endPhase(p) }
            }
        } else {
            events.append(("stray", p, ev))
        }
    }

    // MARK: phases

    func prompt(_ p: Int) {
        let ph = phases[p]
        print("\n── Phase \(p + 1)/\(phases.count): \(ph.name.uppercased()) ──")
        print(ph.instruction)
        print("Press Enter to start.", terminator: "")
        fflush(stdout)
        state = .waitingEnter(next: p)
    }

    func startStdinReader() {
        Thread {
            var c: UInt8 = 0
            while read(STDIN_FILENO, &c, 1) == 1 {
                if c == 10 || c == 13 {
                    DispatchQueue.main.async {
                        if case .waitingEnter(let p) = self.state { self.beginPhase(p) }
                    }
                }
            }
        }.start()
    }

    func beginPhase(_ p: Int) {
        let ph = phases[p]
        print("")
        if ph.keys == 0 {
            // Give the hands time to leave the keyboard / reach the palm rest.
            print("  starting in 2 s…", terminator: ""); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.phaseStart = mach_absolute_time()
                self.mark("phase_start", p)
                self.state = .recording(phase: p)
                print("\r  RECORDING \(Int(ph.seconds)) s…   ", terminator: ""); fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + ph.seconds) { self.endPhase(p) }
            }
        } else {
            phaseStart = mach_absolute_time()
            phaseKeys = 0
            mark("phase_start", p)
            state = .recording(phase: p)
            print("  \(ph.name): 0/\(ph.keys)", terminator: ""); fflush(stdout)
        }
    }

    func mark(_ kind: String, _ p: Int) {
        let now = mach_absolute_time()
        events.append((kind, p, KeyEvent(raw: now, ts: now, recv: now)))
    }

    func endPhase(_ p: Int) {
        mark("phase_end", p)
        print("\r  \(phases[p].name): done.            ")
        if p + 1 < phases.count { prompt(p + 1) } else { finish() }
    }

    func finish() {
        state = .done
        restoreTerminal()
        print("\nSaving data…")
        writeData()
        print("Saved to \(dir.path)\n")
        analyze(dir: dir)
        exit(0)
    }

    func writeData() {
        let samples = ring.range(sessionStart &- UInt64(msToTicks(1000)), mach_absolute_time())
        var s = "t_ticks,arrival_ticks,x,y,z\n"
        s.reserveCapacity(samples.count * 64)
        for x in samples { s += "\(x.t),\(x.arrival),\(x.x),\(x.y),\(x.z)\n" }
        try! s.write(to: dir.appendingPathComponent("samples.csv"), atomically: true, encoding: .utf8)

        var e = "kind,phase,phase_name,raw_ts,ts_ticks,recv_ticks\n"
        for x in events { e += "\(x.kind),\(x.phase),\(phases[x.phase].name),\(x.ev.raw),\(x.ev.ts),\(x.ev.recv)\n" }
        try! e.write(to: dir.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8)

        let meta = """
        event_clock=\(eventClock?.rawValue ?? "unknown")
        timebase=\(timebase.numer)/\(timebase.denom)
        samples=\(samples.count)
        """
        try! meta.write(to: dir.appendingPathComponent("meta.txt"), atomically: true, encoding: .utf8)

        let latest = dir.deletingLastPathComponent().appendingPathComponent("latest")
        try? FileManager.default.removeItem(at: latest)
        try? FileManager.default.createSymbolicLink(atPath: latest.path, withDestinationPath: dir.lastPathComponent)

        // Files created under sudo should still belong to the user.
        if geteuid() == 0, let u = ProcessInfo.processInfo.environment["SUDO_UID"].flatMap(UInt32.init),
           let g = ProcessInfo.processInfo.environment["SUDO_GID"].flatMap(UInt32.init) {
            for p in [dir.deletingLastPathComponent().path, dir.path] + ["samples.csv", "events.csv", "meta.txt"].map({ dir.appendingPathComponent($0).path }) {
                chown(p, u, g)
            }
        }
    }
}

func runGuidedTest() {
    Recorder().run()
}
