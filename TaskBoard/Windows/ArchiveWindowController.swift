import AppKit
import SwiftUI

@MainActor
final class ArchiveWindowController: NSWindowController {
    init(model: AppModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "任务归档"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentMinSize = NSSize(width: 440, height: 420)
        window.contentView = NSHostingView(rootView: ArchiveView(model: model))
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true {
            window?.center()
        }
        window?.makeKeyAndOrderFront(nil)
    }
}
