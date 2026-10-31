import AppKit
import SwiftUI

/// First-run window, two screens: (1) access — the macOS messages that follow, in order, each with the
/// button to click (SetupGuide repeats the current one next to macOS's UI); (2) once keys reach
/// Clackwise — "Access granted", a focused field to hear it. Shown until Done; after macOS relaunches the app it resumes at screen 2. Reopened from
/// Settings → About.
final class OnboardingWindowController: NSWindowController {
    init(model: AppModel) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        let host = NSHostingController(rootView: OnboardingView(model: model))
        host.sizingOptions = .preferredContentSize
        w.contentViewController = host
        super.init(window: w)
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.tapWorking {
                TryItScreen(model: model)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 16)))
            } else {
                AccessScreen(model: model)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: -16)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.tapWorking)
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 26)
        .frame(width: 460, height: 480, alignment: .top)   // both screens: no window resize between them
    }
}

// MARK: - screen 1: access

private struct AccessScreen: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            AppIconView().frame(width: 56, height: 56)
            Text("Let Clackwise hear your keys")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 10)
            Text(model.needsRelaunch ? "Access is on. Reopen Clackwise once to start using it."
                 : model.accessDenied ? "You chose Deny, so macOS won’t ask again. You can switch it on yourself."
                                      : "Clackwise plays a sound with every keypress, so macOS asks you to allow it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 10) {
                Text(model.accessDenied ? "Switch it on by hand" : "What macOS shows next")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if model.accessDenied {
                    StepLine(n: 1, text: "Open **Privacy & Security → Input Monitoring** in System Settings")
                } else {
                    StepLine(n: 1, text: "Keystroke Receiving → click **Open System Settings**, not the blue **Deny**")
                }
                StepLine(n: 2, text: "Input Monitoring → switch on **Clackwise**")
                StepLine(n: 3, text: "Confirm with **Touch ID** or your password")
                StepLine(n: 4, text: "Reopen Clackwise? → **Quit & Reopen**")
                Text(model.accessDenied ? "Clackwise is already in that list. The button opens it."
                                        : "A small note points to each step, then you’re back here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            .padding(.top, 20)

            Spacer(minLength: 12)

            Label("Nothing you type is stored or sent anywhere.", systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
            Group {
                if model.needsRelaunch {
                    Button { model.actions?.relaunch() } label: { Text("Reopen Clackwise").frame(minWidth: 180) }
                } else if model.accessDenied {
                    Button { model.actions?.showInputMonitoring() } label: { Text("Open Input Monitoring").frame(minWidth: 180) }
                } else {
                    Button { model.actions?.requestAccess() } label: { Text("Continue").frame(minWidth: 180) }
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 14)
        }
    }
}

private struct StepLine: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(n)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 19, height: 19)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - screen 2: try it

private struct TryItScreen: View {
    let model: AppModel
    @State private var text = ""      // in memory only, gone when the window closes
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Label("Access granted", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(Color.green.opacity(0.12)))
            AppIconView().frame(width: 64, height: 64).padding(.top, 22)
            Text("You’re set. Hear it.")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 10)
            Text("Type anything: this is how every key on your Mac sounds now.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            TextField("Start typing…", text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(.system(size: 15))
                .focused($focused)
                .padding(.top, 22)
            Group {
                if let hint {
                    Label(hint, systemImage: "speaker.slash").foregroundStyle(.secondary)
                } else {
                    Text(" ")
                }
            }
            .font(.caption)
            .padding(.top, 8)

            Spacer(minLength: 0)

            Button { model.actions?.finishOnboarding() } label: { Text("Done").frame(minWidth: 180) }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)   // no Return shortcut: Return in the field is just a key
        }
        .onAppear { focused = true }
    }

    /// Why typing might stay silent.
    private var hint: String? {
        if !model.enabled { return "Clackwise is off. Turn it on from the menu bar." }
        guard let n = model.notice, n != .needsAccess else { return nil }
        return n.title
    }
}
