import Observation
import SwiftUI

/// What the UI shows. AppController writes it (main thread); views read it and call `actions`.
/// Snapshots fill it with sample data and leave `actions` nil.
@Observable final class AppModel {
    weak var actions: AppActions?

    var enabled = true
    var volume = 0.8
    var packs: [PackItem] = []
    var packID: String?
    var loadingPackID: String?
    /// Why sound is muted or paused while Clackwise is on; nil = playing normally.
    var notice: Notice?
    var icon: IconState = .on

    // Permission (onboarding and the panel's notice).
    var accessGranted = false   // CGPreflightListenEventAccess
    var tapWorking = false
    /// Granted in System Settings, but the tap still doesn't receive events: macOS wants a relaunch.
    var needsRelaunch = false
    /// The user answered macOS's "Keystroke Receiving" alert with Deny: macOS won't ask again, so Input Monitoring has to be switched on by hand.
    var accessDenied = false

    // General
    var openAtLogin = false
    var loginNeedsApproval = false
    var allowWireless = false
    var pauseForMic = true
    var shortcut: Shortcut? = .standard
    var shortcutTaken = false

    // Sound
    /// False on Macs without the motion sensor: Dynamics is disabled.
    var hasSensor = true
    var strength = 1.0
    var keyUp = true
    var variation = true
    var trim = true

    // Advanced
    var version = "v2"
    var mode = "instant"
    var onsetMeasurement = false
    var debugLines: [String] = []
    var outputs: [String] = []

    var currentPack: PackItem? { packs.first { $0.id == packID } }

    /// Binding that writes through an action (the controller then updates the model).
    func bind<T>(_ key: KeyPath<AppModel, T>, _ set: @escaping (AppActions, T) -> Void) -> Binding<T> {
        Binding(get: { self[keyPath: key] }, set: { v in if let a = self.actions { set(a, v) } })
    }
}

protocol AppActions: AnyObject {
    func setEnabled(_ on: Bool)
    func setVolume(_ v: Double)
    func pickPack(_ id: String)
    func setOpenAtLogin(_ on: Bool)
    func setAllowWireless(_ on: Bool)
    func setPauseForMic(_ on: Bool)
    func setShortcut(_ s: Shortcut?)
    func setRecordingShortcut(_ recording: Bool)
    func setStrength(_ v: Double)
    func setKeyUp(_ on: Bool)
    func setVariation(_ on: Bool)
    func setTrim(_ on: Bool)
    func setVersion(_ v: String)
    func setMode(_ m: String)
    func setOnsetMeasurement(_ on: Bool)
    func recalibrate()
    func showStatsFile()
    func requestAccess()
    func showInputMonitoring()
    func relaunch()
    func showSettings()
    func showOnboarding()
    func finishOnboarding()
    func refresh()
}

enum IconState { case on, off, muted, secure, needsAccess }

enum Notice: Equatable {
    case needsAccess, wireless(String), secureInput, microphone, audio(String)

    var symbol: String {
        switch self {
        case .needsAccess, .audio: return "exclamationmark.triangle.fill"
        case .wireless: return "speaker.slash.fill"
        case .secureInput: return "lock.fill"
        case .microphone: return "mic.fill"
        }
    }
    var title: String {
        switch self {
        case .needsAccess: return "Clackwise can’t hear your keys"
        case .wireless(let name): return "Muted on \(name)"
        case .secureInput: return "Paused for a password field"
        case .microphone: return "Paused while the microphone is in use"
        case .audio: return "Sound output unavailable"
        }
    }
    var detail: String {
        switch self {
        case .needsAccess: return "Allow Input Monitoring for Clackwise in System Settings."
        case .wireless: return "Bluetooth and AirPlay add 100 ms or more of delay. You can allow them in Settings."
        case .secureInput: return "macOS hides typing from all apps while secure input is on."
        case .microphone: return "Sounds come back when the call or recording ends."
        case .audio(let e): return e
        }
    }
}

struct PackItem: Identifiable, Hashable {
    let id: String
    let name: String        // "Cherry MX Black — deep"
    let type: String        // linear, tactile, clicky, other
    let color: String?     // stem colour, hex
    let classic: Bool
    let synthesizedKeyUp: Bool

    var switchName: String { name.components(separatedBy: " — ").first ?? name }
    var character: String? { name.components(separatedBy: " — ").dropFirst().first }

    /// Picker sections: kbsim recordings by switch type, then the original Mechvibes packs.
    static func groups(_ packs: [PackItem]) -> [(title: String, packs: [PackItem])] {
        let modern = packs.filter { !$0.classic }
        var out = [("Linear", "linear"), ("Tactile", "tactile"), ("Clicky", "clicky"), ("Other", "other")].map { t in
            (title: t.0, packs: modern.filter { ($0.type == t.1) || (t.1 == "other" && !["linear", "tactile", "clicky"].contains($0.type)) })
        }
        out.append((title: "Classic", packs: packs.filter(\.classic)))
        return out.filter { !$0.packs.isEmpty }
    }
}

extension NSColor {
    convenience init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init?(hex: String?) {
        guard let c = NSColor(hex: hex) else { return nil }
        self.init(nsColor: c)
    }
}
