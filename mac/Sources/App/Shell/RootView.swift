// 外壳：最左边是功能栏，右边是当前功能的内容。
// 以后加新功能：在 AppModule 里加一项，在 moduleContent 里接上它的页面即可，不影响已有功能。
import SwiftUI

/// app 里的功能模块
enum AppModule: String, CaseIterable, Identifiable {
    case groupChat
    case solo           // 单独会话：直接选路径新建、在后台 tmux 里运行的会话（见 Solo/SoloModule.swift）
    case claudeSessions // 浏览 Claude 历史会话（物理机 / 虚拟机）
    case codexSessions  // 浏览 Codex 历史会话
    case tunnels        // ssh 端口转发（见 Tunnels/，不依赖核心）

    var id: String { rawValue }

    var title: String {
        switch self {
        case .groupChat: return "群聊"
        case .solo: return "会话"
        case .claudeSessions: return "Claude"
        case .codexSessions: return "Codex"
        case .tunnels: return "端口"
        }
    }

    var icon: String {
        switch self {
        case .groupChat: return "bubble.left.and.bubble.right"
        case .solo: return "terminal"
        case .claudeSessions: return "text.bubble"
        case .codexSessions: return "chevron.left.forwardslash.chevron.right"
        case .tunnels: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var module = LocalState(AppModule.groupChat)
    // 会话浏览的状态放在这里，切到别的功能再切回来，选中的会话和已读的内容还在
    @StateObject private var claudeSessions = SessionBrowserModel(agent: .claude)
    @StateObject private var codexSessions = SessionBrowserModel(agent: .codex)
    @StateObject private var soloSessions = SoloModel()

    var body: some View {
        HStack(spacing: 0) {
            ModuleRail(selection: $module.value)
            Divider()
            moduleContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("操作失败", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // 点授权通知时：窗口关着要能重新打开它；不在群聊页的话切回群聊页
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        .onChange(of: model.focusRequests) { _, _ in module.value = .groupChat }
        // 点单独会话的通知时：切到「会话」页选中它
        .onChange(of: model.soloFocusRequests) { _, _ in
            module.value = .solo
            if let id = model.soloFocusTarget { soloSessions.selectedId = id }
        }
    }

    /// 会话浏览里点「继续沟通」：交给「会话」页接着这个会话打开，成功就切过去。失败返回原因
    private func continueSession(_ session: SessionSummary) async -> String? {
        let failure = await soloSessions.resume(session)
        if failure == nil { module.value = .solo }
        return failure
    }

    /// 会话浏览里右键项目「在这里新建会话」：交给「会话」页在这个目录新建，成功就切过去。失败返回原因
    private func newSession(agent: AgentKind, cwd: String) async -> String? {
        let failure = await soloSessions.create(agent: agent, cwd: cwd)
        if failure == nil { module.value = .solo }
        return failure
    }

    @ViewBuilder
    private var moduleContent: some View {
        if module.value == .tunnels {
            TunnelsModule() // 端口转发是 app 自己起 ssh，不依赖核心
        } else if !model.coreOnline {
            CoreOfflineView() // 其余功能都依赖核心，核心不在时统一提示
        } else {
            switch module.value {
            case .groupChat: GroupChatModule()
            case .solo: SoloModule(model: soloSessions)
            case .claudeSessions: SessionsModule(browser: claudeSessions, continueSession: continueSession,
                                                 newSession: { await newSession(agent: .claude, cwd: $0) })
            case .codexSessions: SessionsModule(browser: codexSessions, continueSession: continueSession,
                                                newSession: { await newSession(agent: .codex, cwd: $0) })
            case .tunnels: EmptyView() // 上面已经单独处理，这里只是让 switch 完整
            }
        }
    }
}

/// 最左边的功能栏：上面是功能，最下面是核心状态（点开就是核心设置）
struct ModuleRail: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: AppModule
    @ObservedObject private var tunnels = TunnelManager.shared

    /// 功能图标右上角的状态点：「端口」有隧道连通是绿点，开着但还没连通（连接中、重试中）是橙点，全关不显示
    private func badge(for item: AppModule) -> Color? {
        guard item == .tunnels else { return nil }
        let states = TunnelSpec.all.map { tunnels.state($0) }
        if states.contains(.running) { return .green }
        if states.contains(where: { if case .retrying = $0 { return true } else { return $0 == .connecting } }) { return .orange }
        return nil
    }

    /// 功能图标右上角的数字：「会话」显示开着几个单独会话，0 个不显示
    private func count(for item: AppModule) -> Int? {
        guard item == .solo, model.openSoloCount > 0 else { return nil }
        return model.openSoloCount
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(AppModule.allCases) { item in
                Button { selection = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon).font(.system(size: 17))
                            .overlay(alignment: .topTrailing) {
                                if let color = badge(for: item) {
                                    Circle().fill(color)
                                        .frame(width: 8, height: 8)
                                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                                        .offset(x: 5, y: -3)
                                }
                                if let count = count(for: item) {
                                    // 角标左边固定在图标右上角往里 7pt，位数多了往右长，不会盖住图标
                                    CountBadge(count: count, tint: selection == item ? Color.accentColor : .secondary)
                                        .alignmentGuide(.trailing) { $0[.leading] + 7 }
                                        .offset(y: -6)
                                }
                            }
                        Text(item.title).font(.system(size: 10))
                    }
                    .frame(width: 52, height: 48)
                    .foregroundStyle(selection == item ? Color.accentColor : .secondary)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selection == item ? Color.accentColor.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
                .help(item.title)
            }
            Spacer()
            SettingsLink {
                VStack(spacing: 3) {
                    Circle().fill(model.coreOnline ? Color.green : Color.red).frame(width: 8, height: 8)
                    Text("核心").font(.system(size: 10))
                }
                .frame(width: 52, height: 40)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle()) // 整块都能点，不只是圆点和文字
            }
            .buttonStyle(.plain)
            .clickable()
            .help(model.coreOnline ? "核心运行中，点开查看和控制" : "核心没有运行，点开启动")
        }
        .padding(.vertical, 10)
        .frame(width: 64)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }
}

/// 功能图标右上角的数字角标（「开着几个」这种计数，不是提醒）。
/// 底色跟着图标走：没选中是灰色、选中是强调色，不用红色，红色留给要人处理的事；
/// 数字和外圈用窗口背景色，深色 / 浅色模式下都自动反色。个位数是圆形，位数多了自动变宽
struct CountBadge: View {
    let count: Int
    let tint: Color

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 3.5)
            .frame(minWidth: 14, minHeight: 14)
            .background(Capsule().fill(tint))
            .overlay(Capsule().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .fixedSize()
    }
}

/// 连不上核心时显示：告诉用户怎么把核心拉起来
struct CoreOfflineView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var output = LocalState("")

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle").font(.system(size: 40)).foregroundStyle(.orange)
            Text("kkAgent 核心没有运行").font(.title3)
            Text("Agent 之间的消息都由核心转发。启动后这里会自动恢复。").foregroundStyle(.secondary)
            Button("启动核心") { output.value = CoreControl.start() ?? "已发出启动指令，几秒后自动连上" }
                .controlSize(.large)
                .clickable()
            if !output.value.isEmpty {
                Text(output.value).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
