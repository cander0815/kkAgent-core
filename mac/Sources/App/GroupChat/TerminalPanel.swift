// 成员详情里内嵌的终端：接入 tmux 里常驻的 coder / tester 会话，在 App 里直接看、直接打字。
//
// - 后台跑的就是 `tmux attach -t <会话名>`：关掉面板只是断开这一个连接，agent 照常跑，不会另开一个 agent；
// - 终端控件用第三方库 SwiftTerm（源码在 mac/Vendor/SwiftTerm），打开面板时才创建，关掉就释放；
// - 历史记录在 tmux 那边（滚轮翻历史靠 tmux 的鼠标模式），这里不需要保留很多回滚行。
import AppKit
import SwiftTerm
import SwiftUI

/// 包一层 SwiftTerm 的终端控件，里面跑 tmux attach
struct TmuxTerminalView: NSViewRepresentable {
    let session: String
    /// 连接断开时调用（tmux 会话没了、或者里面的程序退出了）
    var onDisconnect: () -> Void = {}
    // 字体、字号、光标形状（在「设置 → 终端」里改，见 TerminalAppearance）
    @AppStorage(TerminalAppearance.fontKey) private var fontFamily = TerminalAppearance.defaultFamily
    @AppStorage(TerminalAppearance.sizeKey) private var fontSize = TerminalAppearance.defaultSize
    @AppStorage(TerminalAppearance.cursorKey) private var cursor = TerminalAppearance.Cursor.bar

    func makeCoordinator() -> Coordinator { Coordinator(onDisconnect: onDisconnect) }

    func makeNSView(context: Context) -> KKTerminalView {
        let view = KKTerminalView(frame: .zero)
        view.font = TerminalAppearance.font(family: fontFamily, size: fontSize)
        view.cursor = cursor
        // 白天主题的终端（颜色见 TerminalStyle），和外面的卡片底色一致
        view.nativeBackgroundColor = TerminalStyle.body
        view.nativeForegroundColor = TerminalStyle.text
        view.processDelegate = context.coordinator
        // 先只给这一个 tmux 会话设置：隐藏底部状态栏、打开鼠标（滚轮翻历史）、窗口大小跟着最近操作的那个客户端走
        // （外部终端也 attach 着时，不会被挤成最小的那一个），然后接入
        let tmux = Self.tmuxPath
        let name = Self.quote(session)
        // 唯一的全局设置是 set-clipboard on（用户同意过）：会话里的 Claude 自己占着鼠标，拖选后用 OSC 52 写剪贴板，
        // tmux 默认的 external 会把这条丢掉，改成 on 才能穿过 tmux 到这里、写进系统剪贴板
        let script = ["status off", "mouse on", "window-size latest"]
            .map { "\(tmux) set-option -t \(name) \($0) >/dev/null 2>&1" }
            .joined(separator: "; ") + "; \(tmux) set-option -s set-clipboard on >/dev/null 2>&1"
            + "; exec \(tmux) attach -t \(name)"
        // 中文要正常显示，得给 tmux 一个 UTF-8 的语言环境（从程序坞打开的 App 不带终端里的这些环境变量）
        let environment = Terminal.getEnvironmentVariables(termName: "xterm-256color") + ["LANG=en_US.UTF-8", "LC_CTYPE=en_US.UTF-8"]
        view.startProcess(executable: "/bin/sh", args: ["-c", script], environment: environment)
        return view
    }

    /// 设置里改了外观：开着的终端马上换（tmux 会按新的字宽自动重排行列）
    func updateNSView(_ nsView: KKTerminalView, context: Context) {
        let font = TerminalAppearance.font(family: fontFamily, size: fontSize)
        if nsView.font != font { nsView.font = font }
        if nsView.cursor != cursor { nsView.cursor = cursor }
    }

    /// 给多大就用多大。SwiftTerm 的控件会按「列数 × 字宽」报告自己想要的宽度（80 列约 600pt），
    /// 不拦下来的话，会把 360 宽的右栏整个撑出窗口（右边的按钮被截掉）。终端列数会跟着实际宽度自动调整
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KKTerminalView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    /// 面板关掉、或者切到别的成员时：结束这个 attach 客户端（tmux 里的会话不受影响）
    static func dismantleNSView(_ nsView: KKTerminalView, coordinator: Coordinator) {
        let pid = nsView.process.shellPid
        nsView.terminate()
        if pid > 0 { reap(pid) }
    }

    /// 回收结束掉的 attach 客户端进程。SwiftTerm 的 terminate 只发 SIGTERM、不回收，不处理的话会留下僵尸进程、占着 PTY。
    /// 只针对这一个自己启动的进程（sh 已经 exec 成了 tmux attach），不碰 tmux 服务端和会话里的 agent：
    /// 最多等 2 秒让它自己退出，还不退就强制结束，再回收
    private static func reap(_ pid: pid_t) {
        DispatchQueue.global().async {
            var status: Int32 = 0
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || (result == -1 && errno == ECHILD) { return } // 回收了，或者已经被别处回收
                Thread.sleep(forTimeInterval: 0.05)
            }
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onDisconnect: () -> Void
        init(onDisconnect: @escaping () -> Void) { self.onDisconnect = onDisconnect }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { self.onDisconnect() }
        }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }

    /// 从程序坞打开的 App 拿不到终端里的 PATH，直接按常见安装位置找 tmux
    static var tmuxPath: String {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "tmux"
    }

    /// 给 shell 用的单引号转义
    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 终端卡片的配色：默认白天主题（浅底深字），颜色取自设计稿里 App 自己的浅色变量（kktodo/第5步-界面设计稿.html）。
/// 注意：这个文件 import 了 SwiftTerm，它也有个 Color 类型，所以这里的 Color 都要写成 SwiftUI.Color
enum TerminalStyle {
    static let body = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)                              // #ffffff 终端底色
    static let text = NSColor(srgbRed: 0x24 / 255, green: 0x24 / 255, blue: 0x2A / 255, alpha: 1)   // #24242a 终端文字
    static let head = SwiftUI.Color(red: 0xF3 / 255, green: 0xF3 / 255, blue: 0xF5 / 255)           // #f3f3f5 头部
    static let foot = SwiftUI.Color(red: 0xF8 / 255, green: 0xF8 / 255, blue: 0xFA / 255)           // #f8f8fa 底部
    static let border = SwiftUI.Color(red: 0xE4 / 255, green: 0xE4 / 255, blue: 0xE8 / 255)         // #e4e4e8 边框和分隔线
    static let headText = SwiftUI.Color(red: 0x4A / 255, green: 0x4A / 255, blue: 0x52 / 255)       // #4a4a52 头部文字
    static let footText = SwiftUI.Color(red: 0x79 / 255, green: 0x79 / 255, blue: 0x82 / 255)       // #797982 底部文字
}

/// 成员详情里的「终端」标签页：一张圆角卡片，头部（连接状态、单独开窗口、收起）+ 终端 + 底部的边界说明
struct MemberTerminalPane: View {
    @EnvironmentObject private var model: AppModel
    let item: MemberDetail
    @Environment(\.openWindow) private var openWindow
    /// 收起终端（不想看时收起来，省得一直占着一个 attach 连接）
    @AppStorage("terminalCollapsed") private var collapsed = false
    /// 连接断开后，点「重新连接」时换一个新的 id，让终端控件重建
    @StateObject private var connection = LocalState(UUID())
    @StateObject private var disconnected = LocalState(false)
    /// 点了「重新打开会话」、请求还没回来
    @StateObject private var submitting = LocalState(false)
    /// 这次打开请求的序号（核心返回的）；nil = 没有在等的打开请求
    @StateObject private var requested = LocalState<Int?>(nil)

    private var member: Member { item.member }
    /// tmux 会话在不在（在终端里 exit 了就不在了）
    private var running: Bool { item.state.tmuxRunning }
    /// 这次打开失败了：核心记下的失败是这次（或更晚的）请求的。每次刷新都直接比较，不靠「失败原因有没有变」——
    /// 同样的错误连续出现两次时，界面可能根本看不到中间的变化
    private var openFailed: Bool {
        guard let seq = requested.value else { return false }
        return item.state.openErrorSeq >= seq && !item.state.openError.isEmpty
    }
    /// 正在打开：请求还没回来，或者请求回来了、会话还没起来也还没报失败
    private var opening: Bool { submitting.value || (requested.value != nil && !openFailed) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(member.tmux).font(Theme.code)
                if !collapsed {
                    Label(!running ? "没在运行" : disconnected.value ? "已断开" : "已连接", systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon).font(.caption2)
                        .foregroundStyle(running && !disconnected.value ? SwiftUI.Color.green : TerminalStyle.footText)
                }
                Spacer()
                Button { openWindow(id: "terminal", value: member.tmux) } label: { Image(systemName: "macwindow.on.rectangle") }
                    .buttonStyle(.borderless).tip("在单独的窗口里打开").clickable()
                Button { collapsed.toggle() } label: { Image(systemName: collapsed ? "chevron.down" : "chevron.up") }
                    .buttonStyle(.borderless).tip(collapsed ? "展开终端" : "收起终端").clickable()
            }
            .foregroundStyle(TerminalStyle.headText)
            .padding(.horizontal, 11).frame(height: 34)
            .background(TerminalStyle.head)
            TerminalStyle.border.frame(height: 1)

            Group {
                if collapsed {
                    VStack(spacing: 8) {
                        Text("终端已收起，agent 继续运行").font(.callout)
                        Text("重新展开后，接着看它的执行过程。").font(.caption).foregroundStyle(TerminalStyle.footText)
                        Button("展开终端") { collapsed = false }.clickable()
                    }
                    .foregroundStyle(TerminalStyle.headText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !running {
                    // 会话没了（比如在终端里 exit 了）：可以重新打开，接着原来的会话
                    VStack(spacing: 8) {
                        Text(opening ? "正在打开会话…" : "会话没在运行").font(.callout)
                        Text(opening ? "要等它的界面就绪，一般几秒到几十秒。"
                             : "可能是在终端里退出了。重新打开会接着原来的会话，之前的上下文都在；不点的话，下一条消息投递时核心也会打开它。")
                            .font(.caption).foregroundStyle(TerminalStyle.footText).multilineTextAlignment(.center)
                        if !opening && !item.state.openError.isEmpty {
                            Text("上次没打开：\(item.state.openError)").font(.caption).foregroundStyle(.red)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }
                        if !opening {
                            Button("重新打开会话") {
                                submitting.value = true
                                let memberId = member.id
                                Task {
                                    // 请求本身失败（连不上核心等）时序号是 nil，按钮会恢复，AppModel 会弹窗说明原因
                                    let seq = await model.openSession(memberId: memberId)
                                    // 请求返回前 AppModel 已经刷新过一次，会话可能已经起来了：那就不用再等这次请求的结果。
                                    // 要读最新的成员状态（这个闭包里捕获的 item 是点按钮那一刻的旧数据）
                                    let nowRunning = model.detail?.members.first { $0.member.id == memberId }?.state.tmuxRunning ?? false
                                    requested.value = nowRunning ? nil : seq
                                    submitting.value = false
                                }
                            }.clickable()
                        }
                    }
                    .foregroundStyle(TerminalStyle.headText)
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if disconnected.value {
                    VStack(spacing: 8) {
                        Text("连接已断开").font(.callout)
                        Button("重新连接") {
                            disconnected.value = false
                            connection.value = UUID()
                        }.clickable()
                    }
                    .foregroundStyle(TerminalStyle.headText)
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 终端区域保持系统默认的 I 形光标（项目规则：能输入文字的地方不改鼠标形状）。四周留一点内边距
                    TmuxTerminalView(session: member.tmux) { disconnected.value = true }
                        .id(connection.value)
                        // 绑着单独会话的成员：在群里看着它的终端，也算看着那个单独会话（「会话」页的红点、结束通知跟着生效）
                        .background {
                            if member.soloId != 0 { SoloViewProbe(id: member.soloId).id(member.soloId) }
                        }
                        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(SwiftUI.Color(nsColor: TerminalStyle.body))
            // 会话重新起来了（点了「重新打开会话」，或者投递时核心打开了它）：自动连上
            .onChange(of: running) { _, isRunning in
                // 不管是打开了，还是又没了（比如再次 exit）：之前的打开请求都已经结束，不能带到下一次
                requested.value = nil
                guard isRunning else { return }
                disconnected.value = false
                connection.value = UUID()
            }

            TerminalStyle.border.frame(height: 1)
            Text("关闭面板只断开连接，agent 会继续运行。准备手动操作时，建议先暂停自动投递；"
                 + "在外部终端里 attach 做的操作核心监控不到，回车前会复核输入框，但仍可能和自动投递撞在一起。")
                .font(.caption2).foregroundStyle(TerminalStyle.footText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(TerminalStyle.foot)
        }
        // 圆角卡片，四周留出边距（照设计稿：左右 14）
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(TerminalStyle.border, lineWidth: 1))
        .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 12)
    }
}

/// 单独窗口里的终端（从成员详情点「在单独的窗口里打开」）。和面板里的是两个独立的 attach 连接，可以同时开着
struct TerminalWindowView: View {
    let session: String
    @StateObject private var connection = LocalState(UUID())
    @StateObject private var disconnected = LocalState(false)

    var body: some View {
        Group {
            if disconnected.value {
                VStack(spacing: 8) {
                    Text("连接已断开").font(.callout)
                    Button("重新连接") {
                        disconnected.value = false
                        connection.value = UUID()
                    }.clickable()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TmuxTerminalView(session: session) { disconnected.value = true }.id(connection.value)
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .navigationTitle("终端 · \(session)")
    }
}
