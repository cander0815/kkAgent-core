// kkAgent 界面入口：一个主窗口 + 菜单栏图标。
// 界面只是核心的「遥控器」，退出界面不影响后台核心和正在进行的投递。
import SwiftUI

@main
struct KKAgentApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("kkAgent", id: "main") {
            RootView()
                .environmentObject(model)
                .appTextSize() // 正文字号（设置 → 显示）
                // 最小宽度要放得下：功能栏 64 + 群列表 220 + 对话 420 + 成员详情 360
                .frame(minWidth: 1080, minHeight: 600)
                .task { model.start() }
                // 程序坞图标：App 在运行就一直显示（关掉窗口也在），点它重新打开主窗口
        }

        // 单独窗口里的终端：成员详情里点「在单独的窗口里打开」，参数是 tmux 会话名（同一个会话只开一个窗口）
        WindowGroup("终端", id: "terminal", for: String.self) { $session in
            if let session { TerminalWindowView(session: session) }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            MenuBarLabel(online: model.coreOnline)
        }

        // ⌘, 打开：核心的状态和控制、用哪个终端
        Settings {
            TabView {
                CoreSettingsView().environmentObject(model)
                    .tabItem { Label("核心", systemImage: "cpu") }
                TerminalSettingsView()
                    .tabItem { Label("终端", systemImage: "terminal") }
                DisplaySettingsView()
                    .tabItem { Label("显示", systemImage: "textformat.size") }
            }
        }
    }
}

/// 顶部菜单栏里的「KK」字样。核心没在运行时变淡。
/// 菜单栏只认图片或纯文字，这里把文字画成模板图片，系统会按浅色 / 深色菜单栏自动着色
struct MenuBarLabel: View {
    let online: Bool

    var body: some View {
        Image(nsImage: Self.render(online: online))
    }

    private static func render(online: Bool) -> NSImage {
        let base = NSFont.systemFont(ofSize: 15, weight: .heavy)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 15) } ?? base
        let text = "KK" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(online ? 1 : 0.35)]
        // 图片只包住字母本身（高 = 大写字母高度），不留行高的上下空白，
        // 否则菜单栏会把整张图按栏高缩小，字就显得比旁边的图标小一圈
        let size = NSSize(width: ceil(text.size(withAttributes: attrs).width), height: ceil(font.capHeight))
        let image = NSImage(size: size, flipped: false) { _ in
            text.draw(at: NSPoint(x: 0, y: font.descender), withAttributes: attrs) // 基线对齐到图片底边
            return true
        }
        image.isTemplate = true
        return image
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.coreOnline ? "核心运行中" : "核心未运行")
        Text("群聊 \(model.groups.count) 个")
        Divider()
        Button("打开 kkAgent") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("核心设置…") }
        Button("退出界面（核心继续在后台运行）") { NSApp.terminate(nil) }
    }
}
