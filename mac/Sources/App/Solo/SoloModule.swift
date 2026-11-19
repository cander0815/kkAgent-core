// 左边栏「会话」：脱离群聊、直接选路径新建的单独会话（核心见 Core/Solo.swift，方案见 kktodo/单独会话-方案.md）。
// 只显示在这里创建、还没结束的会话。会话一直在后台的 tmux 里运行，只有点「销毁」或者在终端里 exit 才结束；
// 结束后会话记录还在，可以在上面的 Claude / Codex 会话浏览里看历史。
import AppKit
import SwiftUI

/// 「会话」页的数据：列表由 AppModel 每 2 秒拉一次交过来（见 apply）
@MainActor
final class SoloModel: ObservableObject {
    @Published private(set) var sessions: [SoloSession] = []
    @Published var selectedId: Int64?
    @Published var errorMessage: String?
    private let api = APIClient()

    var selected: SoloSession? { sessions.first { $0.id == selectedId } }

    // ---------- 会话名 ----------
    // 自己改的名字和 Claude / Codex 会话浏览共用一份（UserDefaults 的 sessionNames.<类型>，按会话 ID 存），哪边改两边都看得到。
    // 显示顺序：自己改的 > 会话里起的名字（Claude 的 /rename、Codex 桌面端的会话名）> 项目文件夹名
    @Published private var namesRevision = 0 // 改名后让界面刷新

    private func namesKey(_ agent: AgentKind) -> String { "sessionNames.\(agent.rawValue)" }

    func customName(_ s: SoloSession) -> String? {
        _ = namesRevision
        return Self.storedName(s)
    }

    func displayName(_ s: SoloSession) -> String {
        _ = namesRevision
        return Self.name(for: s)
    }

    /// 显示名（通知里也用，所以做成静态的，不依赖页面）
    static func name(for s: SoloSession) -> String {
        storedName(s) ?? (s.title.isEmpty ? projectName(s.cwd) : s.title)
    }

    private static func storedName(_ s: SoloSession) -> String? {
        guard !s.sessionId.isEmpty else { return nil }
        return (UserDefaults.standard.dictionary(forKey: "sessionNames.\(s.agent.rawValue)") as? [String: String])?[s.sessionId]
    }

    // ---------- 看过没有（见 SoloAttention.swift） ----------
    @Published private var readRevision = 0 // 记了已读后让界面刷新

    func isUnread(_ s: SoloSession) -> Bool {
        _ = readRevision
        return SoloReadState.isUnread(s)
    }

    /// 选中的会话正显示在用户眼前：把这份列表里它的那一轮记成看过（刷新后、换选中时调用）
    func markShownAsViewed() {
        guard let s = selected, s.state == "running", SoloReadState.isUnread(s), SoloViewTracker.shared.isViewing(s.id) else { return }
        SoloReadState.markViewed(s)
        readRevision += 1
    }

    /// 改名；留空等于恢复（用会话里起的名字或项目名）
    func rename(_ s: SoloSession, to name: String) {
        guard !s.sessionId.isEmpty else { return }
        var names = UserDefaults.standard.dictionary(forKey: namesKey(s.agent)) as? [String: String] ?? [:]
        let name = name.trimmingCharacters(in: .whitespaces)
        names[s.sessionId] = name.isEmpty ? nil : name
        UserDefaults.standard.set(names, forKey: namesKey(s.agent))
        namesRevision += 1
    }

    /// 新建、销毁之后马上拉一次（平时的 2 秒刷新由 AppModel 统一拉，再交给 apply）
    func refresh() async {
        guard let list: [SoloSession] = try? await api.get("/api/solo") else { return }
        apply(list)
    }

    /// 用最新的列表更新页面。内容没变就不重新赋值，免得整页重画
    func apply(_ list: [SoloSession]) {
        if list != sessions { sessions = list }
        // 选中的已经结束了（销毁或 exit）：选中第一个
        if selected == nil { selectedId = list.first?.id }
        markShownAsViewed()
    }

    /// 新建，成功后选中它。失败返回原因
    func create(agent: AgentKind, cwd: String) async -> String? {
        do {
            let created: SoloSession? = try await api.post("/api/solo", CreateSoloRequest(agent: agent, cwd: cwd))
            await refresh()
            if let created { selectedId = created.id }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 「继续沟通」：接着会话浏览里的一个已有会话打开（已经开着的话核心直接返回那一条），成功后选中它。失败返回原因
    func resume(_ session: SessionSummary) async -> String? {
        do {
            let request = CreateSoloRequest(agent: session.agent, cwd: session.cwd, sessionId: session.id, vm: session.vm)
            let opened: SoloSession? = try await api.post("/api/solo", request)
            await refresh()
            // 核心没返回会话（刚好结束了之类）不能当成功，不然切过去什么也没打开
            guard let opened else { return "核心没有返回打开的会话，请再点一次" }
            selectedId = opened.id
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func destroy(_ id: Int64) async {
        do {
            try await api.delete("/api/solo/\(id)")
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }
}

struct SoloModule: View {
    @ObservedObject var model: SoloModel
    @StateObject private var showCreate = LocalState(false)
    @StateObject private var toDestroy = LocalState<SoloSession?>(nil)
    @StateObject private var renaming = LocalState<SoloSession?>(nil) // 正在改名的会话，不为空时弹出改名框
    @StateObject private var nameText = LocalState("")

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 280)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 列表平时由 AppModel 每 2 秒拉一次交过来（会话 exit 后自动从列表消失）；打开页面时先补一次，不显示旧列表
        .task { await model.refresh() }
        // 换了选中的会话：等新终端显示出来再判断看过没有（不用等下一次刷新）
        .onChange(of: model.selectedId) { _, _ in
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                model.markShownAsViewed()
            }
        }
        .sheet(isPresented: $showCreate.value) { CreateSoloSheet(model: model) }
        .alert("给会话改名", isPresented: Binding(get: { renaming.value != nil }, set: { if !$0 { renaming.value = nil } })) {
            TextField("名字", text: $nameText.value)
            Button("确定") { if let s = renaming.value { model.rename(s, to: nameText.value) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("名字只在 kkAgent 里显示，Claude / Codex 会话浏览里也用这个名字。留空就恢复成会话里起的名字（Claude 里用 /rename 起的）或项目名。")
        }
        .confirmationDialog("销毁这个会话？", isPresented: Binding(get: { toDestroy.value != nil }, set: { if !$0 { toDestroy.value = nil } })) {
            Button("销毁", role: .destructive) {
                if let s = toDestroy.value { Task { await model.destroy(s.id) } }
            }
        } message: {
            Text(destroyMessage)
        }
        .alert("操作失败", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var destroyMessage: String {
        guard let s = toDestroy.value else { return "" }
        let bound = s.boundGroupName.isEmpty ? "" : "它现在在群聊「\(s.boundGroupName)」里（成员名 \(s.boundAlias)），销毁后会从群里移出。"
        return "会关掉它的进程。\(bound)会话记录保留，可以在 \(s.agent.displayName) 会话浏览里看历史。"
    }

    // ---------- 左边：列表 ----------

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("会话").font(.headline)
                    Text("\(model.sessions.count) 个在运行").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button { showCreate.value = true } label: { Label("新建会话", systemImage: "plus") }
                    .tip("选一个代码目录，新建一个在后台运行的 Claude / Codex 会话").clickable()
            }
            .padding(.horizontal, 12).frame(height: 56)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.sessions) { s in
                        SoloRow(session: s, name: model.displayName(s), unread: model.isUnread(s),
                                selected: model.selectedId == s.id) { model.selectedId = s.id }
                            .contextMenu {
                                Button("改名…") { startRename(s) }.disabled(s.sessionId.isEmpty)
                                if model.customName(s) != nil {
                                    Button("恢复原来的名字") { model.rename(s, to: "") }
                                }
                            }
                    }
                }
                .padding(8)
            }
            .overlay {
                if model.sessions.isEmpty {
                    Text("还没有会话。点「新建会话」，选一个代码目录就能开一个。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }

    // ---------- 右边：选中会话的终端 ----------

    @ViewBuilder
    private var detail: some View {
        if let s = model.selected {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    AgentTile(agent: s.agent, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(model.displayName(s)).font(.headline).lineLimit(1)
                            Button { startRename(s) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).disabled(s.sessionId.isEmpty)
                                .tip("给会话改名").clickable()
                        }
                        Text(subtitle(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(role: .destructive) { toDestroy.value = s } label: { Label("销毁", systemImage: "xmark.circle") }
                        .tip("关掉这个会话的进程（会话记录保留）").clickable()
                }
                .padding(.horizontal, 14).frame(height: 56) // 和左边列表的顶部一样高，分隔线才对得齐
                Divider()
                switch s.state {
                case "running":
                    // 每个会话一个独立的终端连接；切换会话时按 id 重建
                    // 和成员详情里的终端一样：白底圆角卡片，文字离卡片边留一点距离，卡片离页面边也留一点
                    TerminalWindowView(session: s.tmux).id(s.id)
                        .background(SoloViewProbe(id: s.id).id(s.id)) // 告诉「看过没有」的判断：现在显示的是它的终端
                        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
                        .background(Color(nsColor: TerminalStyle.body))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(TerminalStyle.border, lineWidth: 1))
                        .padding(14)
                case "failed":
                    centered("启动失败", s.error.isEmpty ? "可以销毁后重新新建。" : "原因：\(s.error)\n可以销毁后重新新建。")
                default:
                    centered("正在启动…", s.agent == .codex
                             ? "先跑一轮把 Codex 会话建出来，再在终端里打开，一般十几秒到一分钟。"
                             : "正在虚拟机里启动 Claude，界面就绪后这里就能直接交互。")
                }
            }
        } else {
            centered("没有选中的会话", "左边点「新建会话」，选一个代码目录开一个在后台运行的会话。")
        }
    }

    private func startRename(_ s: SoloSession) {
        nameText.value = model.displayName(s)
        renaming.value = s
    }

    private func subtitle(_ s: SoloSession) -> String {
        let machine = s.vm.isEmpty ? "物理机" : "虚拟机"
        let group = s.boundGroupName.isEmpty ? "" : " · 在群聊「\(s.boundGroupName)」里（\(s.boundAlias)）"
        return "\(shortPath(s.cwd)) · \(s.agent.displayName) · \(machine) · \(s.tmux)\(group)"
    }

    private func centered(_ title: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title3)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 列表里的一行：类型、会话名、状态
private struct SoloRow: View {
    let session: SoloSession
    let name: String
    let unread: Bool // 有这一轮的结果还没看过：名字右边显示小红点
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AgentTile(agent: session.agent, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).lineLimit(1)
                    Text(status).font(.caption).foregroundStyle(statusColor).lineLimit(1)
                }
                Spacer(minLength: 0)
                if unread {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(session.agent == .codex ? "\(session.cwd)\nCodex 暂不检测人工审批" : session.cwd)
        .clickable()
    }

    /// 状态一行：先看现在在干什么（需要授权、执行中），再看最近一轮怎么结束的，都没有就是普通的「运行中」
    private var status: String {
        switch session.state {
        case "running": break
        case "failed": return "启动失败"
        default: return "正在启动…"
        }
        let group = session.boundGroupName.isEmpty ? "" : " · 在群聊「\(session.boundGroupName)」里"
        let ended = session.lastEndedAt.isEmpty ? "" : " · \(TimeText.time(session.lastEndedAt))"
        switch session.activity {
        case "waitingPermission": return "需要授权\(group)"
        case "working": return "执行中\(group)"
        default: break
        }
        switch session.lastOutcome {
        case "completed": return "这一轮已结束\(ended)\(group)"
        case "failed": return "这一轮出错了\(ended)\(group)"
        case "interrupted": return "已打断\(ended)\(group)"
        default: return session.boundGroupName.isEmpty ? "运行中 · \(TimeText.time(session.createdAt)) 创建" : "运行中\(group)"
        }
    }

    private var statusColor: Color {
        switch session.state {
        case "running": break
        case "failed": return .red
        default: return .orange
        }
        if session.activity == "waitingPermission" { return .orange }
        if session.activity == "working" { return .blue }
        return session.lastOutcome == "failed" ? .red : .secondary
    }
}

/// 新建单独会话：第一步选工作目录，再选类型
private struct CreateSoloSheet: View {
    @ObservedObject var model: SoloModel
    @Environment(\.dismiss) private var dismiss
    /// 上次用的目录，下次默认填上
    @AppStorage("soloLastCwd") private var lastCwd = ""
    @StateObject private var cwd = LocalState("")
    @StateObject private var agent = LocalState(AgentKind.claude)
    @StateObject private var error = LocalState("")
    @StateObject private var submitting = LocalState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建会话").font(.title3)
            Form {
                HStack {
                    TextField("工作目录", text: $cwd.value, prompt: Text("会话在哪个代码目录里工作"))
                    Button("选择文件夹…", action: pickFolder).clickable()
                }
                Picker("类型", selection: $agent.value) {
                    ForEach(AgentKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .clickable()
            }
            Text(agent.value == .claude
                 ? "Claude 建在虚拟机里（目录要在 /Users 下）。会话一直在后台运行，点「销毁」或在终端里 exit 才结束。"
                 : "Codex 建在物理机上，会先跑一轮把会话建出来。会话一直在后台运行，点「销毁」或在终端里 exit 才结束。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !error.value.isEmpty {
                Text(error.value).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).clickable()
                Button("新建", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cwd.value.trimmingCharacters(in: .whitespaces).isEmpty || submitting.value)
                    .clickable()
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { if cwd.value.isEmpty { cwd.value = lastCwd } }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        let current = (cwd.value as NSString).expandingTildeInPath
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current) }
        if panel.runModal() == .OK, let url = panel.url { cwd.value = url.path }
    }

    private func create() {
        let path = cwd.value.trimmingCharacters(in: .whitespaces)
        submitting.value = true
        Task {
            let failure = await model.create(agent: agent.value, cwd: path)
            submitting.value = false
            if let failure {
                error.value = failure
            } else {
                lastCwd = path
                dismiss()
            }
        }
    }
}
