// 自己画的鼠标悬停说明（代替系统的 .help）：
//   系统的提示要停 1 秒左右才出现、显示期间文字不会更新；这个停 0.3 秒就出现，文字变了马上跟着变
//   （比如复制后立刻显示「已复制」）。
// 用法：在只有图标、能点的按钮上加 .tip("说明文字")。
//
// 实现：提示画在一个单独的小窗口里，所以不会被列表、侧栏的边界裁掉；
// 窗口不接收鼠标，不会挡住下面的按钮。默认显示在图标上方，放不下就显示在下方。
import AppKit
import SwiftUI

extension View {
    /// 鼠标停在上面时显示的说明
    func tip(_ text: String) -> some View {
        modifier(TipModifier(text: text))
    }
}

private struct TipModifier: ViewModifier {
    let text: String
    @StateObject private var tip = TipState()

    func body(content: Content) -> some View {
        content
            .background(TipAnchor(tip: tip))
            .onHover { tip.hover($0, text: text) }
            .onChange(of: text) { _, newText in tip.update(newText) }
            .onDisappear { tip.hide() }
    }
}

/// 一个图标的提示状态：鼠标进来后等一会儿再显示，出去就收起
@MainActor
private final class TipState: ObservableObject {
    weak var anchor: NSView? // 图标所在的位置，用来算提示框放哪
    private var pending: DispatchWorkItem?
    private var showing = false

    func hover(_ inside: Bool, text: String) {
        pending?.cancel()
        if inside {
            let work = DispatchWorkItem { [weak self] in self?.show(text) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else {
            hide()
        }
    }

    /// 提示正显示着、文字变了：原地换成新文字
    func update(_ text: String) {
        if showing { show(text) }
    }

    func hide() {
        pending?.cancel()
        if showing { TipWindow.shared.hide() }
        showing = false
    }

    private func show(_ text: String) {
        guard let view = anchor, let window = view.window else { return }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        TipWindow.shared.show(text, near: rect, screen: window.screen)
        showing = true
    }
}

/// 藏在图标背后的空 NSView，只为了拿到图标在屏幕上的位置
private struct TipAnchor: NSViewRepresentable {
    let tip: TipState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        tip.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        tip.anchor = view
    }
}

/// 全 app 共用一个提示窗口（同一时间只会显示一个提示）
///
/// 提示框用纯 AppKit 画（NSTextField + 自己算尺寸、直接设 frame），不用 SwiftUI 的 NSHostingController：
/// 之前用 HostingController 时，文字会换行，SwiftUI 和窗口的约束布局互相触发、停不下来，
/// AppKit 发现这个窗口一轮里重排次数超限，直接抛异常把整个 App 结束掉（不弹崩溃框，看着像自己退出）。
/// 现在这里没有约束、也没有 SwiftUI，就不会再有这种循环。
@MainActor
private final class TipWindow {
    static let shared = TipWindow()

    private static let maxWidth: CGFloat = 280 // 提示框最宽多少，超过就换行
    private static let paddingX: CGFloat = 8   // 文字离提示框左右边的距离
    private static let paddingY: CGFloat = 5   // 文字离提示框上下边的距离

    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true // 不挡住下面的按钮
        panel.level = .floating
        panel.hidesOnDeactivate = true  // 切到别的 app 时跟着隐藏

        // 文字：白色 11.5 号字，自动换行
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .white
        label.isSelectable = false

        // 背景：深色圆角小卡片
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        card.layer?.cornerRadius = 6
        card.addSubview(label)
        panel.contentView = card
    }

    func show(_ text: String, near anchor: NSRect, screen: NSScreen?) {
        // 先按最大宽度量出文字换行后要多大，再加上四周留白，就是提示框的大小
        label.stringValue = text
        let textMaxWidth = Self.maxWidth - Self.paddingX * 2
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textMaxWidth, height: 1000)) ?? .zero
        let textSize = NSSize(width: ceil(measured.width), height: ceil(measured.height))
        label.frame = NSRect(x: Self.paddingX, y: Self.paddingY, width: textSize.width, height: textSize.height)
        let size = NSSize(width: textSize.width + Self.paddingX * 2, height: textSize.height + Self.paddingY * 2)
        let visible = screen?.visibleFrame ?? .infinite
        let gap: CGFloat = 6

        // 水平：和图标居中对齐，但不超出屏幕
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        // 垂直：默认在图标上方（放下方会被鼠标指针挡住；屏幕坐标 y 向上增大），上面放不下才放下面
        var y = anchor.maxY + gap
        if y + size.height > visible.maxY { y = anchor.minY - gap - size.height }

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }
}
