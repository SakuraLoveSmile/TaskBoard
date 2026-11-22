import QuartzCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    // 面板始终按最终尺寸贴住球所在的角，窗口生长时像揭幕一样把它露出来
    private var anchor: UnitPoint {
        model.panelAnchor == .topLeading ? .topLeading : .topTrailing
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if model.isExpanded {
                    let size = model.panelTargetSize
                    PanelView(model: model)
                        .frame(width: size.width, height: size.height)
                        .opacity(model.panelContentOpacity)
                        .position(
                            x: model.panelAnchor == .topLeading ? size.width / 2 : geo.size.width - size.width / 2,
                            y: size.height / 2
                        )
                        .transition(.opacity)
                }
                // 球按实时窗口尺寸贴角定位并手动淡出，避免作为“被移除视图”冻结在旧坐标系里漂移
                if !model.isExpanded || model.ballOpacity > 0.001 {
                    PebbleView(model: model)
                        .frame(width: Theme.pebbleSide, height: Theme.pebbleSide)
                        .opacity(model.ballOpacity)
                        .allowsHitTesting(!model.isExpanded)
                        .position(
                            x: model.panelAnchor == .topLeading ? Theme.pebbleSide / 2 : geo.size.width - Theme.pebbleSide / 2,
                            y: Theme.pebbleSide / 2
                        )
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.7, anchor: anchor)
                                    .animation(.spring(response: 0.3, dampingFraction: 0.78)),
                                removal: .identity
                            )
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.clear)
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }
}

struct PebbleView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dimmed = false
    @State private var awake = false
    @State private var pressing = false
    @State private var dragging = false
    @State private var tilt = 0.0
    @State private var lastMouseSample: (point: CGPoint, time: CFTimeInterval)?

    // 专注时长不参与进度：浮球环始终表示任务进度
    private var progress: Double {
        model.displayProgress
    }

    private var ringColor: Color {
        model.settings.progressMode == .external ? Theme.accent : Color.primary.opacity(0.55)
    }

    private var pebbleOpacity: Double {
        if hovering { return 1 }
        if dimmed && !model.pomodoro.isActive { return awake ? 0.88 : 0.52 }
        return 0.94
    }

    // 整球（含玻璃外壳）由 PanelController 缩放，这里只负责缩放时机
    private var squashing: Bool {
        pressing && !dragging
    }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: 3)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)

            if progress > 0.001 {
                Circle()
                    .inset(by: 3)
                    .trim(from: 0, to: progress)
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            label
        }
        .rotationEffect(.degrees(tilt))
        .frame(width: Theme.pebbleSide, height: Theme.pebbleSide)
        .contentShape(Circle())
        .opacity(pebbleOpacity)
        .onHover { inside in
            hovering = inside
            if inside { dimmed = false }
        }
        .task(id: hovering) {
            guard !hovering else {
                dimmed = false
                return
            }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, !hovering else { return }
            dimmed = true
        }
        // 暗态下按固定频率测鼠标与球心的距离，靠近先“睁眼”，不依赖辅助功能权限
        .task(id: dimmed) {
            guard dimmed else {
                awake = false
                return
            }
            while !Task.isCancelled {
                let near = model.isPointerNearPebble?(60) ?? false
                if near != awake {
                    withAnimation(.easeOut(duration: near ? 0.16 : 0.6)) {
                        awake = near
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .gesture(dragGesture)
        .contextMenu { contextMenu }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.easeInOut(duration: 0.7), value: dimmed)
        .onChange(of: squashing) { _, isSquashing in
            model.pebblePressHandler?(isSquashing)
        }
        .onDisappear {
            model.pebblePressHandler?(false)
        }
        .onChange(of: dimmed) { _, isDimmed in
            if !isDimmed { awake = false }
        }
        .accessibilityLabel("TaskBoard 浮钮，打开今日看板")
    }

    @ViewBuilder
    private var label: some View {
        if model.pomodoro.isActive {
            Text(model.pomodoro.timeText)
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.9))
        } else if hovering || awake {
            Text("\(model.displayPercent)%")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85))
        } else {
            Image(systemName: "checklist")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.78))
        }
    }

    private func settleTilt() {
        lastMouseSample = nil
        if reduceMotion {
            tilt = 0
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.45)) { tilt = 0 }
        }
    }

    // 窗口跟着鼠标走，拖拽 translation 会停在阈值附近，倾斜只能按屏幕速度采样
    private func updateTilt() {
        guard !reduceMotion else { return }
        let now = CACurrentMediaTime()
        let point = NSEvent.mouseLocation
        defer { lastMouseSample = (point, now) }
        guard let last = lastMouseSample else { return }
        let elapsed = now - last.time
        guard elapsed > 0.001 else { return }
        let velocityX = Double((point.x - last.point.x) / elapsed)
        let target = max(-10, min(10, velocityX * 0.015))
        tilt = tilt * 0.6 + target * 0.4
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                pressing = true
                let distance = hypot(value.translation.width, value.translation.height)
                if !dragging && distance > 3 {
                    dragging = true
                    lastMouseSample = nil
                    model.beginMoveHandler?()
                }
                if dragging {
                    updateTilt()
                    model.moveToMouseHandler?()
                }
            }
            .onEnded { _ in
                pressing = false
                settleTilt()
                if dragging {
                    dragging = false
                    model.endMoveHandler?()
                } else {
                    model.expand()
                }
            }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("打开看板") { model.expand() }
        Button(model.pomodoro.isActive ? "暂停 / 继续专注" : "开始专注") {
            model.togglePomodoro()
        }
        Divider()
        Button(model.archivedCount > 0 ? "任务归档（\(model.archivedCount)）…" : "任务归档…") {
            model.openArchive()
        }
        Button("设置…") { model.openSettings() }
        Button("隐藏浮钮") { model.setPebbleHidden(true) }
        Button(model.captureAllowed ? "关闭截图模式" : "允许截图/录屏") {
            model.setCaptureAllowed(!model.captureAllowed)
        }
        Divider()
        Button("退出 TaskBoard") { NSApp.terminate(nil) }
    }
}
