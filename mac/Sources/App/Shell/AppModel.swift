// 界面的全部状态。每 2 秒向核心拉一次数据（拉哪些见下面「轮询」）；所有操作都通过接口交给核心去做。
import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var coreOnline = false
    @Published var health: CoreHealth?
    @Published var groups: [GroupSummary] = []
    @Published private(set) var selectedGroupId: String?
    @Published var detail: GroupDetail?
    @Published private(set) var selectedMemberId: Int64?
    @Published var transcript: [TranscriptEvent] = []
    @Published var errorMessage: String? // 弹窗显示

    /// 置顶的群（按置顶先后）。只是界面上的显示偏好，存在本机 UserDefaults，不经过核心
    @Published private(set) var pinnedGroupIds: [String] = []
    /// 现在开着的单独会话有几个（运行中 + 正在启动，启动失败的不算），功能栏「会话」图标上的数字角标用
    @Published private(set) var openSoloCount = 0
    /// 要你去处理的群：群 id → 一句话原因（成员在等授权、在等你回答、消息卡住了）。
    /// 群列表在这些群上加橙色标识，处理掉之后下一次刷新就消失（见 needsYouByGroup）
    @Published private(set) var needsYou: [String: String] = [:]
    /// 各群成员的忙闲：群 id → 成员列表（按入群先后）。群列表上的状态点用
    @Published private(set) var activity: [String: [MemberActivity]] = [:]
    /// 正在运行的 ubx 虚拟机的负载，功能栏「核心」下面显示。每 10 秒查一次（见 refreshVMLoadIfDue），查不到时清空
    @Published private(set) var vmLoads: [VMLoad] = []

    let api = APIClient()
    private var transcriptOffset: Int?
    private var transcriptSource: String? // 上次读的是哪个会话文件（offset 只在同一个文件里有意义）
    private var started = false
    /// 有成员卡在授权框上时弹通知横幅（见 AttentionNotifier.swift）
    private let notifier = AttentionNotifier()
    /// 打开主窗口（窗口关掉后，点通知要能把它重新打开）。由 RootView 出现时设置
    var openMainWindow: (() -> Void)?
    /// 每点一次授权通知加 1：RootView 看到它变了就切回群聊页
    @Published private(set) var focusRequests = 0
    /// 点了授权通知、要打开终端的成员：成员详情看到是自己，就切到终端标签页并展开终端，然后清掉
    @Published var terminalRequest: Int64?
    /// 点了单独会话的通知：要打开的单独会话，每点一次 soloFocusRequests 加 1，RootView 看到它变了就切到「会话」页选中它
    private(set) var soloFocusTarget: Int64?
    @Published private(set) var soloFocusRequests = 0

    init() {
        selectedGroupId = UserDefaults.standard.string(forKey: "selectedGroupId")
        pinnedGroupIds = UserDefaults.standard.stringArray(forKey: "pinnedGroupIds") ?? []
    }

    /// 群列表的显示顺序：置顶的在前（按置顶先后），其余按最近活跃（核心返回的顺序）。
    /// 只有顶层群；集群的子群挂在主群下面显示（见 subgroups）
    var sortedGroups: [GroupSummary] {
        let topLevel = groups.filter { $0.parentId.isEmpty }
        let pinned = pinnedGroupIds.compactMap { id in topLevel.first { $0.id == id } }
        return pinned + topLevel.filter { !pinnedGroupIds.contains($0.id) }
    }

    /// 集群主群下的子群，按创建先后（先拆出来的在上面）
    func subgroups(of parentId: String) -> [GroupSummary] {
        groups.filter { $0.parentId == parentId }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 每个群要你处理什么：一个群里有好几件时，显示第一件，后面写「等 N 件」
    private static func needsYouByGroup(attention: [AttentionItem], stuck: [StuckDelivery]) -> [String: String] {
        var reasons: [String: [String]] = [:]
        // 没绑进群的单独会话 groupId 为空，不在群列表里显示（它在「会话」页）
        for item in attention where !item.groupId.isEmpty {
            let who = item.bySubagent ? "\(item.alias) 的子 agent" : item.alias
            reasons[item.groupId, default: []].append(item.tool == "AskUserQuestion" ? "\(who) 在等你回答" : "\(who) 在等授权")
        }
        for item in stuck {
            reasons[item.groupId, default: []].append("\(item.alias) 的消息卡住了")
        }
        return reasons.mapValues { list in list.count == 1 ? list[0] : "\(list[0]) 等 \(list.count) 件" }
    }

    func isPinned(_ id: String) -> Bool { pinnedGroupIds.contains(id) }

    func togglePin(_ id: String) {
        if isPinned(id) { pinnedGroupIds.removeAll { $0 == id } } else { pinnedGroupIds.append(id) }
        UserDefaults.standard.set(pinnedGroupIds, forKey: "pinnedGroupIds")
    }

    // ---------- 轮询 ----------
    // 整个 app 向核心拉数据只有这一个 2 秒的循环（「端口」页不经过核心，有自己的定时器）。每一轮按下面的规则决定拉什么：
    // - 一直拉：核心在不在、群列表、单独会话、等授权、卡住的投递。左边栏的状态点、角标和系统通知要用，在哪一页、窗口开没开都要拉
    // - 只在群聊页、并且窗口看得见时拉：群详情、成员忙闲、执行过程。核心算这几项最费劲，别的页面又用不到
    // - 虚拟机负载：10 秒拉一次

    /// 现在显示的是哪一页，RootView 切页时设置。切回群聊页时马上补一次刷新，不用等下一轮
    var activeModule: AppModule = .groupChat {
        didSet { if activeModule == .groupChat && oldValue != .groupChat { Task { await refresh() } } }
    }
    /// 拿到最新的单独会话列表时调用（RootView 交给「会话」页，那一页不再自己拉）
    var onSolos: (([SoloSession]) -> Void)?
    private var lastVMLoadAt = Date.distantPast

    /// 群聊页是不是正显示在用户眼前：选的是群聊页，并且主窗口没关、没最小化、没被别的窗口完全挡住
    private var showsGroupChat: Bool {
        activeModule == .groupChat
            && NSApp.windows.contains { $0.canBecomeMain && $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    /// 开始轮询，重复调用没关系
    func start() {
        guard !started else { return }
        started = true
        notifier.onOpen = { [weak self] groupId, memberId in self?.focus(groupId: groupId, memberId: memberId) }
        notifier.onOpenSolo = { [weak self] soloId in self?.focusSolo(soloId) }
        // 窗口重新露出来（打开、取消最小化、挡着它的窗口移开）时马上补一次刷新，不先显示旧数据
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.showsGroupChat else { return }
                Task { await self.refresh() }
            }
        }
        Task {
            while true {
                await refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refresh() async {
        do {
            let newHealth: CoreHealth = try await api.get("/api/health")
            if newHealth != health { health = newHealth }
            coreOnline = true
            refreshVMLoadIfDue()
            let newGroups: [GroupSummary] = try await api.get("/api/groups")
            if newGroups != groups { groups = newGroups }
            // 选中的群没了（被解散）就切到列表里的第一个
            // 一个群都没有时 first 是 nil，和当前 nil 相同就别再切，否则 selectGroup → refresh → selectGroup 无限循环
            if !groups.contains(where: { $0.id == selectedGroupId }) && sortedGroups.first?.id != selectedGroupId {
                selectGroup(sortedGroups.first?.id)
            }
            let groupChat = showsGroupChat
            // 群列表上每个群的成员忙闲：要查所有群的所有成员，比别的请求慢，先发出去和后面的请求一起跑，最后再取结果
            async let memberActivity: [MemberActivity]? = fetch("/api/activity", when: groupChat)
            if groupChat, let gid = selectedGroupId {
                let newDetail: GroupDetail = try await api.get("/api/groups/\(gid)")
                if newDetail != detail { detail = newDetail }
            }
            // 单独会话：这一轮结束、出错、启动失败弹通知横幅（不管现在在哪一页）。查不到就这次不处理，不影响别的刷新
            if let solos: [SoloSession] = try? await api.get("/api/solo") {
                notifier.updateSolos(solos)
                onSolos?(solos)
                let open = solos.filter { $0.state == "running" || $0.state == "starting" }.count
                if open != openSoloCount { openSoloCount = open }
            }
            // 卡在授权框上的群成员和单独会话：新出现的弹通知横幅（查不到不影响别的刷新）
            let attention: [AttentionItem]? = try? await api.get("/api/attention")
            if let attention { notifier.update(attention) }
            // 卡住了的投递（消息写进去了没能确认，后面的都排着）：新出现的弹必须点掉的横幅（查不到不影响别的刷新）
            let stuck: [StuckDelivery]? = try? await api.get("/api/stuck")
            if let stuck { notifier.updateStuck(stuck) }
            // 两份都拿到了才更新群列表的标识：只拿到一份就算的话，标识会一闪一闪
            if let attention, let stuck {
                let reasons = Self.needsYouByGroup(attention: attention, stuck: stuck)
                if reasons != needsYou { needsYou = reasons }
            }
            if groupChat { await refreshTranscript() }
            // 成员忙闲放在最后取，不挡住会话记录的刷新。查不到就保留上一次的；内容没变不重新赋值，免得整个列表重画
            if let members = await memberActivity {
                let grouped = Dictionary(grouping: members, by: \.groupId)
                if grouped != activity { activity = grouped }
            }
        } catch ClientError.offline {
            coreOnline = false
            if !vmLoads.isEmpty { vmLoads = [] } // 核心不在，不显示旧的负载数字
        } catch {
            // 单次刷新失败不弹窗，下一轮再试
        }
    }

    /// 条件成立才发请求，否则直接返回 nil（给上面 async let 用）。请求失败也返回 nil
    private func fetch<T: Decodable>(_ path: String, when condition: Bool) async -> T? {
        guard condition else { return nil }
        return try? await api.get(path)
    }

    /// 距上次超过 10 秒就拉一次虚拟机负载。单独起一个任务、不等它：虚拟机卡住时核心最多要等 15 秒，不能拖住整轮刷新
    private func refreshVMLoadIfDue() {
        guard Date().timeIntervalSince(lastVMLoadAt) >= 10 else { return }
        lastVMLoadAt = Date()
        Task {
            let loads: [VMLoad] = (try? await api.get("/api/vm-load")) ?? [] // 查不到就不显示，不留旧数字
            if loads != vmLoads { vmLoads = loads }
        }
    }

    // ---------- 群 ----------

    func selectGroup(_ id: String?) {
        guard id != selectedGroupId || detail == nil else { return }
        selectedGroupId = id
        UserDefaults.standard.set(id, forKey: "selectedGroupId")
        detail = nil
        selectMember(nil)
        Task { await refresh() }
    }

    func createGroup(name: String, cluster: Bool) async {
        await perform {
            let group: GroupSummary = try await api.post("/api/groups", CreateGroupRequest(name: name, cluster: cluster))
            selectGroup(group.id)
        }
    }

    func dissolveGroup(_ id: String) async {
        let ok = await perform { try await api.delete("/api/groups/\(id)") }
        if ok && isPinned(id) { togglePin(id) } // 群没了，置顶记录也清掉
    }

    // ---------- 成员 ----------

    func addMember(_ request: AddMemberRequest) async -> Bool {
        guard let gid = selectedGroupId else { return false }
        return await perform {
            let _: Member = try await api.post("/api/groups/\(gid)/members", request)
        }
    }

    /// 更换成员的会话（比如换成分叉出来的新会话）。成功返回 true
    func changeSession(memberId: Int64, sessionId: String) async -> Bool {
        await perform {
            let _: Member = try await api.post("/api/members/\(memberId)/session", ChangeSessionRequest(sessionId: sessionId))
        }
    }

    /// 点了单独会话的通知：打开主窗口，切到「会话」页选中它
    func focusSolo(_ id: Int64) {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        soloFocusTarget = id
        soloFocusRequests += 1
    }

    /// 点了授权通知：打开主窗口，选中那个群和成员（右栏就是它的终端）
    func focus(groupId: String, memberId: Int64) {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true) // 用户点了通知，要把窗口带到前面
        focusRequests += 1
        terminalRequest = memberId
        selectGroup(groupId)
        selectMember(memberId)
    }

    /// 重新打开 tmux 成员的会话（在终端里 exit 了之后）。要等界面就绪，核心在后台做。
    /// 返回这次请求的序号：之后成员状态里 tmuxRunning 变成 true 就是打开了，openErrorSeq ≥ 这个序号就是这次失败了。
    /// 请求本身失败（连不上核心等）返回 nil
    func openSession(memberId: Int64) async -> Int? {
        var seq: Int?
        let ok = await perform {
            let result: OpenSessionResult = try await api.post("/api/members/\(memberId)/open", [String: String]())
            seq = result.seq
        }
        return ok ? seq : nil
    }

    /// 暂停 / 恢复自动投递（暂停期间消息只排队，人在终端里手动操作时用）
    func setPaused(memberId: Int64, paused: Bool) async {
        await perform {
            let _: OkResult = try await api.post("/api/members/\(memberId)/pause", PauseRequest(paused: paused))
        }
    }

    /// 「解除并继续」：已写入未确认的投递不再挡着后面的消息。这一条仍是未确认，不算送达，也不会重投
    func releaseAttempt(_ attemptId: Int64) async {
        await perform {
            let _: OkResult = try await api.post("/api/attempts/\(attemptId)/release", [String: String]())
        }
    }

    /// 取消一条排队中的消息（对方不会收到）。失败返回原因（排队弹窗盖在主界面上，原因要显示在弹窗里，所以不走全局弹窗）
    func cancelDelivery(_ deliveryId: Int64) async -> String? {
        await performReturningError { try await api.delete("/api/deliveries/\(deliveryId)") }
    }

    /// 强制发送一条排队中的消息：不等对方空闲，马上送进去。失败返回原因
    func forceSendDelivery(_ deliveryId: Int64) async -> String? {
        await performReturningError {
            let _: OkResult = try await api.post("/api/deliveries/\(deliveryId)/force", [String: String]())
        }
    }

    private func performReturningError(_ action: () async throws -> Void) async -> String? {
        var failure: String?
        do { try await action() } catch { failure = error.localizedDescription }
        await refresh()
        return failure
    }

    func removeMember(_ id: Int64) async {
        await perform { try await api.delete("/api/members/\(id)") }
        if selectedMemberId == id { selectMember(nil) }
    }

    // ---------- 消息 ----------

    func send(to: String, content: String, urgent: Bool = false) async -> Bool {
        guard let gid = selectedGroupId else { return false }
        return await perform {
            let _: PostMessageResult = try await api.post("/api/groups/\(gid)/messages",
                                                          PostMessageRequest(from: "user", to: to, content: content,
                                                                             urgent: urgent ? true : nil))
        }
    }

    // ---------- 执行过程 ----------

    func selectMember(_ id: Int64?) {
        selectedMemberId = id
        transcript = []
        transcriptOffset = nil
        transcriptSource = nil
        if id != nil { Task { await refreshTranscript() } }
    }

    private func refreshTranscript() async {
        guard let id = selectedMemberId else { return }
        let from = transcriptOffset
        // offset 只在同一个文件里有意义，连同读的是哪个文件一起带回去（桌面端 Codex 会分段写到新文件，见 TranscriptChunk.source）
        let source = transcriptSource?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let query = from.map { "?offset=\($0)&source=\(source)" } ?? ""
        // 请求期间切换了成员，或者另一次刷新已经读过这一段（轮询和点击同时触发），就丢掉这次结果，免得重复追加
        guard let chunk: TranscriptChunk = try? await api.get("/api/members/\(id)/transcript\(query)"),
              id == selectedMemberId, transcriptOffset == from else { return }
        transcriptOffset = chunk.offset
        transcriptSource = chunk.source
        transcript += chunk.events
    }

    // ---------- 小工具 ----------

    /// 执行一个操作，失败就弹窗；完成后立刻刷新。成功返回 true
    @discardableResult
    private func perform(_ action: () async throws -> Void) async -> Bool {
        do {
            try await action()
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
