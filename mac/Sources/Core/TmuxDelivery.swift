// 「交出去就算完成」的投递（tmux 里的 coder / tester、桌面端 Codex 的 codex queue、经中转会话发给开着窗口的 Claude），
// 一步步来，每一步都记进数据库（attempts 表），详见 kktodo/kkAgent-参考Orca改进方案.md 第四节第 3 步：
//
//   准备 → 开始写入 → 已回车 → 已确认
//
// - 送进去的文字第一行是投递编号 [kk#<attemptId>]。对方真正收到时（Claude 的 UserPromptSubmit、Codex 会话记录里的
//   user_message），第一行是这个编号、全文也一致，才算确认送达。只是「出现了这个编号」不算（可能是引用了旧消息）。
// - 还没开始写入就放弃（对方忙了、输入框里有人在打字）：这批消息改回排队，之后再投。
// - 已经开始写入、却没能确认：记成「已写入未确认」，绝不重投、不重贴。这个会话之后的消息先不投，
//   等迟到的确认（定时检查会补）或者人工「解除并继续」。
import Foundation

/// 一次投递的结果
enum AttemptOutcome {
    case confirmed               // 确认对方收到了
    case unconfirmed(String)     // 写进去了，但没能确认（原因）
    case deferred(String)        // 还没写就放弃了，消息改回排队（原因）
    /// 强制发送时对方正在忙：已经写进去了，排在它当前这一轮之后，还没轮到处理，所以按时确认不了。
    /// 照样记成「已写入未确认」（挡着后面的投递、定时检查会补确认），但这是意料之中的，不发未确认通知
    case queuedBehindTurn
}

extension DeliveryQueue {
    /// 投递编号行。确认时要求对方收到的第一行和它完全一样
    static func attemptTag(_ attemptId: Int64) -> String { "[kk#\(attemptId)]" }

    /// 按成员的投递方式送进去。还没开始写入时出的错照常抛出（算投递失败，可以重投）
    func deliverWithAttempt(member: Member, attemptId: Int64, text: String, force: Bool = false) throws -> AttemptOutcome {
        if !member.tmux.isEmpty { return try deliverViaTmux(member: member, attemptId: attemptId, text: text, force: force) }
        switch member.agent {
        case .codex:
            // 桌面端 Codex：codex queue 一调用就可能已经进了对方的队列，之后出什么错都只能算「未确认」。
            // 「开始写入」必须先记进库（记不进去就抛错，算还没写入）。发出前再看一眼用户是不是刚点了暂停
            if let blocked = pausedBlocker(member) { return .deferred(blocked) }
            try repo.advanceAttempt(attemptId, to: .writeStarted)
            do {
                try runCodexQueue(member: member, text: text)
            } catch {
                return .unconfirmed("codex queue 出错：\(error)")
            }
            _ = try? repo.advanceAttempt(attemptId, to: .inputAccepted) // 记不上也没关系：停在「开始写入」同样按已写入处理
            if waitForConfirmation(member: member, attemptId: attemptId, text: text, timeout: 20) { return .confirmed }
            return force && stillWorking(member) ? .queuedBehindTurn : .unconfirmed("交给 codex queue 后 20 秒内没在会话记录里看到这一条")
        case .claude:
            // 开着窗口的 Claude：中转会话会核对 SendMessage 的回执（成功并且预览就是这条消息的开头），回执就是确认
            let live = Transcript.claudeLiveStatus(sessionId: member.sessionId, vm: member.vm)
            if let blocked = pausedBlocker(member) { return .deferred(blocked) } // 发出前再看一眼用户是不是刚点了暂停
            try repo.advanceAttempt(attemptId, to: .writeStarted)
            do {
                try Relay.on(member.vm).send(to: live.name, text: text)
            } catch {
                return .unconfirmed("中转发送出错：\(error)")
            }
            // 回执只说明送到了，还没看到对方开工：先占着这个会话，等定时检查在它的会话记录里看到这一条（observeStarts）
            do {
                try repo.confirmAttempt(attemptId, observed: false)
            } catch {
                return .unconfirmed("中转已确认发出，但记录确认时数据库出错：\(error)")
            }
            return .confirmed
        }
    }

    // ---------- tmux ----------

    /// text 里的 ESC 已经在 Delivery.deliver 换成了可见的 ␛（库里存的就是这份实际发出去的文字）
    private func deliverViaTmux(member: Member, attemptId: Int64, text: String, force: Bool) throws -> AttemptOutcome {
        // 这次新开的会话：界面就绪就能确定是空闲的（状态 hook 还没来得及上报）
        let freshlyStarted = try ensureTmuxSession(member)

        // 1. 认准目标：记下窗格 id、里面进程的 pid、会话的启动令牌，之后所有 tmux 命令都直接发给这个窗格
        //    （不按会话名，防止同名会话被重建、或者窗格被换掉时贴进别的地方），每次写之前都核对这些都没变
        guard let identity = Tmux.paneIdentity(member.tmux), let pane = identity.split(separator: " ").first.map(String.init) else {
            return .deferred("tmux 会话 \(member.tmux) 读不到窗格信息")
        }
        let target = WriteTarget(pane: pane, identity: identity, launchId: AgentStatusStore.shared.launchId(owner: .of(member)),
                                 freshlyStarted: freshlyStarted)

        // 窗口被终端面板挤窄过的话先放大（原因见 Tmux.restoreSizeIfDetached），等界面按新大小重画完再看输入框
        if Tmux.restoreSizeIfDetached(pane) { waitScreenSettled(pane) }

        // 2. 输入框必须是空的（里面有人在打字、或者弹着确认框，就不贴），对方必须还是空闲的
        guard let before = Composer.draft(agent: member.agent, styledScreen: Tmux.styledScreen(pane)) else {
            return .deferred("看不到输入框（可能弹着确认框）")
        }
        guard before.isEmpty else { return .deferred("输入框里有没提交的文字，可能有人在操作") }
        if let blocked = writeBlocker(member: member, target: target, force: force) { return .deferred(blocked) }

        // 3. 记「开始写入」再粘贴：从这一刻起，出任何问题都只能算「未确认」。
        //    「开始写入」记不进库就抛错（算还没写入），绝不能先写终端：崩溃后会被当成没写过而重投
        try Tmux.loadBuffer(pane, text: text) // 只是载入 tmux 的缓冲区，还没进对方的终端
        try repo.advanceAttempt(attemptId, to: .writeStarted)
        // 记库期间对方可能变了（人先开始了新的一轮、弹了授权框……）：粘贴前再查一次。
        // 这时还没往终端写任何东西，作废这次尝试，消息回到排队
        if let blocked = writeBlocker(member: member, target: target, force: force) {
            repo.cancelAttempt(attemptId, evenIfWriteStarted: true)
            return .deferred(blocked)
        }
        do {
            try Tmux.pasteBuffer(pane)
        } catch {
            return .unconfirmed("粘贴出错：\(error)")
        }

        // 4. 确认粘贴完整进了输入框，并且连续 300ms 不变；8 秒内确认不了就不按回车。
        //    记下这时输入框那几行的原样内容（保留缩进、空行）：输入框原来是空的，所以这一刻出现的就是这次贴的
        guard let pasted = waitForPasted(member: member, pane: pane, text: text) else {
            return .unconfirmed("8 秒内没确认粘贴的内容完整进了输入框，没有按回车")
        }

        // 5. 回车前最后核对：目标没变、对方仍然空闲、成员没被移出、核心没在退出，
        //    并且输入框和刚才记下的原样完全一样（人改过任何一个字、缩进、空行都不按，防止把别人改过的内容发出去）
        if let blocked = writeBlocker(member: member, target: target, beforeEnter: true, force: force) { return .unconfirmed("\(blocked)，没有按回车") }
        guard Composer.rawBox(agent: member.agent, styledScreen: Tmux.styledScreen(pane)) == pasted else {
            return .unconfirmed("回车前输入框里的内容变了，没有按回车")
        }
        do {
            try Tmux.pressEnter(pane)
        } catch {
            return .unconfirmed("按回车出错：\(error)")
        }
        _ = try? repo.advanceAttempt(attemptId, to: .inputAccepted) // 记不上也没关系：停在「开始写入」同样按已写入处理

        // 6. 确认送达。不自动补按回车：拿不出「输入框里就是这次的内容、没人动过」的可靠证据，宁可记未确认交给人处理
        if waitForConfirmation(member: member, attemptId: attemptId, text: text, timeout: 15) { return .confirmed }
        if force && stillWorking(member) { return .queuedBehindTurn }
        return .unconfirmed("回车后 15 秒内没能确认对方收到")
    }

    /// 强制发送后没能按时确认时用：对方是不是仍在干活（消息排在它当前这一轮之后，还没轮到处理）。
    /// 只认「明确在忙」；状态未知、已经空闲都返回 false（空闲了还确认不了，说明真有问题，要照常通知）
    private func stillWorking(_ member: Member) -> Bool {
        switch member.agent {
        case .claude:
            return AgentStatusStore.shared.cachedState(of: member) == .working
        case .codex:
            return CodexTurns.shared.isBusy(sessionId: member.sessionId, forWrite: true,
                                            startedAfter: CodexTurns.processStart(tmux: member.tmux)) == true
        }
    }

    /// 用户是不是暂停了自动投递：每次写之前都从库里重新读（投递开始后用户才点暂停的情况要拦住），读不到也当作暂停
    private func pausedBlocker(_ member: Member) -> String? {
        guard let fresh = try? repo.getMember(member.id) else { return "读不到成员信息" }
        return fresh.paused ? "用户暂停了自动投递" : nil
    }

    /// 这次往哪里写：投递开始时记下，每次写之前核对没变
    private struct WriteTarget {
        let pane: String           // 窗格 id（%N）
        let identity: String       // 窗格 id + 里面进程的 pid
        let launchId: String?      // Claude 会话的启动令牌（同一个窗格里会话重开过的话会变）
        let freshlyStarted: Bool   // 这次新开的会话：状态 hook 还没上报，用「界面已就绪」代替「空闲」
    }

    /// 往窗格里写之前的检查，有问题返回原因：核心正在退出、成员已被移出 / 子群已解散、窗格或会话变了、对方已经不空闲。
    /// beforeEnter：回车前的那次检查（输入框里已经是我们贴的内容）
    /// force：用户要求强制发送，对方「正在干活」不算拦截（其他检查照旧；Claude / Codex 会把输入排在当前这一轮之后）
    private func writeBlocker(member: Member, target: WriteTarget, beforeEnter: Bool = false, force: Bool = false) -> String? {
        if isStopping { return "核心正在退出" }
        if isCancelled(member.id) { return "成员已被移出或子群已解散" }
        if let blocked = pausedBlocker(member) { return blocked }
        if hasUnsettledInterrupt(member) { return "有还没结算的打断（按了 Esc、结果还没确认）" }
        if Tmux.paneIdentity(target.pane) != target.identity { return "tmux 窗格变了（会话被重建或里面的程序换了）" }
        switch member.agent {
        case .claude:
            if AgentStatusStore.shared.launchId(owner: .of(member)) != target.launchId { return "会话重开过（启动令牌变了）" }
            switch AgentStatusStore.shared.cachedState(of: member) {
            case .idle: return nil
            case .waitingPermission: return "弹出了授权框"
            case .working: return force ? nil : "对方已经开始干活（可能有人在终端里先发了消息）"
            case .unknown:
                // 这次刚开的会话还没上报过状态：不受旧会话记录（可能停在上次被杀时的半轮）约束，
                // 但必须看当前屏幕正面是空闲的（没有弹框、没有忙碌动画、输入框认得出来）。回车前只忽略我们刚贴进去的草稿
                if target.freshlyStarted {
                    let screen = MemberReadiness.claudeScreen(Tmux.styledScreen(target.pane), turnEnded: true, ignoreDraft: beforeEnter)
                    return screen == .idle ? nil : "刚打开的会话屏幕上看不出是空闲的"
                }
                // 状态未知（核心重启后对方一直没动过）：和忙闲判断用同一套依据，屏幕和会话记录都确认这一轮结束了才写
                let screen = MemberReadiness.claudeScreen(Tmux.styledScreen(target.pane), turnEnded: MemberReadiness.claudeTurnEndedWhenUnknown(member),
                                                          ignoreDraft: beforeEnter)
                return screen == .idle ? nil : "对方状态未知"
            }
        case .codex:
            switch CodexTurns.shared.isBusy(sessionId: member.sessionId, forWrite: true,
                                            startedAfter: CodexTurns.processStart(tmux: member.tmux)) {
            case false: return nil
            case nil where target.freshlyStarted: return nil
            case true: return force ? nil : "对方已经开始干活（可能有人在终端里先发了消息）"
            default: return "对方状态未知"
            }
        }
    }

    /// 窗口改大小后等界面重画完：屏幕连续 300ms 不变就算画完，最多等 3 秒（等不到也照常往下走，后面的检查会把关）
    private func waitScreenSettled(_ pane: String) {
        let deadline = Date().addingTimeInterval(3)
        var last = Tmux.styledScreen(pane)
        var since = Date()
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            let now = Tmux.styledScreen(pane)
            if now != last {
                last = now
                since = Date()
            } else if Date().timeIntervalSince(since) >= 0.3 {
                return
            }
        }
    }

    /// 等粘贴的内容完整出现在输入框里，并且连续 300ms 不变。最多等 8 秒；
    /// 成功时返回这时输入框那几行的原样内容（保留缩进、空行），回车前拿它比对
    private func waitForPasted(member: Member, pane: String, text: String) -> String? {
        let deadline = Date().addingTimeInterval(8)
        var stable: (raw: String, since: Date)?
        while Date() < deadline {
            let screen = Tmux.styledScreen(pane)
            if let draft = Composer.draft(agent: member.agent, styledScreen: screen),
               Composer.looksPasted(agent: member.agent, draft: draft, text: text),
               let raw = Composer.rawBox(agent: member.agent, styledScreen: screen) {
                if let s = stable, s.raw == raw {
                    if Date().timeIntervalSince(s.since) >= 0.3 { return raw }
                } else {
                    stable = (raw, Date())
                }
            } else {
                stable = nil
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    // ---------- 确认送达 ----------

    /// 在 timeout 秒内等对方收到这一条的证据，收到了就把这次尝试推进到「已确认」
    func waitForConfirmation(member: Member, attemptId: Int64, text: String, timeout: TimeInterval) -> Bool {
        let target = ReceiveTarget(memberId: member.id, agent: member.agent, vm: member.vm, sessionId: member.sessionId,
                                   attemptCreatedAt: repo.getAttempt(attemptId)?.createdAt ?? .distantFuture)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if confirmIfReceived(target, attemptId: attemptId, text: text) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return confirmIfReceived(target, attemptId: attemptId, text: text)
    }

    /// 去哪里找「对方收到了」的证据：投递当时的那个会话（成员之后可能换了会话，补确认时不能用它现在的会话）
    struct ReceiveTarget {
        let memberId: Int64
        let agent: AgentKind
        let vm: String
        let sessionId: String
        let attemptCreatedAt: Date // 比它早开始的回合不可能是在处理这一条
    }

    /// 对方收到的、和这次投递完全一致的消息，以及有没有看到它开始处理这一条：
    /// - 一致：第一行是这次的投递编号，并且原文完全一致（只统一换行符、去掉首尾空白、拆掉 Claude 包的 pasted_content；
    ///   字符串里的空格、缩进、空行都要一样）。只是「引用了这个编号」不算；
    /// - 开工：Claude 的 UserPromptSubmit 是开工那一刻触发的；会话记录里的用户消息要后面已经有 assistant 回复；
    ///   Codex 的用户消息要有一轮接手它，并且那一轮是在这次投递之后才开始的（之前就在跑的旧回合不算）
    /// 返回 nil = 没收到；true / false = 收到了，有没有看到开工。
    /// withTranscript 为 true 时再读一遍 Claude 的会话记录（要读文件，虚拟机里还要走 ubx，比较慢）
    private func receivedEvidence(_ target: ReceiveTarget, attemptId: Int64, text: String, withTranscript: Bool) -> Bool? {
        var received: [(text: String, started: Bool)]
        let tag = Self.attemptTag(attemptId)
        switch target.agent {
        case .claude:
            // 状态归属：绑着单独会话的成员看那个单独会话的那一份（读不到成员就按成员自己算，会话 ID 还要再核对一次）
            let owner = (try? repo.getMember(target.memberId)).map(StatusOwner.of) ?? .member(target.memberId)
            received = AgentStatusStore.shared.recentPrompts(owner: owner, sessionId: target.sessionId).map { ($0, true) }
            if withTranscript, let file = Transcript.find(agent: .claude, sessionId: target.sessionId, vm: target.vm) {
                received += Transcript.claudeUserRecords(file: file, vm: target.vm, tag: tag).map { ($0.text, $0.answered) }
            }
        case .codex:
            // 接手的那一轮必须在这次投递开始之后才开始：投递记录是粘贴之前建的，真正处理这一条的回合一定在它之后。
            // 不留容差：比投递早开始的旧回合，哪怕只早一点，也不是在处理这一条。
            // 补确认（withTranscript）时把所有分段都查一遍：消息可能落在已经停写的旧段里，核心重启后内存里也没有它
            let messages = withTranscript ? CodexTurns.shared.userMessagesInAllSegments(sessionId: target.sessionId)
                                          : CodexTurns.shared.userMessages(sessionId: target.sessionId)
            received = messages.map { ($0.text, $0.turnStart.map { $0 >= target.attemptCreatedAt } ?? false) }
        }
        let wanted = canonical(text)
        let matches = received.filter { firstLine(canonical(unwrapPasted($0.text))) == tag && canonical(unwrapPasted($0.text)) == wanted }
        guard !matches.isEmpty else { return nil }
        return matches.contains { $0.started }
    }

    /// 对方已经收到这一条了吗（判断标准见 receivedEvidence）。收到了就记成已确认，顺带记下有没有看到开工
    @discardableResult
    func confirmIfReceived(_ target: ReceiveTarget, attemptId: Int64, text: String, withTranscript: Bool = false) -> Bool {
        guard let started = receivedEvidence(target, attemptId: attemptId, text: text, withTranscript: withTranscript) else { return false }
        // 先推进阶段、再改投递状态（见 Repository.confirmAttempt）；记不进库就当这次没确认，下次定时检查再补
        do {
            try repo.confirmAttempt(attemptId, observed: started)
        } catch {
            log("投递 \(Self.attemptTag(attemptId)) 已收到，但记录确认时数据库出错：\(error)")
            return false
        }
        return true
    }

    /// 定时检查调用：确认收到了、还没看到开工的尝试，找开工的证据（找到了才放开这个会话的后续投递）。
    /// 和确认用同一套精确比对，不另开宽松的通道
    func observeStarts() {
        for attempt in repo.unobservedAttempts() where !attempt.text.isEmpty {
            let target = ReceiveTarget(memberId: attempt.memberId, agent: attempt.agent, vm: attempt.vm, sessionId: attempt.sessionId,
                                       attemptCreatedAt: attempt.createdAt)
            if receivedEvidence(target, attemptId: attempt.id, text: attempt.text, withTranscript: true) == true {
                try? repo.markAttemptObserved(attempt.id)
                log("投递 \(Self.attemptTag(attempt.id))：已看到对方开始处理")
            }
        }
    }

    /// 比对原文前的规范化：只统一换行符（终端粘贴会把 \n 变成 \r）、去掉首尾空白
    private func canonical(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Claude 会把粘贴进来的内容包一层再交给模型（实测）：
    ///   <pasted_content id="11a4">\n原文\n</pasted_content id="11a4">
    /// 整条消息正好就是这样一个块（外面没有别的字）时取出原文；否则原样返回（外面有别人打的字，就不算这一条）
    private func unwrapPasted(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^<pasted_content id="([^"]+)">\n(.*)\n</pasted_content id="\1">$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let inner = Range(match.range(at: 2), in: trimmed) else { return message }
        return String(trimmed[inner])
    }

    private func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 定时检查调用：给「已写入未确认」的尝试补确认（hook 或会话记录迟到了），确认了投递会改成已送达
    func confirmLateAttempts() {
        // 确认了、投递状态却没改过来的（两步之间数据库出过错）先补上
        try? repo.repairConfirmedDeliveries()
        for attempt in repo.openAttempts() where !attempt.text.isEmpty {
            // 用投递当时的会话找证据，不用成员现在的（成员可能已经换了会话）
            let target = ReceiveTarget(memberId: attempt.memberId, agent: attempt.agent, vm: attempt.vm, sessionId: attempt.sessionId,
                                       attemptCreatedAt: attempt.createdAt)
            if confirmIfReceived(target, attemptId: attempt.id, text: attempt.text, withTranscript: true) {
                log("投递 \(Self.attemptTag(attempt.id)) 已补确认送达")
            }
        }
    }

    // ---------- 桌面端 Codex ----------

    private func runCodexQueue(member: Member, text: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Config.codexBin)
        p.arguments = ["queue", "--thread", member.sessionId, "--message", text]
        p.environment = ShellEnv.environment
        if !member.cwd.isEmpty { p.currentDirectoryURL = URL(fileURLWithPath: member.cwd) }
        let errors = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors
        try p.run()
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw CoreError(message: "退出码 \(p.terminationStatus)：\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}

/// 读 tmux 屏幕上的输入框
enum Composer {
    /// 输入框里真正打的字（去掉变暗的建议文字、整理掉缩进和空行）。空字符串 = 输入框是空的；nil = 看不到输入框（比如弹着确认框）。
    /// 整理过，会丢掉缩进、空行的差别，所以只用来判断「空不空、像不像这次贴的」；回车前防人改动要用 rawBox
    static func draft(agent: AgentKind, styledScreen: String) -> String? {
        guard let box = region(agent: agent, styledScreen: styledScreen) else { return nil }
        return joined(box.map { stripStyle(removeDim($0)) }, prompt: agent == .claude ? "❯" : "›")
    }

    /// 输入框那几行的原样内容（保留颜色编码、缩进、空行）。贴完稳定时记下一份，回车前再取一份，
    /// 两份完全一样才说明没人动过；nil = 看不到输入框
    static func rawBox(agent: AgentKind, styledScreen: String) -> String? {
        region(agent: agent, styledScreen: styledScreen)?.joined(separator: "\n")
    }

    /// 找出屏幕上输入框的那几行（原样，不做任何处理）
    private static func region(agent: AgentKind, styledScreen: String) -> [String]? {
        let lines = styledScreen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        switch agent {
        case .claude:
            // Claude 的输入框在最后两条横线之间，第一行以 ❯ 开头
            let rules = lines.indices.filter { isRule(stripStyle(lines[$0])) }
            guard rules.count >= 2 else { return nil }
            let top = rules[rules.count - 2], bottom = rules[rules.count - 1]
            let box = Array(lines[(top + 1)..<bottom])
            guard let first = box.first, stripStyle(first).hasPrefix("❯") else { return nil }
            return box
        case .codex:
            // Codex 的输入框以 › 开头；屏幕最下面是状态栏（模型名、目录等），和输入框之间隔一个空行。
            // 输入框里的段落之间也可能有空行，所以取到「最后一个空行」之前为止
            let isBlank = { (line: String) in stripStyle(line).trimmingCharacters(in: .whitespaces).isEmpty }
            // 屏幕没占满时底部是空行，先去掉，不然「最后一个空行」会落到状态栏下面
            var screen = lines
            while let last = screen.last, isBlank(last) { screen.removeLast() }
            guard let start = screen.lastIndex(where: { stripStyle($0).hasPrefix("›") }) else { return nil }
            let end = screen[start...].lastIndex(where: isBlank) ?? screen.endIndex
            return Array(screen[start..<end])
        }
    }

    /// 粘贴之后，输入框看起来是不是这次贴进去的内容：全文一致（去掉空白后比较，屏幕会折行），
    /// 或者是折叠后的占位（Claude：[Pasted text #N +行数 lines]；Codex：[Pasted Content 字数 chars]）。
    /// 这只是「贴完整了吗」的观察，不能当成「输入框里是我们的内容」的证明（同行数、同字数的别的内容也会通过）；
    /// 所有权靠「贴之前输入框是空的」+「回车前和贴完时一模一样」来保证，见 deliverViaTmux
    static func looksPasted(agent: AgentKind, draft: String, text: String) -> Bool {
        guard !draft.isEmpty else { return false }
        if normalized(draft) == normalized(text) { return true }
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        switch agent {
        case .claude:
            // 实测占位里的数字是换行的个数（5 行文字显示「+4 lines」）；末尾有没有换行会差一个，所以两个数都认
            guard let match = draft.range(of: #"^\[Pasted text #\d+ \+(\d+) lines\]$"#, options: .regularExpression) else { return false }
            let shown = Int(draft[match].split(separator: "+").last?.filter(\.isNumber) ?? "") ?? -1
            return shown == lineCount - 1 || shown == lineCount
        case .codex:
            // 字数会因为换行的处理略有出入，允许一点误差（同 Orca 的做法）
            guard let match = draft.range(of: #"^\[Pasted Content (\d+) chars\]$"#, options: .regularExpression) else { return false }
            let count = Int(draft[match].filter(\.isNumber)) ?? -1
            let expected = text.count
            return count >= expected && count <= expected + lineCount * 2 + 8
        }
    }

    /// 去掉所有空白后的文字。只用来判断屏幕上的输入框是不是这段内容（屏幕会折行、缩进），
    /// 不能用来确认对方收到的原文（会把 "a b" 和 "ab" 当成一样）
    static func normalized(_ text: String) -> String {
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
    }

    private static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 20 && trimmed.allSatisfy { $0 == "─" }
    }

    /// 把输入框的几行拼起来：去掉开头的提示符和每行的缩进
    private static func joined(_ box: [String], prompt: Character) -> String {
        box.enumerated().map { index, line in
            var text = Substring(line)
            if index == 0, text.first == prompt { text = text.dropFirst() }
            return text.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    /// 去掉变暗（ESC[2m）的那几段：那是 Claude / Codex 显示的建议文字或占位提示，不是真正打的字
    private static func removeDim(_ line: String) -> String {
        line.replacingOccurrences(of: #"\u001B\[2m[^\u001B]*"#, with: "", options: .regularExpression)
    }

    /// 去掉所有颜色、样式的控制序列
    private static func stripStyle(_ line: String) -> String {
        line.replacingOccurrences(of: #"\u001B\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
    }
}
