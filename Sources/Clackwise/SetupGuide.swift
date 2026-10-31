import AppKit
import Observation
import os
import SwiftUI

/// Just-in-time help while the user is in macOS's own UI for Input Monitoring: a small floating,
/// non-activating panel next to whatever macOS shows right now, with only the current step.
/// Window owner names and bounds come from CGWindowListCopyWindowInfo, which needs no permission
/// (titles would; they aren't read). Started by onboarding's Continue, stopped when onboarding
/// continues (Clackwise active again with access, Done, or the relaunch).
final class SetupGuide {
    enum Step: Equatable {
        case alert, switchOn, confirm, reopen

        var text: AttributedString {
            switch self {
            case .alert: return try! AttributedString(markdown: "Click **Open System Settings**, not Deny")
            case .switchOn: return try! AttributedString(markdown: "Switch on **Clackwise**")
            case .confirm: return try! AttributedString(markdown: "Confirm with **Touch ID** or your password")
            case .reopen: return try! AttributedString(markdown: "Click **Quit & Reopen**")
            }
        }
        var plain: String { String(text.characters) }
    }

    @Observable final class State {
        var step: Step = .switchOn
        var side: Side = .right
    }
    enum Side { case right, left, below, none }

    /// Process names of the macOS UI involved (Tahoe): the "Keystroke Receiving" alert, the Touch ID /
    /// password sheet, the Privacy & Security pane (its "Quit & Reopen" alert), System Settings itself.
    static let alertOwners: Set<String> = ["universalAccessAuthWarn"]
    static let authOwners: Set<String> = ["LocalAuthenticationRemoteService", "coreautha", "SecurityAgent"]
    static let paneOwners: Set<String> = ["SecurityPrivacyExtension"]
    static let settingsOwners: Set<String> = ["System Settings", "System Preferences"]

    private let state = State()
    private var panel: NSPanel?
    private var timer: Timer?
    private var grantedAt: Date?
    private var lastLogged = ""
    private var lastWindows = ""
    private let log = Logger(subsystem: "io.github.bobk4ta.clackwise", category: "guide")
    /// Access state from AppController (tap delivering keys).
    var isGranted: () -> Bool = { false }

    var isRunning: Bool { timer != nil }

    /// macOS's "Keystroke Receiving" alert is on screen.
    static func alertVisible() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { alertOwners.contains($0[kCGWindowOwnerName as String] as? String ?? "") }
    }

    /// macOS's alert, Touch ID sheet or System Settings is on screen (so don't open anything else).
    static func systemUIVisible() -> Bool {
        let owners = alertOwners.union(authOwners).union(settingsOwners)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { owners.contains($0[kCGWindowOwnerName as String] as? String ?? "") }
    }

    func start() {
        guard timer == nil else { return }
        grantedAt = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        log.notice("guide started")
    }

    func stop() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
        if lastLogged != "" { log.notice("guide stopped") }
        lastLogged = ""
    }

    private struct Win { let owner: String; let frame: NSRect; let layer: Int }

    /// On-screen windows, front to back, in Cocoa coordinates.
    private func windows() -> [Win] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mainHeight = NSScreen.screens.first?.frame.maxY else { return [] }
        return list.compactMap { w in
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"], wd > 40, h > 40 else { return nil }
            return Win(owner: owner, frame: NSRect(x: x, y: mainHeight - y - h, width: wd, height: h), layer: w[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    private func tick() {
        let ws = windows()
        func first(_ owners: Set<String>) -> Win? { ws.first { owners.contains($0.owner) } }
        let granted = isGranted()
        if granted && grantedAt == nil { grantedAt = Date() }
        let involved = ws.filter { Self.alertOwners.union(Self.authOwners).union(Self.paneOwners).union(Self.settingsOwners).contains($0.owner) }
        let snapshot = involved.map { "\($0.owner) \(Int($0.frame.width))×\(Int($0.frame.height)) L\($0.layer)" }.joined(separator: ", ")
        if snapshot != lastWindows {
            lastWindows = snapshot
            log.notice("guide windows: \(snapshot.isEmpty ? "none" : snapshot, privacy: .public)")
        }
        // System Settings' largest window is the main one; a smaller one over it is a sheet (Touch ID /
        // password before the grant, Quit & Reopen after it, depending on how macOS hosts them).
        let settingsWins = ws.filter { Self.settingsOwners.contains($0.owner) }
        let settings = settingsWins.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        let sheet = settingsWins.first { w in
            guard let m = settings, w.frame != m.frame else { return false }
            return m.frame.insetBy(dx: -8, dy: -40).contains(w.frame) && w.frame.width < m.frame.width
        }
        let paneAlert = ws.first { Self.paneOwners.contains($0.owner) && $0.frame.width < 600 }
        let step: Step?, anchor: Win?
        if let a = first(Self.alertOwners) {
            (step, anchor) = (.alert, a)
        } else if let a = first(Self.authOwners) {
            (step, anchor) = (.confirm, a)
        } else if granted {
            // Quit & Reopen: its own window or a sheet if seen; otherwise point at System Settings for a
            // few seconds after access arrived (it appears right then), then step aside.
            let recent = grantedAt.map { Date().timeIntervalSince($0) < 8 } ?? false
            if let a = paneAlert ?? sheet { (step, anchor) = (.reopen, a) }
            else if recent, let s = settings { (step, anchor) = (.reopen, s) }
            else { (step, anchor) = (nil, nil) }
        } else if let a = sheet {
            (step, anchor) = (.confirm, a)
        } else if let s = settings {
            (step, anchor) = (.switchOn, s)
        } else {
            (step, anchor) = (nil, nil)
        }
        // Back in Clackwise with access: onboarding continues there.
        if granted && NSApp.isActive { stop(); return }

        let key = "\(step.map { "\($0)" } ?? "hidden") @ \(anchor?.owner ?? "-")"
        let changed = key != lastLogged
        if changed {
            lastLogged = key
            if let step { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                               userInfo: [.announcement: step.plain, .priority: NSAccessibilityPriorityLevel.high.rawValue]) }
        }
        guard let step else {
            panel?.orderOut(nil)
            if changed { log.notice("guide: \(key, privacy: .public)") }
            return
        }
        if state.step != step { withAnimation(.easeOut(duration: 0.18)) { state.step = step } }
        place(near: anchor?.frame)
        // Placement proof for the logs: window owner and frames only (no titles, no content).
        if changed, let p = panel {
            log.notice("guide: \(key, privacy: .public), anchor \(anchor.map { NSStringFromRect($0.frame) } ?? "none", privacy: .public) → panel \(NSStringFromRect(p.frame), privacy: .public) (\(String(describing: self.state.side), privacy: .public))")
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 64), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu            // above macOS's alerts and System Settings
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true     // a label, not a control: clicks go to what's underneath
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        let host = NSHostingView(rootView: GuideCard(state: state))
        host.frame = p.contentRect(forFrameRect: p.frame)
        p.contentView = host
        return p
    }

    /// Next to the anchor (right, else left, else below), on the anchor's screen; without an anchor,
    /// top right of the main screen.
    private func place(near anchor: NSRect?) {
        let p = panel ?? makePanel()
        panel = p
        let size = p.contentView?.fittingSize ?? NSSize(width: 260, height: 64)
        let gap: CGFloat = 14
        var origin: NSPoint, side: Side
        if let a = anchor, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: a.midX, y: a.midY)) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            let top = min(a.maxY - 12, v.maxY) - size.height
            if a.maxX + gap + size.width <= v.maxX {
                origin = NSPoint(x: a.maxX + gap, y: top); side = .right
            } else if a.minX - gap - size.width >= v.minX {
                origin = NSPoint(x: a.minX - gap - size.width, y: top); side = .left
            } else {
                origin = NSPoint(x: a.midX - size.width / 2, y: a.minY - gap - size.height); side = .below
            }
            origin.x = max(v.minX + 8, min(origin.x, v.maxX - size.width - 8))
            origin.y = max(v.minY + 8, min(origin.y, v.maxY - size.height - 8))
        } else {
            let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            origin = NSPoint(x: v.maxX - size.width - 16, y: v.maxY - size.height - 16); side = .none
        }
        if state.side != side { state.side = side }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        if !p.isVisible { p.orderFrontRegardless() }
    }
}

/// The card: Clackwise's icon, "Clackwise setup", the one current step; an arrow toward macOS's UI.
struct GuideCard: View {
    let state: SetupGuide.State

    var body: some View {
        HStack(spacing: 10) {
            if state.side == .right { arrow("arrow.left") }
            AppIconView().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Clackwise setup")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(state.step.text)
                    .font(.system(size: 13))
                    .id(state.step)
                    .transition(.opacity)
            }
            .frame(minWidth: 150, alignment: .leading)
            if state.side == .left { arrow("arrow.right") }
        }
        .overlay(alignment: .top) { if state.side == .below { arrow("arrow.up").offset(y: -22) } }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .fixedSize()
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.accentColor)
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
