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
                            GroupRow(group: group, pinned: model.isPinned(group.id), needsYou: model.needsYou[group.id])
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
                                SubgroupRow(group: sub, needsYou: model.needsYou[sub.id])
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
                } else {
                    Text(group.cluster ? (group.owner.isEmpty ? "还没有群主" : "群主 \(group.owner)")
                         : group.memberCount == 0 ? "还没有成员" : "\(group.memberCount) 位成员")
                        .font(.caption).foregroundStyle(.secondary)
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
                } else if group.blocked {
                    Text("已暂停，等群主介入").font(.caption).foregroundStyle(.orange)
                } else if group.failCount > 0 {
                    Text("打回 \(group.failCount) 次").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(group.branch.isEmpty ? "正在建立" : group.branch).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
