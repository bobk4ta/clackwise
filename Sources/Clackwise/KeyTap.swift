import Foundation
import CoreGraphics
import ApplicationServices
import os

private let tapLog = Logger(subsystem: "io.github.bobk4ta.clackwise", category: "tap")

/// Listen-only session event tap (by default keyDown / keyUp / flagsChanged) on its own
/// high-priority thread. Delivers (type, event, receive time); never modifies or swallows events.
final class KeyTap {
    typealias Handler = (CGEventType, CGEvent, UInt64) -> Void
    static let keys: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
    /// Mouse / trackpad buttons (onset measurement only).
    static let buttons: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
    private let handler: Handler
    private let types: [CGEventType]
    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var counterLock = os_unfair_lock()
    private var reenables = 0, reinstalls = 0

    init(types: [CGEventType] = KeyTap.keys, handler: @escaping Handler) { self.types = types; self.handler = handler }

    var isInstalled: Bool { tap != nil }
    /// Times macOS disabled the tap (timeout / user input, or found disabled) and it was re-enabled,
    /// and times it had to be recreated because its port died.
    var recoveries: (reenabled: Int, reinstalled: Int) {
        os_unfair_lock_lock(&counterLock); defer { os_unfair_lock_unlock(&counterLock) }
        return (reenables, reinstalls)
    }
    private func countReenable() { os_unfair_lock_lock(&counterLock); reenables += 1; os_unfair_lock_unlock(&counterLock) }

    /// Returns false when the tap can't be created (no Input Monitoring permission).
    func install() -> Bool {
        if tap != nil { return true }
        let mask = types.reduce(0) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, ctx in
            let recv = mach_absolute_time()
            let me = Unmanaged<KeyTap>.fromOpaque(ctx!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true); me.countReenable() }
                tapLog.notice("tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public): re-enabled")
            } else {
                me.handler(type, event, recv)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        // Not enabled here: a new tap comes back enabled only if macOS allows it, which is what
        // isWorking reports. Enabling it before the thread runs made a tap created while macOS's
        // permission alert was still up read "enabled" (onboarding test 3).
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        let th = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.name = "keytap"
        th.qualityOfService = .userInteractive
        thread = th
        th.start()
        return true
    }

    /// Health check (main thread, every few seconds and after wake / login): recreate the tap if its
    /// port died or it can't be re-enabled, re-enable it if macOS left it disabled. False = no
    /// working tap (Input Monitoring off: macOS may create the tap but keep it disabled).
    @discardableResult
    func ensureAlive() -> Bool {
        guard let t = tap else { return install() && isWorking }
        if CFMachPortIsValid(t), CGEvent.tapIsEnabled(tap: t) { reportedDead = false; return true }
        if CFMachPortIsValid(t) {
            CGEvent.tapEnable(tap: t, enable: true)
            if CGEvent.tapIsEnabled(tap: t) {
                countReenable()
                tapLog.notice("tap found disabled: re-enabled")
                return true
            }
        }
        // Dead port, or disabled for good: start over (also picks up a permission granted later).
        CFMachPortInvalidate(t)
        if let rl = runLoop { CFRunLoopStop(rl) }
        tap = nil; runLoop = nil; thread = nil
        let ok = install() && isWorking
        if ok {
            os_unfair_lock_lock(&counterLock); reinstalls += 1; os_unfair_lock_unlock(&counterLock)
            tapLog.notice("tap recreated")
        } else if !reportedDead {
            reportedDead = true
            tapLog.notice("tap stays disabled (Input Monitoring off?)")
        }
        return ok
    }
    private var reportedDead = false

    /// Created and enabled: events are being delivered.
    var isWorking: Bool { tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false }
}

/// Which modifier a flagsChanged keycode is, and whether it is down now (device-dependent bits,
/// so left and right are told apart). Caps Lock toggles: every change counts as a press.
enum Modifier {
    static let deviceMasks: [CGKeyCode: UInt64] = [
        0x38: 0x0000_0002, 0x3C: 0x0000_0004,   // shift L/R
        0x3B: 0x0000_0001, 0x3E: 0x0000_2000,   // control L/R
        0x3A: 0x0000_0020, 0x3D: 0x0000_0040,   // option L/R
        0x37: 0x0000_0008, 0x36: 0x0000_0010,   // command L/R
    ]
    static let capsLock: CGKeyCode = 0x39, fn: CGKeyCode = 0x3F

    /// nil = not a modifier we track.
    static func isDown(code: CGKeyCode, flags: CGEventFlags) -> Bool? {
        if let m = deviceMasks[code] { return flags.rawValue & m != 0 }
        if code == fn { return flags.contains(.maskSecondaryFn) }
        return nil
    }
}
