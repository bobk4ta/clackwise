import Foundation
import IOKit
import IOKit.hid

// MARK: - Ring buffer

public struct Sample {
    public var t: UInt64        // HID report timestamp (mach ticks)
    public var arrival: UInt64  // mach_absolute_time() when our callback ran
    public var x: Double, y: Double, z: Double  // g
    public init(t: UInt64, arrival: UInt64, x: Double, y: Double, z: Double) {
        self.t = t; self.arrival = arrival; self.x = x; self.y = y; self.z = z
    }
}

public final class Ring {
    private var buf: [Sample]
    private var head = 0
    public private(set) var total = 0
    private let lock = NSLock()
    public let cap: Int

    public init(cap: Int) {
        self.cap = cap
        buf = Array(repeating: Sample(t: 0, arrival: 0, x: 0, y: 0, z: 0), count: cap)
    }

    public func append(_ s: Sample) {
        lock.lock()
        buf[head] = s
        head = (head + 1) % cap
        total += 1
        lock.unlock()
    }

    /// Samples with t0 <= t <= t1, oldest first.
    public func range(_ t0: UInt64, _ t1: UInt64) -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        let n = min(total, cap)
        var out: [Sample] = []
        out.reserveCapacity(512)
        for i in 0..<n {
            let s = buf[(head - n + i + cap) % cap]
            if s.t >= t0 && s.t <= t1 { out.append(s) }
        }
        return out
    }

    /// Replaces `out` with the samples with t >= t0, oldest first. Walks back from the newest
    /// sample, so the cost depends on the window, not on the ring size.
    public func recent(since t0: UInt64, into out: inout [Sample]) {
        out.removeAll(keepingCapacity: true)
        lock.lock(); defer { lock.unlock() }
        let n = min(total, cap)
        var k = 0
        while k < n, buf[(head - 1 - k + cap) % cap].t >= t0 { k += 1 }
        for i in stride(from: k - 1, through: 0, by: -1) { out.append(buf[(head - 1 - i + cap) % cap]) }
    }

    public func latest() -> Sample? {
        lock.lock(); defer { lock.unlock() }
        return total == 0 ? nil : buf[(head - 1 + cap) % cap]
    }
}

// MARK: - Sensor

public let PAGE_VENDOR = 0xFF00
public let USAGE_ACCEL = 3

public func cfNum32(_ v: Int32) -> CFNumber {
    var v = v
    return CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v)!
}

public func ioretStr(_ r: kern_return_t) -> String {
    switch r {
    case kIOReturnSuccess: return "OK"
    case kIOReturnNotPrivileged: return "kIOReturnNotPrivileged (0xe00002c1)"
    case kIOReturnNotPermitted: return "kIOReturnNotPermitted (0xe00002e2)"
    case kIOReturnExclusiveAccess: return "kIOReturnExclusiveAccess (0xe00002c5)"
    case kIOReturnUnsupported: return "kIOReturnUnsupported (0xe00002c7)"
    case kIOReturnBadArgument: return "kIOReturnBadArgument (0xe00002c2)"
    default: return String(format: "0x%08x", UInt32(bitPattern: r))
    }
}

public func forEachService(_ cls: String, _ body: (io_service_t, [String: Any]) -> Bool) {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(it) }
    var s = IOIteratorNext(it)
    while s != 0 {
        var props: Unmanaged<CFMutableDictionary>?
        IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0)
        let d = (props?.takeRetainedValue() as? [String: Any]) ?? [:]
        let keep = body(s, d)
        if !keep { IOObjectRelease(s) }
        s = IOIteratorNext(it)
    }
}

/// Whether this Mac has the motion sensor at all. M1 MacBook Air, 13" M1 MacBook Pro, Intel and desktop
/// Macs have no accelerometer on the SPU, so there is nothing to open and Dynamics has no input.
public enum SensorSupport {
    /// `devices` = properties of the AppleSPUHIDDevice registry entries.
    public static func hasAccelerometer(devices: [[String: Any]]) -> Bool {
        devices.contains { $0["PrimaryUsagePage"] as? Int == PAGE_VENDOR && $0["PrimaryUsage"] as? Int == USAGE_ACCEL }
    }

    /// Reads the registry; touches nothing.
    public static func detect() -> Bool {
        var devices: [[String: Any]] = []
        forEachService("AppleSPUHIDDevice") { _, d in devices.append(d); return false }
        return hasAccelerometer(devices: devices)
    }
}

/// Reads the reporting-related properties of the accel AppleSPUHIDDriver.
public func accelDriverState() -> String {
    var out = "not found"
    forEachService("AppleSPUHIDDriver") { _, d in
        if d["PrimaryUsagePage"] as? Int == PAGE_VENDOR && d["PrimaryUsage"] as? Int == USAGE_ACCEL {
            let keys = ["SensorPropertyReportingState", "SensorPropertyPowerState", "ReportInterval"]
            out = keys.map { "\($0)=\(d[$0].map { "\($0)" } ?? "nil")" }.joined(separator: " ")
        }
        return false
    }
    return out
}

/// The commands that start the accelerometer. Each one is a CFNumber (SInt32) set on the driver service
/// with IORegistryEntrySetCFProperty; they act as commands and are never stored as state.
enum SPUCommand: String {
    case reporting = "SensorPropertyReportingState"
    case power = "SensorPropertyPowerState"
    case interval = "ReportInterval"

    /// What a wake sends: reporting on, power on, then the report interval in µs.
    static func wake(intervalUs: Int32) -> [(SPUCommand, Int32)] {
        [(.reporting, 1), (.power, 1), (.interval, intervalUs)]
    }

    func send(_ value: Int32, to service: io_service_t) -> kern_return_t {
        IORegistryEntrySetCFProperty(service, rawValue as CFString, cfNum32(value))
    }
}

/// Wakes the accelerometer's AppleSPUHIDDriver (or every SPU driver with `allDrivers`).
/// Returns the kern_return_t of each command sent to the accelerometer's driver.
@discardableResult
public func wakeAccelDriver(intervalUs: Int32 = 1000, allDrivers: Bool = false) -> [(String, kern_return_t)] {
    var results: [(String, kern_return_t)] = []
    forEachService("AppleSPUHIDDriver") { service, props in
        let isAccel = props["PrimaryUsagePage"] as? Int == PAGE_VENDOR && props["PrimaryUsage"] as? Int == USAGE_ACCEL
        guard isAccel || allDrivers else { return false }
        let codes = SPUCommand.wake(intervalUs: intervalUs).map { ($0.rawValue, $0.send($1, to: service)) }
        if isAccel { results += codes }
        return false
    }
    return results
}

public final class Accelerometer {
    public let ring: Ring
    public private(set) var device: IOHIDDevice?
    private let reportBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    public var rawHook: ((UnsafePointer<UInt8>, Int, UInt64) -> Void)?
    /// Called on the sensor thread after each sample is in the ring. Set before `start()`.
    public var sampleHook: ((Sample) -> Void)?
    public private(set) var badLength = 0
    private var runLoop: CFRunLoop?
    private var stopped = false

    public init(ring: Ring) { self.ring = ring }
    // The HID thread holds self until it has closed the device, so no callback can follow.
    deinit { reportBuf.deallocate() }

    /// Opens the accel IOHIDDevice. Returns the IOReturn of IOHIDDeviceOpen (or an error string).
    public func open() -> (IOReturn, String) {
        var svc: io_service_t = 0
        forEachService("AppleSPUHIDDevice") { s, d in
            if svc == 0 && d["PrimaryUsagePage"] as? Int == PAGE_VENDOR && d["PrimaryUsage"] as? Int == USAGE_ACCEL {
                svc = s
                return true
            }
            return false
        }
        guard svc != 0 else { return (kIOReturnNotFound, "no AppleSPUHIDDevice with page 0xFF00 usage 3") }
        defer { IOObjectRelease(svc) }
        guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, svc) else { return (kIOReturnError, "IOHIDDeviceCreate returned nil") }
        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        if r == kIOReturnSuccess { device = dev }
        return (r, ioretStr(r))
    }

    /// Starts a dedicated thread servicing the HID run loop. The thread keeps this object alive
    /// until `close()`.
    public func start() {
        guard let dev = device else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(dev, reportBuf, 4096, { ctx, _, _, _, _, report, len, ts in
            let me = Unmanaged<Accelerometer>.fromOpaque(ctx!).takeUnretainedValue()
            me.handle(report, len, ts)
        }, ctx)
        let th = Thread { [self] in
            let rl = CFRunLoopGetCurrent()!
            runLoop = rl
            IOHIDDeviceScheduleWithRunLoop(dev, rl, CFRunLoopMode.defaultMode.rawValue)
            while !stopped { CFRunLoopRunInMode(.defaultMode, 1.0, false) }
            IOHIDDeviceUnscheduleFromRunLoop(dev, rl, CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        th.qualityOfService = .userInteractive
        th.name = "accel"
        th.start()
    }

    /// Stops the HID thread and closes the device (asynchronously, on that thread).
    public func close() {
        stopped = true
        if let rl = runLoop { CFRunLoopStop(rl) }
    }

    private func handle(_ r: UnsafePointer<UInt8>, _ len: Int, _ ts: UInt64) {
        let now = mach_absolute_time()
        rawHook?(r, len, ts)
        guard len == 22 else { badLength += 1; return }
        @inline(__always) func i32(_ o: Int) -> Int32 {
            Int32(bitPattern: UInt32(r[o]) | UInt32(r[o + 1]) << 8 | UInt32(r[o + 2]) << 16 | UInt32(r[o + 3]) << 24)
        }
        let sample = Sample(t: ts, arrival: now,
                            x: Double(i32(6)) / 65536, y: Double(i32(10)) / 65536, z: Double(i32(14)) / 65536)
        ring.append(sample)
        sampleHook?(sample)
    }
}
