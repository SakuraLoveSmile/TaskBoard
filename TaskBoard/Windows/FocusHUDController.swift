import AppKit
import SwiftUI

@MainActor
final class FocusHUDController {
    static let width: CGFloat = 320
    static let height: CGFloat = 48

    private let model: AppModel
    private let panel: PebblePanel
    private let glass: GlassHostView<FocusHUDView>

    init(model: AppModel) {
        self.model = model
        self.glass = GlassHostView(rootView: FocusHUDView(model: model), cornerRadius: 16)
        self.panel = PebblePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.minSize = NSSize(width: Self.width, height: Self.height)
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = true
        panel.sharingType = ProcessInfo.processInfo.arguments.contains("--capture") ? .readOnly : .none

        let content = NSView(
            frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height)
        )
        content.autoresizingMask = [.width, .height]
        glass.frame = content.bounds
        glass.autoresizingMask = [.width, .height]
        content.addSubview(glass)
        panel.contentView = content
    }

    func setCaptureAllowed(_ allowed: Bool) {
        panel.sharingType = allowed ? .readOnly : .none
    }

    func updateVisibility() {
        let isWorkPhase = model.pomodoro.state != .idle && model.pomodoro.phase == .work
        let task = model.focusTask
        let shouldShow = isWorkPhase && task != nil && task?.isDone == false

        if shouldShow {
            if !panel.isVisible {
                position()
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func containsGlobalPoint(_ point: CGPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }

    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrame(
            NSRect(
                x: visible.midX - Self.width / 2,
                y: visible.maxY - Self.height - 10,
                width: Self.width,
                height: Self.height
            ),
            display: false
        )
    }
}
