import SwiftUI

/// The menu bar panel (MenuBarExtra, window style), laid out like a Control Center module.
struct PanelView: View {
    let model: AppModel
    var dismiss: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            if let n = model.notice, model.enabled {
                NoticeRow(notice: n, model: model)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
            volume
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            Divider().padding(.horizontal, 14)
            PackList(model: model)
            Divider().padding(.horizontal, 14)
            footer
                .padding(6)
        }
        .frame(width: 300)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.notice)
        .onAppear { model.actions?.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(model.enabled ? Color.accentColor : Color.primary.opacity(0.1))
                Image(nsImage: MenuBarIcon.image(model.enabled ? .on : .off))
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(model.enabled ? Color.white : Color.primary)
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Clackwise").font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("Clackwise", isOn: model.bind(\.enabled) { $0.setEnabled($1) })
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
        }
    }

    private var subtitle: String {
        guard model.enabled else { return "Off" }
        if model.notice != nil { return model.notice == .needsAccess ? "Needs access" : "Paused" }
        return model.currentPack?.switchName ?? "On"
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Slider(value: model.bind(\.volume) { $0.setVolume($1) }, in: 0...1)
                .controlSize(.small)
                .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 20)
        }
        .disabled(!model.enabled)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            MenuRow(title: "Settings…", shortcut: "⌘,") { dismiss(); model.actions?.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
            MenuRow(title: "Quit Clackwise", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

/// Why sound is muted or paused, with the one action that fixes it where there is one.
struct NoticeRow: View {
    let notice: Notice
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: notice.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(.callout.weight(.medium))
                Text(notice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if notice == .needsAccess {
                    HStack {
                        if model.needsRelaunch {
                            Button("Relaunch Clackwise") { model.actions?.relaunch() }
                        } else {
                            Button("Open System Settings") { model.actions?.requestAccess() }
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch notice {
        case .needsAccess, .audio: return .orange
        default: return .secondary
        }
    }
}

struct PackList: View {
    let model: AppModel
    private static let height: CGFloat = 340
    private static let fade: CGFloat = 40
    /// The last row is on screen (rows are created lazily, so this means "scrolled to the end").
    @State private var atEnd = false

    var body: some View {
        let groups = PackItem.groups(model.packs)
        let lastID = groups.last?.packs.last?.id
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.title) { g in
                        HStack {
                            Text(g.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if g.title == "Classic" {
                                Label("synthesized key-up", systemImage: "circle.dotted")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .padding(.bottom, 3)
                        ForEach(g.packs) { p in
                            PackRow(pack: p, selected: p.id == model.packID, loading: p.id == model.loadingPackID) {
                                model.actions?.pickPack(p.id)
                            }
                            .id(p.id)
                            .onAppear { if p.id == lastID { atEnd = true } }
                            .onDisappear { if p.id == lastID { atEnd = false } }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.visible)
            .frame(height: Self.height)
            // More rows below: fade the bottom edge and show a chevron, so the list doesn't look cut off.
            .mask(
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: atEnd ? .black : .clear, location: atEnd ? 1 : 0.7)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                }
            )
            .overlay(alignment: .bottom) {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                    .opacity(atEnd ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .animation(.easeOut(duration: 0.15), value: atEnd)
            .onAppear { if let id = model.packID { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

struct PackRow: View {
    let pack: PackItem
    let selected: Bool
    let loading: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                KeycapChip(hex: pack.color)
                (Text(pack.switchName) + Text(pack.character.map { "  \($0)" } ?? "").foregroundColor(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if pack.synthesizedKeyUp {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .help("Key-up sound is synthesized")
                }
                Group {
                    if loading { ProgressView().controlSize(.mini) }
                    else if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor) }
                }
                .frame(width: 14)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(pack.name + (pack.synthesizedKeyUp ? ", synthesized key-up" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A full-width row that behaves like a menu item: highlight on hover, title left, shortcut right.
struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let s = shortcut { Text(s).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
