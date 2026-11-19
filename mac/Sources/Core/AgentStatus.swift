// 集群 tmux 成员（目前是 coder 这个 Claude）的实时状态，来自 Claude Code 的 hook。
//
// 每次新建 tmux 会话时生成一个随机的 launchId，同时当作这次启动的令牌：
// hook 上报时带着它，核心核对「成员 + session_id + launchId」都对得上才认，旧会话、别的会话的事件一律忽略。
//
// 状态只放在内存里：核心重启后一律从 unknown 开始，由后续的 hook 和会话记录重新确定。
// 启动令牌存进数据库：核心重启后 tmux 里的 Claude 还活着，靠它继续认这个会话发来的事件。
//
// 实测（Claude Code 2.1.308）得出的规则，详见 kktodo/kkAgent-参考Orca改进方案.md 第四节第 1 步：
// - 主 agent 的事件不带 agent_id，子 agent 的带；
// - PermissionRequest 不带 tool_use_id，要从同一主体前一个 PreToolUse 补；
// - 批准授权会触发 PostToolBatch（列出 tool_use_id），拒绝授权什么 hook 都不触发，只能靠会话记录兜底。
import Foundation

/// 一次授权请求的概要：通知群主时告诉它卡在哪里
struct PermissionInfo {
    let bySubagent: Bool // 是子 agent 发起的（主 agent 回复完了，它的授权框也可能还占着终端）
    let tool: String     // 工具名，比如 Bash、Write
    let detail: String   // 要做什么：命令、文件路径等，截短到一行
}

/// 一份状态属于谁：群成员，或者左边栏「会话」里的单独托管会话（见 Solo.swift）。
/// 两张表的 id 各自独立，用枚举分开，不会混用。单独会话拉进群后，那个成员的状态就是这个单独会话的状态（只有一份）
enum StatusOwner: Hashable {
    case member(Int64)
    case solo(Int64)

    /// 成员的状态归谁：绑着单独会话的看那个单独会话，其他的就是成员自己
    static func of(_ member: Member) -> StatusOwner {
        member.soloId != 0 ? .solo(member.soloId) : .member(member.id)
    }

    /// hook 上报的路径片段：members/<id> 或 solo/<id>
    var hookPath: String {
        switch self {
        case .member(let id): return "members/\(id)"
        case .solo(let id): return "solo/\(id)"
        }
    }

    /// 设置文件名
    var settingsName: String {
        switch self {
        case .member(let id): return "member-\(id).json"
        case .solo(let id): return "solo-\(id).json"
        }
    }
}

/// 主 agent 的一轮怎么结束的（单独会话的「本轮已结束」提醒用，见 Solo.swift 的 recordSoloTurn）
enum TurnOutcome: String {
    case completed   // 正常结束（Stop / Codex task_complete）。只说明这一轮结束了，不代表任务做对了
    case failed      // 出错结束（StopFailure / Codex 其他原因的中止）
    case interrupted // 被打断（用户按 Esc、拒绝授权）
}

enum AgentState: String {
    case unknown            // 刚启动、核心刚重启，还不知道
    case working            // 主 agent 正在跑一轮
    case waitingPermission  // 有授权框在等人点（主 agent 或子 agent 的）
    case idle               // 主 agent 这一轮结束了，并且没有授权在等
}

final class AgentStatusStore {
    static let shared = AgentStatusStore()

    /// 装 hook 需要的最低版本：PostToolBatch 从 2.1.118 起才有，更早的版本不装它（授权只靠 Stop / 会话记录解除）
    private static let postToolBatchSince = [2, 1, 118]

    private struct Entry {
        let launchId: String
        let sessionId: String
        /// 每收到一个事件就加 1。读会话记录兜底时要先解锁，回写前核对它没变，
        /// 否则读的期间来了新的一轮，旧证据会把新一轮错误地改成空闲
        var revision = 0
        var mainTurn: AgentState = .unknown // 主 agent 的回合：只会是 unknown / working / idle
        var promptSeq = 0                   // 主 agent 第几次 UserPromptSubmit（开工序号）
        var promptId = ""                   // 主 agent 当前这一轮的 prompt_id（同一轮的事件都带它）
        /// 见过的 prompt_id（UserPromptSubmit 带来的，和从其他事件认下的），最多留 50 个。
        /// 用来区分「上一轮迟到的事件」（id 见过）和「没经过 UserPromptSubmit 就开跑的新一轮」（id 没见过），见 record
        var knownPromptIds: [String] = []
        var recentPrompts: [String] = []    // 最近几次提交的 prompt 原文（确认投递时比对编号和全文，见 TmuxDelivery.swift）
        /// 正在等的授权：主体（主 agent 是空字符串，子 agent 是它的 agent_id）→ tool_use_id 集合。
        /// 补不到 tool_use_id 时记成 "?"，只能等这个主体的回合结束来清
        var pending: [String: Set<String>] = [:]
        /// 每个主体最近一次 PreToolUse：用来给 PermissionRequest 补 tool_use_id（只认同一轮的）
        var lastPreToolUse: [String: (promptId: String, tool: String, input: String, id: String)] = [:]
        /// 这一次「等授权」从什么时候开始；不在等授权时为 nil（第 4 步：通知群主用）
        var waitingSince: Date?
        var reminded = false // 这一次等待已经提醒过「等太久了」
        /// 每个还在等的授权请求卡在哪里，键是「主体|tool_use_id」。请求解除了就删掉，提醒时只说还没处理的
        var pendingInfo: [String: PermissionInfo] = [:]

        var state: AgentState {
            pending.values.contains { !$0.isEmpty } ? .waitingPermission : mainTurn
        }

        /// 已经解除的请求，把它的概要也删掉
        mutating func prunePendingInfo() {
            pendingInfo = pendingInfo.filter { key, _ in
                let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                return parts.count == 2 && pending[parts[0]]?.contains(parts[1]) == true
            }
        }

        /// 还没处理的授权请求的概要：只有一个就是它；有好几个就合成一条，把它们都列出来
        var unresolvedSummary: PermissionInfo? {
            let infos = Array(pendingInfo.values)
            guard infos.count > 1 else { return infos.first }
            let list = infos.map { "\($0.bySubagent ? "子 agent " : "")\($0.tool)：\($0.detail)" }.joined(separator: "；")
            return PermissionInfo(bySubagent: infos.contains { $0.bySubagent }, tool: "\(infos.count) 个授权", detail: list)
        }
    }

    private let lock = NSLock()
    private var entries: [StatusOwner: Entry] = [:]
    private var refreshing = false // refreshWaiting 正在跑：上一次还没跑完（虚拟机慢）就跳过这次

    /// 变成空闲时调用，用来立即唤醒排队的投递（单独会话要先找到绑着它的成员）。在 main.swift 里设置
    var onIdle: ((StatusOwner) -> Void)?
    /// 开始等授权时调用一次；等太久还没处理时再调用一次（第三个参数为 true）。在 main.swift 里设置
    var onPermission: ((StatusOwner, PermissionInfo, Bool) -> Void)?
    /// 主 agent 的一轮真的结束了（主回合从 working 变成 idle）时调用一次，带上怎么结束的。在 main.swift 里设置。
    /// 和 onIdle 不同：授权解除、核心重启后界面就绪也会变空闲，那些不是「一轮结束」
    var onTurnEnded: ((StatusOwner, TurnOutcome) -> Void)?

    // ---------- 启动时登记 ----------

    /// 新建 tmux 会话前调用：生成 launchId（存进数据库），写好 hook 脚本和这份状态专用的设置文件，返回 claude 要加的参数。
    /// label 只用来写日志（成员名，或「单独会话 #id」）
    func prepareLaunch(owner: StatusOwner, sessionId: String, vm: String, label: String, repo: Repository) throws -> [String] {
        let launchId = UUID().uuidString.lowercased() + UUID().uuidString.lowercased() // 64 位随机串，兼作令牌
        let version = claudeVersion(vm: vm)
        let settingsPath = try writeHookFiles(owner: owner, vm: vm, launchId: launchId, version: version)
        switch owner {
        case .member(let id): try repo.setMemberLaunch(id, launchId: launchId)
        case .solo(let id): try repo.setSoloLaunch(id, launchId: launchId)
        }
        lock.lock()
        entries[owner] = Entry(launchId: launchId, sessionId: sessionId)
        lock.unlock()
        log("\(label) 的状态 hook 已就绪（Claude 版本 \(version.map { $0.map(String.init).joined(separator: ".") } ?? "未知")）")
        return ["--settings", settingsPath]
    }

    /// 核心启动时调用：按数据库里的启动令牌恢复登记，状态从 unknown 开始，等下一个 hook 事件来更新。
    /// 绑着单独会话的成员不单独登记：它的状态就是那个单独会话的那一份
    func restore(repo: Repository) {
        var restored: [StatusOwner: Entry] = [:]
        for (memberId, launchId) in (try? repo.memberLaunches()) ?? [] {
            guard let member = try? repo.getMember(memberId), member.soloId == 0 else { continue }
            restored[.member(memberId)] = Entry(launchId: launchId, sessionId: member.sessionId)
        }
        for solo in (try? repo.liveSolos()) ?? [] where !solo.launchId.isEmpty {
            restored[.solo(solo.id)] = Entry(launchId: solo.launchId, sessionId: solo.sessionId)
        }
        lock.lock()
        entries.merge(restored) { _, new in new }
        lock.unlock()
    }

    // ---------- 收 hook 事件 ----------

    /// 处理一条 hook 事件。launchId 或 session_id 对不上时返回 false（事件被忽略）
    @discardableResult
    func record(owner: StatusOwner, launchId: String, payload: [String: Any]) -> Bool {
        lock.lock()
        guard var e = entries[owner], e.launchId == launchId,
              payload["session_id"] as? String == e.sessionId else {
            lock.unlock()
            return false
        }
        let wasIdle = e.state == .idle
        let wasWaiting = e.state == .waitingPermission
        let event = payload["hook_event_name"] as? String ?? ""
        let agent = payload["agent_id"] as? String ?? "" // 空 = 主 agent
        let promptId = payload["prompt_id"] as? String ?? ""
        var turnEnded: TurnOutcome? // 这个事件让主 agent 的一轮结束了：怎么结束的
        // 主 agent 的事件带来一个没见过的 prompt_id：有一轮没经过 UserPromptSubmit 就开跑了。
        // 实测（Claude 2.1.323）：一轮还没跑完时追加的消息，敲回车那一刻就触发 UserPromptSubmit，带的是当时那一轮的旧 id；
        // 之后这条消息如果没插进当前这一轮、而是换成新 id 单独跑（Claude 输出文字时追加的；或者在途请求被丢掉时），
        // 新 id 不会再有 UserPromptSubmit。不认下它的话，它的 Stop 对不上会被当成迟到的丢掉，状态一直卡在执行中
        if agent.isEmpty, !promptId.isEmpty, !e.knownPromptIds.contains(promptId),
           ["PreToolUse", "PermissionRequest", "PostToolBatch", "Stop", "StopFailure"].contains(event) {
            if e.mainTurn == .working {
                // 正在跑的那一轮换成了新 id（旧的那一轮可能连 Stop 都没有）：之后按新 id 认
                e.promptId = promptId
                e.knownPromptIds = Array((e.knownPromptIds + [promptId]).suffix(50))
            } else if ["PreToolUse", "PermissionRequest"].contains(event) {
                // 以为空闲，其实又跑起了一轮（上一轮的 Stop 已经到了）：记成执行中。
                // 空闲时来的 Stop 不处理（比如终端里的 ! 命令只发一个 Stop，或者那一轮已经跑完了）
                e.mainTurn = .working
                e.promptId = promptId
                e.knownPromptIds = Array((e.knownPromptIds + [promptId]).suffix(50))
            }
        }
        switch event {
        case "UserPromptSubmit":
            // 只认主 agent 的；同一个 prompt_id 重复到达（hook 重发，或者一轮中途追加消息）不再算一次开工
            guard agent.isEmpty, promptId.isEmpty || promptId != e.promptId else { break }
            // 新的一轮开始，主 agent 自己的旧等待作废
            e.mainTurn = .working
            e.promptSeq += 1
            e.promptId = promptId
            if !promptId.isEmpty { e.knownPromptIds = Array((e.knownPromptIds + [promptId]).suffix(50)) }
            e.recentPrompts = Array((e.recentPrompts + [payload["prompt"] as? String ?? ""]).suffix(20))
            e.pending[""] = nil
        case "PreToolUse":
            if let id = payload["tool_use_id"] as? String {
                e.lastPreToolUse[agent] = (promptId, payload["tool_name"] as? String ?? "", stableJSON(payload["tool_input"]), id)
            }
        case "PermissionRequest":
            // 没带 tool_use_id：同一主体、同一轮里前一个 PreToolUse 的工具名和参数都一样，就用它的
            var id = payload["tool_use_id"] as? String ?? ""
            if id.isEmpty, let pre = e.lastPreToolUse[agent], pre.promptId == promptId,
               pre.tool == payload["tool_name"] as? String ?? "", pre.input == stableJSON(payload["tool_input"]) {
                id = pre.id
            }
            let key = id.isEmpty ? "?" : id
            e.pending[agent, default: []].insert(key)
            e.pendingInfo["\(agent)|\(key)"] = permissionInfo(payload, bySubagent: !agent.isEmpty)
        case "PostToolBatch":
            // 只解除这个主体、并且 tool_calls 里列出来的那几个等待
            let ids = (payload["tool_calls"] as? [[String: Any]] ?? []).compactMap { $0["tool_use_id"] as? String }
            e.pending[agent]?.subtract(ids)
        case "SubagentStop":
            // 子 agent 结束了，它的授权框也就没了
            if !agent.isEmpty { e.pending[agent] = nil }
        case "Stop", "StopFailure":
            // 主 agent 这一轮结束：只清主 agent 自己的等待，子 agent 的授权框可能还占着终端。
            // prompt_id 对不上的是上一轮迟到的 Stop，不能把新的一轮结束掉
            if agent.isEmpty, promptId.isEmpty || e.promptId.isEmpty || promptId == e.promptId {
                // 只有真的从 working 结束才算一轮结束：重复到达的 Stop 这时已经是 idle，不再算
                if e.mainTurn == .working { turnEnded = event == "Stop" ? .completed : .failed }
                e.mainTurn = .idle
                e.pending[""] = nil
            }
        default:
            break
        }
        // 第 4 步：刚开始等授权时记下时间、通知一次（说的是触发这次等待的那个请求）；不再等授权了就清掉
        e.prunePendingInfo()
        var startedWaiting: PermissionInfo?
        if !wasWaiting && e.state == .waitingPermission {
            e.waitingSince = Date()
            e.reminded = false
            startedWaiting = permissionInfo(payload, bySubagent: !agent.isEmpty)
        } else if e.state != .waitingPermission {
            e.waitingSince = nil
        }
        e.revision += 1
        entries[owner] = e
        let becameIdle = !wasIdle && e.state == .idle
        lock.unlock()
        // 在锁外回调：唤醒投递、发通知都会再来查状态
        if let turnEnded { onTurnEnded?(owner, turnEnded) }
        if becameIdle { onIdle?(owner) }
        if let startedWaiting { onPermission?(owner, startedWaiting, false) }
        return true
    }

    /// 从 PermissionRequest 事件里取出工具名和要做的事（命令、文件路径等），截短成一行
    private func permissionInfo(_ payload: [String: Any], bySubagent: Bool) -> PermissionInfo {
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        // 向用户提问（AskUserQuestion）：显示第一个问题本身，不显示整段 JSON
        let question = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
        let raw = question ?? ["command", "file_path", "path", "url", "pattern", "description"].lazy.compactMap { input[$0] as? String }.first
            ?? stableJSON(payload["tool_input"])
        let line = raw.replacingOccurrences(of: "\n", with: " ")
        return PermissionInfo(bySubagent: bySubagent, tool: payload["tool_name"] as? String ?? "未知工具",
                              detail: line.count > 120 ? String(line.prefix(120)) + "…" : line)
    }

    /// 现在卡在授权框上的：开始等的时间、还没处理的请求概要（App 用来发系统通知；单独会话由调用方换成绑着它的成员）
    func waitingOwners() -> [(owner: StatusOwner, since: Date, info: PermissionInfo)] {
        lock.lock()
        defer { lock.unlock() }
        return entries.compactMap { owner, e in
            guard e.state == .waitingPermission, let since = e.waitingSince, let info = e.unresolvedSummary else { return nil }
            return (owner, since, info)
        }
    }

    /// 当前 tmux 会话的启动令牌；同一个窗格里会话重开过的话它会变。没登记过返回 nil
    func launchId(owner: StatusOwner) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[owner]?.launchId
    }

    /// 最近提交过的 prompt 原文（主 agent 的，最多 20 条）。只返回这个会话的：成员换了会话后，旧会话的投递不能拿新会话的记录确认
    func recentPrompts(owner: StatusOwner, sessionId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let e = entries[owner], e.sessionId == sessionId else { return [] }
        return e.recentPrompts
    }

    // ---------- 同一个进程换了会话（/clear、/resume，见 SessionFollow.swift） ----------

    /// 收到 SessionStart 时先问一下：启动令牌对得上、并且会话 ID 和登记的不一样，返回登记的旧 ID；否则返回 nil（不用换）
    func changedSession(owner: StatusOwner, launchId: String, newSessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let e = entries[owner], e.launchId == launchId, !newSessionId.isEmpty, e.sessionId != newSessionId else { return nil }
        return e.sessionId
    }

    /// 数据库已经改成新会话后调用：登记换成新 ID，旧会话的回合、授权等待、最近提交一律作废，记成空闲
    /// （/clear、/resume 只能在输入框里敲，说明这时没有在跑的一轮）。然后唤醒排队的投递
    func adoptSession(owner: StatusOwner, launchId: String, sessionId: String) {
        lock.lock()
        guard let old = entries[owner], old.launchId == launchId else {
            lock.unlock()
            return
        }
        var e = Entry(launchId: launchId, sessionId: sessionId)
        e.mainTurn = .idle
        e.revision = old.revision + 1 // 正在读会话记录兜底的那边回写前会发现变了，不会拿旧会话的证据覆盖
        entries[owner] = e
        lock.unlock()
        onIdle?(owner)
    }

    /// 单独会话结束（销毁 / 用户 exit）后去掉它的状态登记，之后它的 hook 事件一律不认
    func forget(_ owner: StatusOwner) {
        lock.lock()
        entries[owner] = nil
        lock.unlock()
    }


    /// 核心自己新开 / 重开的 tmux 会话，界面已经就绪（出现了输入框）：这次启动以来一个 hook 事件都没来过，
    /// 说明还没开始任何一轮，记成空闲。不记的话要等它跑完一轮才知道它空闲——但没人给它发消息它就不会跑，
    /// 「重新打开会话」之后排队的消息会永远投不进去（续接的会话记录最后可能停在上次被杀时的半轮，也认不出空闲）
    func markReadyAfterLaunch(owner: StatusOwner, launchId: String) {
        lock.lock()
        guard var e = entries[owner], e.launchId == launchId, e.revision == 0, e.mainTurn == .unknown else {
            lock.unlock()
            return
        }
        e.mainTurn = .idle
        e.revision += 1
        entries[owner] = e
        lock.unlock()
        onIdle?(owner)
    }

    // ---------- 第 6 步：打断用 ----------

    /// 某一刻的主回合信息，按 Esc 之前和确认之后核对用
    struct TurnSnapshot {
        let launchId: String
        let mainTurn: AgentState
        let promptId: String
        let revision: Int
        let noPermissionWaiting: Bool // 主 agent 和子 agent 都没有授权在等
    }

    func turnSnapshot(owner: StatusOwner) -> TurnSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let e = entries[owner] else { return nil }
        return TurnSnapshot(launchId: e.launchId, mainTurn: e.mainTurn, promptId: e.promptId,
                            revision: e.revision, noPermissionWaiting: !e.pending.values.contains { !$0.isEmpty })
    }

    /// 会话记录证明这一轮已经结束（被 Esc 打断、或者自己结束了、却等不到 Stop）时，把主回合改成空闲。
    /// 在锁内核对：还是这次启动、还是这一轮、期间没来过新事件（revision 没变）、主回合还是 working、没有任何授权在等。
    /// 只改主回合，不碰子 agent 的等待。返回有没有改成：没改成说明期间状态变了，调用方要重新取证，不能当成已经空闲。
    /// outcome：会话记录证明的结束方式（被打断 / 自己结束），改成了才按它记一次「一轮结束」
    func markTurnEnded(owner: StatusOwner, launchId: String, promptId: String, revision: Int, outcome: TurnOutcome) -> Bool {
        lock.lock()
        guard var e = entries[owner], e.launchId == launchId, !promptId.isEmpty, e.promptId == promptId,
              e.revision == revision, e.mainTurn == .working, !e.pending.values.contains(where: { !$0.isEmpty }) else {
            lock.unlock()
            return false
        }
        e.mainTurn = .idle
        e.revision += 1
        entries[owner] = e
        lock.unlock()
        onTurnEnded?(owner, outcome)
        onIdle?(owner)
        return true
    }

    // ---------- 查状态 ----------

    /// 只看内存里记着的状态，不读会话记录（群详情接口用：界面每 2 秒刷新一次，不能被虚拟机里的读取拖慢）。
    /// 拒绝授权后的兜底解除由投递流程里的 state(of:) 来做
    func cachedState(of member: Member) -> AgentState {
        cachedState(owner: .of(member), tmux: member.tmux)
    }

    /// 同上，按状态归属查（单独会话的列表用）
    func cachedState(owner: StatusOwner, tmux: String) -> AgentState {
        lock.lock()
        let state = entries[owner]?.state
        lock.unlock()
        guard let state, Tmux.exists(tmux) else { return .unknown }
        return state
    }

    /// 给所有「等授权」的成员核对一次会话记录（拒绝授权后没有任何 hook，靠它把状态解除）。
    /// 由投递的定时检查在后台调用，同一时间只跑一次
    func refreshWaiting(repo: Repository) {
        lock.lock()
        guard !refreshing else {
            lock.unlock()
            return
        }
        refreshing = true
        let waiting = entries.filter { $0.value.state == .waitingPermission }.map(\.key)
        // 等授权超过设定时间还没处理：再提醒一次（每次等待只提醒这一次）
        var reminders: [(StatusOwner, PermissionInfo)] = []
        for owner in waiting {
            // 提醒里只说现在还没处理的请求（最初触发的那个可能已经处理掉了）
            guard var e = entries[owner], !e.reminded, let since = e.waitingSince, let info = e.unresolvedSummary,
                  Date().timeIntervalSince(since) >= Config.permissionRemindAfter else { continue }
            e.reminded = true
            entries[owner] = e
            reminders.append((owner, info))
        }
        lock.unlock()
        for (owner, info) in reminders { onPermission?(owner, info, true) }
        defer {
            lock.lock()
            refreshing = false
            lock.unlock()
        }
        for owner in waiting {
            // 用会话记录兜底要知道会话在哪：成员用成员自己的；单独会话（不管绑没绑进群）用单独会话的记录
            switch owner {
            case .member(let id):
                guard let member = try? repo.getMember(id) else { continue }
                if state(of: member) == .idle { onIdle?(owner) }
            case .solo(let id):
                guard let solo = try? repo.getSolo(id), solo.state == "running" else { continue }
                if state(owner: owner, sessionId: solo.sessionId, vm: solo.vm, tmux: solo.tmux, label: "单独会话 #\(id)") == .idle {
                    onIdle?(owner)
                }
            }
        }
    }

    /// 成员当前状态；没有登记过（不是 tmux 里的 Claude）、或者 tmux 会话已经不在了，返回 unknown。
    /// 在等授权时顺带用会话记录兜底：拒绝授权不触发任何 hook，只能看会话记录里有没有出现对应的 tool_result。
    /// 要读文件（虚拟机里还要走 ubx），只在投递流程的后台队列里调用
    func state(of member: Member) -> AgentState {
        state(owner: .of(member), sessionId: member.sessionId, vm: member.vm, tmux: member.tmux, label: member.alias)
    }

    /// 同上，直接给出会话在哪（没绑进群的单独会话没有成员，用它自己的记录）。label 只用来写日志
    func state(owner: StatusOwner, sessionId: String, vm: String, tmux: String, label: String) -> AgentState {
        lock.lock()
        let e = entries[owner]
        lock.unlock()
        guard let e else { return .unknown }
        // 进程退出后 tmux 会话会跟着关掉；旧进程留下的状态（比如没解除的授权等待）不能再算数
        guard Tmux.exists(tmux) else { return .unknown }
        guard e.state == .waitingPermission else { return e.state }

        let waiting = Set(e.pending.values.flatMap { $0 }).subtracting(["?"])
        guard !waiting.isEmpty, let file = Transcript.find(agent: .claude, sessionId: sessionId, vm: vm) else {
            return e.state
        }
        let evidence = Transcript.claudePermissionEvidence(file: file, vm: vm)
        let settled = evidence.resultIds.intersection(waiting)
        guard !settled.isEmpty else { return e.state }

        lock.lock()
        guard var current = entries[owner], current.launchId == e.launchId else {
            lock.unlock()
            return .unknown
        }
        // 读会话记录期间又来了事件（比如新的一轮开始了）：这次读到的证据作废，按最新状态返回，下次查询再核对
        guard current.revision == e.revision else {
            lock.unlock()
            return current.state
        }
        for key in current.pending.keys { current.pending[key]?.subtract(settled) }
        // 有 tool_result 只说明授权框没了（批准也会写）。主 agent 的授权被拒绝时，这一轮也跟着结束，
        // 会话记录最后是打断标记，之后不会再有 Stop，所以这时才把主回合记成结束（真的从 working 结束才算一轮被打断）
        var interrupted = false
        if evidence.endedByInterrupt, e.pending[""]?.isDisjoint(with: settled) == false {
            interrupted = current.mainTurn == .working
            current.mainTurn = .idle
        }
        current.prunePendingInfo()
        if current.state != .waitingPermission { current.waitingSince = nil }
        current.revision += 1
        entries[owner] = current
        let state = current.state
        lock.unlock()
        log("\(label) 的授权等待已从会话记录确认解除（\(settled.count) 个）")
        if interrupted { onTurnEnded?(owner, .interrupted) }
        return state
    }

    // ---------- hook 文件 ----------

    /// 写 hook 脚本（所有成员共用）和这个成员的设置文件，返回设置文件路径。
    /// 数据目录在 /Users 下，虚拟机里同一路径能看到同样的文件（虚拟机里也是同一个 uid，所以 700 权限照样能读）
    private func writeHookFiles(owner: StatusOwner, vm: String, launchId: String, version: [Int]?) throws -> String {
        let fm = FileManager.default
        let dir = "\(Config.dataDir)/hooks"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)

        // 脚本参数：<事件名> <归属：members/<id> 或 solo/<id>> <launchId> <vm 或 host>
        // 以前第二个参数只是成员 id（纯数字）：正在跑的老会话还用着旧的设置文件，所以纯数字照旧当成员
        // 虚拟机里经默认网关（就是物理机）访问核心，Host 头写成核心认的本机地址（做法同 Relay.swift）
        let script = """
            #!/bin/sh
            # kkAgent 状态 hook：把 Claude Code 的事件原样转给核心，核心只取需要的字段
            # PermissionRequest 必须输出 {}；SessionStart 输出核心的回复（会被加进上下文：换了会话的群成员补上入群说明，
            # 其他情况核心回复为空）；其他事件什么都不输出（UserPromptSubmit 的输出会被加进上下文）
            [ "$1" = PermissionRequest ] && printf '{}\\n'
            if [ "$1" = SessionStart ]; then out=-; else out=/dev/null; fi
            if [ "$4" = vm ]; then host=$(ip route show default | awk '{print $3; exit}'); else host=127.0.0.1; fi
            case "$2" in *[!0-9]*) path=$2 ;; *) path=members/$2 ;; esac
            # 连接 2 秒、总共 5 秒超时；核心连不上也不影响 Claude
            curl -s -o "$out" --noproxy '*' --connect-timeout 2 -m 5 \\
              -H 'Host: 127.0.0.1:\(Config.port)' -H 'Content-Type: application/json' --data-binary @- \\
              "http://$host:\(Config.port)/api/$path/hook?launch=$3" 2>/dev/null
            exit 0
            """
        let scriptPath = "\(dir)/status-hook.sh"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptPath)

        // SessionStart：用户在终端里 /clear、/resume 换了会话时跟着换（见 SessionFollow.swift）
        var events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "SubagentStop", "Stop", "StopFailure"]
        if let version, version.lexicographicallyPrecedes(Self.postToolBatchSince) == false {
            events.append("PostToolBatch")
        }
        let place = vm.isEmpty ? "host" : "vm"
        var hooks: [String: Any] = [:]
        for event in events {
            var entry: [String: Any] = ["hooks": [["type": "command", "command": "\(scriptPath) \(event) \(owner.hookPath) \(launchId) \(place)", "timeout": 10]]]
            if ["PreToolUse", "PermissionRequest"].contains(event) { entry["matcher"] = "*" }
            hooks[event] = [entry]
        }
        let settingsPath = "\(dir)/\(owner.settingsName)"
        try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: .prettyPrinted)
            .write(to: URL(fileURLWithPath: settingsPath))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsPath)
        return settingsPath
    }

    /// 在实际要跑的那台机器上探测 Claude 版本（虚拟机里的版本不能拿物理机的代替），探测不到返回 nil
    private func claudeVersion(vm: String) -> [Int]? {
        let output: String
        if vm.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Config.claudeBin)
            p.arguments = ["--version"]
            p.environment = ShellEnv.environment
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
        } else {
            // bash -i：虚拟机里的 claude 是 nvm 装的，要读 .bashrc 才在 PATH 里
            guard let data = VM.output(vm, ["bash", "-ic", "claude --version"]) else { return nil }
            output = String(decoding: data, as: UTF8.self)
        }
        // 输出形如「2.1.308 (Claude Code)」，取第一个 x.y.z
        guard let range = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return output[range].split(separator: ".").compactMap { Int($0) }
    }

    /// 把工具参数转成固定顺序的 JSON 字符串，用来比较 PreToolUse 和 PermissionRequest 是不是同一次调用
    private func stableJSON(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
