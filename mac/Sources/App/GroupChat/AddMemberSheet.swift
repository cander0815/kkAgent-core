// 添加成员，两种方式：
// - 新建会话（普通群默认）：先选工作目录，再选 Claude / Codex，由 kkAgent 新建会话、托管在 tmux 里（见 kktodo/群里新建会话-方案.md）
// - 拉入已有会话：填会话 ID，把已经开着的会话拉进群
// 集群群聊只能拉入已有会话（群主），子群的成员由群主 spawn
import AppKit
import SwiftUI

struct AddMemberSheet: View {
    private enum Mode: String, CaseIterable {
        case create = "新建会话"
        case existing = "拉入已有会话"
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mode = LocalState(Mode.create)
    @StateObject private var cwd = LocalState("")
    @StateObject private var agent = LocalState(AgentKind.claude)
    @StateObject private var sessionId = LocalState("")
    @StateObject private var alias = LocalState("")
    @StateObject private var description = LocalState("")
    @StateObject private var error = LocalState("")
    @StateObject private var submitting = LocalState(false)
    /// 左边栏「会话」里还在运行、没进任何群的单独会话：拉入已有会话时可以直接选（核心会复用它的进程）
    @StateObject private var solos = LocalState<[SoloSession]>([])
    @StateObject private var pickedSolo = LocalState<Int64?>(nil)

    /// 集群群聊（主群或子群）不能在这里新建会话
    private var canCreate: Bool {
        guard let group = model.detail?.group else { return false }
        return !group.cluster && group.parentId.isEmpty
    }

    private var creating: Bool { canCreate && mode.value == .create }

    private var ready: Bool {
        guard !alias.value.isEmpty, !submitting.value else { return false }
        return creating ? !cwd.value.trimmingCharacters(in: .whitespaces).isEmpty : !sessionId.value.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加成员").font(.title3)
            if canCreate {
                Picker("", selection: $mode.value) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .clickable()
            }
            Form {
                if creating {
                    // 第一步先选工作目录：新会话就在这个目录里干活
                    HStack {
                        TextField("工作目录", text: $cwd.value, prompt: Text("新会话在哪个代码目录里工作"))
                        Button("选择文件夹…", action: pickFolder).clickable()
                    }
                }
                Picker("类型", selection: $agent.value) {
                    ForEach(AgentKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .clickable()
                if !creating {
                    // 普通群可以直接选一个单独会话（选了就填好类型和会话 ID）
                    if canCreate && !solos.value.isEmpty {
                        Picker("单独会话", selection: $pickedSolo.value) {
                            Text("不选，手填会话 ID").tag(Int64?.none)
                            ForEach(solos.value) { s in
                                Text("\(s.agent.displayName) · \(shortPath(s.cwd))").tag(Int64?.some(s.id))
                            }
                        }
                        .clickable()
                        .onChange(of: pickedSolo.value) { _, id in
                            guard let s = solos.value.first(where: { $0.id == id }) else { return }
                            agent.value = s.agent
                            sessionId.value = s.sessionId
                        }
                    }
                    TextField("会话 ID", text: $sessionId.value, prompt: Text("在会话里问它「你的会话 ID 是什么」"))
                }
                TextField("成员名", text: $alias.value, prompt: Text("coder、tester、pm"))
                // 多行：可以写清楚它负责的范围，至少显示 4 行，超过 8 行再滚动
                TextField("负责什么", text: $description.value, prompt: Text("编码、测试、产品；可以多写几句它负责的范围"), axis: .vertical)
                    .lineLimit(4...8)
            }
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !error.value.isEmpty {
                Text(error.value).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).clickable()
                Button(creating ? "新建并加入" : "加入群聊", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
                    .clickable()
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if !canCreate { mode.value = .existing }
            // 默认工作目录：群里第一个成员的目录（大多数时候大家在同一个仓库里干活）
            if cwd.value.isEmpty, let first = model.detail?.members.first?.member.cwd { cwd.value = first }
        }
        .task {
            // 只列运行中、还没进群的单独会话
            let all: [SoloSession] = (try? await APIClient().get("/api/solo")) ?? []
            solos.value = all.filter { $0.state == "running" && $0.boundGroupId.isEmpty }
        }
    }

    private var hint: String {
        guard creating else { return "加入后会自动给它发一段入群说明，告诉它怎么在群里发消息、只发结论。" }
        return agent.value == .claude
            ? "Claude 会建在虚拟机里（工作目录要在 /Users 下），由 kkAgent 托管在 tmux 里，可以在成员详情里打开终端交互。建好后自动收到入群说明。"
            : "Codex 建在物理机上，由 kkAgent 托管在 tmux 里，可以在成员详情里打开终端交互。会先跑一轮把会话建出来（十几秒到一分钟），这期间发给它的消息会先排着。"
    }

    /// 选文件夹：只能选目录，从当前填的目录开始
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

    private func add() {
        let request = creating
            ? AddMemberRequest(agent: agent.value, sessionId: "", alias: alias.value, description: description.value,
                               create: true, cwd: cwd.value.trimmingCharacters(in: .whitespaces))
            : AddMemberRequest(agent: agent.value, sessionId: sessionId.value, alias: alias.value, description: description.value)
        submitting.value = true
        Task {
            let ok = await model.addMember(request)
            submitting.value = false
            if ok {
                dismiss()
            } else {
                // 失败时（比如会话 ID 找不到、目录不对）保留输入，原因显示在这个弹窗里，不再另弹警告框
                error.value = model.errorMessage ?? "加入失败"
                model.errorMessage = nil
            }
        }
    }
}
