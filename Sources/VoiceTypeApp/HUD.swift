import AppKit
import SwiftUI
import VoiceTypeCore

/// Never key, never main: showing it cannot move keyboard focus out of the target app.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class HUDModel: ObservableObject {
    @Published var state: SessionState = .idle
    @Published var title = ""
    @Published var caption = ""
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    private var tint: Color {
        switch model.state {
        case .recording: return .red
        case .done: return .green
        case .error: return .orange
        case .cancelled, .idle: return .gray
        default: return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(model.title).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            }
            if !model.caption.isEmpty {
                Text(model.caption)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08)))
    }
}

final class HUDController: HUDPresenting {
    let panel: HUDPanel
    private let model = HUDModel()
    private let hosting: NSHostingView<HUDView>
    private var hideWork: DispatchWorkItem?

    init() {
        hosting = NSHostingView(rootView: HUDView(model: model))
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 64),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hosting
    }

    func update(state: SessionState, message: String?, caption: String) {
        switch state {
        case .recording, .finalizing, .processing, .inserting:
            hideWork?.cancel(); hideWork = nil
            model.state = state
            model.title = message ?? ""
            if state == .recording || !caption.isEmpty { model.caption = caption }
            present()
        case .done, .error, .cancelled:
            guard let message = message else { hide(); return }
            model.state = state
            model.title = message
            model.caption = ""
            present()
            scheduleHide(after: message == "已插入" ? 0.8 : 2.6)
        case .idle:
            if hideWork == nil { hide() }
        }
    }

    private func present() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 96, width: size.width, height: size.height), display: true)
        }
        // orderFrontRegardless shows the panel without activating VoiceType or taking key status.
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideWork = nil; self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hide() { panel.orderOut(nil) }
}
