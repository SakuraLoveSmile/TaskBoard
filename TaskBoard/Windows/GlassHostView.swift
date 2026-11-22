import AppKit
import SwiftUI

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class GlassHostView<Content: View>: NSView {
    private let glass = NSGlassEffectView()
    private let hosting: FirstMouseHostingView<Content>

    var cornerRadius: CGFloat {
        didSet {
            glass.cornerRadius = cornerRadius
            needsLayout = true
        }
    }

    init(rootView: Content, cornerRadius: CGFloat) {
        self.hosting = FirstMouseHostingView(rootView: rootView)
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        glass.style = .regular
        glass.cornerRadius = cornerRadius
        glass.autoresizingMask = [.width, .height]
        // 交互式玻璃在按下时会把内容放大，铺满窗口的球会被四边裁掉，故关闭

        glass.wantsLayer = true
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        // 关闭 SwiftUI 向窗口回传拟合尺寸，否则窗口可能被压矮导致圆形被裁切
        hosting.sizingOptions = []

        glass.contentView = hosting
        addSubview(glass)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        hosting.frame = glass.bounds
        glass.cornerRadius = cornerRadius
    }
}
