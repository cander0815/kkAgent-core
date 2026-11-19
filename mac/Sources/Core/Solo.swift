// 左边栏「会话」：不属于任何群、直接选路径新建的单独会话，由 kkAgent 托管在 tmux 里（方案见 kktodo/单独会话-方案.md）。
//
// - 新建：先登记一条记录（starting），在后台启动，接口马上返回。Claude 只建在虚拟机里、装状态 hook；
//   Codex 先用 codex exec 跑一轮最小的开场把会话建出来（要它立即结束），再在 tmux 里 resume。
// - 结束只有两种：在「会话」页点销毁（关 tmux）；用户在终端里 exit（tmux 没了，定时检查发现后收尾）。结束后不再显示。
// - 可以拉进普通群：成员记下 soloId，用它现有的 tmux，不另起进程；状态共用这一份（StatusOwner.solo）。
//   进程归属以这里为准：从群里移出、解散群只解绑；单独会话结束时，绑着它的成员一起移出（群里记一条提示），
//   这样群这边不会把它重建出来，也不会改走后台续接。
import Foundation

/// 新建托管会话（群里新建的成员、单独会话）共用的校验：工作目录、Claude 用哪台虚拟机
enum NewSession {
    /// 返回标准化后的工作目录和所在机器（Codex 为空 = 物理机）。不满足条件抛出给用户看的错误
    static func resolve(agent: AgentKind, cwd raw: String) throws -> (cwd: String, vm: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UserError("请先选工作目录") }
        // 展开 ~、去掉多余的 / 和 ..，必须是物理机上存在的目录
        let cwd = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            throw UserError("工作目录 \(cwd) 不存在，或者不是文件夹")
        }
        guard agent == .claude else { return (cwd, "") }
        // 和集群 coder 同样的规则：只建在虚拟机里，虚拟机只看得到 /Users 下的目录；只有一台在运行才用它
        guard cwd.hasPrefix("/Users/") else { throw UserError("工作目录 \(cwd) 不在 /Users 下，虚拟机里看不到，Claude 没法在里面工作") }
        let running = VM.running()
        guard running.count == 1 else {
            throw UserError(running.isEmpty
                ? "没有正在运行的虚拟机。Claude 只在虚拟机里新建，请先启动虚拟机"
                : "有多台虚拟机在运行（\(running.joined(separator: "、"))），不知道建在哪台。请先只留一台在运行")
        }
        return (cwd, running[0])
    }
}

/// 单独会话的会话名：Claude 里用 /rename 起的名字、Codex 桌面端的会话名。
/// 「会话」页每 2 秒刷新一次列表，Claude 的要进虚拟机读会话文件，所以每个会话最多 15 秒读一次，其余时候用上次读到的
enum SoloTitles {
    private static var cache: [Int64: (title: String, at: Date)] = [:]
    private static let lock = NSLock()

    static func title(of solo: Repository.SoloRecord) -> String {
        guard !solo.sessionId.isEmpty else { return "" }
        lock.lock()
        let cached = cache[solo.id]
        lock.unlock()
        if let cached, Date().timeIntervalSince(cached.at) < 15 { return cached.title }
        let title = solo.agent == .claude
            ? Transcript.claudeCustomTitle(sessionId: solo.sessionId, vm: solo.vm)
            : Sessions.codexThreadNames()[solo.sessionId] ?? ""
        lock.lock()
        cache[solo.id] = (title, Date())
        lock.unlock()
        return title
    }
}

/// Codex 单独会话的结束检查进度：每个会话从什么时候开始认结束的回合（见 checkSoloTurns）
enum SoloTurnWatch {
    private static var since: [Int64: Date] = [:]
    private static let lock = NSLock()

    /// 会话对外变成运行中之前、核心启动接管运行中的会话时调用：从现在起认结束的回合。
    /// 不等第一次定时检查再记，不然「刚运行就做完」的第一轮会落在基线之前、永远不记
    static func start(_ id: Int64) {
        lock.lock()
        since[id] = Date()
        lock.unlock()
    }

    /// 返回从哪个时间之后认结束的回合。还没起点的（理论上不会有）这一次记下当前时间、返回 nil，只建基线
    static func baseline(_ id: Int64) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let known = since[id] { return known }
        since[id] = Date()
        return nil
    }

    static func advance(_ id: Int64, to date: Date) {
        lock.lock()
        since[id] = date
        lock.unlock()
    }

    /// Claude 打断兜底要进虚拟机读会话记录：每个会话最多 10 秒查一次（定时检查每 3 秒一次）
    private static var lastStuckCheck: [Int64: Date] = [:]

    static func shouldCheckStuck(_ id: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastStuckCheck[id], Date().timeIntervalSince(last) < 10 { return false }
        lastStuckCheck[id] = Date()
        return true
    }
}

extension DeliveryQueue {
    /// 单独 Codex 会话的开场：只用来把会话建出来，不在群里，不发群说明
    private static let soloCodexOpening = """
        这是一个由 kkAgent 托管的单独会话，用户之后会在终端里直接和你对话。
        现在立即结束这一轮：只回复「已就位」，不要开始任何工作，也不要用 sleep、轮询或任何方式在这一轮里等待。
        """

    // ---------- 新建 ----------

    /// 新建一个单独会话：校验、登记（starting），在后台启动，马上返回记录
    func createSolo(agent: AgentKind, cwd raw: String) throws -> Repository.SoloRecord {
        let (cwd, vm) = try NewSession.resolve(agent: agent, cwd: raw)
        let solo = try repo.createSolo(agent: agent, vm: vm, cwd: cwd,
                                       sessionId: agent == .claude ? UUID().uuidString.lowercased() : "")
        log("新建单独会话 #\(solo.id)（\(agent.rawValue)），工作目录 \(cwd)")
        DispatchQueue.global().async { self.startSolo(solo.id) }
        return solo
    }

    /// 「继续沟通」：接着一个已有的会话开单独会话（比如子群解散后还想找 coder 聊）。
    /// 在会话原来所在的机器上 resume，不新建会话、不发任何消息；之后和新建的单独会话完全一样（销毁或 exit 才结束、能拉进群）。
    /// 同一个会话不能同时被两个进程写：kkAgent 自己正在用的（群成员、还没结束的单独会话）这里拦住；
    /// 用户自己在别的终端、桌面端开着的看不出来，界面上点之前提醒先关掉那边
    func resumeSolo(agent: AgentKind, sessionId raw: String, vm: String, cwd rawCwd: String) throws -> Repository.SoloRecord {
        let sessionId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 已经在「会话」页里开着：直接返回那一条，界面跳过去
        if let open = try repo.liveSolos().first(where: { $0.agent == agent && $0.sessionId == sessionId }) {
            guard open.state != "failed" else { throw UserError("这个会话在「会话」页里有一条启动失败的记录，先把它销毁再继续") }
            // 运行中但 tmux 已经没了（用户刚 exit，定时检查还没收尾）：先收尾，再往下接着这个会话新开一条。
            // 正在启动的 tmux 本来就可能还没起来，照样复用
            if open.state == "running" && !Tmux.exists(open.tmux, fresh: true) {
                endSolo(open, reason: "在终端里退出了")
            } else {
                return open
            }
        }
        if let member = try repo.membersUsing(agent: agent, sessionId: sessionId).first {
            let group = (try? repo.getGroup(member.groupId))?.name ?? member.groupId
            throw UserError("这个会话还是群聊「\(group)」里的成员 \(member.alias)，直接在群里打开它的会话就行（另开一个会和群里同时写同一个会话）")
        }
        let cwd = URL(fileURLWithPath: (rawCwd as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard !rawCwd.isEmpty, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            throw UserError("会话的工作目录 \(cwd) 已经不在了（worktree 可能被删了），没法接着这个会话")
        }
        if !vm.isEmpty {
            guard agent == .claude else { throw UserError("Codex 会话只在物理机上") }
            guard VM.running().contains(vm) else { throw UserError("会话在虚拟机 \(vm) 里，它现在没在运行，请先启动") }
        }
        guard Transcript.find(agent: agent, sessionId: sessionId, vm: vm) != nil else {
            throw UserError("找不到这个会话的记录，没法接着它")
        }
        let solo = try repo.createSolo(agent: agent, vm: vm, cwd: cwd, sessionId: sessionId)
        log("单独会话 #\(solo.id)（\(agent.rawValue)）接着已有会话 \(sessionId) 打开，工作目录 \(cwd)")
        DispatchQueue.global().async { self.startSolo(solo.id) }
        return solo
    }

    /// 后台启动。期间被销毁了（状态不再是 starting）就停手，并关掉刚起的 tmux
    private func startSolo(_ id: Int64) {
        guard var solo = try? repo.getSolo(id), solo.state == "starting" else { return }
        let label = "单独会话 #\(id)"
        do {
            // 新建的 Codex 先跑一轮把会话建出来；「继续沟通」已经有会话 ID，直接在 tmux 里 resume
            if solo.agent == .codex && solo.sessionId.isEmpty {
                let sessionId = try runSoloCodexOpening(id: id, cwd: solo.cwd)
                try repo.setSoloSessionId(id, sessionId: sessionId)
                guard let fresh = try repo.getSolo(id), fresh.state == "starting" else { return }
                solo = fresh
            }
            let (command, readyMarker) = try tmuxLaunch(agent: solo.agent, vm: solo.vm, cwd: solo.cwd, sessionId: solo.sessionId,
                                                        owner: .solo(id), label: label)
            // 起 tmux 前最后看一眼：这期间被销毁了、或者核心正在退出（建会话的进程被停之前可能已经吐出了会话 ID），就不起。
            // 核心退出时状态留在 starting，下次启动由 recoverSolosOnStartup 收尾
            guard !isStopping, try repo.getSolo(id)?.state == "starting" else { return }
            try Tmux.start(solo.tmux, cwd: solo.cwd, command: command)
            // 起 tmux 的同时核心开始退出了：这是新起的、还没交给用户的会话，关掉，不越过退出时的取消
            if isStopping {
                Tmux.kill(solo.tmux)
                return
            }
            guard Tmux.waitReady(solo.tmux, readyMarker: readyMarker, timeout: Config.tmuxReadyTimeout) else {
                throw CoreError(message: Tmux.exists(solo.tmux, fresh: true) ? "界面 \(Int(Config.tmuxReadyTimeout / 60)) 分钟内没就绪" : "界面就绪前就退出了（可能是进虚拟机或启动失败）")
            }
            if solo.agent == .claude { markReadyIfIdle(owner: .solo(id), tmux: solo.tmux) }
            // 等界面就绪期间核心开始退出了：同样关掉，状态留在 starting
            if isStopping {
                Tmux.kill(solo.tmux)
                return
            }
            // 先定好从什么时候开始认结束的回合，再对外变成运行中（Codex 拿会话 ID 的开场那一轮在这之前就结束了）
            SoloTurnWatch.start(id)
            // 启动期间被销毁了：不能再改回 running，刚起的 tmux 也关掉
            guard try repo.setSoloState(id, "running", from: ["starting"]) else {
                Tmux.kill(solo.tmux)
                return
            }
            log("\(label) 已启动：tmux 会话 \(solo.tmux)")
        } catch {
            // 核心正在退出导致的失败（建会话的进程被停了）：状态留在 starting，下次启动时按「启动中断」收尾
            if isStopping {
                log("\(label) 启动被核心退出打断")
                return
            }
            log("\(label) 启动失败：\(error)")
            if (try? repo.setSoloState(id, "failed", error: String(String(describing: error).prefix(300)), from: ["starting"])) == true {
                Tmux.kill(solo.tmux)
                AgentStatusStore.shared.forget(.solo(id))
            }
        }
    }

    /// 单独 Codex 会话的开场：codex exec 跑一轮最小的提示，拿到会话 ID。最多等 bootstrapTimeout 秒，到点停掉。
    /// 进程按单独会话 id 登记：销毁时马上停掉（terminateSolo），核心退出时一起回收（terminateAll）
    private func runSoloCodexOpening(id: Int64, cwd: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Config.codexBin)
        p.arguments = ["exec", "--json"] + Config.codexExecApproval + ModelSettingsStore.codexArgs() + ["-C", cwd, "-"]
        p.environment = ShellEnv.environment
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        try registerSolo(id, p)
        defer { unregisterSolo(id, p) }
        try? input.fileHandleForWriting.write(contentsOf: Data(Self.soloCodexOpening.utf8))
        try? input.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + Config.bootstrapTimeout) { if p.isRunning { p.terminate() } }
        // 一行一个 JSON 事件，只要 thread.started 里的会话 ID
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        for line in data.split(separator: 0x0A) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  event["type"] as? String == "thread.started", let id = event["thread_id"] as? String, !id.isEmpty else { continue }
            return id
        }
        throw CoreError(message: "Codex 会话没能建起来（codex exec 退出码 \(p.terminationStatus)）")
    }

    /// 核心启动时调用：上次核心退出时还在启动的单独会话（启动是新建时的后台任务，重启后没人接着做）。
    /// tmux 在、并且屏幕上正面看得出界面已经就绪（Claude 输入框认得出来、没有弹框；Codex 有「for shortcuts」）就接管成运行中；
    /// 否则记成启动失败（关掉半截的 tmux），用户可以销毁后重新新建。不做自动重试。
    /// 上次的 Codex 建会话进程已经随核心退出被停掉了（terminateAll），不会留下副本
    func recoverSolosOnStartup() {
        // 核心重启前就在运行的：从现在起认结束的回合（核心停着时结束的不补）
        for solo in (try? repo.liveSolos()) ?? [] where solo.state == "running" { SoloTurnWatch.start(solo.id) }
        for solo in (try? repo.liveSolos()) ?? [] where solo.state == "starting" {
            var ready = false
            if Tmux.exists(solo.tmux, fresh: true) {
                let styled = Tmux.styledScreen(solo.tmux)
                switch solo.agent {
                case .claude: ready = MemberReadiness.claudeScreen(styled, turnEnded: true) != .unknown
                case .codex: ready = !solo.sessionId.isEmpty && styled.contains("for shortcuts")
                }
            }
            if ready { SoloTurnWatch.start(solo.id) }
            if ready, (try? repo.setSoloState(solo.id, "running", from: ["starting"])) == true {
                log("单独会话 #\(solo.id) 上次启动到一半核心重启了，界面已就绪，接管为运行中")
                continue
            }
            Tmux.kill(solo.tmux)
            AgentStatusStore.shared.forget(.solo(solo.id))
            _ = try? repo.setSoloState(solo.id, "failed", error: "核心重启时它还在启动，启动中断了，可以销毁后重新新建", from: ["starting"])
            log("单独会话 #\(solo.id) 启动被核心重启打断，记成启动失败")
        }
    }

    // ---------- 列表和结束 ----------

    /// 「会话」页的列表：还没结束的单独会话。顺手收尾已经运行过、tmux 却不在了的（用户 exit 了）
    func soloList() -> [SoloSession] {
        let solos = (try? repo.liveSolos()) ?? []
        return solos.compactMap { solo in
            if solo.state == "running" && !Tmux.exists(solo.tmux) {
                endSolo(solo, reason: "在终端里退出了")
                return nil
            }
            let bound = try? repo.memberBound(toSolo: solo.id)
            let group = bound.flatMap { try? repo.getGroup($0.groupId) }
            return SoloSession(id: solo.id, agent: solo.agent, vm: solo.vm, sessionId: solo.sessionId, cwd: solo.cwd, tmux: solo.tmux,
                               state: solo.state, error: solo.error, createdAt: solo.createdAt,
                               boundGroupId: group?.id ?? "", boundGroupName: group?.name ?? "", boundAlias: bound?.alias ?? "",
                               title: SoloTitles.title(of: solo), activity: soloActivity(solo).rawValue,
                               lastOutcome: solo.lastOutcome, lastEndedAt: solo.lastEndedAt)
        }
    }

    /// 单独会话现在在干什么：Claude 看状态 hook 记在内存里的；Codex 看会话记录里有没有进行中的回合（都不读虚拟机）
    private func soloActivity(_ solo: Repository.SoloRecord) -> AgentState {
        guard solo.state == "running" else { return .unknown }
        switch solo.agent {
        case .claude:
            return AgentStatusStore.shared.cachedState(owner: .solo(solo.id), tmux: solo.tmux)
        case .codex:
            switch CodexTurns.shared.isBusy(sessionId: solo.sessionId, startedAfter: CodexTurns.processStart(tmux: solo.tmux)) {
            case true?: return .working
            case false?: return .idle
            case nil: return .unknown
            }
        }
    }

    /// 定时检查调用：运行中的单独会话 tmux 不在了（用户 exit），收尾。正在启动的不管（tmux 本来就可能还没起来）
    func checkSolos() {
        for solo in (try? repo.liveSolos()) ?? [] where solo.state == "running" && !Tmux.exists(solo.tmux) {
            endSolo(solo, reason: "在终端里退出了")
        }
        checkSoloTurns()
    }

    // ---------- 这一轮怎么结束的 ----------

    /// 定时检查调用：认出运行中的单独会话刚结束的一轮。
    /// - Claude：正常结束和出错靠 Stop / StopFailure hook（onTurnEnded → recordSoloTurn），这里只补用户按 Esc 打断的：
    ///   Claude 被打断时不发 Stop，用和群成员同一套严格取证（recoverStuckTurn）收尾；
    /// - Codex：看会话记录里结束的回合。会话变成运行中之前（核心重启时是接管的那一刻）记下起点时间（SoloTurnWatch.start），
    ///   之后只认结束时间晚于它的：新建时拿会话 ID 的那一轮、「继续沟通」打开的旧会话的历史、核心重启前结束的都不算；
    ///   换段后旧的结束记录也因为时间早被排除
    private func checkSoloTurns() {
        for solo in (try? repo.liveSolos()) ?? [] where solo.state == "running" && !solo.sessionId.isEmpty {
            switch solo.agent {
            case .claude:
                guard SoloTurnWatch.shouldCheckStuck(solo.id) else { continue }
                recoverStuckTurn(owner: .solo(solo.id), sessionId: solo.sessionId, vm: solo.vm, tmux: solo.tmux, label: "单独会话 #\(solo.id)")
            case .codex:
                guard let since = SoloTurnWatch.baseline(solo.id),
                      let ended = CodexTurns.shared.endedTurnsInOrder(sessionId: solo.sessionId) else { continue }
                // 按会话记录里的先后，一轮一轮认；最后认到的那一轮就是「最近一轮」
                for turn in ended {
                    guard let at = turn.at, at > since else { continue }
                    let outcome: TurnOutcome = turn.how == "complete" ? .completed
                        : ["aborted:interrupted", "aborted:replaced"].contains(turn.how) ? .interrupted : .failed
                    recordSoloTurn(solo.id, outcome: outcome, endedAt: at)
                    SoloTurnWatch.advance(solo.id, to: at)
                }
            }
        }
    }

    /// 记下单独会话这一轮怎么结束的（App 按结束时间判断有没有没看过的结果、要不要发通知）
    func recordSoloTurn(_ id: Int64, outcome: TurnOutcome, endedAt: Date = Date()) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        do {
            try repo.setSoloOutcome(id, outcome: outcome.rawValue, endedAt: formatter.string(from: endedAt))
            log("单独会话 #\(id) 这一轮结束了：\(outcome.rawValue)")
        } catch {
            log("单独会话 #\(id) 记录这一轮的结果失败：\(error)")
        }
    }

    /// 销毁：关掉 tmux，记成结束，绑着它的成员一起移出
    func destroySolo(_ id: Int64) throws {
        guard let solo = try repo.getSolo(id), solo.state != "ended" else { throw UserError("这个会话已经结束了") }
        // 先改状态再停进程、关 tmux：后台还在启动的那一步看到状态变了就会停手；
        // Codex 还在建会话的话，它的 codex exec 马上停掉（不用等超时）
        try repo.setSoloState(id, "ended", error: "已销毁")
        terminateSolo(id)
        Tmux.kill(solo.tmux)
        endSolo(solo, reason: "被销毁了")
    }

    /// 单独会话结束后的收尾：记成结束、不再认它的 hook；绑着它的成员移出群（停掉投递、排着的消息作废），群里记一条提示。
    /// 成员留着的话，群这边会想把它重建或改走后台续接，所以直接移出
    private func endSolo(_ solo: Repository.SoloRecord, reason: String) {
        _ = try? repo.setSoloState(solo.id, "ended", error: reason, from: ["starting", "running", "failed"])
        AgentStatusStore.shared.forget(.solo(solo.id))
        log("单独会话 #\(solo.id) 已结束：\(reason)")
        guard let member = try? repo.memberBound(toSolo: solo.id) else { return }
        cancel(memberId: member.id)
        try? repo.cancelPendingDeliveries(memberId: member.id)
        try? repo.removeMember(member.id)
        if let group = try? repo.getGroup(member.groupId) {
            _ = try? repo.addMessage(groupId: group.id, from: "system", to: "user",
                                     content: Prompts.alertHeader(group) + "\(member.alias) 绑着的单独会话\(reason)，已经把它移出群聊，还没送出的消息不再投递。",
                                     kind: "alert")
        }
    }
}
