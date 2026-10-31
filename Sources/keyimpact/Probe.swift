import Foundation
import ApplicationServices
import ClackwiseCore

func runProbe(wake: Bool, seconds: Double) {
    print(permissionLine())
    print("timebase: numer=\(timebase.numer) denom=\(timebase.denom) (1 tick = \(Double(timebase.numer) / Double(timebase.denom)) ns)")
    print("accel driver before: \(accelDriverState())")

    if wake {
        for (k, r) in wakeAccelDriver() { print("  set \(k): \(ioretStr(r))") }
        print("accel driver after wake: \(accelDriverState())")
    } else {
        print("(--no-wake: not touching driver properties)")
    }

    let ring = Ring(cap: 8192)
    let acc = Accelerometer(ring: ring)
    let (r, msg) = acc.open()
    print("IOHIDDeviceOpen: \(msg)")
    guard r == kIOReturnSuccess else { exit(1) }

    var raws: [(UInt64, [UInt8])] = []
    let rawLock = NSLock()
    acc.rawHook = { p, len, ts in
        rawLock.lock()
        if raws.count < 6 { raws.append((ts, Array(UnsafeBufferPointer(start: p, count: len)))) }
        rawLock.unlock()
    }
    acc.start()
    if wake {
        // meepslap wakes again after open; keep the same order.
        for (k, r) in wakeAccelDriver() where r != kIOReturnSuccess { print("  re-wake \(k): \(ioretStr(r))") }
    }

    let t0 = mach_absolute_time()
    Thread.sleep(forTimeInterval: seconds)
    let t1 = mach_absolute_time()
    let s = ring.range(t0 &- UInt64(msToTicks(1000)), t1)
    print("reports received in ~\(seconds)s: \(ring.total)  (wrong-length: \(acc.badLength))")
    guard s.count > 10 else {
        print("NO DATA — sensor not streaming")
        print("accel driver now: \(accelDriverState())")
        exit(1)
    }
    rawLock.lock()
    for (ts, b) in raws {
        print(String(format: "  raw ts=%llu len=%d: ", ts, b.count) + b.map { String(format: "%02x", $0) }.joined(separator: " "))
    }
    rawLock.unlock()

    let span = ticksToMs(Int64(s.last!.t) - Int64(s.first!.t))
    let rate = Double(s.count - 1) / (span / 1000)
    var dts: [Double] = [], lat: [Double] = []
    var dupTs = 0
    for i in 1..<s.count {
        let d = ticksToMs(Int64(s[i].t) - Int64(s[i - 1].t))
        if d == 0 { dupTs += 1 }
        dts.append(d)
    }
    for x in s { lat.append(ticksToMs(Int64(x.arrival) - Int64(x.t))) }
    print(String(format: "sample rate (report timestamps): %.1f Hz over %.0f ms", rate, span))
    print(String(format: "report dt ms: min %.3f p10 %.3f p50 %.3f p90 %.3f max %.3f  identical-ts pairs: %d",
                 dts.min()!, pct(dts, 10), pct(dts, 50), pct(dts, 90), dts.max()!, dupTs))
    print(String(format: "delivery latency (callback time - report ts) ms: p10 %.3f p50 %.3f p90 %.3f max %.3f",
                 pct(lat, 10), pct(lat, 50), pct(lat, 90), lat.max()!))
    let mx = s.map(\.x).reduce(0, +) / Double(s.count)
    let my = s.map(\.y).reduce(0, +) / Double(s.count)
    let mz = s.map(\.z).reduce(0, +) / Double(s.count)
    print(String(format: "mean g: x %.4f y %.4f z %.4f |g| %.4f", mx, my, mz, sqrt(mx * mx + my * my + mz * mz)))
    let mags = s.map { sqrt(pow($0.x - mx, 2) + pow($0.y - my, 2) + pow($0.z - mz, 2)) }
    print(String(format: "idle dynamic |a-g| (g): p50 %.5f p90 %.5f max %.5f", pct(mags, 50), pct(mags, 90), mags.max()!))
    print("accel driver now: \(accelDriverState())")
}
