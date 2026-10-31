import CoreAudio
import Foundation

/// Is another process recording from a microphone right now? Read-only CoreAudio properties, no
/// permission needed, nothing is captured. macOS 14.2+: per-process `IsRunningInput` (precise, and
/// our own output on a headset can't count). Earlier: any input-only device running somewhere.
public enum MicActivity {
    public static func inUse() -> Bool {
        if #available(macOS 14.2, *) { return processRunningInput() }
        return inputOnlyDeviceRunning()
    }

    @available(macOS 14.2, *)
    private static func processRunningInput() -> Bool {
        let me = getpid()
        for p in objects(kAudioHardwarePropertyProcessObjectList) {
            guard read(p, kAudioProcessPropertyIsRunningInput, UInt32.self) == 1 else { continue }
            if read(p, kAudioProcessPropertyPID, pid_t.self) != me { return true }
        }
        return false
    }

    private static func inputOnlyDeviceRunning() -> Bool {
        objects(kAudioHardwarePropertyDevices).contains { d in
            streams(d, kAudioObjectPropertyScopeInput) > 0 && streams(d, kAudioObjectPropertyScopeOutput) == 0
                && read(d, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32.self) == 1
        }
    }

    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func streams(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(d, &addr, 0, nil, &size) == noErr ? Int(size) / MemoryLayout<AudioStreamID>.size : 0
    }

    private static func read<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _: T.Type) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let p = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { p.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, p) == noErr else { return nil }
        return p.load(as: T.self)
    }
}
