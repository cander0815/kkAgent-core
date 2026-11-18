// 接口路由和业务逻辑。界面用 JSON，kkAgent 命令行用表单提交、拿纯文本。
//
// GET    /api/health                       核心运行信息
// GET    /api/groups                       群列表（带统计）
// POST   /api/groups                       新建群 {name}
// GET    /api/groups/:id                   群详情：成员（含状态）、消息、投递记录
// DELETE /api/groups/:id                   解散群
// GET    /api/groups/:id/members           成员列表（?format=text 给命令行）
// POST   /api/groups/:id/members           加成员 {agent, sessionId, alias, description}
// DELETE /api/members/:id                  移出成员
// POST   /api/members/:id/session          更换成员的会话 {sessionId}（集群群主会连子群里的一起换）
// GET    /api/members/:id/transcript       执行过程（?offset= 增量读取）
// POST   /api/groups/:id/messages          发消息 {from, to, content}（JSON 或表单）
// POST   /api/groups/:id/spawn             集群：群主建一个子群 + 后台 coder / tester（表单 from, task, content，返回纯文本）
// POST   /api/groups/:id/reopen            集群：群主找回已解散的子群（表单 from、task、content、coder、tester，返回纯文本）
// POST   /api/groups/:id/dissolve          集群：群主解散自己的子群（表单 from，返回纯文本）
// GET    /api/relay/hook                   中转会话的 hook 专用
// POST   /api/members/:id/hook             tmux 成员的状态 hook 专用（?launch= 启动令牌，请求体是 hook 事件原文）
// POST   /api/attempts/:id/release         「解除并继续」：已写入未确认的投递不再挡着这个会话后面的消息（投递本身仍是未确认）
// POST   /api/members/:id/pause            暂停 / 恢复自动投递 {paused}（暂停期间消息只排队，人在终端里手动操作时用）
// GET    /api/attention                    现在卡在授权框上、需要人去处理的成员（所有群的，App 用来发系统通知）
// POST   /api/members/:id/open             重新打开 tmux 成员的会话（在终端里 exit 了之后），接着原来的会话，不发任何消息
// GET    /api/solo                         左边栏「会话」：还没结束的单独托管会话
// POST   /api/solo                         新建单独会话 {agent, cwd}（后台启动，马上返回）；带 sessionId、vm 时是「继续沟通」：接着这个已有会话打开
// DELETE /api/solo/:id                     销毁单独会话（关 tmux；绑着它的群成员一起移出）
// POST   /api/solo/:id/hook                单独会话的状态 hook 专用（?launch= 启动令牌）
// GET    /api/vms                          正在运行的虚拟机名字
// GET    /api/model-settings               设置 → 模型：当前的默认模型 / 思考强度，以及两个 CLI 支持的模型
// POST   /api/model-settings               保存默认模型 / 思考强度 {claudeModel, claudeEffort, codexModel, codexEffort}
// GET    /api/sessions                     历史会话列表（?agent=claude|codex&vm=机器名，vm 不带表示物理机）
// GET    /api/sessions/:id/transcript      会话全部内容（?agent=&vm=&offset=，从头读，offset 增量读取）
import Foundation

/// 用户输入有问题，返回 400 和一句人话
struct UserError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

final class API {
    private let repo: Repository
    private let delivery: DeliveryQueue
    private let startedAt = nowISO()
    private let reservedAliases: Set<String> = ["all", "user", "system"]

    private let cluster: Cluster

    init(repo: Repository, delivery: DeliveryQueue) {
        self.repo = repo
        self.delivery = delivery
        cluster = Cluster(repo: repo, delivery: delivery)
    }

    func handle(_ req: HTTPRequest) -> HTTPResponse {
        // 命令行（表单提交或 format=text）拿到的结果和错误都是纯文本
        let forCli = req.isForm || req.query["format"] == "text"
        // 只接受本机程序（界面、命令行、hook）的请求。浏览器里的网页发请求一定带 Origin，
        // DNS rebinding 时 Host 是攻击者的域名，两样都拒掉，网页就没法冒充用户给群发消息或读数据
        let host = req.headers["host"] ?? ""
        guard req.headers["origin"] == nil, host == "127.0.0.1:\(Config.port)" || host == "localhost:\(Config.port)" else {
            return .text("只接受本机程序的请求", status: 403)
        }
        do {
            return try route(req)
        } catch let error as UserError {
            return forCli ? .text(error.message, status: 400) : .json(APIError(error: error.message), status: 400)
        } catch {
            log("接口出错 \(req.method) \(req.path)：\(error)")
            let message = "核心内部错误：\(error)"
            return forCli ? .text(message, status: 500) : .json(APIError(error: message), status: 500)
        }
    }

    private func route(_ req: HTTPRequest) throws -> HTTPResponse {
        let parts = req.path.split(separator: "/").map(String.init) // 如 ["api", "groups", "g1ab"]
        let method = req.method

        // 按模板匹配路径，:xxx 的位置按顺序取出来，匹配不上返回 nil
        func match(_ verb: String, _ template: String) -> [String]? {
            let t = template.split(separator: "/").map(String.init)
            guard verb == method, t.count == parts.count else { return nil }
            var params: [String] = []
            for (expected, actual) in zip(t, parts) {
                if expected.hasPrefix(":") { params.append(actual) } else if expected != actual { return nil }
            }
            return params
        }

        if match("GET", "api/health") != nil {
            return .json(CoreHealth(pid: getpid(), startedAt: startedAt, port: Config.port, relayRunning: Relay.anyRunning))
        }
        if match("GET", "api/groups") != nil {
            return .json(try repo.listGroups())
        }
        if match("POST", "api/groups") != nil {
            let body = try decode(CreateGroupRequest.self, req)
            let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw UserError("群名不能为空") }
            return .json(try repo.createGroup(name: name, cluster: body.cluster ?? false))
        }
        if let p = match("GET", "api/groups/:id") {
            return .json(try groupDetail(p[0]))
        }
        if let p = match("DELETE", "api/groups/:id") {
            try dissolveGroup(p[0])
            return .json(OkResult())
        }
        if let p = match("GET", "api/groups/:id/members") {
            let group = try requireGroup(p[0])
            let members = try repo.listMembers(groupId: p[0])
            guard req.query["format"] == "text" else { return .json(members) }
            let lines = members.map { "- \($0.alias)（\($0.agent.rawValue)\($0.description.isEmpty ? "" : "，" + $0.description)）" }
            return .text((["群聊「\(group.name)」(\(group.id)) 的成员："] + lines).joined(separator: "\n"))
        }
        if let p = match("POST", "api/groups/:id/members") {
            return .json(try addMember(p[0], try decode(AddMemberRequest.self, req)))
        }
        if let p = match("DELETE", "api/members/:id") {
            try removeMember(Int64(p[0]) ?? -1)
            return .json(OkResult())
        }
        if let p = match("POST", "api/members/:id/session") {
            return .json(try changeSession(Int64(p[0]) ?? -1, try decode(ChangeSessionRequest.self, req)))
        }
        if let p = match("GET", "api/members/:id/transcript") {
            guard let member = try repo.getMember(Int64(p[0]) ?? -1) else { throw UserError("成员不存在") }
            guard let file = Transcript.find(agent: member.agent, sessionId: member.sessionId, vm: member.vm) else { throw UserError("找不到会话文件") }
            // 第一次打开只读最后 512KB，避免大会话一次读太多。
            // 界面带回来的 source 不是现在这个文件（桌面端 Codex 切到了新的一段）：旧文件的 offset 对新文件没意义，从新文件的起点读
            let sameFile = req.query["source"].map { $0.isEmpty || $0 == file } ?? true
            let requested = sameFile ? req.query["offset"].flatMap { Int($0) } : 0
            let offset = max(0, requested ?? Transcript.fileSize(file, vm: member.vm) - 512 * 1024)
            return .json(Transcript.readEvents(agent: member.agent, file: file, offset: offset, vm: member.vm))
        }
        if let p = match("POST", "api/groups/:id/messages") {
            let body: PostMessageRequest
            if req.isForm {
                let form = req.formValues()
                body = PostMessageRequest(from: form["from"] ?? "user", to: form["to"] ?? "", content: form["content"] ?? "",
                                          verdict: form["verdict"], urgent: form["urgent"] == "1", re: form["re"])
            } else {
                body = try decode(PostMessageRequest.self, req)
            }
            // --re 的编号先检查格式，写错了不发，免得消息发出去了才报错
            let reIds = try parseMessageIds(body.re ?? "")
            let result = try postMessage(p[0], body)
            let names = result.recipients.isEmpty ? "用户" : result.recipients.joined(separator: "、")
            // 紧急消息不承诺「第一个送达」：可能已经有一批正在写入，或者被暂停、授权框、未确认挡着
            let note = result.message.urgent && !result.recipients.isEmpty ? "（已标为紧急，满足投递条件后优先合并送达）" : ""
            // 消息已经发出去了，标记失败也不能报错：否则 agent 以为没发出去，会再发一遍
            let handledNote = reIds.isEmpty || body.from == "user" ? ""
                : "\n" + ((try? markHandled(p[0], me: body.from, ids: reIds)) ?? "消息已发出，但没能标记已处理，用 \(Config.cli) done 再标一次")
            return req.isForm ? .text("已发送给 \(names)\(note)\(handledNote)") : .json(result)
        }
        if let p = match("GET", "api/groups/:id/inbox") {
            let me = (req.query["me"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .text(try inboxText(p[0], me: me, direct: req.query["direct"] == "1", includeHandled: req.query["all"] == "1"))
        }
        if let p = match("POST", "api/groups/:id/done") {
            let form = req.formValues()
            let me = (form["me"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = try parseMessageIds(form["ids"] ?? "")
            guard !ids.isEmpty else { throw UserError("要写消息编号，如 \(Config.cli) done -g \(p[0]) --me \(me.isEmpty ? "<我的名字>" : me) 123 124") }
            return .text(try markHandled(p[0], me: me, ids: ids))
        }
        if let p = match("POST", "api/groups/:id/spawn") {
            let form = req.formValues()
            let trim = { (key: String) in (form[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            return .text(try cluster.spawn(groupId: p[0], from: trim("from"), task: trim("task"), brief: trim("content")))
        }
        if let p = match("POST", "api/groups/:id/reopen") {
            let form = req.formValues()
            let trim = { (key: String) in (form[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            return .text(try cluster.reopen(groupId: p[0], from: trim("from"), task: trim("task"), brief: trim("content"),
                                            coderId: trim("coder"), testerId: trim("tester")))
        }
        if let p = match("POST", "api/groups/:id/dissolve") {
            let from = (req.formValues()["from"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .text(try ownerDissolve(p[0], from: from))
        }
        if match("GET", "api/relay/hook") != nil {
            // 虚拟机里的中转会话会带上 ?vm=机器名，物理机的不带
            let data = try JSONSerialization.data(withJSONObject: Relay.on(req.query["vm"] ?? "").hookResponse())
            return HTTPResponse(status: 200, contentType: "application/json; charset=utf-8", body: data)
        }
        if let p = match("POST", "api/members/:id/hook") {
            // 怎么处理、回复什么见 hookEvent
            let payload = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            return hookEvent(owner: .member(Int64(p[0]) ?? -1), launchId: req.query["launch"] ?? "", payload: payload)
        }
        // ---------- 左边栏「会话」：单独托管会话（见 Solo.swift） ----------
        if match("GET", "api/solo") != nil {
            return .json(delivery.soloList())
        }
        if match("POST", "api/solo") != nil {
            let body = try decode(CreateSoloRequest.self, req)
            let solo = (body.sessionId ?? "").isEmpty
                ? try delivery.createSolo(agent: body.agent, cwd: body.cwd)
                : try delivery.resumeSolo(agent: body.agent, sessionId: body.sessionId ?? "", vm: body.vm ?? "", cwd: body.cwd)
            return .json(delivery.soloList().first { $0.id == solo.id })
        }
        if let p = match("DELETE", "api/solo/:id") {
            try delivery.destroySolo(Int64(p[0]) ?? -1)
            return .json(OkResult())
        }
        if let p = match("POST", "api/solo/:id/hook") {
            let payload = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            return hookEvent(owner: .solo(Int64(p[0]) ?? -1), launchId: req.query["launch"] ?? "", payload: payload)
        }
        if match("GET", "api/attention") != nil {
            // 只读内存里记着的状态，不碰会话记录（App 每 2 秒查一次）。tmux 会话已经不在的不算
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let items: [AttentionItem] = AgentStatusStore.shared.waitingOwners().compactMap { waiting in
                let since = formatter.string(from: waiting.since)
                switch waiting.owner {
                case .member(let id):
                    guard let member = try? repo.getMember(id), Tmux.exists(member.tmux),
                          let group = try? repo.getGroup(member.groupId) else { return nil }
                    return AttentionItem(memberId: member.id, groupId: group.id, groupName: group.name, alias: member.alias,
                                         tool: waiting.info.tool, detail: waiting.info.detail, bySubagent: waiting.info.bySubagent,
                                         since: since)
                case .solo(let id):
                    // 单独会话一律带上 soloId（App 按它去重，绑进群、移出群前后是同一次等待）；
                    // 绑在群里的再带上群和成员，点通知时跳到群里那个成员，没绑的跳到「会话」页
                    guard let solo = try? repo.getSolo(id), solo.state == "running", Tmux.exists(solo.tmux) else { return nil }
                    let member = try? repo.memberBound(toSolo: id)
                    let group = member.flatMap { try? repo.getGroup($0.groupId) }
                    return AttentionItem(memberId: group == nil ? 0 : member?.id ?? 0, groupId: group?.id ?? "", groupName: group?.name ?? "",
                                         alias: group == nil ? "单独会话 #\(id)" : member?.alias ?? "",
                                         tool: waiting.info.tool, detail: waiting.info.detail, bySubagent: waiting.info.bySubagent,
                                         since: since, soloId: id)
                }
            }
            return .json(items.sorted { $0.since < $1.since })
        }
        if let p = match("POST", "api/members/:id/open") {
            guard let member = try repo.getMember(Int64(p[0]) ?? -1) else { throw UserError("成员不存在") }
            guard !member.tmux.isEmpty else { throw UserError("\(member.alias) 不是常驻在 tmux 里的成员") }
            // 要等界面就绪（几秒到几十秒），放到后台做；返回这次请求的序号，界面拿它和 openErrorSeq 对照判断是否失败
            return .json(OpenSessionResult(seq: delivery.openSession(member)))
        }
        if let p = match("POST", "api/members/:id/pause") {
            guard let member = try repo.getMember(Int64(p[0]) ?? -1) else { throw UserError("成员不存在") }
            let body = try decode(PauseRequest.self, req)
            try repo.setMemberPaused(member.id, paused: body.paused)
            log("用户\(body.paused ? "暂停" : "恢复")了 \(member.alias) 的自动投递")
            if !body.paused { delivery.wake(memberId: member.id) } // 恢复后马上把排着的消息送进去（对方空闲的话）
            return .json(OkResult())
        }
        // 排队列表里的「取消」和「强制发送」：只针对还在排队的普通消息（入群说明不能动，成员没它就启动不起来）
        if let p = match("DELETE", "api/deliveries/:id") {
            let queued = try requirePendingDelivery(p[0])
            guard try repo.cancelPendingDelivery(queued.id) else { throw UserError("这条消息刚好已经在送了，取消不了") }
            log("用户取消了一条排队中的消息（投递 \(queued.id)）")
            return .json(OkResult())
        }
        if let p = match("POST", "api/deliveries/:id/force") {
            let queued = try requirePendingDelivery(p[0])
            guard let member = try repo.getMember(queued.memberId) else { throw UserError("成员不存在") }
            guard !member.paused else { throw UserError("\(member.alias) 已暂停自动投递，先恢复再强制发送") }
            log("用户要求强制发送给 \(member.alias) 的排队消息（投递 \(queued.id)）")
            guard self.delivery.forceSend(deliveryId: queued.id, member: member) else {
                throw UserError("没能强制发送，消息仍在排队：\(member.alias) 可能弹着授权框、输入框里有没提交的文字、状态不明、有一条未确认的投递或还没结算的打断挡着，或者托管的 Codex 会话还没建好")
            }
            return .json(OkResult())
        }
        if let p = match("POST", "api/attempts/:id/release") {
            // 只解除调度上的阻挡：这次投递仍是「已写入未确认」，绝不改成送达，也不重投
            guard let attempt = repo.getAttempt(Int64(p[0]) ?? -1) else { throw UserError("投递尝试不存在") }
            try repo.releaseAttempt(attempt.id)
            log("用户解除了投递 \(DeliveryQueue.attemptTag(attempt.id)) 的阻挡，后面排队的消息继续投")
            return .json(OkResult())
        }
        if match("GET", "api/vms") != nil {
            return .json(VM.running())
        }
        if match("GET", "api/model-settings") != nil {
            return .json(ModelSettingsInfo(settings: ModelSettingsStore.load(),
                                           claudeModels: ModelCatalog.claude(), codexModels: ModelCatalog.codex()))
        }
        if match("POST", "api/model-settings") != nil {
            try ModelSettingsStore.save(try decode(ModelSettings.self, req))
            return .json(OkResult())
        }
        if match("GET", "api/sessions") != nil {
            let agent = try agentParam(req)
            // 带上每个会话用过的群名（session_groups 表），界面搜索时也匹配群名
            let groupNames = (try? repo.sessionGroupNames(agent: agent)) ?? [:]
            return .json(Sessions.list(agent: agent, vm: req.query["vm"] ?? "").map { session in
                var session = session
                session.groups = groupNames[session.id]
                return session
            })
        }
        if let p = match("GET", "api/sessions/:id/transcript") {
            let agent = try agentParam(req)
            let vm = req.query["vm"] ?? ""
            guard let file = Transcript.find(agent: agent, sessionId: p[0], vm: vm) else { throw UserError("找不到会话文件") }
            // 和成员的执行过程不同，这里默认从头读，界面会接着 offset 一段段读完。
            // 带回来的 source 不是现在这个文件（切了分段）：从新文件的起点读
            let sameFile = req.query["source"].map { $0.isEmpty || $0 == file } ?? true
            let offset = sameFile ? req.query["offset"].flatMap { Int($0) } ?? 0 : 0
            return .json(Transcript.readEvents(agent: agent, file: file, offset: offset, vm: vm, fullText: true))
        }
        throw UserError("接口不存在：\(method) \(req.path)")
    }

    private func agentParam(_ req: HTTPRequest) throws -> AgentKind {
        guard let agent = AgentKind(rawValue: req.query["agent"] ?? "") else { throw UserError("agent 只能是 claude 或 codex") }
        return agent
    }

    // ---------- 业务逻辑 ----------

    private func requireGroup(_ gid: String) throws -> GroupSummary {
        guard let group = try repo.getGroup(gid) else { throw UserError("群聊 \(gid) 不存在") }
        return group
    }

    /// 取一条「排队中」的普通投递；已经送出 / 不存在 / 是入群说明都报错
    private func requirePendingDelivery(_ id: String) throws -> Repository.QueuedDelivery {
        guard let queued = repo.queuedDelivery(Int64(id) ?? -1), queued.status == .pending else {
            throw UserError("这条消息已经不在排队了，可能刚刚送出去了")
        }
        guard queued.purpose != .bootstrap else { throw UserError("入群说明不能取消或强制发送") }
        return queued
    }

    private func groupDetail(_ gid: String) throws -> GroupDetail {
        let group = try requireGroup(gid)
        let members = try repo.listMembers(groupId: gid).map { MemberDetail(member: $0, state: state(of: $0)) }
        return GroupDetail(group: group, members: members, messages: try repo.listMessages(groupId: gid),
                           deliveries: try repo.listDeliveries(groupId: gid))
    }

    /// 成员当前状态：只给事实，文案由界面决定
    private func state(of m: Member) -> MemberState {
        let file = Transcript.find(agent: m.agent, sessionId: m.sessionId, vm: m.vm)
        let live = m.agent == .claude ? Transcript.claudeLiveStatus(sessionId: m.sessionId, vm: m.vm) : .init()
        // 只有 tmux 里的 Claude 装了状态 hook
        let agentStatus = m.agent == .claude && !m.tmux.isEmpty ? AgentStatusStore.shared.cachedState(of: m).rawValue : ""
        // kkAgent 托管的会话还没写出会话文件：看它的第一条投递（入群说明 / bootstrap）走到哪了，界面显示「正在启动 / 启动失败」
        var startup = "", startupError = ""
        if m.headless && file == nil, let first = repo.firstDelivery(memberId: m.id) {
            switch first.status {
            case .pending, .running: startup = "starting"
            case .failed:
                startup = "failed"
                startupError = first.error
            default: break
            }
        }
        return MemberState(transcriptFound: file != nil, delivering: delivery.isDelivering(m.id),
                           codexBusy: m.agent == .codex
                               && CodexTurns.shared.isBusy(sessionId: m.sessionId, startedAfter: CodexTurns.processStart(tmux: m.tmux)) == true,
                           claudeLive: live.live, claudeLiveName: live.name, claudeLiveStatus: live.status,
                           agentStatus: agentStatus, tmuxRunning: !m.tmux.isEmpty && Tmux.exists(m.tmux),
                           openError: delivery.openError(memberId: m.id).message, openErrorSeq: delivery.openError(memberId: m.id).seq,
                           startup: startup, startupError: startupError)
    }

    /// 发一条群消息：入库，再按收件人逐个排队投递
    private func postMessage(_ gid: String, _ body: PostMessageRequest) throws -> PostMessageResult {
        // 群没了、或发送人不在群里：多半是任务结束后会话又被打开了，直接告诉它别再发
        guard let group = try repo.getGroup(gid) else {
            throw UserError(Prompts.notInGroup("群聊 \(gid) 已经解散了。"))
        }
        guard !body.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UserError("消息内容不能为空") }

        let members = try repo.listMembers(groupId: gid)
        let sender = members.first { $0.alias == body.from }
        if body.from != "user" && sender == nil {
            // 移出时成员记录已删，分不清是被移出还是名字写错，两种情况都提一句
            throw UserError(Prompts.notInGroup("\(body.from) 已经不在群聊「\(group.name)」里了"
                + "（如果你确定还在群里，可能是名字写错了，用 \(Config.cli) members -g \(gid) 核对）。"))
        }
        guard body.to != body.from else { throw UserError("不能发给自己") }
        let verdict = try checkVerdict(group: group, body: body)

        var to = body.to
        var content = body.content
        var recipients: [Member]
        switch to {
        case "all": recipients = members.filter { $0.alias != body.from }
        case "user": recipients = [] // 发给用户本人，只入库显示
        default:
            guard let target = members.first(where: { $0.alias == to }) else {
                throw UserError("收件人 \(to) 不在群里，可用 \(Config.cli) members -g \(gid) 查看成员")
            }
            recipients = [target]
        }

        if !group.parentId.isEmpty {
            // 集群子群：打回计数。tester 每打回一次 +1，超过上限后不再投给 coder，改交给群主
            if verdict == "fail" {
                let (count, blocked) = try repo.recordFail(groupId: gid, limit: maxFails)
                if blocked {
                    // 暂停后一律不投给 coder
                    content = Prompts.blockedNotice(count: count, limit: maxFails) + "\n\n" + content
                    if let owner = members.first(where: { $0.alias == group.owner }) {
                        log("子群 \(gid) 第 \(count) 次打回，已暂停自动打回，交给群主")
                        to = owner.alias
                        recipients = [owner]
                    } else {
                        // 群主被移出了子群：只能留给用户在界面上看
                        log("子群 \(gid) 第 \(count) 次打回，已暂停；群主不在子群里，留给用户")
                        to = "user"
                        content = Prompts.ownerMissing(owner: group.owner) + "\n\n" + content
                        recipients = []
                    }
                }
            }
            // 群主给 coder 发消息 = 群主介入了：清零并解除暂停
            if body.from == group.owner && (to == "coder" || to == "all") && (group.failCount > 0 || group.blocked) {
                try repo.resetFails(groupId: gid)
            }
        }

        let urgent = body.urgent == true
        let message = try repo.addMessage(groupId: gid, from: body.from, to: to, content: content, verdict: verdict, urgent: urgent)
        // 后台成员之间（coder ↔ tester）的消息算任务；群主和用户发的算指示
        let purpose: DeliveryPurpose = sender?.headless == true ? .task : .instruction
        for r in recipients {
            let text = Prompts.delivered(group: group, sender: sender, recipient: r, messageId: message.id, content: content, verdict: verdict,
                                         urgent: urgent, sentAt: message.createdAt)
            delivery.enqueue(deliveryId: try repo.addDelivery(messageId: message.id, memberId: r.id, text: text, purpose: purpose),
                             member: r)
        }
        return PostMessageResult(message: message, recipients: recipients.map(\.alias))
    }

    /// 打回超过这么多次就暂停，交给群主介入
    private let maxFails = 8

    // ---------- 收件箱：查发给自己、还没处理的消息 ----------

    /// 「我」在这个群里对应的成员记录。集群主群的群主同时在各个子群里，子群里的记录一起算，
    /// 这样群主在主群查一次就能看到所有子群发给它的消息
    private func myMemberIds(_ gid: String, me: String) throws -> [Int64] {
        let group = try requireGroup(gid)
        guard !me.isEmpty else { throw UserError("要用 --me 写上你在群里的名字") }
        guard let mine = try repo.listMembers(groupId: gid).first(where: { $0.alias == me }) else {
            throw UserError("\(me) 不在群聊「\(group.name)」里，可用 \(Config.cli) members -g \(gid) 核对名字")
        }
        var ids = [mine.id]
        if group.cluster {
            for sub in try repo.listSubgroups(parentId: gid) {
                if let m = try repo.listMembers(groupId: sub.id).first(where: { $0.alias == me }) { ids.append(m.id) }
            }
        }
        return ids
    }

    /// "123, #124 125" → [123, 124, 125]。逗号、空格、换行分隔都行，# 可带可不带
    /// （命令行里 # 后面会被 shell 当注释吃掉，所以提示词里一律教只写数字；这里兼容加了引号的写法）
    private func parseMessageIds(_ text: String) throws -> [Int64] {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
        return try parts.filter { !$0.isEmpty }.map {
            guard let id = Int64($0) else { throw UserError("消息编号要是数字：\($0)") }
            return id
        }
    }

    /// 把几条消息标成已处理，返回给命令行看的结果
    private func markHandled(_ gid: String, me: String, ids: [Int64]) throws -> String {
        let found = try repo.markHandled(memberIds: try myMemberIds(gid, me: me), messageIds: ids)
        let missing = ids.filter { !found.contains($0) }
        var text = found.isEmpty ? "" : "已标为处理完：" + found.map { "#\($0)" }.joined(separator: " ")
        if !missing.isEmpty {
            if !text.isEmpty { text += "\n" }
            // 群主在子群里只能标这个子群的消息，主群和别的子群的要到主群里标
            text += "这些编号不是发给 \(me) 的消息、或者不在这个群里，没有标记：" + missing.map { "#\($0)" }.joined(separator: " ")
        }
        return text
    }

    /// kkAgent inbox 的输出：发给我的消息。
    /// 默认只列已经轮到它看（送进会话了，或者投递失败、它根本没收到）却还没处理的；
    /// 还在排队、正在送的不列，只报个数：它们稍后照常会送进会话，先在这里处理掉会导致送进来后再做一遍
    private func inboxText(_ gid: String, me: String, direct: Bool, includeHandled: Bool) throws -> String {
        let group = try requireGroup(gid)
        var items = try repo.inbox(memberIds: try myMemberIds(gid, me: me), direct: direct, includeHandled: includeHandled)
        var queuedCount = 0
        if !includeHandled {
            let isQueued = { (item: Repository.InboxItem) in item.status == .pending || item.status == .running }
            queuedCount = items.filter(isQueued).count
            items.removeAll(where: isQueued)
        }
        let scope = direct ? "点名发给 \(me)" : "发给 \(me)"
        let queuedNote = queuedCount > 0 ? "另有 \(queuedCount) 条还在排队，稍后会送进来，到时照常处理。" : ""
        guard !items.isEmpty else {
            return (includeHandled ? "没有\(scope)的消息。" : "没有\(scope)、还没处理的消息。") + queuedNote
        }

        let statusName: [DeliveryStatus: String] = [.pending: "排队中，还没送到", .running: "正在送", .delivered: "已送达",
                                                    .unconfirmed: "已写入，没确认收到", .failed: "投递失败，你没收到过"]
        // 消息可能是前几天的，时间带上日期
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let time = { (iso: String) in parseISO(iso).map(formatter.string) ?? iso }
        var lines = [includeHandled ? "最近\(scope) 的 \(items.count) 条消息：" : "\(scope)、还没处理的消息（\(items.count) 条）："]
        for item in items {
            let m = item.message
            var tags = [statusName[item.status] ?? item.status.rawValue]
            if m.to == "all" { tags.append("群发") }
            if m.urgent { tags.append("紧急") }
            if item.handled { tags.append("已处理") }
            // 群主查的是主群加各个子群，标出是哪个群的，回复时 -g 要写那个群
            let place = m.groupId == gid ? "" : "群「\(item.groupName)」(\(m.groupId)) "
            lines.append("")
            lines.append("#\(m.id) \(place)来自 \(m.from == "user" ? "用户" : m.from) · \(time(m.createdAt)) · \(tags.joined(separator: "，"))")
            lines.append(m.content)
        }
        lines.append("")
        if !queuedNote.isEmpty { lines.append(queuedNote) }
        lines.append("处理完：回复时在 send 里加 --re <编号>；不需要回复的执行 \(Config.cli) done -g \(group.id) --me \(me) <编号>（编号只写数字，不带 #）")
        return lines.joined(separator: "\n")
    }

    /// 校验验收结论：只有集群子群里的 tester 能带，pass / fail 二选一。返回规范化后的值（普通消息为空）
    private func checkVerdict(group: GroupSummary, body: PostMessageRequest) throws -> String {
        let verdict = (body.verdict ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !verdict.isEmpty else { return "" }
        guard verdict == "pass" || verdict == "fail" else { throw UserError("--verdict 只能是 pass 或 fail") }
        guard !group.parentId.isEmpty, body.from == "tester" else {
            throw UserError("只有集群子群里的 tester 能带 --verdict")
        }
        if verdict == "fail" && body.to != "coder" { throw UserError("验收不通过（--verdict fail）要发给 coder") }
        if verdict == "pass" && body.to != "coder" {
            throw UserError("验收通过（--verdict pass）只发给 coder：coder 会带着结论向群主报告、等群主放行")
        }
        return verdict
    }

    /// 移出成员：取消发给它的排队消息，通知它本人，再告诉群里其他人
    private func removeMember(_ id: Int64) throws {
        guard let member = try repo.getMember(id), let group = try repo.getGroup(member.groupId) else { return }
        try repo.cancelPendingDeliveries(memberId: member.id)
        try repo.removeMember(member.id)
        // 集群主群的群主被移出：清掉群主，之后可以重新拉一个群主进来
        if group.cluster && member.alias == group.owner { try repo.setGroupOwner(group.id, owner: "") }
        if member.headless {
            // 后台会话是专门为这个群建的，移出就停下，不再唤醒它发通知（常驻 tmux 的连 tmux 会话一起关掉）。
            // 绑着单独会话的只解绑：进程归「会话」页管，tmux 不关
            delivery.cancel(memberId: member.id)
            if !member.tmux.isEmpty && member.soloId == 0 { Tmux.kill(member.tmux) }
        } else {
            delivery.enqueueNotice(member: member, text: Prompts.removed(group: group))
        }

        // 「xx 已离开群聊」作为系统消息记进群聊（from=system, to=all，界面据此显示成一行），并投递给剩下的成员
        let notice = Prompts.memberLeft(group: group, alias: member.alias)
        let message = try repo.addMessage(groupId: group.id, from: "system", to: "all", content: "\(member.alias) 已离开群聊")
        for other in try repo.listMembers(groupId: group.id) {
            delivery.enqueue(deliveryId: try repo.addDelivery(messageId: message.id, memberId: other.id, text: notice, purpose: .notice),
                             member: other)
        }
    }

    /// 解散群：每个成员都收到「已解散、你已退出」，然后删掉群的全部记录（排队中的消息随之取消）。
    /// 集群的主群：子群一起解散。后台会话不发通知，直接停掉；worktree 和分支保留，由人决定删不删
    /// except：发起解散的成员，不用再通知它
    private func dissolveGroup(_ gid: String, except: String = "") throws {
        let group = try requireGroup(gid)
        for sub in try repo.listSubgroups(parentId: gid) {
            try dissolveGroup(sub.id)
        }
        let members = try repo.listMembers(groupId: gid)
        for member in members where !member.headless && member.alias != except {
            delivery.enqueueNotice(member: member, text: Prompts.dissolved(group: group))
        }
        try repo.deleteGroup(gid)
        // 先删记录再停进程：排队中的投递发现记录没了就不会再启动
        for member in members where member.headless {
            delivery.cancel(memberId: member.id)
            // 绑着单独会话的只解绑，tmux 不关（进程归「会话」页管）
            if !member.tmux.isEmpty && member.soloId == 0 { Tmux.kill(member.tmux) }
        }
        if !group.worktree.isEmpty {
            log("子群 \(gid) 已解散，worktree 保留：\(group.worktree)（分支 \(group.branch)）")
        }
    }

    /// 群主用 kkAgent dissolve 解散自己的子群（一般在 coder 报告合并完成后）。
    /// 只能解散子群，主群由用户在界面上解散
    private func ownerDissolve(_ gid: String, from: String) throws -> String {
        let sub = try requireGroup(gid)
        guard !sub.parentId.isEmpty else { throw UserError("「\(sub.name)」不是子群。主群只能由用户在 kkAgent 界面上解散") }
        guard sub.owner == from else { throw UserError("子群「\(sub.name)」的群主是 \(sub.owner)，只有群主能解散") }
        // 解散会删掉成员记录，先记下 coder / tester 的会话 ID，回复里给出找回命令
        let members = try repo.listMembers(groupId: gid)
        let sessionOf = { (alias: String) in members.first { $0.alias == alias }?.sessionId ?? "" }
        try dissolveGroup(gid, except: from)
        var text = "子群「\(sub.name)」已解散，coder 和 tester 已停止。worktree \(sub.worktree)（分支 \(sub.branch)）保留，删不删由用户决定。"
        if !sessionOf("coder").isEmpty {
            text += "\n" + Prompts.reopenHint(clusterId: sub.parentId, owner: from, coderId: sessionOf("coder"), testerId: sessionOf("tester"))
        }
        return text
    }

    private func addMember(_ gid: String, _ body: AddMemberRequest) throws -> Member {
        let group = try requireGroup(gid)
        let sessionId = body.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = body.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard alias.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw UserError("成员名只能用字母、数字、下划线和短横线，比如 coder、tester")
        }
        guard !reservedAliases.contains(alias) else { throw UserError("成员名不能用 \(alias)，这是保留字") }
        guard try repo.listMembers(groupId: gid).allSatisfy({ $0.alias != alias }) else { throw UserError("群里已经有叫 \(alias) 的成员了") }
        // 在群里新建会话：不走下面「找已有会话」的那些校验
        if body.create == true { return try createMember(group: group, alias: alias, body: body) }
        // 拉入左边栏「会话」里的单独会话：复用它现有的 tmux 进程，不另起
        if !sessionId.isEmpty {
            if let solo = try repo.runningSolo(agent: body.agent, sessionId: sessionId) {
                return try bindSolo(solo, group: group, alias: alias, description: body.description)
            }
            // 还在启动、或者启动失败的单独会话不能拉（按普通会话拉进来会另起进程）
            if try repo.liveSolos().contains(where: { $0.agent == body.agent && $0.sessionId == sessionId }) {
                throw UserError("这个单独会话还在启动或者启动失败了，等它在「会话」页显示运行中再拉进群")
            }
        }
        // kkAgent 托管的会话（集群子群的、群里新建的）只能在它自己的群里：加到别处会有两条队列同时往这个会话投递
        guard !(try repo.isHeadlessSession(sessionId)) else {
            throw UserError("这是 kkAgent 托管的会话（集群子群或群里新建的），只能在它自己的群里，不能再加到别的群")
        }
        // 集群主群只有一个成员：群主。它会把 coder / tester 这两个名字带进每个子群，所以不能用
        if group.cluster {
            guard group.owner.isEmpty else { throw UserError("集群群聊只能有一个成员（群主 \(group.owner)），子群的成员由群主 spawn") }
            guard alias != "coder" && alias != "tester" else { throw UserError("群主不能叫 coder 或 tester，子群里这两个名字留给后台会话") }
        }
        let (file, vm) = try locateSession(agent: body.agent, sessionId: sessionId)

        let member = try repo.addMember(groupId: gid, alias: alias, agent: body.agent, sessionId: sessionId,
                                        description: body.description.trimmingCharacters(in: .whitespacesAndNewlines),
                                        cwd: Transcript.readCwd(agent: body.agent, file: file, vm: vm), vm: vm)
        // 给新成员发入群说明（作为 system 消息，界面上也看得到）。集群主群的成员就是群主，发群主版的说明
        let intro: String
        if group.cluster {
            try repo.setGroupOwner(gid, owner: alias)
            intro = Prompts.ownerIntro(group: group, owner: member)
        } else {
            intro = Prompts.intro(group: group, member: member, allMembers: try repo.listMembers(groupId: gid))
        }
        let message = try repo.addMessage(groupId: gid, from: "system", to: alias, content: intro)
        delivery.enqueue(deliveryId: try repo.addDelivery(messageId: message.id, memberId: member.id, text: intro, purpose: .notice),
                         member: member)
        return member
    }

    /// 在群里新建一个会话并加进群，由 kkAgent 托管在 tmux 里（和集群子群的 coder / tester 一样，见 kktodo/群里新建会话-方案.md）：
    /// - Claude 只建在虚拟机里，预先生成会话 ID，第一次投递入群说明时用 --session-id 新建（带状态 hook）；
    /// - Codex 只在物理机上，会话 ID 先留空：入群说明作为 bootstrap 用 codex exec 跑一轮把会话建出来、回填 ID，之后的消息走 tmux。
    /// 只支持普通群：集群群主会被复制进每个子群，复制的那一行没有 tmux，同一个会话会被另起后台进程
    private func createMember(group: GroupSummary, alias: String, body: AddMemberRequest) throws -> Member {
        guard !group.cluster && group.parentId.isEmpty else {
            throw UserError("集群群聊里不能直接新建会话：主群请拉入已有会话当群主，子群的成员由群主 spawn")
        }
        // 工作目录和虚拟机的校验和单独会话共用（见 Solo.swift 的 NewSession）
        let (cwd, vm) = try NewSession.resolve(agent: body.agent, cwd: body.cwd ?? "")
        let description = body.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let tmux = Tmux.sessionName(groupId: group.id, alias: alias)

        let member: Member
        switch body.agent {
        case .claude:
            member = try repo.addMember(groupId: group.id, alias: alias, agent: .claude, sessionId: UUID().uuidString.lowercased(),
                                        description: description, cwd: cwd, vm: vm, headless: true, tmux: tmux)
        case .codex:
            member = try repo.addMember(groupId: group.id, alias: alias, agent: .codex, sessionId: "",
                                        description: description, cwd: cwd, vm: "", headless: true, tmux: tmux)
        }

        // 入群说明当第一条消息。Codex 那一轮要求立即结束（只用来把会话建出来），之后的消息等它建好再送
        var intro = Prompts.intro(group: group, member: member, allMembers: try repo.listMembers(groupId: group.id))
        if body.agent == .codex { intro += "\n\n" + Prompts.bootstrapEndTurn }
        let message = try repo.addMessage(groupId: group.id, from: "system", to: alias, content: intro)
        delivery.enqueue(deliveryId: try repo.addDelivery(messageId: message.id, memberId: member.id, text: intro,
                                                           purpose: body.agent == .codex ? .bootstrap : .notice),
                         member: member)
        log("群 \(group.id) 新建了 \(body.agent.rawValue) 会话 \(alias)，工作目录 \(cwd)")
        return member
    }

    /// 把运行中的单独会话拉进群：成员记下 soloId，用它现有的 tmux（不另起进程、不重新 bootstrap、启动令牌不变），
    /// 状态直接共用单独会话那一份。入群说明照普通消息排队投递，忙闲、草稿、暂停、授权、未确认这些门禁都照常检查。
    /// 同一时间只能绑一个群；只支持普通群
    private func bindSolo(_ solo: Repository.SoloRecord, group: GroupSummary, alias: String, description: String) throws -> Member {
        guard !group.cluster && group.parentId.isEmpty else {
            throw UserError("单独会话只能拉进普通群聊，集群群聊不支持")
        }
        guard try repo.memberBound(toSolo: solo.id) == nil else {
            throw UserError("这个单独会话已经在别的群里了，同一时间只能在一个群里")
        }
        let member = try repo.addMember(groupId: group.id, alias: alias, agent: solo.agent, sessionId: solo.sessionId,
                                        description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                                        cwd: solo.cwd, vm: solo.vm, headless: true, tmux: solo.tmux, soloId: solo.id)
        let intro = Prompts.intro(group: group, member: member, allMembers: try repo.listMembers(groupId: group.id))
        let message = try repo.addMessage(groupId: group.id, from: "system", to: alias, content: intro)
        delivery.enqueue(deliveryId: try repo.addDelivery(messageId: message.id, memberId: member.id, text: intro, purpose: .notice),
                         member: member)
        log("群 \(group.id) 拉入了单独会话 #\(solo.id)，成员名 \(alias)")
        return member
    }

    /// 找会话文件：先在物理机上找，找不到再到正在运行的虚拟机里挨个找（只有 Claude 会话会在虚拟机里）。
    /// 会话 ID 是随机生成的，不会两边重复，所以不用让用户选在哪台机器。返回文件路径和所在机器（空 = 物理机）
    private func locateSession(agent: AgentKind, sessionId: String) throws -> (file: String, vm: String) {
        if let file = Transcript.find(agent: agent, sessionId: sessionId) { return (file, "") }
        if agent == .claude {
            for name in VM.running() {
                if let file = Transcript.find(agent: .claude, sessionId: sessionId, vm: name) { return (file, name) }
            }
        }
        throw UserError("在物理机和正在运行的虚拟机里都找不到这个 \(agent.rawValue) 会话：\(sessionId)")
    }

    /// 状态 hook 上报的事件。对不上的事件（旧会话、令牌不对）直接忽略，hook 脚本不看结果。
    /// SessionStart 例外：hook 脚本会把回复原样打印出来、加进 Claude 的上下文，所以回复纯文本（换了会话的群成员是入群说明，其他为空）
    private func hookEvent(owner: StatusOwner, launchId: String, payload: [String: Any]) -> HTTPResponse {
        if payload["hook_event_name"] as? String == "SessionStart" {
            let text = delivery.followSession(owner: owner, launchId: launchId, payload: payload)
            return HTTPResponse(status: 200, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
        }
        AgentStatusStore.shared.record(owner: owner, launchId: launchId, payload: payload)
        return .json(OkResult())
    }

    /// 更换成员的会话（比如把主会话分叉出一个新会话接着用）：改会话 ID、工作目录、所在机器。
    /// 集群群主会被复制进每个子群，那些成员行一起换，子群的汇报才会送到新会话。
    /// 还没送出的消息投递时会重新读成员，自然送到新会话
    private func changeSession(_ id: Int64, _ body: ChangeSessionRequest) throws -> Member {
        guard let member = try repo.getMember(id), let group = try repo.getGroup(member.groupId) else { throw UserError("成员不存在") }
        guard !member.headless else {
            throw UserError("\(member.alias) 是集群子群里的后台会话，会话和 tmux 是绑在一起的，不能更换")
        }
        // 子群里的群主行是从主群复制来的：转到主群那一行去换，主群和各个子群才会一起换。
        // （主群那一行已经是别的会话了，说明之前单独换过，那就只换这一行）
        if !group.parentId.isEmpty, member.alias == group.owner,
           let parentRow = try repo.listMembers(groupId: group.parentId).first(where: { $0.alias == group.owner }),
           parentRow.sessionId == member.sessionId {
            _ = try changeSession(parentRow.id, body)
            guard let updated = try repo.getMember(member.id) else { throw UserError("\(member.alias) 已被移出群聊") }
            return updated
        }
        let sessionId = body.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty, sessionId != member.sessionId else { throw UserError("新会话 ID 为空，或者和现在的一样") }
        guard !(try repo.isHeadlessSession(sessionId)) else { throw UserError("这是集群子群里的后台会话，不能拿来用") }
        guard try repo.listMembers(groupId: group.id).allSatisfy({ $0.sessionId != sessionId }) else {
            throw UserError("这个会话已经是群里的另一个成员了")
        }
        let (file, vm) = try locateSession(agent: member.agent, sessionId: sessionId)
        let cwd = Transcript.readCwd(agent: member.agent, file: file, vm: vm)

        try repo.changeMemberSession(member.id, sessionId: sessionId, cwd: cwd, vm: vm)
        var changed = 1
        if group.cluster && member.alias == group.owner {
            for sub in try repo.listSubgroups(parentId: group.id) {
                for row in try repo.listMembers(groupId: sub.id) where row.alias == member.alias && row.sessionId == member.sessionId {
                    try repo.changeMemberSession(row.id, sessionId: sessionId, cwd: cwd, vm: vm)
                    changed += 1
                }
            }
        }
        log("\(member.alias)（群 \(group.id)）换成新会话 \(sessionId)，共更新 \(changed) 个成员行")
        // 换的同时被移出了（两个请求并发）：成员行已经没了
        guard let updated = try repo.getMember(member.id) else { throw UserError("\(member.alias) 已被移出群聊") }
        return updated
    }

    private func decode<T: Decodable>(_ type: T.Type, _ req: HTTPRequest) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: req.body)
        } catch {
            throw UserError("请求格式不对：\(error.localizedDescription)")
        }
    }
}
