import AppKit

final class PebblePanel: NSPanel {
    // 响应链把 cancelOperation 送回窗口本身时调用，避免自我转发造成的无限递归
    var onUnhandledCancel: (() -> Void)?
    private var forwardingCancel = false
    private var cancelReentered = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if forwardingCancel {
            cancelReentered = true
            return
        }
        forwardingCancel = true
        cancelReentered = false
        defer { forwardingCancel = false }
        NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: sender)
        if cancelReentered {
            onUnhandledCancel?()
        }
    }
}
