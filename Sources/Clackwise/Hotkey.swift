import AppKit
import Carbon

/// A key + modifiers combination, stored in UserDefaults as "shortcut" = [keyCode, carbonModifiers].
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon: cmdKey, optionKey, controlKey, shiftKey

    /// ⌃⌥⌘K: free in macOS and common apps (Rectangle uses ⌃⌥K without ⌘).
    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey | cmdKey))

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        // Needs ⌘, ⌥ or ⌃ (Shift alone would swallow capital letters), except F-keys.
        guard m & UInt32(cmdKey | optionKey | controlKey) != 0 || Self.functionKeys[Int(event.keyCode)] != nil else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    var stored: [Int] { [Int(keyCode), Int(modifiers)] }
    init?(stored: Any?) {
        guard let a = stored as? [Int], a.count == 2 else { return nil }
        self.init(keyCode: UInt32(a[0]), modifiers: UInt32(a[1]))
    }

    /// "⌃⌥⌘K", in the order macOS menus use.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(Int(keyCode))
    }

    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]
    static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// The key's label on the current keyboard layout (so ⌘Z shows "Z" on QWERTZ too).
    static func keyName(_ code: Int) -> String {
        if let s = functionKeys[code] ?? specialKeys[code] { return s }
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "key \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let r = data.withUnsafeBytes { raw -> OSStatus in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        guard r == noErr, len > 0 else { return "key \(code)" }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}

/// One system-wide hot key (Carbon RegisterEventHotKey: no extra permission, works in every app).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: () -> Void = {}

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let me = Unmanaged<HotKey>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// nil unregisters. False if macOS refused (another app already owns the combination).
    @discardableResult
    func register(_ s: Shortcut?) -> Bool {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        guard let s else { return true }
        let id = EventHotKeyID(signature: OSType(0x4B53_4E44), id: 1)   // 'KSND'
        return RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}
