// Mechvibes pack model, config parsing and keycode table adapted from Clacky
// (https://github.com/jasonzh0/Clacky, MIT, © 2026 Clacky contributors):
// Clacky/Core/SoundPack.swift, SoundPackLoader.swift, KeycodeMap.swift.
// Changes: Mechvibes v2 fields (`soundup`, `<key>-up`, `{0-4}` variants), kbsim per-row samples,
// key names for the stats file, keyboard layout positions, our own pack manifest for display names,
// and PCM preprocessing in SoundBank.swift.

import Foundation
import CoreGraphics

/// A Mechvibes-compatible pack on disk (not decoded yet).
public struct SoundPack: Identifiable, Hashable {
    public let id: String          // directory name
    public let name: String
    public let directory: URL
    public let kind: Kind
    /// Key-down sounds per Mechvibes key ("30" = A) and the default for keys without one.
    /// Several entries = random variants.
    public let down: [String: [Source]]
    public let downDefault: [Source]
    public let up: [String: [Source]]
    public let upDefault: [Source]
    /// Real key-up recordings. Packs without them get a key-up synthesized from the press (SoundBank).
    public var hasKeyUp: Bool { !up.isEmpty || !upDefault.isEmpty }
    /// kbsim convention `GENERIC_R{0-4}`: one sample per keyboard row, assigned to keys by row.
    public let rowMapped: Bool
    /// From our manifest (packs.json): switch type ("linear", "tactile", "clicky", "other"), the
    /// switch's stem colour as hex for the picker chip, and Classic = the original Mechvibes packs.
    /// Packs not in the manifest (user packs): "other", no colour, not classic.
    public var type = "other"
    public var color: String?
    public var classic = false

    public enum Kind: String, Hashable { case single, multi }

    public enum Source: Hashable {
        case slice(file: URL, startMs: Double, durationMs: Double)
        case file(URL)
    }
}

/// Codable form of the Mechvibes `config.json` (v1 sprite/multi and v2 multi with key-up).
/// Reference: https://github.com/hainguyents13/mechvibes
struct MechvibesConfig: Decodable {
    let id: String?
    let name: String
    let key_define_type: String
    let sound: String?
    let soundup: String?
    let defines: [String: Define]

    enum Define: Decodable, Hashable {
        case slice(start: Double, duration: Double)
        case file(String)
        case none

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .none; return }
            if let arr = try? container.decode([Double].self) {
                self = arr.count >= 2 ? .slice(start: arr[0], duration: arr[1]) : .none
                return
            }
            if let str = try? container.decode(String.self) { self = .file(str); return }
            self = .none
        }
    }
}

public enum SoundPackLoader {
    /// Our manifest next to the packs: display names and menu order. Packs not listed are
    /// appended, named by their config.
    struct Manifest: Decodable {
        struct Entry: Decodable { let dir: String; let name: String; let type: String?; let color: String?; let classic: Bool? }
        let packs: [Entry]
    }

    public static var userPacksDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clackwise/SoundPacks", isDirectory: true)
    }

    public static func discover(in roots: [URL]) -> [SoundPack] {
        var packs: [SoundPack] = []
        var seen = Set<String>()
        for root in roots {
            let manifest = (try? Data(contentsOf: root.appendingPathComponent("packs.json")))
                .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            let entries = Dictionary((manifest?.packs ?? []).map { ($0.dir, $0) }, uniquingKeysWith: { a, _ in a })
            let order = (manifest?.packs ?? []).map(\.dir)
            let dirs = childDirectories(of: root).sorted {
                (order.firstIndex(of: $0.lastPathComponent) ?? .max, $0.lastPathComponent) <
                (order.firstIndex(of: $1.lastPathComponent) ?? .max, $1.lastPathComponent)
            }
            for d in dirs where !seen.contains(d.lastPathComponent) {
                let e = entries[d.lastPathComponent]
                guard var p = load(from: d, displayName: e?.name) else { continue }
                if let t = e?.type { p.type = t }
                p.color = e?.color
                p.classic = e?.classic ?? false
                seen.insert(p.id)
                packs.append(p)
            }
        }
        return packs
    }

    /// Parses one pack directory. nil if config.json is missing or malformed.
    public static func load(from dir: URL, displayName: String? = nil) -> SoundPack? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              let c = try? JSONDecoder().decode(MechvibesConfig.self, from: data) else { return nil }
        var down: [String: [SoundPack.Source]] = [:], up: [String: [SoundPack.Source]] = [:]
        var downDefault: [SoundPack.Source] = [], upDefault: [SoundPack.Source] = []
        var rowMapped = false
        let kind: SoundPack.Kind
        switch c.key_define_type {
        case "single":
            guard let sprite = c.sound else { return nil }
            kind = .single
            let file = dir.appendingPathComponent(sprite)
            for (k, d) in c.defines {
                guard case let .slice(s, l) = d, l > 0 else { continue }
                if k.hasSuffix("-up") { up[String(k.dropLast(3))] = [.slice(file: file, startMs: s, durationMs: l)] }
                else { down[k] = [.slice(file: file, startMs: s, durationMs: l)] }
            }
            downDefault = down["30"] ?? down.values.first ?? []
        case "multi":
            kind = .multi
            for (k, d) in c.defines {
                guard case let .file(name) = d else { continue }
                let u = dir.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: u.path) else { continue }
                if k.hasSuffix("-up") { up[String(k.dropLast(3))] = [.file(u)] } else { down[k] = [.file(u)] }
            }
            // v2: "sound" is the default press sound, "{0-4}" = random variants. kbsim's
            // "GENERIC_R{0-4}" are per row instead (R0 = F-row … R4 = bottom rows; kbsim
            // KeySimulator.js plays row-specific, pitch-adjusted samples), so those go to keys by row.
            downDefault = expand(c.sound, in: dir).map { .file($0) }
            upDefault = expand(c.soundup, in: dir).map { .file($0) }
            if let snd = c.sound, snd.contains("R{0-4}"), downDefault.count == 5 {
                rowMapped = true
                for (key, pos) in KeyboardLayout.positions where down[key] == nil {
                    down[key] = [downDefault[min(pos.row, 4)]]
                }
            }
            if downDefault.isEmpty { downDefault = down["any"] ?? down["30"] ?? down.values.first ?? [] }
        default:
            return nil
        }
        guard !down.isEmpty || !downDefault.isEmpty else { return nil }
        return SoundPack(id: dir.lastPathComponent, name: displayName ?? c.name, directory: dir, kind: kind,
                         down: down, downDefault: downDefault, up: up, upDefault: upDefault, rowMapped: rowMapped)
    }

    /// "press/GENERIC_R{0-4}.mp3" → the existing files R0…R4. Plain names pass through if they exist.
    static func expand(_ pattern: String?, in dir: URL) -> [URL] {
        guard let p = pattern else { return [] }
        var names = [p]
        if let r = p.range(of: #"\{(\d+)-(\d+)\}"#, options: .regularExpression) {
            let nums = p[r].dropFirst().dropLast().split(separator: "-").compactMap { Int($0) }
            if nums.count == 2, nums[0] <= nums[1] {
                names = (nums[0]...nums[1]).map { p.replacingCharacters(in: r, with: String($0)) }
            }
        }
        return names.map { dir.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func childDirectories(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}

/// macOS virtual key code → Mechvibes (iohook) scancode and a readable name (US layout positions).
/// Mechvibes codes from Clacky's KeycodeMap.
public enum KeycodeMap {
    public static func mechvibesKey(for code: CGKeyCode) -> String? { table[code]?.0 }
    public static func name(for code: CGKeyCode) -> String { table[code]?.1 ?? extraNames[code] ?? "key\(code)" }

    static let extraNames: [CGKeyCode: String] = [0x3F: "Fn", 0x0A: "§", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
                                                  0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20"]

    static let table: [CGKeyCode: (String, String)] = [
        0x35: ("1", "Esc"), 0x12: ("2", "1"), 0x13: ("3", "2"), 0x14: ("4", "3"), 0x15: ("5", "4"),
        0x17: ("6", "5"), 0x16: ("7", "6"), 0x1A: ("8", "7"), 0x1C: ("9", "8"), 0x19: ("10", "9"),
        0x1D: ("11", "0"), 0x1B: ("12", "-"), 0x18: ("13", "="), 0x33: ("14", "Delete"), 0x30: ("15", "Tab"),
        0x0C: ("16", "Q"), 0x0D: ("17", "W"), 0x0E: ("18", "E"), 0x0F: ("19", "R"), 0x11: ("20", "T"),
        0x10: ("21", "Y"), 0x20: ("22", "U"), 0x22: ("23", "I"), 0x1F: ("24", "O"), 0x23: ("25", "P"),
        0x21: ("26", "["), 0x1E: ("27", "]"), 0x24: ("28", "Return"), 0x3B: ("29", "LeftControl"),
        0x00: ("30", "A"), 0x01: ("31", "S"), 0x02: ("32", "D"), 0x03: ("33", "F"), 0x05: ("34", "G"),
        0x04: ("35", "H"), 0x26: ("36", "J"), 0x28: ("37", "K"), 0x25: ("38", "L"), 0x29: ("39", ";"),
        0x27: ("40", "'"), 0x32: ("41", "`"), 0x38: ("42", "LeftShift"), 0x2A: ("43", "\\"),
        0x06: ("44", "Z"), 0x07: ("45", "X"), 0x08: ("46", "C"), 0x09: ("47", "V"), 0x0B: ("48", "B"),
        0x2D: ("49", "N"), 0x2E: ("50", "M"), 0x2B: ("51", ","), 0x2F: ("52", "."), 0x2C: ("53", "/"),
        0x3C: ("54", "RightShift"), 0x43: ("55", "Keypad*"), 0x3A: ("56", "LeftOption"), 0x31: ("57", "Space"),
        0x39: ("58", "CapsLock"), 0x7A: ("59", "F1"), 0x78: ("60", "F2"), 0x63: ("61", "F3"), 0x76: ("62", "F4"),
        0x60: ("63", "F5"), 0x61: ("64", "F6"), 0x62: ("65", "F7"), 0x64: ("66", "F8"), 0x65: ("67", "F9"),
        0x6D: ("68", "F10"), 0x47: ("69", "KeypadClear"), 0x59: ("71", "Keypad7"), 0x5B: ("72", "Keypad8"),
        0x5C: ("73", "Keypad9"), 0x4E: ("74", "Keypad-"), 0x56: ("75", "Keypad4"), 0x57: ("76", "Keypad5"),
        0x58: ("77", "Keypad6"), 0x45: ("78", "Keypad+"), 0x53: ("79", "Keypad1"), 0x54: ("80", "Keypad2"),
        0x55: ("81", "Keypad3"), 0x52: ("82", "Keypad0"), 0x41: ("83", "Keypad."), 0x67: ("87", "F11"),
        0x6F: ("88", "F12"), 0x4C: ("57372", "KeypadEnter"), 0x3E: ("57373", "RightControl"),
        0x4B: ("57397", "Keypad/"), 0x3D: ("57400", "RightOption"), 0x73: ("57415", "Home"),
        0x7E: ("57416", "Up"), 0x74: ("57417", "PageUp"), 0x7B: ("57419", "Left"), 0x7C: ("57421", "Right"),
        0x77: ("57423", "End"), 0x7D: ("57424", "Down"), 0x79: ("57425", "PageDown"),
        0x75: ("57427", "ForwardDelete"), 0x37: ("3675", "LeftCommand"), 0x36: ("3676", "RightCommand"),
    ]
}

/// Approximate positions of the Mechvibes keys on a MacBook (US ANSI) keyboard: row 0 = F-row …
/// row 5 = bottom row, column in key units from the left edge. Used for kbsim's per-row samples and
/// to find neighbouring keys whose recordings can stand in as variants.
public enum KeyboardLayout {
    public static let positions: [String: (row: Int, col: Double)] = {
        var p: [String: (Int, Double)] = [:]
        func row(_ r: Int, _ keys: [(String, Double)]) {
            var x = 0.0
            for (k, w) in keys { p[k] = (r, x + w / 2); x += w }
        }
        row(0, [("1", 1)] + ["59", "60", "61", "62", "63", "64", "65", "66", "67", "68", "87", "88"].map { ($0, 1.0) })
        row(1, [("41", 1)] + (2...13).map { (String($0), 1.0) } + [("14", 1.5)])
        row(2, [("15", 1.5)] + (16...27).map { (String($0), 1.0) } + [("43", 1)])
        row(3, [("58", 1.75)] + (30...40).map { (String($0), 1.0) } + [("28", 1.75)])
        row(4, [("42", 2.25)] + (44...53).map { (String($0), 1.0) } + [("54", 1.75), ("57416", 1)])
        row(5, [("29", 1), ("56", 1), ("3675", 1.25), ("57", 5), ("3676", 1.25), ("57400", 1),
                ("57419", 1), ("57424", 1), ("57421", 1)])
        return p.mapValues { (row: $0.0, col: $0.1) }
    }()

    /// Wide or stabilized keys sound different from their neighbours: they never borrow variants.
    public static let wideKeys: Set<String> = ["14", "15", "58", "28", "42", "54", "57"]
}
