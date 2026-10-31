import AppKit
import SwiftUI

/// Settings: General, Sound, About as toolbar tabs; Advanced appears while Option is held (and stays
/// while it is the selected tab).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let tabs = NSTabViewController()
    private var advanced: NSTabViewItem!
    private var flagsMonitor: Any?

    init(model: AppModel) {
        self.model = model
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init(window: w)
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []   // switching tabs is frequent: no crossfade
        for (label, symbol, view) in [("General", "gearshape", AnyView(GeneralTab(model: model))),
                                      ("Sound", "speaker.wave.2", AnyView(SoundTab(model: model))),
                                      ("About", "info.circle", AnyView(AboutTab(model: model)))] {
            tabs.addTabViewItem(item(label, symbol, view))
        }
        advanced = item("Advanced", "wrench.and.screwdriver", AnyView(AdvancedTab(model: model)))
        w.contentViewController = tabs
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.toolbarStyle = .preference
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func item(_ label: String, _ symbol: String, _ view: AnyView) -> NSTabViewItem {
        let vc = NSHostingController(rootView: view.frame(width: 520))
        vc.sizingOptions = .preferredContentSize
        vc.title = label   // the window title follows the selected tab
        let it = NSTabViewItem(viewController: vc)
        it.label = label
        it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return it
    }

    func show(tab: Int? = nil) {
        if let t = tab { select(t) }
        setAdvanced(NSEvent.modifierFlags.contains(.option))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if flagsMonitor == nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
                self?.setAdvanced(e.modifierFlags.contains(.option))
                return e
            }
        }
    }

    func select(_ index: Int) {
        if index == 3 { setAdvanced(true) }
        tabs.selectedTabViewItemIndex = min(index, tabs.tabViewItems.count - 1)
    }

    private func setAdvanced(_ show: Bool) {
        let shown = tabs.tabViewItems.contains(advanced)
        let selected = tabs.tabViewItems.indices.contains(tabs.selectedTabViewItemIndex) && tabs.tabViewItems[tabs.selectedTabViewItemIndex] == advanced
        if show && !shown { tabs.addTabViewItem(advanced) }
        if !show && shown && !selected { tabs.removeTabViewItem(advanced) }
    }

    func windowWillClose(_ notification: Notification) {
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        if tabs.tabViewItems.contains(advanced) {
            if tabs.tabViewItems[tabs.selectedTabViewItemIndex] == advanced { tabs.selectedTabViewItemIndex = 0 }
            tabs.removeTabViewItem(advanced)
        }
    }
}

// MARK: - tabs

/// A toggle with a one-line explanation under its label, as in System Settings.
struct ExplainedToggle: View {
    let title: String
    let detail: String
    let isOn: Binding<Bool>
    var body: some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(detail)
        }
    }
}

struct GeneralTab: View {
    let model: AppModel
    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: model.bind(\.openAtLogin) { $0.setOpenAtLogin($1) })
                if model.loginNeedsApproval {
                    Text("Approve Clackwise in System Settings → General → Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent {
                    ShortcutRecorder(model: model)
                } label: {
                    Text("Turn sounds on or off")
                    Text(model.shortcutTaken ? "Another app already uses this shortcut. Choose a different one."
                                             : "Works in every app.")
                }
            }
            Section {
                ExplainedToggle(title: "Pause while the microphone is in use",
                                detail: "Keeps key sounds out of calls and recordings.",
                                isOn: model.bind(\.pauseForMic) { $0.setPauseForMic($1) })
                ExplainedToggle(title: "Play on Bluetooth and AirPlay",
                                detail: "These outputs add 100 ms or more of delay, so sounds trail your typing.",
                                isOn: model.bind(\.allowWireless) { $0.setAllowWireless($1) })
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SoundTab: View {
    let model: AppModel
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Dynamics") {
                        Text(!model.hasSensor || model.strength < 0.005 ? "Off" : "\(Int((model.strength * 100).rounded())) %")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: model.bind(\.strength) { $0.setStrength($1) }, in: 0...1.5) {
                        Text("Dynamics")
                    } minimumValueLabel: {
                        Text("Even").font(.caption).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("Strong").font(.caption).foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                    .disabled(!model.hasSensor)
                    Text(model.hasSensor
                         ? "Harder presses sound brighter and a little louder; softer ones mellower. Even plays every key alike."
                         : "This Mac has no motion sensor, so Dynamics is off and every key plays at the normal level.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
            Section {
                ExplainedToggle(title: "Key-up sounds", detail: "Plays the key returning, not only the press.",
                                isOn: model.bind(\.keyUp) { $0.setKeyUp($1) })
                ExplainedToggle(title: "Variation", detail: "Small differences between presses so repeats don’t sound copied.",
                                isOn: model.bind(\.variation) { $0.setVariation($1) })
                ExplainedToggle(title: "Trim lead-in", detail: "Starts each sound right at the click, so it lands with your keypress.",
                                isOn: model.bind(\.trim) { $0.setTrim($1) })
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct AboutTab: View {
    let model: AppModel
    static let repoURL = URL(string: "https://github.com/bobk4ta/clackwise")!

    private var version: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "—"
        return "Version \(v)" + ((i?["CFBundleVersion"] as? String).map { " (\($0))" } ?? "")
    }

    /// LICENSES.md, lightly rendered: headings bold, hard-wrapped paragraphs re-flowed, inline
    /// Markdown (code, links) kept.
    private var licenses: AttributedString {
        guard let text = Bundle.main.url(forResource: "LICENSES", withExtension: "md")
            .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else { return "LICENSES.md is missing from this build." }
        var blocks: [(heading: Bool, text: String)] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { blocks.append((false, para.joined(separator: " "))); para = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush() }
            else if line.hasPrefix("#") { flush(); blocks.append((true, String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))) }
            else { para.append(line) }
        }
        flush()
        var out = AttributedString()
        for (i, b) in blocks.enumerated() {
            if i > 0 { out += AttributedString(b.heading ? "\n\n" : "\n") }
            if b.heading {
                var h = AttributedString(b.text)
                h.font = .system(size: 11, weight: .semibold)
                h.foregroundColor = .primary
                out += h
            } else {
                out += (try? AttributedString(markdown: b.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(b.text)
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            AppIconView().frame(width: 84, height: 84)
            Text("Clackwise").font(.title2.weight(.semibold)).padding(.top, 6)
            Text(version).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Mechanical keyboard sounds for your Mac’s keyboard.")
                .font(.callout)
                .padding(.top, 8)
            HStack(spacing: 10) {
                Button("Show Welcome Window") { model.actions?.showOnboarding() }
                Link(destination: Self.repoURL) { Label("GitHub", systemImage: "arrow.up.right") }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 14)
            VStack(alignment: .leading, spacing: 6) {
                Text("Acknowledgements").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    Text(licenses)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 132)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 24)
    }
}

struct AdvancedTab: View {
    let model: AppModel
    var body: some View {
        Form {
            Section {
                Picker("Velocity", selection: model.bind(\.version) { $0.setVersion($1) }) {
                    Text("v2 — timbre layers ±2 dB").tag("v2")
                    Text("v1 — loudness −12…0 dB + low-pass").tag("v1")
                }
                Picker("Detection", selection: model.bind(\.mode) { $0.setMode($1) }) {
                    Text("Instant (no added delay)").tag("instant")
                    Text("Wait for full peak (+20 ms)").tag("peak")
                }
                Toggle("Shock-onset measurement", isOn: model.bind(\.onsetMeasurement) { $0.setOnsetMeasurement($1) })
                HStack {
                    Button("Recalibrate") { model.actions?.recalibrate() }
                    Button("Show Stats File") { model.actions?.showStatsFile() }
                }
            } footer: {
                Text("Shown while holding Option. For measurement and comparison; defaults are tuned.")
            }
            Section("Live") {
                ForEach(Array((model.debugLines + model.outputs).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

// MARK: - shortcut recorder

/// Click, press a combination (needs ⌘, ⌥ or ⌃); Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    let model: AppModel
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(recording ? "Type shortcut…" : (model.shortcut?.display ?? "Record Shortcut"))
                    .monospacedDigit()
                    .frame(minWidth: 96)
                    .foregroundStyle(recording ? Color.accentColor : (model.shortcut == nil ? .secondary : .primary))
            }
            .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut: \(model.shortcut?.display ?? "none")")
            if model.shortcut != nil && !recording {
                Button { model.actions?.setShortcut(nil) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        model.actions?.setRecordingShortcut(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch Int(e.keyCode) {
            case 53: stop()                                          // Esc
            case 51 where e.modifierFlags.intersection([.command, .option, .control]).isEmpty:  // Delete
                model.actions?.setShortcut(nil); stop()
            default:
                guard let s = Shortcut(event: e) else { NSSound.beep(); return nil }
                model.actions?.setShortcut(s); stop()
            }
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if recording { recording = false; model.actions?.setRecordingShortcut(false) }
    }
}
