import SwiftUI

/// Menu bar only (LSUIElement): the MenuBarExtra panel is the app's main UI; Settings and
/// onboarding are AppKit windows owned by AppController.
struct ClackwiseApp: App {
    @NSApplicationDelegateAdaptor(AppController.self) private var controller

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!controller.selfCheck)) {
            PanelHost(model: controller.model)
        } label: {
            Image(nsImage: MenuBarIcon.image(controller.model.icon))
        }
        .menuBarExtraStyle(.window)
    }
}

private struct PanelHost: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View { PanelView(model: model) { dismiss() } }
}
