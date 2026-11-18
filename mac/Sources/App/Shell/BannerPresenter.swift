// 自己画的通知横幅，代替系统通知。
// 系统通知只在主屏幕弹，人在看别的屏幕时容易错过；这里弹在「用户正在看的那块屏幕」的右上角
// （前台 app 的窗口在哪块屏幕就是哪块，没有窗口时看鼠标，见 activeScreen）。
// 做法：一个无边框、不抢焦点、置顶的小面板（NSPanel），所有桌面空间和全屏 app 上都能看到。
// - 点横幅：执行 onClick（打开主窗口对应的位置），横幅消失
// - 鼠标放上去右上角出现 ×，点它只关闭
// - 放着不管 duration 秒后自己淡出；鼠标停在上面时不消失，移开后再重新计时
//   （停留秒数、是否「点了才消失」在 设置 → 通知 里改，见 NotificationSettingsView）
// - 同一块屏幕上同时有多条时，往下排
// 参考 claudeStatusLight 的 BannerPresenter，改成只弹在当前屏幕。
import AppKit
import SwiftUI

@MainActor
final class BannerPresenter {
    static let shared = BannerPresenter()
    private init() {}

    /// 正显示着的横幅
    private var active: [NSPanel] = []

    private let width: CGFloat = 360
    private let margin: CGFloat = 16   // 离屏幕边缘的距离
    private let spacing: CGFloat = 10  // 多条横幅之间的间距

    // 设置 → 通知 里改的两项（存在 UserDefaults，每次弹出时读当前值）
    static let durationKey = "bannerDuration"
    static let defaultDuration = 10.0
    static let durationRange = 3.0...60.0
    /// 打开后横幅不会自己消失，要点一下（或点 ×）才关
    static let stickyKey = "bannerSticky"

    private var duration: TimeInterval {
        UserDefaults.standard.object(forKey: Self.durationKey) as? Double ?? Self.defaultDuration
    }
    private var sticky: Bool { UserDefaults.standard.bool(forKey: Self.stickyKey) }

    func show(title: String, body: String, onClick: @escaping () -> Void) {
        let screen = Self.activeScreen()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        // 计时：鼠标在横幅上时暂停，移开后重新等 duration 秒。设成「点了才消失」时不计时
        var timer: DispatchWorkItem?
        let restartTimer = { [weak self, weak panel] in
            timer?.cancel()
            guard let self, !self.sticky else { return }
            let item = DispatchWorkItem { if let panel { self.dismiss(panel) } }
            timer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + self.duration, execute: item)
        }

        let view = BannerView(
            title: title, message: body,
            onClick: { [weak self, weak panel] in
                onClick()
                if let panel { self?.dismiss(panel) }
            },
            onClose: { [weak self, weak panel] in if let panel { self?.dismiss(panel) } },
            onHover: { hovering in
                if hovering { timer?.cancel() } else { restartTimer() }
            })
        let hosting = FirstClickHostingView(rootView: view.frame(width: width))
        // 高度跟着文字行数走
        let height = hosting.fittingSize.height
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = hosting
        panel.setContentSize(NSSize(width: width, height: height))

        // 右上角；这块屏幕上已有横幅的话，排到最下面那条的下方
        let visible = screen.visibleFrame
        let lowestTop = active.filter { $0.screen == screen }.map(\.frame.minY).min()
        let top = lowestTop.map { $0 - spacing } ?? visible.maxY - margin
        let x = visible.maxX - width - margin
        let y = top - height

        // 从右边轻轻滑进来、淡入
        panel.setFrameOrigin(NSPoint(x: x + 24, y: y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        active.append(panel)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().setFrameOrigin(NSPoint(x: x, y: y))
            panel.animator().alphaValue = 1
        }
        NSSound(named: "Glass")?.play()
        restartTimer()
    }

    private func dismiss(_ panel: NSPanel) {
        guard let index = active.firstIndex(of: panel) else { return } // 已经在关了
        active.remove(at: index)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    /// 用户正在看的那块屏幕：
    /// 1. 前台 app 最前面那个窗口所在的屏幕（Cmd+Tab 切 app 时鼠标可能还在别的屏幕，看窗口更准）
    /// 2. 前台 app 没有窗口时（比如没开窗口的 Finder），用鼠标所在的屏幕
    /// 3. 都找不到就用主屏幕
    private static func activeScreen() -> NSScreen {
        if let frame = frontmostWindowFrame(),
           let screen = NSScreen.screens.first(where: { NSMouseInRect(NSPoint(x: frame.midX, y: frame.midY), $0.frame, false) }) {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// 前台 app 最前面那个普通窗口的位置（换算成 NSScreen 用的坐标）。
    /// 窗口列表按从前到后排；只读位置和所属进程，不读窗口标题，所以不需要「屏幕录制」权限
    private static func frontmostWindowFrame() -> NSRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in windows {
            // layer 0 是普通窗口；菜单栏、Dock、悬浮面板的 layer 都不是 0
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 50, rect.height > 50 // 跳过极小的隐藏窗口
            else { continue }
            // CG 坐标原点在主屏幕左上角、往下为正；NSScreen 原点在主屏幕左下角、往上为正
            let mainHeight = NSScreen.screens[0].frame.height
            return NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}

/// App 不在前台时，面板里的第一下点击默认只会「激活窗口」而不触发按钮，这里让第一下就生效
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 横幅内容：左边 App 图标，右边标题 + 正文，样式接近系统通知
private struct BannerView: View {
    let title: String
    let message: String
    let onClick: () -> Void
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(alignment: .center, spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // 毛玻璃底：和系统通知一样能透出后面的内容，比纯白底柔和
        .background(BlurBackground())
        .clipShape(shape)
        // 一圈很细的描边，让横幅在同色背景上也有边界
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(shape)
        .onTapGesture(perform: onClick)
        .clickable()
        // 左上角的关闭按钮（和系统通知同一个位置），鼠标放上来才出现
        .overlay(alignment: .topLeading) {
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(BlurBackground().clipShape(Circle()))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .clickable()
                .padding(5)
            }
        }
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
    }
}

/// 系统的毛玻璃效果（透出窗口后面的内容）。App 在后台时也保持毛玻璃，不变成灰色
private struct BlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
