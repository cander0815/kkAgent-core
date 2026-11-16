// 对话区：顶部群名 + 成员头像，中间是交接记录，底部以「我」的身份发消息
import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    let detail: GroupDetail
    @StateObject private var showAddMember = LocalState(false)
    @StateObject private var confirmDissolve = LocalState(false)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            timeline
            Composer(detail: detail) // 顶部自带可拖动的分隔线
        }
        .sheet(isPresented: $showAddMember.value) { AddMemberSheet().environmentObject(model) }
        .confirmationDialog("解散群聊「\(detail.group.name)」？", isPresented: $confirmDissolve.value) {
            Button("解散", role: .destructive) { Task { await model.dissolveGroup(detail.group.id) } }
        } message: {
            Text(Labels.dissolveMessage(detail.group))
        }
    }

    // ---------- 顶部 ----------

    private var header: some View {
        HStack(spacing: 14) {
            // 空间不够时先缩短群名，成员标签保持完整
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(detail.group.name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    CopyButton(text: detail.group.name, help: "复制群名", color: .secondary).font(.callout)
                    // 群建了多久，每分钟刷新一次；放不下时先缩短群名，这一行保持完整
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(TimeText.age(detail.group.createdAt, now: context.date))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .lineLimit(1).fixedSize()
                            .help("创建于 \(TimeText.dateTime(detail.group.createdAt))")
                    }
                }
                // 第二行：群 ID（带复制按钮，不用再去「更多」菜单里找），后面接集群 / 子群信息
                HStack(spacing: 4) {
                    Text(detail.group.id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    CopyButton(text: detail.group.id, help: "复制群 ID", color: .secondary)
                    clusterInfo
                }
                .font(.caption)
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            // 成员：头像 + 名字，点一下在右边看它的执行过程
            HStack(spacing: 6) {
                ForEach(detail.members) { item in
                    MemberChip(item: item, selected: model.selectedMemberId == item.member.id) {
                        model.selectMember(model.selectedMemberId == item.member.id ? nil : item.member.id)
                    }
                }
                Button { showAddMember.value = true } label: {
                    Image(systemName: "plus").frame(width: 26, height: 26)
                        .background(Circle().strokeBorder(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3])))
                        .contentShape(Circle()) // 整个圆都能点，不只是中间的 + 号
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).tip("添加成员").clickable()
            }
            Menu {
                Button("解散群聊…", role: .destructive) { confirmDissolve.value = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tip("更多").clickable()
        }
        .padding(.horizontal, 16)
        .frame(height: 52) // 和左边群聊列表的顶部一样高，分隔线才对得齐
    }

    /// 接在群 ID 后面：集群主群说明有几个子群；子群显示 worktree（可复制、可在终端打开）和验收进度
    @ViewBuilder
    private var clusterInfo: some View {
        let group = detail.group
        if group.cluster {
            Text("·").foregroundStyle(.secondary)
            let count = model.subgroups(of: group.id).count
            Text(count == 0 ? "集群，还没有拆出功能" : "集群，已拆出 \(count) 个功能").font(.caption).foregroundStyle(.secondary)
        } else if !group.parentId.isEmpty {
            Text("·").foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("\(group.branch) → \(group.baseBranch)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                CopyButton(text: group.worktree, icon: "folder", help: "复制 worktree 路径：\(group.worktree)", color: .secondary)
                OpenTerminalButton(cwd: group.worktree, vm: "", color: .secondary)
                if group.blocked {
                    Text("打回 \(group.failCount) 次，已暂停，等群主介入").font(.caption).foregroundStyle(.orange)
                } else if group.failCount > 0 {
                    Text("打回 \(group.failCount) 次").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    // ---------- 交接记录 ----------

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if detail.messages.isEmpty {
                        Text(detail.members.isEmpty
                             ? "点右上角的 + 把会话拉进群。"
                             : "还没有消息。可以在下面给某个成员派活，它做完会把结论交给下一位。")
                            .foregroundStyle(.secondary).padding(24)
                    }
                    ForEach(detail.messages) { message in
                        Group {
                            // 系统消息：kind=alert 是投递出错、重启打断这类要让人看到的通知；
                            // 其余 to=all 是「xx 已离开群聊」，to=某成员 是给它的入群说明
                            if message.from == "system" && message.kind == "alert" {
                                SystemAlertRow(message: message)
                            } else if message.from == "system" && message.to == "all" {
                                LeaveNoticeRow(message: message)
                            } else if message.from == "system" {
                                JoinNoticeRow(message: message)
                            } else {
                                HandoffRow(message: message, detail: detail)
                            }
                        }
                        .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: detail.messages.count) { scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = detail.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

/// 顶部的成员小标签：头像（带状态点）+ 名字
struct MemberChip: View {
    let item: MemberDetail
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                AgentAvatar(member: item, size: 22)
                Text(item.member.alias).font(Theme.nameFont(12)).lineLimit(1).fixedSize()
            }
            .padding(.leading, 2).padding(.trailing, 8).padding(.vertical, 2)
            .background(Capsule().fill(selected ? Theme.color(item.member.agent).opacity(0.14) : .clear))
            .overlay(Capsule().stroke(selected ? Theme.color(item.member.agent).opacity(0.5) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .clickable()
        .help("\(item.member.alias)：\(item.statusLabel)。点击查看执行过程")
    }
}

/// 底部发消息：上面是多行输入框，下面一行是「发给谁」和发送按钮。
/// 拖动顶部的分隔线可以调输入框高度，高度记在本机，下次打开不变
struct Composer: View {
    @EnvironmentObject private var model: AppModel
    let detail: GroupDetail
    @StateObject private var to = LocalState("all")
    @StateObject private var draft = LocalState("")
    @StateObject private var urgent = LocalState(false) // 这条标为紧急（第 6 步，实验功能），发完自动关掉
    @AppStorage("composerHeight") private var editorHeight: Double = 110
    @StateObject private var dragStartHeight = LocalState<Double?>(nil) // 拖动开始时的高度，拖完清空
    @FocusState private var focused: Bool

    private static let heightRange: ClosedRange<Double> = 60...360
    private var canSend: Bool { !draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            VStack(spacing: 10) {
                editor
                HStack(spacing: 10) {
                    Picker("发给", selection: $to.value) {
                        Text("所有人").tag("all")
                        ForEach(detail.members) { Text($0.member.alias).tag($0.member.alias) }
                    }
                    .fixedSize()
                    .clickable()
                    Toggle("紧急（实验）", isOn: $urgent.value)
                        .toggleStyle(.checkbox)
                        .help("对方空闲后排在普通消息前面送进去。只在对方继续做下去会白干时用")
                        .clickable()
                    Spacer()
                    Text("⌘↩ 发送").font(.caption).foregroundStyle(.tertiary)
                    Button("发送", action: send)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSend)
                        .clickable()
                }
            }
            .padding(12)
        }
    }

    /// 分隔线：鼠标放上去变成上下箭头，往上拖输入框变高，往下拖变矮
    private var resizeHandle: some View {
        Divider()
            .padding(.vertical, 3) // 线只有 1 像素，上下各留 3 点方便抓
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight.value ?? editorHeight
                        dragStartHeight.value = start
                        editorHeight = (start - value.translation.height).clamped(to: Self.heightRange)
                    }
                    .onEnded { _ in dragStartHeight.value = nil }
            )
    }

    private var editor: some View {
        TextEditor(text: $draft.value) // 字号跟着设置里的正文字号（见 AppTextSize）
            .focused($focused)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25))
            )
            .overlay(alignment: .topLeading) {
                // TextEditor 没有占位文字，空的时候自己叠一行提示
                if draft.value.isEmpty {
                    Text("以你的身份发一条消息")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: editorHeight)
    }

    private func send() {
        guard canSend else { return }
        let content = draft.value
        let isUrgent = urgent.value
        Task {
            if await model.send(to: to.value, content: content, urgent: isUrgent) {
                draft.value = ""
                urgent.value = false
            }
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
