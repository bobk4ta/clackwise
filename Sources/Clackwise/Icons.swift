import AppKit
import SwiftUI

/// Menu bar glyph: a keycap seen slightly from the front (top face + taller front skirt), as a
/// template image. on = filled face; off = hollow, dimmed; muted = slashed; secure input = lock in
/// the face; no Input Monitoring = "!" in the face.
enum MenuBarIcon {
    static func image(_ state: IconState) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            draw(state)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = switch state {
        case .on: "Clackwise"
        case .off: "Clackwise, off"
        case .muted: "Clackwise, muted"
        case .secure: "Clackwise, paused for secure input"
        case .needsAccess: "Clackwise, needs Input Monitoring"
        }
        return img
    }

    private static let body = NSRect(x: 1.25, y: 2.75, width: 15.5, height: 12.5)
    private static let face = NSRect(x: 3.95, y: 4.15, width: 10.1, height: 6.7)

    private static func draw(_ state: IconState) {
        let alpha: CGFloat = state == .off ? 0.45 : 1
        NSColor.black.withAlphaComponent(alpha).set()
        let outer = NSBezierPath(roundedRect: body, xRadius: 3.4, yRadius: 3.4)
        outer.lineWidth = 1.4
        outer.stroke()
        let f = NSBezierPath(roundedRect: face, xRadius: 1.9, yRadius: 1.9)
        if state == .off {
            f.lineWidth = 1.1
            f.stroke()
        } else {
            f.fill()
        }
        switch state {
        case .muted:
            // Knock out a wide band, then draw the slash: legible on any menu bar.
            let a = NSPoint(x: 2.2, y: 1.8), b = NSPoint(x: 15.8, y: 16.2)
            let gap = NSBezierPath(); gap.move(to: a); gap.line(to: b); gap.lineWidth = 3.6; gap.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .clear
            gap.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let s = NSBezierPath(); s.move(to: a); s.line(to: b); s.lineWidth = 1.4; s.lineCapStyle = .round
            s.stroke()
        case .secure:
            knockout("lock.fill", pointSize: 5.6)
        case .needsAccess:
            knockout("exclamationmark", pointSize: 5.8)
        case .on, .off:
            break
        }
    }

    private static func knockout(_ symbol: String, pointSize: CGFloat) {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .black)
        guard let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = sym.size
        let r = NSRect(x: face.midX - s.width / 2, y: face.midY - s.height / 2, width: s.width, height: s.height)
        sym.draw(in: r, from: .zero, operation: .destinationOut, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// The app icon, drawn on Apple's 1024 grid (824 body, continuous corners). Rendered to an
/// .iconset by `Clackwise --make-icon <dir>` at build time; also shown in About and onboarding.
struct AppIconView: View {
    var body: some View {
        GeometryReader { g in
            let u = g.size.width / 1024
            ZStack {
                RoundedRectangle(cornerRadius: 185 * u, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "#5B6A85")!, Color(hex: "#2A3142")!], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 185 * u, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom), lineWidth: 3 * u)
                    )
                    .frame(width: 824 * u, height: 824 * u)
                Keycap(u: u)
                    .shadow(color: .black.opacity(0.35), radius: 34 * u, y: 26 * u)
                    .offset(y: -6 * u)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private struct Keycap: View {
        let u: CGFloat
        var body: some View {
            ZStack(alignment: .top) {
                // Skirt: the cap's sides, darker toward the bottom.
                RoundedRectangle(cornerRadius: 104 * u, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "#F3F0EA")!, Color(hex: "#C9C3B8")!], startPoint: .top, endPoint: .bottom))
                    .frame(width: 520 * u, height: 500 * u)
                // Top face (the dish), lit from above.
                RoundedRectangle(cornerRadius: 78 * u, style: .continuous)
                    .fill(LinearGradient(colors: [.white, Color(hex: "#ECE8E0")!], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 78 * u, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 3 * u)
                    )
                    .frame(width: 404 * u, height: 352 * u)
                    .padding(.top, 34 * u)
                    .shadow(color: .black.opacity(0.10), radius: 8 * u, y: 6 * u)
                // Homing bar, the one bit of colour.
                Capsule()
                    .fill(Color(hex: "#FF9F0A")!)
                    .frame(width: 96 * u, height: 16 * u)
                    .padding(.top, 300 * u)
            }
        }
    }
}

enum AppIcon {
    @MainActor static func png(size: Int) -> Data? {
        let r = ImageRenderer(content: AppIconView().frame(width: CGFloat(size), height: CGFloat(size)))
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// Writes the 10 PNGs `iconutil -c icns` expects.
    @MainActor static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
                guard let d = png(size: base * scale) else { throw CocoaError(.fileWriteUnknown) }
                try d.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}

/// A small keycap in the switch's stem colour, for the pack picker.
struct KeycapChip: View {
    let hex: String?
    var body: some View {
        let c = NSColor(hex: hex) ?? NSColor(white: 0.6, alpha: 1)
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(LinearGradient(colors: [Color(nsColor: c), Color(nsColor: c.blended(withFraction: 0.28, of: .black) ?? c)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                .fill(Color(nsColor: c.blended(withFraction: 0.22, of: .white) ?? c))
                .padding(.horizontal, 2.4)
                .padding(.top, 1.4)
                .padding(.bottom, 3.6)
        }
        .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(Color.primary.opacity(0.34), lineWidth: 0.75))
        .frame(width: 15, height: 14)
        .accessibilityHidden(true)
    }
}
