// 会话浏览功能（左边功能栏的「Claude」「Codex」）：会话列表（按项目分组）| 会话全部内容。
//
// 视觉规则（和 Theme.swift 一致）：颜色只用来分清「谁」。
//   Claude 页的主色是紫罗兰，Codex 页是青绿，「我」用系统强调色；
//   项目、时间、工具调用这些辅助信息一律用中性灰，不抢眼。
import SwiftUI

struct SessionsModule: View {
    @ObservedObject var browser: SessionBrowserModel
    let continueSession: (SessionSummary) async -> String? // 「继续沟通」，返回失败原因
    let newSession: (String) async -> String?              // 右键项目「在这里新建会话」，参数是项目目录，返回失败原因

    var body: some View {
        HStack(spacing: 0) {
            SessionListColumn(browser: browser, newSession: newSession).frame(width: 300)
            Divider()
            if let session = browser.selected {
                SessionDetailView(browser: browser, session: session, continueSession: continueSession).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SessionEmptyState(agent: browser.agent).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await browser.loadList() } // 每次切到这个功能都刷新一次列表
    }
}

// ---------- 两个页面共用的小部件 ----------

extension AgentKind {
    /// 和左边功能栏里的图标保持一致
    var sessionIcon: String { self == .claude ? "text.bubble" : "chevron.left.forwardslash.chevron.right" }
}

/// 页面标识：主色的圆角方块 + 白色图标
struct AgentTile: View {
    let agent: AgentKind
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: agent.sessionIcon)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28).fill(Theme.color(agent).gradient))
    }
}

/// 把 /Users/xxx/... 或虚拟机里的 /home/xxx/... 缩写成 ~/...
func shortPath(_ path: String) -> String {
    path.replacingOccurrences(of: "^/(Users|home)/[^/]+", with: "~", options: .regularExpression)
}

/// 项目名：工作目录的最后一级，比如 /Users/xxx/work/demo → demo
func projectName(_ cwd: String) -> String {
    cwd.isEmpty ? "未知目录" : (cwd as NSString).lastPathComponent
}

/// 还没选会话时
struct SessionEmptyState: View {
    let agent: AgentKind

    var body: some View {
        VStack(spacing: 14) {
            AgentTile(agent: agent, size: 52).opacity(0.85)
            Text("选一个会话").font(.title3.weight(.semibold))
            Text("左边按项目分好了组，点开项目就能看到里面的会话。\n也可以直接搜标题、目录或会话 ID。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

// ---------- 左栏：会话列表 ----------

/// 同一个项目（工作目录）下的会话
private struct ProjectGroup: Identifiable {
    let cwd: String
    let sessions: [SessionSummary]
    var id: String { cwd }
}

struct SessionListColumn: View {
    @ObservedObject var browser: SessionBrowserModel
    let newSession: (String) async -> String?
    @StateObject private var newSessionError = LocalState<String?>(nil) // 新建失败的原因，不为空时弹窗
    @StateObject private var search = LocalState("")
    @StateObject private var dropTarget = LocalState<String?>(nil) // 拖动时鼠标正停在哪个项目上
    @StateObject private var nameEdit = LocalState<NameEdit?>(nil) // 正在起名字的对象，不为空时弹出起名框
    @StateObject private var nameText = LocalState("")             // 起名框里的文字

    private var color: Color { Theme.color(browser.agent) }
    private var keyword: String { search.value.trimmingCharacters(in: .whitespaces) }

    /// 会话是否符合搜索词（标题按改过的名字搜）
    private func matches(_ session: SessionSummary) -> Bool {
        keyword.isEmpty || browser.displayTitle(session).localizedCaseInsensitiveContains(keyword)
            || session.cwd.localizedCaseInsensitiveContains(keyword) || session.id.localizedCaseInsensitiveContains(keyword)
            || (session.groups ?? []).contains { $0.localizedCaseInsensitiveContains(keyword) } // 在 kkAgent 里用过的群名
    }

    /// 打开起名框
    private func startEdit(_ edit: NameEdit, text: String) {
        nameText.value = text
        nameEdit.value = edit
    }

    /// 所有项目的显示顺序（不受搜索影响）：先按最近使用，再套用用户拖出来的顺序
    private var projectOrder: [String] {
        var recent: [String] = []
        var seen = Set<String>()
        for s in browser.sessions where seen.insert(s.cwd).inserted { recent.append(s.cwd) } // 列表本来就是新的在前
        return browser.sortProjects(recent)
    }

    /// 按搜索词过滤后按项目分组；打开了「隐藏子群 worktree」时去掉那些项目
    private var groups: [ProjectGroup] {
        let matched = browser.sessions.filter(matches)
        let byCwd = Dictionary(grouping: matched, by: \.cwd)
        return projectOrder
            .filter { !browser.hideWorktrees || !SessionBrowserModel.isWorktree($0) }
            .compactMap { cwd in byCwd[cwd].map { ProjectGroup(cwd: cwd, sessions: $0) } }
    }

    /// kkAgent 子群建的 worktree 项目有几个（不受搜索影响，开关的提示里用）
    private var worktreeCount: Int {
        projectOrder.filter(SessionBrowserModel.isWorktree).count
    }

    /// 搜索时全部展开，否则搜到的会话藏在收起的项目里看不见
    private func isExpanded(_ cwd: String) -> Bool {
        !keyword.isEmpty || browser.expandedProjects.contains(cwd)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 8) {
                if browser.agent == .claude { machineSwitch }
                TextField("搜索标题、目录、群名或会话 ID", text: $search.value).textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Divider()

            let list = groups
            let order = projectOrder
            let canReorder = keyword.isEmpty // 搜索时只显示了一部分项目，不允许拖
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(list) { group in
                        ProjectHeader(group: group, expanded: isExpanded(group.cwd), color: color,
                                      canReorder: canReorder, isDropTarget: dropTarget.value == group.cwd) {
                            if browser.expandedProjects.contains(group.cwd) {
                                browser.expandedProjects.remove(group.cwd)
                            } else {
                                browser.expandedProjects.insert(group.cwd)
                            }
                        }
                        .modifier(ProjectReorder(enabled: canReorder, cwd: group.cwd, order: order,
                                                 browser: browser, dropTarget: dropTarget,
                                                 newFolder: { startEdit(.newFolder(cwd: group.cwd, moving: nil), text: "") },
                                                 newSession: { createSession(in: group.cwd) }))
                        if isExpanded(group.cwd) { projectContent(group) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .overlay {
                if list.isEmpty && !browser.loadingList {
                    Text(browser.sessions.isEmpty ? "这台机器上还没有会话" : "没有匹配的会话，换个词试试")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
        .alert(nameEdit.value?.title ?? "", isPresented: Binding(
            get: { nameEdit.value != nil },
            set: { if !$0 { nameEdit.value = nil } }
        )) {
            TextField("名字", text: $nameText.value)
            Button("确定") { nameEdit.value?.apply(nameText.value, browser: browser) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(nameEdit.value?.hint ?? "")
        }
        .alert("没能新建会话", isPresented: Binding(get: { newSessionError.value != nil }, set: { if !$0 { newSessionError.value = nil } })) {
            Button("好") { newSessionError.value = nil }
        } message: {
            Text(newSessionError.value ?? "")
        }
    }

    /// 右键项目「在这里新建会话」：直接用项目目录新建，成功后会切到「会话」页
    private func createSession(in cwd: String) {
        Task {
            if let failure = await newSession(cwd) { newSessionError.value = failure }
        }
    }

    /// 一行会话，带右键菜单（改名、移到文件夹）。indent 是左边缩进，文件夹里的会话缩进更多
    private func sessionRow(_ session: SessionSummary, indent: CGFloat = 33) -> some View {
        SessionRow(title: browser.displayTitle(session), updatedAt: session.updatedAt,
                   selected: browser.selected?.id == session.id, color: color, indent: indent) {
            browser.select(session)
        }
        .contextMenu { SessionMenu(browser: browser, session: session, edit: startEdit) }
    }

    /// 展开的项目里：先是这个项目下的文件夹，再是没放进文件夹的会话。
    /// 搜索时只显示有匹配会话的文件夹，并且全部展开
    @ViewBuilder
    private func projectContent(_ group: ProjectGroup) -> some View {
        let folders = browser.folders(in: group.cwd)
        let folderIds = Set(folders.map(\.id))
        ForEach(folders) { folder in
            let items = group.sessions.filter { browser.folderOf[$0.id] == folder.id }
            if keyword.isEmpty || !items.isEmpty {
                let expanded = !keyword.isEmpty || !browser.collapsedFolders.contains(folder.id)
                FolderHeader(folder: folder, count: items.count, expanded: expanded, color: color) {
                    if browser.collapsedFolders.contains(folder.id) {
                        browser.collapsedFolders.remove(folder.id)
                    } else {
                        browser.collapsedFolders.insert(folder.id)
                    }
                }
                .contextMenu {
                    Button("改名…") { startEdit(.folder(folder), text: folder.name) }
                    Button("删除文件夹（里面的会话不受影响）", role: .destructive) { browser.deleteFolder(folder.id) }
                }
                if expanded {
                    // 缩进到文件夹名下面，和外面没放进文件夹的会话明显错开
                    ForEach(items) { session in sessionRow(session, indent: 64) }
                    if items.isEmpty {
                        Text("右键会话，选「移到文件夹」就能放进来")
                            .font(.caption).foregroundStyle(.tertiary)
                            .padding(.leading, 64).padding(.vertical, 4)
                    }
                }
            }
        }
        ForEach(group.sessions.filter { !folderIds.contains(browser.folderOf[$0.id] ?? "") }) { session in
            sessionRow(session)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AgentTile(agent: browser.agent)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(browser.agent.displayName) 会话").font(.headline)
                Text("\(browser.sessions.count) 个会话，\(groups.count) 个项目")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if browser.loadingList { ProgressView().controlSize(.small) }
            // 隐藏 / 显示 kkAgent 集群子群建的 worktree 项目（每个子群一个，多了会把自己的项目挤下去）
            Button { browser.hideWorktrees.toggle() } label: {
                Image(systemName: browser.hideWorktrees ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .tip(browser.hideWorktrees
                 ? "已隐藏 \(worktreeCount) 个子群建的 worktree 项目，点一下显示"
                 : "隐藏子群建的 worktree 项目（\(worktreeCount) 个，在 .worktrees 或 -kkwt 目录下）")
            .clickable()
            Button { Task { await browser.loadList() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).tip("刷新列表").clickable()
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
    }

    /// 物理机 / 虚拟机切换：选中的一段用主色填满
    @ViewBuilder
    private var machineSwitch: some View {
        HStack(spacing: 2) {
            machineButton(name: "", label: "物理机", icon: "desktopcomputer")
            ForEach(browser.vms, id: \.self) { name in
                // 只有一台虚拟机时直接叫「虚拟机」，机器名太长放不下（悬停能看到全名）
                machineButton(name: name, label: browser.vms.count == 1 ? "虚拟机" : name, icon: "shippingbox")
            }
            if browser.vms.isEmpty {
                machineButton(name: nil, label: "虚拟机", icon: "shippingbox")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        if browser.vms.isEmpty {
            Text("虚拟机没开着，开机后点右上角刷新就能看到里面的会话")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// name 为 nil 表示这台机器现在用不了（虚拟机没开），按钮置灰
    private func machineButton(name: String?, label: String, icon: String) -> some View {
        let selected = name == browser.vm
        return Button { if let name { browser.selectMachine(name) } } label: {
            Label(label, systemImage: icon)
                .font(.callout.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : name == nil ? Color.secondary.opacity(0.5) : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? color : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(name == nil)
        .clickable()
        .help(name.map { $0.isEmpty ? "物理机上的会话" : "虚拟机 \($0) 里的会话" } ?? "虚拟机没开着")
    }
}

/// 项目排序：拖动标题行换位置，右键移到最上 / 最下。搜索时关闭（只显示了一部分项目，拖了会乱）
private struct ProjectReorder: ViewModifier {
    let enabled: Bool
    let cwd: String
    let order: [String] // 当前显示的完整顺序
    @ObservedObject var browser: SessionBrowserModel
    @ObservedObject var dropTarget: LocalState<String?>
    let newFolder: () -> Void // 右键「在这个项目下新建文件夹」
    let newSession: () -> Void // 右键「在这里新建会话」

    /// 新建会话的菜单项：Claude 只建在虚拟机里（同一个目录虚拟机里也看得到），Codex 建在物理机上
    @ViewBuilder
    private var newSessionButton: some View {
        Button(browser.agent == .claude ? "在这里新建 Claude 会话（虚拟机里）" : "在这里新建 Codex 会话", action: newSession)
            .disabled(cwd.isEmpty)
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(cwd) { Text(projectName(cwd)).font(.callout.weight(.semibold)).padding(6) }
                .dropDestination(for: String.self) { items, _ in
                    dropTarget.value = nil
                    guard let dragged = items.first, order.contains(dragged) else { return false }
                    withAnimation(.easeOut(duration: 0.2)) { browser.moveProject(dragged, to: cwd, visible: order) }
                    return true
                } isTargeted: { targeted in
                    if targeted { dropTarget.value = cwd } else if dropTarget.value == cwd { dropTarget.value = nil }
                }
                .contextMenu {
                    newSessionButton
                    Button("在这个项目下新建文件夹…", action: newFolder)
                    Divider()
                    Button("移到最上面") { browser.moveProjectToEdge(cwd, top: true, visible: order) }
                        .disabled(order.first == cwd)
                    Button("移到最下面") { browser.moveProjectToEdge(cwd, top: false, visible: order) }
                        .disabled(order.last == cwd)
                    Divider()
                    Button("恢复按最近使用排序") { browser.resetProjectOrder() }
                        .disabled(browser.projectOrder.isEmpty)
                }
        } else {
            // 搜索时不能排序，新建会话照样可以
            content.contextMenu { newSessionButton }
        }
    }
}

/// 项目标题行：箭头 + 文件夹 + 项目名 + 上级路径 + 会话数，点一下展开 / 收起
private struct ProjectHeader: View {
    let group: ProjectGroup
    let expanded: Bool
    let color: Color
    let canReorder: Bool
    let isDropTarget: Bool // 拖动的项目正停在这一行上，放手就挪到这里
    let toggle: () -> Void
    @StateObject private var hovering = LocalState(false)

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: expanded ? "folder.fill" : "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(color.opacity(0.85))
                VStack(alignment: .leading, spacing: 0) {
                    Text(projectName(group.cwd)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !group.cwd.isEmpty {
                        Text(shortPath((group.cwd as NSString).deletingLastPathComponent))
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                // 鼠标停在这一行时才出现拖动把手，平时不占眼
                if canReorder && hovering.value {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .pointerStyle(.grabIdle)
                        .tip("拖动调整项目顺序，右键可以直接移到最下面")
                }
                Text("\(group.sessions.count)")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(isDropTarget ? color.opacity(0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isDropTarget ? color.opacity(0.6) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { hovering.value = $0 }
        .help(group.cwd.isEmpty ? "会话里没有记录工作目录" : group.cwd)
        .animation(.easeOut(duration: 0.15), value: expanded)
    }
}

/// 一个会话：标题（最多两行）+ 最后活跃时间。选中时主色底 + 左边一道色条
private struct SessionRow: View {
    let title: String // 改过名就是改后的名字
    let updatedAt: String
    let selected: Bool
    let color: Color
    let indent: CGFloat // 左边缩进：和项目名对齐，文件夹里的再往里缩一级
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title.isEmpty ? "没有文字内容" : title)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(title.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(TimeText.relative(updatedAt))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(selected ? color : Color.secondary)
            }
            .padding(.leading, indent)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? color.opacity(0.14) : .clear))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3).padding(.vertical, 5).padding(.leading, indent - 13)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
    }
}
