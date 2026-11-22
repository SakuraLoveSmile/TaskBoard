import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let pebbleSide: CGFloat = 44
    static let panelWidth: CGFloat = 384
    static let panelHeight: CGFloat = 620
    static let panelCorner: CGFloat = 24
    static let inset: CGFloat = 14

    private struct FrameAnimation {
        let from: NSRect
        let to: NSRect
        let cornerFrom: CGFloat
        let cornerTo: CGFloat
        let start: CFTimeInterval
        let response: Double
        let damping: Double
        let completion: (() -> Void)?
    }

    private let model: AppModel
    private let panel: PebblePanel
    private let glass: GlassHostView<RootView>
    private var dragBaseOrigin: CGPoint?
    private var dragStartMouse: CGPoint?
    private var frameAnimation: FrameAnimation?
    private var frameTimer: Timer?

    init(model: AppModel, rootView: RootView) {
        self.model = model
        self.glass = GlassHostView(rootView: rootView, cornerRadius: Self.pebbleSide / 2)
        self.panel = PebblePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.pebbleSide, height: Self.pebbleSide),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        // isFloatingPanel 会把层级重置为 floating，必须在其后再抬到 statusBar
        panel.level = .statusBar
        panel.animationBehavior = .none
        panel.minSize = NSSize(width: Self.pebbleSide, height: Self.pebbleSide)
        panel.sharingType = ProcessInfo.processInfo.arguments.contains("--capture") ? .readOnly : .none
        panel.delegate = self
        panel.onUnhandledCancel = { [weak model] in
            guard let model else { return }
            if model.refineTask != nil {
                model.cancelRefine()
            } else {
                model.collapse()
            }
        }

        let content = NSView(
            frame: NSRect(x: 0, y: 0, width: Self.pebbleSide, height: Self.pebbleSide)
        )
        content.autoresizingMask = [.width, .height]
        glass.frame = content.bounds
        glass.autoresizingMask = [.width, .height]
        content.addSubview(glass)
        panel.contentView = content
    }

    func show() {
        guard let origin = resolvedOrigin() else { return }
        panel.setFrame(pebbleFrame(origin: origin), display: true)
        if model.settings.hidePebble {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func expandWindow() {
        guard let anchorScreen = screenForCurrentFrame() else { return }
        let visible = anchorScreen.visibleFrame
        let anchor = panel.frame

        let height = min(Self.panelHeight, max(320, visible.height - 24))
        let opensRight = anchor.midX < anchorScreen.frame.midX
        var x = opensRight ? anchor.minX : anchor.maxX - Self.panelWidth
        x = min(max(x, visible.minX + 8), visible.maxX - Self.panelWidth - 8)
        var y = anchor.maxY - height
        y = min(max(y, visible.minY + 8), visible.maxY - height - 8)

        model.panelAnchor = opensRight ? .topLeading : .topTrailing
        model.panelTargetSize = CGSize(width: Self.panelWidth, height: height)

        panel.orderFrontRegardless()
        panel.makeKey()
        animateFrame(
            to: NSRect(x: x, y: y, width: Self.panelWidth, height: height),
            cornerRadius: Self.panelCorner,
            response: 0.42,
            damping: 0.84
        )
    }

    func collapseWindow() {
        guard let origin = resolvedOrigin() else { return }
        animateFrame(
            to: pebbleFrame(origin: origin),
            cornerRadius: Self.pebbleSide / 2,
            response: 0.36,
            damping: 0.95
        ) { [weak self] in
            guard let self, self.model.settings.hidePebble else { return }
            self.panel.orderOut(nil)
        }
    }

    private func animateFrame(
        to target: NSRect,
        cornerRadius: CGFloat,
        response: Double,
        damping: Double,
        completion: (() -> Void)? = nil
    ) {
        stopFrameAnimation()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(target, display: true)
            glass.cornerRadius = cornerRadius
            let expanded = target.width > Self.pebbleSide
            model.panelContentOpacity = expanded ? 1 : 0
            model.ballOpacity = expanded ? 0 : 1
            completion?()
            return
        }
        frameAnimation = FrameAnimation(
            from: panel.frame,
            to: target,
            cornerFrom: glass.cornerRadius,
            cornerTo: cornerRadius,
            start: CACurrentMediaTime(),
            response: response,
            damping: damping,
            completion: completion
        )
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stepFrameAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
        stepFrameAnimation()
    }

    private func stepFrameAnimation() {
        guard let anim = frameAnimation else { return }
        let elapsed = CACurrentMediaTime() - anim.start
        let progress = Self.springProgress(elapsed, response: anim.response, damping: anim.damping)

        var frame = anim.from
        frame.origin.x = anim.from.minX + (anim.to.minX - anim.from.minX) * progress
        frame.origin.y = anim.from.minY + (anim.to.minY - anim.from.minY) * progress
        frame.size.width = anim.from.width + (anim.to.width - anim.from.width) * progress
        frame.size.height = anim.from.height + (anim.to.height - anim.from.height) * progress
        panel.setFrame(frame, display: true)
        glass.cornerRadius = anim.cornerFrom + (anim.cornerTo - anim.cornerFrom) * progress

        let reveal = min(1, max(0, (frame.size.width - Self.pebbleSide) / (Self.panelWidth - Self.pebbleSide)))
        model.panelContentOpacity = pow(Double(reveal), 1.8)
        model.ballOpacity = pow(Double(1 - reveal), 2.5)

        if elapsed > anim.response, abs(1 - progress) < 0.003 {
            panel.setFrame(anim.to, display: true)
            glass.cornerRadius = anim.cornerTo
            let expanded = anim.to.width > Self.pebbleSide
            model.panelContentOpacity = expanded ? 1 : 0
            model.ballOpacity = expanded ? 0 : 1
            frameAnimation = nil
            frameTimer?.invalidate()
            frameTimer = nil
            anim.completion?()
        }
    }

    private func stopFrameAnimation() {
        frameTimer?.invalidate()
        frameTimer = nil
        frameAnimation = nil
    }

    private static func springProgress(_ t: TimeInterval, response: Double, damping: Double) -> CGFloat {
        let omega = 2 * Double.pi / response
        let omegaD = omega * sqrt(max(0.0001, 1 - damping * damping))
        let value = 1 - exp(-damping * omega * t) * (
            cos(omegaD * t) + (damping * omega / omegaD) * sin(omegaD * t)
        )
        return CGFloat(min(1.01, max(0, value)))
    }

    func setCaptureAllowed(_ allowed: Bool) {
        panel.sharingType = allowed ? .readOnly : .none
    }

    func setHidden(_ hidden: Bool) {
        if hidden {
            if model.isExpanded {
                model.collapse()
                return
            }
            panel.orderOut(nil)
        } else {
            if !model.isExpanded, let origin = resolvedOrigin() {
                panel.setFrame(pebbleFrame(origin: origin), display: true)
            }
            panel.orderFrontRegardless()
        }
    }

    func resetPosition() {
        model.settings.hasPebblePosition = false
        guard let origin = defaultOrigin() else { return }
        panel.setFrameOrigin(origin)
        if !panel.isVisible && !model.settings.hidePebble {
            panel.orderFrontRegardless()
        }
    }

    func beginDrag() {
        stopFrameAnimation()
        dragBaseOrigin = panel.frame.origin
        dragStartMouse = NSEvent.mouseLocation
    }

    func moveToMouse() {
        guard let base = dragBaseOrigin, let startMouse = dragStartMouse else { return }
        let current = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = CGPoint(
            x: base.x + (current.x - startMouse.x),
            y: base.y + (current.y - startMouse.y)
        )
        if let screen = screenForCurrentFrame() {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    func endDrag() {
        dragBaseOrigin = nil
        dragStartMouse = nil
        var origin = panel.frame.origin
        let size = panel.frame.size

        if let screen = screenForCurrentFrame() {
            let visible = screen.visibleFrame
            let snapDistance: CGFloat = 24
            let rightTarget = visible.maxX - size.width - Self.inset
            let leftTarget = visible.minX + Self.inset
            let topTarget = visible.maxY - size.height - 10

            if abs(origin.x - rightTarget) < snapDistance { origin.x = rightTarget }
            if abs(origin.x - leftTarget) < snapDistance { origin.x = leftTarget }
            if abs(origin.y - topTarget) < snapDistance { origin.y = topTarget }

            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }

        panel.setFrameOrigin(origin)
        model.settings.pebbleX = origin.x
        model.settings.pebbleY = origin.y
        model.settings.hasPebblePosition = true
    }

    func containsGlobalPoint(_ point: CGPoint) -> Bool {
        panel.frame.contains(point)
    }

    func setPebblePressed(_ pressed: Bool) {
        guard let layer = glass.layer else { return }
        let scale: CGFloat = pressed ? 0.93 : 1
        // AppKit 视图层的锚点在左下角，手动换到中心再缩放
        let bounds = layer.bounds
        var target = CATransform3DTranslate(CATransform3DIdentity, bounds.midX, bounds.midY, 0)
        target = CATransform3DScale(target, scale, scale, 1)
        target = CATransform3DTranslate(target, -bounds.midX, -bounds.midY, 0)
        layer.removeAnimation(forKey: "press")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = target
            CATransaction.commit()
            return
        }
        let animation = CASpringAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
        animation.toValue = NSValue(caTransform3D: target)
        animation.mass = 1
        animation.stiffness = 816
        animation.damping = 34
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: "press")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        CATransaction.commit()
    }

    func isPointerNearPebble(margin: CGFloat) -> Bool {
        guard panel.isVisible else { return false }
        let mouse = NSEvent.mouseLocation
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        return hypot(mouse.x - center.x, mouse.y - center.y) <= Self.pebbleSide / 2 + margin
    }

    private func pebbleFrame(origin: CGPoint) -> NSRect {
        NSRect(x: origin.x, y: origin.y, width: Self.pebbleSide, height: Self.pebbleSide)
    }

    private func screenForCurrentFrame() -> NSScreen? {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    private func resolvedOrigin() -> CGPoint? {
        if model.settings.hasPebblePosition {
            let saved = CGPoint(x: model.settings.pebbleX, y: model.settings.pebbleY)
            if let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -Self.pebbleSide, dy: -Self.pebbleSide).contains(saved) }) {
                let visible = screen.visibleFrame
                let clamped = CGPoint(
                    x: min(max(saved.x, visible.minX), visible.maxX - Self.pebbleSide),
                    y: min(max(saved.y, visible.minY), visible.maxY - Self.pebbleSide)
                )
                return clamped
            }
        }
        return defaultOrigin()
    }

    private func defaultOrigin() -> CGPoint? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let visible = screen.visibleFrame
        return CGPoint(
            x: visible.maxX - Self.pebbleSide - Self.inset,
            y: visible.maxY - Self.pebbleSide - 10
        )
    }
}
