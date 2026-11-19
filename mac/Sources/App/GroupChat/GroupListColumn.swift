// 群列表栏：所有群（最近活跃的在上面）、新建、管理
import SwiftUI

struct GroupListColumn: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var showNew = LocalState(false)
    @StateObject private var showManage = LocalState(false)
    @StateObject private var toDissolve = LocalState<GroupSummary?>(nil)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("群聊").font(.headline)
                Spacer()
                Menu {
                    Button("管理群聊…") { showManage.value = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tip("更多").clickable()
                Button { showNew.value = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).tip("新建群聊").accessibilityLabel("新建群聊").clickable()
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            Divider()

            // 不用 List(.sidebar)：系统侧栏的半透明底在窗口不在前台时是一整块灰，选中行也是灰的。
            // 和「会话」页的列表一样：浅底，选中行用淡淡的强调色
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.sortedGroups) { group in
                        GroupListItem(selected: model.selectedGroupId == group.id) { model.selectGroup(group.id) } content: {
                            GroupRow(group: group, pinned: model.isPinned(group.id), needsYou: model.needsYou[group.id],
                                     members: model.activity[group.id] ?? [])
                        }
                        // 右键：置顶 / 取消置顶、解散
                        .contextMenu {
                            Button(model.isPinned(group.id) ? "取消置顶" : "置顶") { model.togglePin(group.id) }
                            Divider()
                            Button(group.cluster ? "解散集群（含全部子群）…" : "解散并删除群聊…", role: .destructive) { toDissolve.value = group }
                        }
                        // 集群的子群缩进挂在主群下面
                        ForEach(model.subgroups(of: group.id)) { sub in
                            GroupListItem(selected: model.selectedGroupId == sub.id) { model.selectGroup(sub.id) } content: {
                                // 子群里的群主和主群那一行是同一个会话，不重复显示
                                SubgroupRow(group: sub, needsYou: model.needsYou[sub.id],
                                            members: (model.activity[sub.id] ?? []).filter { $0.alias != sub.owner })
                            }
                            .padding(.leading, 14)
                            .contextMenu {
                                Button("解散这个子群…", role: .destructive) { toDissolve.value = sub }
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
        .sheet(isPresented: $showNew.value) { NewGroupSheet().environmentObject(model) }
        .sheet(isPresented: $showManage.value) { ManageGroupsView().environmentObject(model) }
        .confirmationDialog("解散群聊「\(toDissolve.value?.name ?? "")」？",
                            isPresented: Binding(get: { toDissolve.value != nil }, set: { if !$0 { toDissolve.value = nil } })) {
            Button("解散并删除", role: .destructive) {
                if let g = toDissolve.value { Task { await model.dissolveGroup(g.id) } }
            }
        } message: {
            Text(Labels.dissolveMessage(toDissolve.value))
        }
    }
}

struct GroupRow: View {
    let group: GroupSummary
    let pinned: Bool
    /// 要你去处理的事（成员在等授权、在等你回答、消息卡住了），没有就是 nil
    let needsYou: String?
    /// 成员的忙闲，显示在第二行
    let members: [MemberActivity]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if needsYou != nil { NeedsYouIcon() }
                    if pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).help("已置顶")
                    }
                    if group.cluster {
                        Image(systemName: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary).help("集群群聊")
                    }
                    Text(group.name).lineLimit(1)
                }
                if let needsYou {
                    Text(needsYou).font(.caption).foregroundStyle(.orange).lineLimit(1)
                } else if group.cluster ? group.owner.isEmpty : group.memberCount == 0 {
                    // 有没有成员看群本身的数据，不看忙闲（忙闲可能还没拿到、或者这次没查到）
                    Text(group.cluster ? "还没有群主" : "还没有成员").font(.caption).foregroundStyle(.secondary)
                } else if !members.isEmpty {
                    HStack(spacing: 4) {
                        if group.cluster { Text("群主").font(.caption).foregroundStyle(.secondary) }
                        MemberActivityDots(members: members)
                    }
                    .lineLimit(1)
                } else {
                    // 忙闲还没拿到（刚打开、或者查失败了）：先显示原来的文字
                    Text(group.cluster ? "群主 \(group.owner)" : "\(group.memberCount) 位成员").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(TimeText.relative(group.lastActive)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

/// 集群子群：一个功能。第二行显示验收进度，卡住了用橙色提醒
struct SubgroupRow: View {
    let group: GroupSummary
    /// 要你去处理的事，见 GroupRow.needsYou
    let needsYou: String?
    /// coder / tester 的忙闲（不含群主，群主显示在集群主群那一行）
    let members: [MemberActivity]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if needsYou != nil { NeedsYouIcon() }
                    Text(group.name).lineLimit(1)
                }
                if let needsYou {
                    // 要你处理的事排在最前面：只有你能动手，别的状态等它处理完再看
                    Text(needsYou).font(.caption).foregroundStyle(.orange).lineLimit(1)
                } else {
                    // coder / tester 的忙闲，后面接验收进度（分支名在对话顶部有，这里不再显示）。
                    // 验收进度不依赖忙闲：忙闲还没拿到时也要看得到「已暂停」
                    HStack(spacing: 4) {
                        if !members.isEmpty {
                            MemberActivityDots(members: members)
                        } else {
                            Text(group.branch.isEmpty ? "正在建立" : group.branch).font(.caption).foregroundStyle(.secondary)
                        }
                        if group.blocked {
                            Text("· 已暂停").font(.caption).foregroundStyle(.orange).help("打回超过上限，已暂停，等群主介入")
                        } else if group.failCount > 0 {
                            Text("· 打回 \(group.failCount) 次").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(TimeText.relative(group.lastActive)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 群列表里可以点选的一行（外框和选中样式），里面放 GroupRow 或 SubgroupRow。选中样式和「会话」页的列表一致
private struct GroupListItem<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
    }
}

/// 一排成员状态：每人一个小圆点 + 名字。颜色和成员头像上的状态点一致：
/// 绿 = 空闲，橙 = 在干活，红 = 在等授权 / 等你回答，灰 = 会话没在运行或看不出来。
/// 一个集群里群主和各子群全是绿点，就是谁都没在干活
private struct MemberActivityDots: View {
    let members: [MemberActivity]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(members, id: \.memberId) { m in
                HStack(spacing: 3) {
                    Circle().fill(color(m.status)).frame(width: 6, height: 6)
                    Text(m.alias).font(.caption).foregroundStyle(.secondary)
                }
                .help("\(m.alias)：\(label(m.status))")
            }
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "working": return .orange
        case "idle": return .green
        case "waiting": return .red
        default: return .gray
        }
    }

    private func label(_ status: String) -> String {
        switch status {
        case "working": return "在干活"
        case "idle": return "空闲"
        case "waiting": return "在等授权或等你回答"
        case "off": return "会话没在运行"
        default: return "看不出来"
        }
    }
}

/// 群名前的橙色举手图标：这个群里有事要你去处理
private struct NeedsYouIcon: View {
    var body: some View {
        Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.orange).help("有事要你处理")
    }
}

/// 新建群聊：一个名字，外加要不要建成集群
struct NewGroupSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var name = LocalState("")
    @StateObject private var cluster = LocalState(false)

    private var trimmed: String { name.value.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建群聊").font(.title3)
            TextField("群名，比如「数字人改版」", text: $name.value)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("集群群聊", isOn: $cluster.value).clickable()
                Text("拉一个会话进来当群主。你把大需求交给它，它拆成几个功能，每个功能自动起一个子群，"
                     + "由后台的 coder（Claude）编码、tester（Codex）验收，各自在独立的 git worktree 里工作。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).clickable()
                Button("新建", action: create).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty).clickable()
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        let value = trimmed
        let isCluster = cluster.value
        dismiss()
        Task { await model.createGroup(name: value, cluster: isCluster) }
    }
}

/// 管理群聊：列出所有群的成员数、消息数、最后活跃时间，逐个解散
struct ManageGroupsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var toDissolve = LocalState<GroupSummary?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("管理群聊").font(.title3)
            Text("解散后群里的成员和聊天记录都会删除，各个会话本身不受影响。").font(.caption).foregroundStyle(.secondary)

            Table(model.groups) {
                TableColumn("群聊") { g in Text("\(g.name)  \(Text(g.id).foregroundStyle(.secondary))") }
                TableColumn("成员") { g in Text("\(g.memberCount)") }.width(50)
                TableColumn("消息") { g in Text("\(g.messageCount)") }.width(50)
                TableColumn("最后活跃") { g in Text(TimeText.dateTime(g.lastActive)) }.width(140)
                TableColumn("") { g in Button("解散") { toDissolve.value = g }.foregroundStyle(.red).clickable() }.width(60)
            }
            .frame(minWidth: 560, minHeight: 260)

            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).clickable()
            }
        }
        .padding(20)
        .confirmationDialog("解散群聊「\(toDissolve.value?.name ?? "")」？",
                            isPresented: Binding(get: { toDissolve.value != nil }, set: { if !$0 { toDissolve.value = nil } })) {
            Button("解散", role: .destructive) {
                if let g = toDissolve.value { Task { await model.dissolveGroup(g.id) } }
            }
        } message: {
            Text(Labels.dissolveMessage(toDissolve.value))
        }
    }
}
