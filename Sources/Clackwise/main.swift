import AppKit

let args = CommandLine.arguments
func argument(after flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

// `Clackwise --login-item on|off|status`: set / show the launch-at-login item (SMAppService), exit.
if args.contains("--login-item") {
    let arg = argument(after: "--login-item") ?? "status"
    if arg == "on" || arg == "off", let e = AppController.setLoginItem(arg == "on") { print("error: \(e)"); exit(1) }
    print("launch at login: \(AppController.loginItemStatus)")
    exit(0)
}

// `Clackwise --make-icon <dir.iconset>`: render the app icon (build_app.sh turns it into AppIcon.icns).
if let dir = argument(after: "--make-icon") {
    MainActor.assumeIsolated {
        do { try AppIcon.writeIconset(to: URL(fileURLWithPath: dir)) } catch { print("error: \(error)"); exit(1) }
    }
    exit(0)
}

// `open -n Clackwise.app --args --snapshots <dir>`: PNGs of the UI with sample data, light and dark.
// Launched through LaunchServices so the app is active and controls draw in their key-window state.
// Touches no settings, sensor, audio or event tap.
if let dir = argument(after: "--snapshots") {
    MainActor.assumeIsolated { Snapshots.run(to: URL(fileURLWithPath: dir)) }
}

// Menu bar only (LSUIElement in Info.plist; .accessory also when run unbundled).
NSApplication.shared.setActivationPolicy(.accessory)
ClackwiseApp.main()
