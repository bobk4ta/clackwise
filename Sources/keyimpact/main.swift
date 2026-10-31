import Foundation
import ClackwiseCore
import ApplicationServices
import IOKit

setvbuf(stdout, nil, _IOLBF, 0)

func usage() -> Never {
    print("""
    usage:
      keyimpact status              show sensor driver state + permission status (touches nothing)
      keyimpact probe [--no-wake] [--seconds N]
                                    try to open + stream the accelerometer, report rate/timestamps
      keyimpact test                guided soft/normal/hard keystroke test (saves to ./data/<session>)
      keyimpact analyze <dir>       re-run the summary on a saved session
      keyimpact replay [dir]        replay a session through the app's detector + velocity mapping
      keyimpact packs [--wav dir]   load the bundled packs like the app, report trim/loudness/gain
      keyimpact latency [-n N] [--buffer frames] [--silent]   audio engine latency test
      keyimpact selfshake [-n N] [--volume v]
                                    how much Clackwise's own playback (app pack + volume) shows up in the sensor
      keyimpact onsets [stats.json] shock-onset analysis (early trigger viability) from the app's counters
      keyimpact keyguess            early trigger: how different a wrong key guess sounds in the first ms (row packs)
      keyimpact devices             output devices and their reported latency
      keyimpact idlecost [--seconds N]  CPU of the sensor stream and the silent audio engine (battery)
      keyimpact selftest            packs, mixer DSP and mapping checks (no permissions, no audio device)
      keyimpact calibrate [dir] [--stats stats.json] [--out file]
                                    derive the factory calibration (Resources/calibration.json): v1 from a
                                    lab session dir, v2 from real-use stats (keeps the other part as is)
      keyimpact off                 try to put the accelerometer back to sleep
    """)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }

func permissionLine() -> String {
    "uid=\(getuid()) euid=\(geteuid())  InputMonitoring(CGPreflightListenEventAccess)=\(CGPreflightListenEventAccess())  Accessibility(AXIsProcessTrusted)=\(AXIsProcessTrusted())"
}

switch cmd {
case "status":
    print(permissionLine())
    print("accel driver: \(accelDriverState())")

case "probe":
    let noWake = args.contains("--no-wake")
    var seconds = 3.0
    if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let s = Double(args[i + 1]) { seconds = s }
    runProbe(wake: !noWake, seconds: seconds)

case "off":
    // Undo the wake: ask the driver to stop reporting / power down.
    var res: [(String, kern_return_t)] = []
    forEachService("AppleSPUHIDDriver") { s, d in
        if d["PrimaryUsagePage"] as? Int == PAGE_VENDOR && d["PrimaryUsage"] as? Int == USAGE_ACCEL {
            for k in ["SensorPropertyReportingState", "SensorPropertyPowerState"] {
                res.append((k, IORegistryEntrySetCFProperty(s, k as CFString, cfNum32(0))))
            }
        }
        return false
    }
    for (k, r) in res { print("set \(k)=0: \(ioretStr(r))") }

case "test":
    runGuidedTest()

case "tapcheck":
    // Only checks that a listen-only keyDown tap can be created (no events read).
    let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                callback: { _, _, e, _ in Unmanaged.passUnretained(e) }, userInfo: nil)
    print(permissionLine())
    print("listen-only keyDown tap: \(tap != nil ? "created OK" : "FAILED")")

case "replay":
    let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "data/latest")
    replay(dir: dir)
    replayMapping(dir: dir, calibration: Calibration.load(URL(fileURLWithPath: "Resources/calibration.json")) ?? .builtIn)

case "calibrate":
    let stats = args.firstIndex(of: "--stats").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    let dir = args.count > 1 && !args[1].hasPrefix("-") ? URL(fileURLWithPath: args[1]) : (stats == nil ? URL(fileURLWithPath: "data/latest") : nil)
    let out = args.firstIndex(of: "--out").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    calibrate(dir: dir, stats: stats, base: URL(fileURLWithPath: "Resources/calibration.json"), out: out)

case "packs":
    packsReport(wavDir: args.firstIndex(of: "--wav").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil })

case "latency":
    var n = 60, frames: UInt32 = 64
    if let i = args.firstIndex(of: "-n"), i + 1 < args.count, let v = Int(args[i + 1]) { n = v }
    if let i = args.firstIndex(of: "--buffer"), i + 1 < args.count, let v = UInt32(args[i + 1]) { frames = v }
    latencyTest(n: n, bufferFrames: frames, silent: args.contains("--silent"))

case "selfshake":
    var n = 80
    if let i = args.firstIndex(of: "-n"), i + 1 < args.count, let v = Int(args[i + 1]) { n = v }
    let vol = args.firstIndex(of: "--volume").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
    selfShake(trials: min(n, 250), volume: vol)

case "onsets":
    onsetReport(stats: args.count > 1 ? URL(fileURLWithPath: args[1]) : Stats.directory.appendingPathComponent("stats.json"))

case "keyguess":
    keyGuessReport()

case "devices":
    listOutputDevices()

case "idlecost":
    var secs = 15.0
    if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let v = Double(args[i + 1]) { secs = v }
    idleCost(seconds: secs)

case "selftest":
    exit(selfTest() ? 0 : 1)

case "analyze":
    guard args.count > 1 else { usage() }
    analyze(dir: URL(fileURLWithPath: args[1]))

default:
    usage()
}
