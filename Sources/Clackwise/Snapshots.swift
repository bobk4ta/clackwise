import AppKit
import ClackwiseCore
import SwiftUI

/// `--snapshots <dir>`: renders the onboarding, the menu bar panel and every Settings tab with
/// sample data, light and dark, to <dir>/<name>-<light|dark>.png at 2×, then quits.
/// Windows are real AppKit windows (native controls, toolbar), at alpha 0 on the main screen so
/// they get Retina backing; the image comes from their layer tree, so nothing on screen is read.
enum Snapshots {
    @MainActor static func run(to dir: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.async {
            Task { @MainActor in
                // Controls only draw their active (accent) state in the active app. macOS hands
                // activation over only shortly after you used the app that ran `open` (Terminal).
                for _ in 0..<20 where !app.isActive {
                    app.activate()
                    try? await Task.sleep(for: .milliseconds(150))
                }
                if !app.isActive {
                    print("warning: not the active app (frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")): controls are drawn inactive, without accent colour. Run scripts/snapshots.sh from Terminal yourself.")
                }
                for dark in [false, true] { await renderAll(to: dir, dark: dark) }
                print("snapshots written to \(dir.path)")
                exit(0)
            }
        }
        app.run()
    }

    @MainActor private static func sampleModel() -> AppModel {
        let m = AppModel()
        let root = Bundle.main.resourceURL!.appendingPathComponent("SoundPacks")
        m.packs = SoundPackLoader.discover(in: [root]).map {
            PackItem(id: $0.id, name: $0.name, type: $0.type, color: $0.color, classic: $0.classic, synthesizedKeyUp: !$0.hasKeyUp)
        }
        m.packID = "kbsim-mxblack"
        m.tapWorking = true
        m.accessGranted = true
        m.openAtLogin = true
        m.debugLines = [
            "Sensor 803 Hz · adapted to your typing",
            "Key → sound: 16.5 ms median, 17.0 p90 (last 512)",
            "Output: MacBook Air Speakers [built-in] · 64-frame buffer (1.33 ms) · device+stream 12.8 ms",
            "Last key: 31.2 mg → −7.3 dB, layer 0.46 (0 soft · 0.5 recording · 1 hard)",
            "Mapping v2 (instant): ≤ 10.6 mg soft layer … ≥ 75.5 mg hard, median 34.6 mg, 41 key offsets",
            "Adaptation: 4210 keys, weight 100 %, shift ×1.04, span ×1.02",
            "Pack: 7 clips × 3 layers, clack 2.0 ms into the clip (median), key-up recorded, 60 keys rotate",
        ]
        m.outputs = ["MacBook Air Speakers [built-in]: 48000 Hz, buffer 64 (15–4096), device 60 + stream 556 + safety 48 frames → reported key → sound ≈ 16.2 ms"]
        return m
    }

    @MainActor private static func renderAll(to dir: URL, dark: Bool) async {
        let suffix = dark ? "dark" : "light"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!

        // Onboarding: screen 1 (access) and screen 2 (access granted, try it).
        let m = sampleModel()
        m.tapWorking = false
        m.accessGranted = false
        await renderWindow(OnboardingWindowController(model: m).window!, appearance, dir, "onboarding-1-access-\(suffix)")
        let dm = sampleModel()
        dm.tapWorking = false
        dm.accessGranted = false
        dm.accessDenied = true
        await renderWindow(OnboardingWindowController(model: dm).window!, appearance, dir, "onboarding-1-denied-\(suffix)")
        await renderWindow(OnboardingWindowController(model: sampleModel()).window!,
                           appearance, dir, "onboarding-2-try-\(suffix)")

        // Panel: normal, and with a notice (on a Classic pack, to show that group and its marks).
        await renderPanel(sampleModel(), appearance, dir, "panel-\(suffix)")
        let pm = sampleModel()
        pm.packID = "topre-purple-hybrid-pbt"
        pm.notice = .microphone
        pm.icon = .muted
        await renderPanel(pm, appearance, dir, "panel-mic-\(suffix)")

        // Sound tab on a Mac without the motion sensor.
        let ns = sampleModel()
        ns.hasSensor = false
        let nsc = SettingsWindowController(model: ns)
        nsc.select(1)
        await renderWindow(nsc.window!, appearance, dir, "settings-2-sound-nosensor-\(suffix)")

        // Settings tabs.
        let names = ["general", "sound", "about", "advanced"]
        for (i, name) in names.enumerated() {
            let c = SettingsWindowController(model: sampleModel())
            c.select(i)
            await renderWindow(c.window!, appearance, dir, "settings-\(i + 1)-\(name)-\(suffix)")
        }

        // Setup guide (floating next to macOS's UI): each step, on a desktop-like ground.
        let guide = VStack(alignment: .leading, spacing: 14) {
            ForEach([SetupGuide.Step.alert, .switchOn, .confirm, .reopen], id: \.plain) { step in
                let st = SetupGuide.State()
                let _ = { st.step = step; st.side = .right }()
                GuideCard(state: st)
            }
        }
        .padding(24)
        .background(dark ? Color(white: 0.22) : Color(white: 0.84))
        await renderView(AnyView(guide), appearance, dir, "guide-steps-\(suffix)", opaque: true)

        // Menu bar glyph states, on a menu bar–like strip.
        let states: [IconState] = [.on, .off, .muted, .secure, .needsAccess]
        let strip = HStack(spacing: 18) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                Image(nsImage: MenuBarIcon.image(s)).renderingMode(.template).foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 14).frame(height: 24)
        .background(dark ? Color(white: 0.12) : Color(white: 0.93))
        await renderView(AnyView(strip), appearance, dir, "menubar-icons-\(suffix)", opaque: true)
    }

    @MainActor private static func renderPanel(_ m: AppModel, _ appearance: NSAppearance, _ dir: URL, _ name: String) async {
        await renderView(AnyView(PanelView(model: m)), appearance, dir, name, opaque: false, material: true)
    }

    /// A SwiftUI view in a borderless window; with `material`, on the popover material with the
    /// menu bar panel's rounded corners.
    @MainActor private static func renderView(_ view: AnyView, _ appearance: NSAppearance, _ dir: URL, _ name: String,
                                               opaque: Bool, material: Bool = false) async {
        let host = NSHostingView(rootView: AnyView(view.environment(\.controlActiveState, .key)))
        let size = host.fittingSize
        let w = KeyableWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        if material {
            let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            fx.material = .popover
            fx.blendingMode = .withinWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 12
            fx.layer?.cornerCurve = .continuous
            fx.layer?.masksToBounds = true
            host.frame = fx.bounds
            host.autoresizingMask = [.width, .height]
            fx.addSubview(host)
            w.contentView = fx
        } else {
            w.contentView = host
        }
        await renderWindow(w, appearance, dir, name)
    }

    @MainActor private static func renderWindow(_ w: NSWindow, _ appearance: NSAppearance, _ dir: URL, _ name: String) async {
        w.appearance = appearance
        w.alphaValue = 0
        if let screen = NSScreen.main { w.setFrameOrigin(NSPoint(x: screen.frame.midX - w.frame.width / 2, y: screen.frame.midY - w.frame.height / 2)) }
        w.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        w.contentView?.layoutSubtreeIfNeeded()
        w.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        guard let frameView = w.contentView?.superview, let layer = frameView.layer else { w.orderOut(nil); return }
        let scale = w.backingScaleFactor
        let W = Int(frameView.bounds.width * scale), H = Int(frameView.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        if let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
        }
        w.orderOut(nil)
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
