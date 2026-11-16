// 成员详情（右栏）：状态栏（排队数、暂停自动投递）、等授权提示、「已写入未确认」卡片，
// 下面是标签页：终端（只有 tmux 里的 coder / tester 有）/ 执行过程 / 会话信息。执行过程只给人看，不会传给别的 Agent。
import SwiftUI

struct MemberInspector: View {
    @EnvironmentObject private var model: AppModel
    let item: MemberDetail

    private enum Tab: String, CaseIterable { case terminal = "终端", transcript = "执行过程", info = "会话信息" }
    @StateObject private var tab = LocalState<Tab?>(nil) // nil = 还没选过，用默认的
    @AppStorage("terminalCollapsed") private var terminalCollapsed = false

    private var hasTerminal: Bool { !item.member.tmux.isEmpty }
    private var tabs: [Tab] { hasTerminal ? Tab.allCases : [.transcript, .info] }
    /// 当前显示的标签页：没选过时，有终端的默认看终端；切到没有终端的成员时退回会话信息
    private var currentTab: Tab {
        let chosen = tab.value ?? (hasTerminal ? .terminal : .info)
        return tabs.contains(chosen) ? chosen : .info
    }

    /// 这个成员的投递记录（状态栏的排队数、「已写入未确认」卡片都用它）
    private var deliveries: [Delivery] { model.detail?.deliveries.filter { $0.memberId == item.member.id } ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AgentAvatar(member: item, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.member.alias).font(Theme.nameFont(14))
                    Text("\(item.member.agent.displayName) · \(item.machineLabel)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.selectMember(nil) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).tip("关闭").clickable()
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            Divider()

            MemberStatusBar(item: item, pending: deliveries.filter { $0.status == .pending })
            if item.state.agentStatus == "waitingPermission" {
                PermissionNotice(openTerminal: hasTerminal ? {
                    tab.value = .terminal
                    terminalCollapsed = false
                } : nil)
            }
            UnconfirmedCards(deliveries: deliveries)
            Divider()

            Picker("", selection: Binding(get: { currentTab }, set: { tab.value = $0 })) {
                ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().clickable()
            .padding(10)

            switch currentTab {
            case .terminal: MemberTerminalPane(item: item).id(item.member.tmux) // 换了成员就重新连接
            case .transcript: TranscriptList()
            case .info: MemberInfo(item: item)
            }
        }
        // 点了授权通知：切到终端并展开（详情可能是刚打开的，也可能原来在看别的成员、别的标签页）
        .onAppear(perform: openTerminalIfRequested)
        .onChange(of: model.terminalRequest) { _, _ in openTerminalIfRequested() }
        .onChange(of: item.member.id) { _, _ in openTerminalIfRequested() }
    }

    private func openTerminalIfRequested() {
        guard model.terminalRequest == item.member.id else { return }
        model.terminalRequest = nil
        guard hasTerminal else { return }
        tab.value = .terminal
        terminalCollapsed = false
    }
}

/// 执行过程列表，新内容到了自动滚到底
struct TranscriptList: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("hideTools") private var hideTools = false

    private var events: [TranscriptEvent] {
        model.transcript.filter { event in
            if hideTools && event.kind.isTool { return false }
            return !event.isClaudeCodeInternal
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Toggle("隐藏工具调用", isOn: $hideTools)
                .toggleStyle(.checkbox).font(.caption).clickable()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if events.isEmpty {
                            Text("暂时没有内容").foregroundStyle(.secondary)
                        }
                        ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                            EventRow(event: event).id(index)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: events.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }
}

struct EventRow: View {
    let event: TranscriptEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(event.kind.color).frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(event.kind.label)，\(TimeText.time(event.time))").font(.caption2).foregroundStyle(.secondary)
                Text(event.text)
                    .font(event.kind.isTool ? Theme.code : .callout)
                    .italic(event.kind == .thinking)
                    .foregroundStyle(event.kind == .thinking ? .secondary : .primary)
                    .lineLimit(event.kind.isTool ? 8 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// 更换会话：贴一个新的会话 ID（比如从原会话分叉出来的）
struct ChangeSessionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let member: Member
    @StateObject private var sessionId = LocalState("")

    private var trimmed: String { sessionId.value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("更换 \(member.alias) 的会话").font(.title3)
            Text("填新的 \(member.agent == .claude ? "Claude" : "Codex") 会话 ID。之后发给 \(member.alias) 的消息都会送到新会话，"
                 + "还没送出的也一样。如果它是集群的群主，各个子群里的群主也会一起换。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("新会话 ID", text: $sessionId.value).textFieldStyle(.roundedBorder).font(Theme.code).onSubmit(change)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).clickable()
                Button("更换", action: change).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty).clickable()
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func change() {
        guard !trimmed.isEmpty else { return }
        let value = trimmed
        Task {
            // 失败时 AppModel 会弹窗说明原因，这里只在成功时关掉
            if await model.changeSession(memberId: member.id, sessionId: value) { dismiss() }
        }
    }
}

/// 会话信息：会话 ID、工作目录、状态说明、移出群
struct MemberInfo: View {
    @EnvironmentObject private var model: AppModel
    let item: MemberDetail
    @StateObject private var confirmRemove = LocalState(false)
    @StateObject private var showChangeSession = LocalState(false)

    /// 在终端里接着这个会话聊的命令（需要先自己切到工作目录，claude 只在会话所属的目录下找得到它）
    private var resumeCommand: String {
        switch item.member.agent {
        case .claude: "claude --resume \(item.member.sessionId)"
        case .codex: "codex resume \(item.member.sessionId)"
        }
    }

    var body: some View {
        Form {
            // 常驻 tmux 的成员（集群 coder / tester）：单独一个入口打开它的会话，和下面「在终端打开目录」分开
            if !item.member.tmux.isEmpty {
                Section {
                    LabeledContent("tmux 会话") {
                        HStack(spacing: 5) {
                            Text(item.member.tmux).font(Theme.code).textSelection(.enabled)
                            CopyButton(text: "tmux attach -t \(item.member.tmux)", help: "复制接入命令：tmux attach -t \(item.member.tmux)")
                            Button("打开会话") { TerminalLauncher.attachTmux(item.member.tmux) }
                                .buttonStyle(.borderedProminent).controlSize(.small).clickable()
                        }
                    }
                    Text("在终端里接入它正在运行的会话，可以直接和它对话、按 Esc 打断它。按 Ctrl-b 再按 d 退出，它继续在后台运行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent("负责") { Text(item.member.description.isEmpty ? "未填写" : item.member.description) }
            LabeledContent("会话 ID") {
                HStack(spacing: 5) {
                    Text(item.member.sessionId).font(Theme.code).textSelection(.enabled)
                    CopyButton(text: resumeCommand, help: "复制恢复命令：\(resumeCommand)")
                    // 后台会话（集群 coder / tester）的会话和 tmux 绑在一起，不能换
                    if !item.member.headless {
                        Button("更换…") { showChangeSession.value = true }
                            .buttonStyle(.borderless).tip("换成另一个会话，比如从它分叉出来的新会话").clickable()
                    }
                }
            }
            LabeledContent("工作目录") {
                HStack(spacing: 5) {
                    Text(item.member.cwd).font(Theme.code).textSelection(.enabled)
                    CopyButton(text: item.member.cwd, help: "复制工作目录")
                    OpenTerminalButton(cwd: item.member.cwd, vm: item.member.vm)
                }
            }
            LabeledContent("所在机器") { Text(item.machineLabel) }
            LabeledContent("状态") { Text(item.statusLabel) }
            Text(item.deliveryNote).font(.caption).foregroundStyle(.secondary)
            if let hint = item.statusHint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
            Section {
                Button("移出群聊…", role: .destructive) { confirmRemove.value = true }.clickable()
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showChangeSession.value) { ChangeSessionSheet(member: item.member).environmentObject(model) }
        .confirmationDialog("把 \(item.member.alias) 移出群聊？", isPresented: $confirmRemove.value) {
            Button("移出", role: .destructive) { Task { await model.removeMember(item.member.id) } }
        } message: {
            Text("它的会话本身不受影响。")
        }
    }
}
