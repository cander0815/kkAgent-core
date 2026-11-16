// 第 6 步第二期：紧急消息按一次 Esc 打断 tmux 里的 coder / tester，让它先看纠偏消息。
// 设计和评审结论见 kktodo/kkAgent-参考Orca改进方案.md「第 6 步第二期：详细设计」，这里只说关键规则：
//
// - 只在对方确实在干活、排队里有紧急消息时考虑按；任何一项拿不准（版本、回合、屏幕、数据库）都不按，消息照样排在最前。
// - 每次按键都先登记（interrupts 表），同一个实际会话、同一次启动、同一个目标回合只能登记一次，所以同一回合最多按一次。
// - 按之前最后复查，并记下会话记录的文件、文件身份和大小；然后把记录改成 sent（同时记下「可能按过」的时间，用于冷却），
//   改不进库就不按。
// - 打断是否成功只认会话记录里的证据，而且必须是这次启动、按键位置之后写下的：Claude 按 promptId 找这一轮的打断标记 /
//   正常结束，Codex 按 turn_id 找 turn_aborted / task_complete。屏幕上还必须看得出这一轮已经停下（没有忙碌动画、
//   没有弹框、输入框可用）。10 秒内认不出来就记 unknown，之后由定时检查继续认；一直认不出来就挡着这个会话的投递，
//   2 分钟后告警一次，交给人处理。
// - 会话重开过（启动代次变了）：旧进程那一轮必然已经结束，记录结算成 superseded，绝不拿旧证据去改新进程的状态。
// - 还没结算的记录（registered / sent / unknown）挡住这个会话的所有投递，和 hook 状态无关。
// - 所有这些都在这个会话自己的串行投递队列里做，和投递本身不会同时改状态。
import Foundation

/// 打断流程在内存里要记的几样东西（都只是辅助，核心重启丢了也不影响正确性）
final class InterruptBook {
    /// 给对方的开头说明用：这个会话上一次打断的结果，下一批带紧急消息的投递取走
    enum Note { case interrupted, natural, notInterrupted }

    private let lock = NSLock()
    private var notes: [String: Note] = [:]
    private var settleScheduled = Set<String>()        // 定时检查已经排上、还没执行的结算（按会话）
    private var notPressedAlerted = Set<String>()      // 「没能打断」已经告警过的目标回合
    private var stuckSince: [StatusOwner: (revision: Int, since: Date)] = [:] // hook 停在 working 的同一个 revision 从什么时候开始

    func setNote(_ session: String, _ note: Note) {
        lock.lock()
        defer { lock.unlock() }
        // 「没能打断」不覆盖已经确认的结果
        if note == .notInterrupted, notes[session] != nil { return }
        notes[session] = note
    }

    func takeNote(_ session: String) -> Note? {
        lock.lock()
        defer { lock.unlock() }
        return notes.removeValue(forKey: session)
    }

    /// 排上一次结算；已经排上了返回 false
    func scheduleSettle(_ session: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return settleScheduled.insert(session).inserted
    }

    func settleDone(_ session: String) {
        lock.lock()
        settleScheduled.remove(session)
        lock.unlock()
    }

    /// 这个目标回合的「没能打断」告警写过没有
    func notPressedAlertSent(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return notPressedAlerted.contains(key)
    }

    /// 告警确实写进库之后才记下（写失败的下次还会再试）
    func markNotPressedAlertSent(_ key: String) {
        lock.lock()
        notPressedAlerted.insert(key)
        lock.unlock()
    }

    /// hook 停在 working 的同一个 revision 已经多久了（手动 Esc 兜底用：刚变成 working 的不去读会话记录）
    /// 按状态归属记：单独会话拉进群后，群成员和单独会话查的是同一份
    func stuckDuration(owner: StatusOwner, revision: Int) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        if let s = stuckSince[owner], s.revision == revision { return Date().timeIntervalSince(s.since) }
        stuckSince[owner] = (revision, Date())
        return 0
    }
}

extension DeliveryQueue {
    /// 按 Esc 只对实测过的 Claude 版本做（2.1.322：promptId 和打断标记的对应关系是在这个版本上验证的）
    private static let interruptTestedSince = [2, 1, 322]
    /// 同一个发起人对同一个会话，5 分钟内只按一次（KK / 群主不受限）
    private static let interruptCooldown: TimeInterval = 300
    /// 结果一直没法确认，过这么久告警一次（只是提醒，不解除阻挡）
    private static let unknownAlertAfter: TimeInterval = 120
    /// 紧急消息排了这么久还没能打断，才告警「没能打断」（刚提交、正在弹授权框这类几秒内会自己好的情况不刷屏）
    private static let notPressedAlertAfter: TimeInterval = 30

    static func sessionKey(agent: AgentKind, vm: String, sessionId: String) -> String { "\(agent.rawValue)|\(vm)|\(sessionId)" }
    static func sessionKey(_ m: Member) -> String { sessionKey(agent: m.agent, vm: m.vm, sessionId: m.sessionId) }

    /// 取证的结果：结算成什么状态，以及取证之前拍下的 hook 快照（Claude 改空闲时拿它核对期间没来过新事件）
    private struct Evidence {
        let state: InterruptState
        let snapshot: AgentStatusStore.TurnSnapshot?
    }

    // ---------- 投递前的阻挡 ----------

    /// 这个会话上有没结算的打断时返回 true（不投）。先就地结算一次，结算掉了就不挡。读库出错也挡
    func blockedByInterrupt(_ member: Member) -> Bool {
        do {
            guard let record = try repo.unsettledInterrupt(agent: member.agent, vm: member.vm, sessionId: member.sessionId) else { return false }
            settleInterrupt(record)
            return try repo.unsettledInterrupt(agent: member.agent, vm: member.vm, sessionId: member.sessionId) != nil
        } catch {
            log("\(member.alias)：查打断记录时数据库出错，这次先不投：\(error)")
            return true
        }
    }

    /// 定时检查：给每个有没结算打断的会话排一次结算，放进那个会话自己的投递队列
    func scheduleInterruptSettles() {
        guard let records = try? repo.unsettledInterrupts() else { return }
        for record in records {
            guard let member = try? repo.getMember(record.memberId) else {
                // 成员已经被移出：这个会话不再归我们管，不再挡（按过的时间还在，冷却照样算）
                _ = try? repo.moveInterrupt(record.id, from: [.registered, .sent, .unknown], to: .superseded, reason: "成员已移出")
                continue
            }
            let key = Self.sessionKey(member)
            guard interruptBook.scheduleSettle(key) else { continue }
            queue(for: member).async {
                self.interruptBook.settleDone(key)
                // 排队期间可能已经被投递流程结算掉了：重新读一次（读库出错就等下次）
                if let fresh = try? self.repo.getInterrupt(record.id), [.registered, .sent, .unknown].contains(fresh.state) {
                    self.settleInterrupt(fresh)
                }
            }
        }
    }

    /// 结算一条没结算的记录（在会话的投递队列里调用）
    private func settleInterrupt(_ record: Repository.InterruptRecord) {
        guard let member = try? repo.getMember(record.memberId) else { return }
        switch record.state {
        case .registered:
            // 在队列里能看到它，说明登记它的那次流程已经结束、却没能改成 sent 或 aborted（写库失败），也就一定没按过
            _ = try? repo.moveInterrupt(record.id, from: [.registered], to: .aborted, reason: "登记后没能改成已按键，没按过")
        case .sent, .unknown:
            if let evidence = interruptEvidence(record, member: member) {
                _ = applyEvidence(evidence, record: record, member: member)
                return
            }
            // 一直认不出来：继续挡着，过 2 分钟告警一次（写成功才记已告警，写失败下次再试）
            if !record.alerted, Date().timeIntervalSince(record.createdAt) >= Self.unknownAlertAfter {
                if alertGroup(member: member, text: Prompts.interruptUnknown(member: member, sender: senderLabel(record.senderKey, member: member))) {
                    try? repo.markInterruptAlerted(record.id)
                }
            }
        default:
            break
        }
    }

    /// 按证据结算一条记录。Claude 认到这一轮结束、hook 还停在 working 时，先用取证前的快照把主回合改成空闲：
    /// 期间来过新事件（revision 变了）就不改、也不结算，留到下次重新取证。返回结算成了没有
    private func applyEvidence(_ evidence: Evidence, record: Repository.InterruptRecord, member: Member) -> Bool {
        let ended = evidence.state == .confirmed || evidence.state == .natural
        if member.agent == .claude, ended, let snap = evidence.snapshot, snap.mainTurn == .working {
            guard snap.launchId == record.launch, snap.promptId == record.targetTurn,
                  AgentStatusStore.shared.markTurnEnded(owner: .of(member), launchId: snap.launchId, promptId: record.targetTurn,
                                                        revision: snap.revision,
                                                        outcome: evidence.state == .confirmed ? .interrupted : .completed) else { return false }
        }
        guard (try? repo.moveInterrupt(record.id, from: [.sent, .unknown], to: evidence.state)) == true else { return false }
        log("\(member.alias) 的打断记录 #\(record.id) 已结算：\(evidence.state.rawValue)")
        if ended { interruptBook.setNote(Self.sessionKey(member), evidence.state == .confirmed ? .interrupted : .natural) }
        return true
    }

    // ---------- 打断 ----------

    /// 对方在干活、排队里有紧急消息时调用（在会话的投递队列里）。按了并且确认这一轮已经结束（被打断或刚好自己结束）返回 true，
    /// 调用方接着走普通投递流程（所有门禁照样检查）；其他情况返回 false，消息继续排在最前
    func interruptIfUrgent(_ member: Member) -> Bool {
        guard !member.tmux.isEmpty, !member.paused else { return false }
        let urgent = repo.pendingDeliveries(memberId: member.id).filter { $0.urgent && $0.purpose != .bootstrap }
        guard let oldest = urgent.first else { return false }
        let session = Self.sessionKey(member)

        // 不按的时候：记下开头说明；排了足够久还是按不了，告警一次（写成功才算告过）
        func notPressed(_ reason: String, target: String) -> Bool {
            interruptBook.setNote(session, .notInterrupted)
            let waited = parseISO(oldest.sentAt).map { Date().timeIntervalSince($0) } ?? 0
            let key = "\(session)|\(target.isEmpty ? "d\(oldest.id)" : target)"
            if waited >= Self.notPressedAlertAfter, !interruptBook.notPressedAlertSent(key) {
                let sender = senderIdentity(oldest).map { senderLabel($0.key, member: member) } ?? "群成员"
                if alertGroup(member: member, text: Prompts.interruptNotPressed(member: member, sender: sender, reason: reason)) {
                    interruptBook.markNotPressedAlertSent(key)
                }
            }
            return false
        }

        // 1. 有「已写入未确认」之类的阻挡：普通投递本来就不会走，也不按
        guard !hasBlockingAttempt(member) else { return false }

        // 2. 认准目标回合和这次启动
        guard let identity = Tmux.paneIdentity(member.tmux), let pane = identity.split(separator: " ").first.map(String.init) else {
            return notPressed("读不到 tmux 窗格", target: "")
        }
        let target: String
        let launch: String
        switch member.agent {
        case .claude:
            guard let snap = AgentStatusStore.shared.turnSnapshot(owner: .of(member)), snap.mainTurn == .working, !snap.promptId.isEmpty else {
                return notPressed("状态 hook 不知道它当前在跑哪一轮", target: "")
            }
            guard snap.noPermissionWaiting else { return notPressed("正在等授权", target: snap.promptId) }
            guard let file = Transcript.find(agent: .claude, sessionId: member.sessionId, vm: member.vm),
                  let evidence = Transcript.claudeTurnEvidence(file: file, vm: member.vm, promptId: snap.promptId) else {
                return notPressed("会话记录里认不准这一轮", target: snap.promptId)
            }
            // 版本从这一轮自己的记录上读（正在跑的进程的版本），核心重启后也拿得到
            guard let version = evidence.version, !version.lexicographicallyPrecedes(Self.interruptTestedSince) else {
                return notPressed("Claude 版本未知或低于实测过的 2.1.322", target: snap.promptId)
            }
            // 还没有 assistant 回复（刚提交）时按 Esc，提示词会被放回输入框，所以等它开始回复再说
            guard evidence.outcome == .running(hasAssistant: true) else {
                return notPressed("这一轮还没开始回复，或者已经结束", target: snap.promptId)
            }
            target = snap.promptId
            launch = snap.launchId
        case .codex:
            guard let snap = CodexTurns.shared.turnSnapshot(sessionId: member.sessionId, startedAfter: CodexTurns.processStart(tmux: member.tmux)),
                  snap.active.count == 1,
                  let turn = snap.active.first, !turn.isEmpty else {
                return notPressed("认不准 Codex 当前在跑的回合", target: "")
            }
            target = turn
            launch = identity
        }
        if let reason = preKeyBlocker(agent: member.agent, styled: Tmux.styledScreen(pane)) { return notPressed(reason, target: target) }

        // 3. 选发起人：第一个不在冷却中的紧急消息发送人（KK / 群主不受冷却限制）。查冷却出错一律不按
        var chosen: (key: String, exempt: Bool)?
        for d in urgent {
            guard let sender = senderIdentity(d) else { continue }
            if sender.exempt { chosen = sender; break }
            guard let cooling = try? repo.interruptCooling(senderKey: sender.key, agent: member.agent, vm: member.vm, sessionId: member.sessionId,
                                                            since: Date().addingTimeInterval(-Self.interruptCooldown)) else { return false }
            if !cooling { chosen = sender; break }
        }
        guard let sender = chosen else {
            interruptBook.setNote(session, .notInterrupted) // 冷却中：不告警，免得刷屏
            return false
        }

        // 4. 登记。这一回合已经登记过（不管当时按没按）就不再按；数据库出错也不按
        let recordId: Int64
        do {
            guard let id = try repo.registerInterrupt(member: member, launch: launch, targetTurn: target, senderKey: sender.key, exempt: sender.exempt) else {
                return false
            }
            recordId = id
        } catch {
            log("\(member.alias)：登记打断时数据库出错，不按：\(error)")
            return false
        }

        // 5. 按键前最后复查，并记下这一刻会话记录的位置（之后只认这个位置之后写下的结束证据）。
        //    复查没过、或者位置记不进库，都不按
        let recheck = finalRecheck(member: member, pane: pane, identity: identity, launch: launch, target: target)
        guard let position = recheck.position else {
            let reason = recheck.reason ?? "复查没通过"
            _ = try? repo.moveInterrupt(recordId, from: [.registered], to: .aborted, reason: reason)
            return notPressed(reason, target: target)
        }
        do {
            try repo.setInterruptLog(recordId, file: position.file, inode: position.inode, offset: position.offset)
        } catch {
            _ = try? repo.moveInterrupt(recordId, from: [.registered], to: .aborted, reason: "按键前的位置记不进库")
            return false
        }

        // 6. 先记「可能已按」（同时写下按键时间），记不进库就不按；然后只按一次
        guard (try? repo.moveInterrupt(recordId, from: [.registered], to: .sent)) == true else {
            log("\(member.alias)：打断记录改成已按键时数据库出错，不按")
            return false
        }
        do {
            try Tmux.pressEscape(pane)
        } catch {
            // tmux 命令本身失败，键没有发出去
            _ = try? repo.moveInterrupt(recordId, from: [.sent], to: .aborted, reason: "按键命令出错：\(error)")
            return notPressed("按键命令出错", target: target)
        }
        log("已为紧急消息打断 \(member.alias)（记录 #\(recordId)，目标回合 \(target)）")

        // 7. 10 秒内等会话记录里的证据，认到了就结算（Claude 结算时顺带把 hook 状态改成空闲）
        let deadline = Date().addingTimeInterval(10)
        var result: InterruptState?
        while Date() < deadline && result == nil {
            Thread.sleep(forTimeInterval: 0.5)
            guard let record = try? repo.getInterrupt(recordId), let evidence = interruptEvidence(record, member: member) else { continue }
            if applyEvidence(evidence, record: record, member: member) { result = evidence.state }
        }
        guard let result else {
            // 还停在 sent 的改成 unknown；改不进库也没关系，sent 同样挡着投递，由定时检查继续认
            _ = try? repo.moveInterrupt(recordId, from: [.sent], to: .unknown, reason: "按键后 10 秒内没能确认结果")
            log("\(member.alias) 的打断记录 #\(recordId)：10 秒内没能确认结果，先不投，等定时检查")
            return false
        }
        guard result == .confirmed || result == .natural else { return false }
        // 实测 Esc 之后紧接着输入的第一个字符可能被吞掉：等 1 秒再粘贴。这只是保护间隔，送达照样靠粘贴后的完整性核对
        Thread.sleep(forTimeInterval: 1)
        return true
    }

    // ---------- 手动按 Esc 的兜底 ----------

    /// 人在终端里手动按了 Esc（或者这一轮结束了却没等到 Stop），hook 会一直停在 working。
    /// hook 停在同一个状态超过 30 秒时，用同样严格的证据核对一次：当前这一轮在会话记录里已经被打断或自己结束了、
    /// 之后没有新的一轮、屏幕上看得出已经停下，就用核对前拍的快照把状态改成空闲。只恢复忙闲，不写打断记录
    func recoverStuckTurn(_ member: Member) {
        guard member.agent == .claude, !member.tmux.isEmpty else { return }
        recoverStuckTurn(owner: .of(member), sessionId: member.sessionId, vm: member.vm, tmux: member.tmux, label: member.alias)
    }

    /// 同上，直接给出会话在哪（没绑进群的单独会话由定时检查调用，见 Solo.swift 的 checkSoloTurns）。只用于 Claude
    func recoverStuckTurn(owner: StatusOwner, sessionId: String, vm: String, tmux: String, label: String) {
        guard let snap = AgentStatusStore.shared.turnSnapshot(owner: owner), snap.mainTurn == .working,
              !snap.promptId.isEmpty, snap.noPermissionWaiting,
              interruptBook.stuckDuration(owner: owner, revision: snap.revision) >= 30,
              let file = Transcript.find(agent: .claude, sessionId: sessionId, vm: vm),
              let outcome = Transcript.claudeTurnOutcome(file: file, vm: vm, promptId: snap.promptId),
              outcome == .interrupted || outcome == .natural,
              let pane = Tmux.paneIdentity(tmux)?.split(separator: " ").first.map(String.init),
              endedScreenBlocker(agent: .claude, pane: pane) == nil else { return }
        if AgentStatusStore.shared.markTurnEnded(owner: owner, launchId: snap.launchId, promptId: snap.promptId, revision: snap.revision,
                                                 outcome: outcome == .interrupted ? .interrupted : .completed) {
            log("\(label) 这一轮已经\(outcome == .interrupted ? "被打断" : "结束")，但没收到 Stop，按会话记录恢复成空闲")
        }
    }

    // ---------- 证据和检查 ----------

    /// 按一条打断记录取证：confirmed（被打断）/ natural（自己结束）/ superseded（开了新的一轮，或者会话重开过）；认不出来返回 nil。
    /// 只认这次启动、按键位置之后的证据：
    /// - 成员已经换了会话、或者会话重开过（Claude 的启动令牌、Codex 的窗格身份变了）→ superseded，不碰新进程的状态；
    /// - Claude：会话记录的文件和文件身份必须和按键前记下的一样，打断标记 / 正常结束必须写在按键前的位置之后；
    /// - Codex：必须还是按键前跟踪的那一段文件。Codex 按 turn_id 认：按键前最后复查时这一轮还在进行，turn_id 又不会重复，
    ///   所以它的结束事件一定是之后写的，不需要再比位置。这一轮既不在进行、也没有结束记录（被杀掉的旧进程留下的）→ superseded；
    /// - 屏幕上必须看得出已经停下（没有忙碌动画、弹框，输入框可用、是空的），并且没有授权在等
    private func interruptEvidence(_ record: Repository.InterruptRecord, member: Member) -> Evidence? {
        guard member.agent == record.agent, member.vm == record.vm, member.sessionId == record.sessionId else {
            return Evidence(state: .superseded, snapshot: nil)
        }
        guard let identity = Tmux.paneIdentity(member.tmux), let pane = identity.split(separator: " ").first.map(String.init) else { return nil }
        switch member.agent {
        case .claude:
            // 先拍快照再读会话记录：之后改空闲时用它核对，读的期间来过新事件就不改
            guard let snap = AgentStatusStore.shared.turnSnapshot(owner: .of(member)) else { return nil }
            if snap.launchId != record.launch { return Evidence(state: .superseded, snapshot: nil) }
            guard record.logOffset >= 0, !record.logFile.isEmpty,
                  Transcript.find(agent: .claude, sessionId: member.sessionId, vm: member.vm) == record.logFile,
                  Transcript.fileIdentity(record.logFile, vm: member.vm) == record.logInode,
                  let evidence = Transcript.claudeTurnEvidence(file: record.logFile, vm: member.vm, promptId: record.targetTurn,
                                                               after: record.logOffset) else { return nil }
            switch evidence.outcome {
            case .superseded: return Evidence(state: .superseded, snapshot: snap)
            case .running: return nil
            case .interrupted, .natural:
                guard snap.noPermissionWaiting, endedScreenBlocker(agent: member.agent, pane: pane) == nil else { return nil }
                return Evidence(state: evidence.outcome == .interrupted ? .confirmed : .natural, snapshot: snap)
            }
        case .codex:
            if identity != record.launch { return Evidence(state: .superseded, snapshot: nil) }
            guard let snap = CodexTurns.shared.turnSnapshot(sessionId: member.sessionId, startedAfter: CodexTurns.processStart(tmux: member.tmux)),
                  snap.file == record.logFile else { return nil }
            if !snap.active.isEmpty { return snap.active.contains(record.targetTurn) ? nil : Evidence(state: .superseded, snapshot: nil) }
            // 目标回合既不在进行、也没有结束记录：是被杀掉的旧进程留下的回合，再也等不到结束事件，
            // 不结算的话这条记录会永远挡着投递
            guard let ended = snap.ended[record.targetTurn] else { return Evidence(state: .superseded, snapshot: nil) }
            guard endedScreenBlocker(agent: member.agent, pane: pane) == nil else { return nil }
            switch ended {
            case "aborted:interrupted": return Evidence(state: .confirmed, snapshot: nil)
            case "complete": return Evidence(state: .natural, snapshot: nil)
            default: return nil // 别的原因中止的：说不清，交给人
            }
        }
    }

    /// 按键前的屏幕检查，有挡着的东西时返回原因：确认框 / 授权框、看不到输入框、输入框里有字。
    /// 不检查「正在干活」：按键前它本来就在干活
    private func preKeyBlocker(agent: AgentKind, styled: String) -> String? {
        let dialogs = ["Do you want to", "requires approval", "Yes, I trust this folder"]
        if dialogs.contains(where: styled.contains) { return "屏幕上弹着确认框" }
        guard let draft = Composer.draft(agent: agent, styledScreen: styled) else { return "看不到输入框" }
        return draft.isEmpty ? nil : "输入框里有没提交的文字"
    }

    /// 确认「这一轮已经停下」时的屏幕检查：在按键前那些检查之外，还不能有忙碌的迹象
    /// （Claude 的动画行「✶ Thinking… (1m 10s · …)」和「esc to interrupt」，Codex 的「Working (…」）。看不懂的一律不算停下
    private func endedScreenBlocker(agent: AgentKind, pane: String) -> String? {
        let styled = Tmux.styledScreen(pane)
        if let reason = preKeyBlocker(agent: agent, styled: styled) { return reason }
        if styled.contains("esc to interrupt") { return "屏幕上还在干活" }
        let busyPattern = agent == .claude ? #"…\s*\(\d+[hms]"# : #"Working \("#
        if styled.range(of: busyPattern, options: .regularExpression) != nil { return "屏幕上还在干活" }
        return nil
    }

    /// 按键前最后复查。通过时返回这一刻会话记录的位置（文件、文件身份、大小；Codex 只用文件），没通过返回原因
    private func finalRecheck(member: Member, pane: String, identity: String, launch: String,
                              target: String) -> (position: (file: String, inode: String, offset: Int)?, reason: String?) {
        if isStopping { return (nil, "核心正在退出") }
        if isCancelled(member.id) { return (nil, "成员已被移出或子群已解散") }
        guard let fresh = try? repo.getMember(member.id) else { return (nil, "读不到成员信息") }
        if fresh.paused { return (nil, "用户暂停了自动投递") }
        if hasBlockingAttempt(member) { return (nil, "有还没确认的投递") }
        if Tmux.paneIdentity(pane) != identity { return (nil, "tmux 窗格变了") }
        let position: (file: String, inode: String, offset: Int)
        switch member.agent {
        case .claude:
            guard let snap = AgentStatusStore.shared.turnSnapshot(owner: .of(member)), snap.launchId == launch,
                  snap.promptId == target, snap.mainTurn == .working else { return (nil, "这一轮已经结束或换了一轮") }
            if !snap.noPermissionWaiting { return (nil, "正在等授权") }
            // hook 的 working 可能漏了 Stop：再读一次会话记录，确认这一轮确实还在进行、已经有回复
            guard let file = Transcript.find(agent: .claude, sessionId: member.sessionId, vm: member.vm),
                  let inode = Transcript.fileIdentity(file, vm: member.vm),
                  let evidence = Transcript.claudeTurnEvidence(file: file, vm: member.vm, promptId: target),
                  evidence.outcome == .running(hasAssistant: true) else { return (nil, "会话记录里这一轮已经不在进行") }
            position = (file, inode, evidence.size)
        case .codex:
            guard let snap = CodexTurns.shared.turnSnapshot(sessionId: member.sessionId, startedAfter: CodexTurns.processStart(tmux: member.tmux)),
                  snap.active == [target] else {
                return (nil, "这一轮已经结束或换了一轮")
            }
            position = (snap.file, "", -1)
        }
        if let reason = preKeyBlocker(agent: member.agent, styled: Tmux.styledScreen(pane)) { return (nil, reason) }
        return (position, nil)
    }

    /// 这个会话上有没有「已写入未确认」之类的投递阻挡；读库出错也当作有（注意 try? 会把「出错」和「没有」都变成 nil，不能用它）
    private func hasBlockingAttempt(_ member: Member) -> Bool {
        do {
            return try repo.blockingAttempt(agent: member.agent, vm: member.vm, sessionId: member.sessionId) != nil
        } catch {
            return true
        }
    }

    /// 这个会话上有没有还没结算的打断；读库出错也当作有（写前检查用）
    func hasUnsettledInterrupt(_ member: Member) -> Bool {
        do {
            return try repo.unsettledInterrupt(agent: member.agent, vm: member.vm, sessionId: member.sessionId) != nil
        } catch {
            return true
        }
    }

    /// 紧急消息的发起人：稳定身份（成员发的取它的会话，KK 发的取 user）和是否不受冷却限制（KK、集群群主）
    private func senderIdentity(_ d: Repository.QueuedDelivery) -> (key: String, exempt: Bool)? {
        guard let message = repo.getMessage(d.messageId), message.from != "system" else { return nil }
        if message.from == "user" { return ("user", true) }
        guard let group = try? repo.getGroup(message.groupId),
              let sender = (try? repo.listMembers(groupId: group.id))?.first(where: { $0.alias == message.from }) else { return nil }
        return (Self.sessionKey(sender), !group.owner.isEmpty && group.owner == sender.alias)
    }

    /// 告警里写的发起人
    private func senderLabel(_ key: String, member: Member) -> String {
        if key == "user" { return "用户" }
        let alias = (try? repo.listMembers(groupId: member.groupId))?.first { Self.sessionKey($0) == key }?.alias
        return alias ?? "群成员"
    }

    /// 在成员所在的群里记一条只给用户看的系统告警（不建投递记录，不会唤醒任何 agent）。写成了返回 true
    private func alertGroup(member: Member, text: String) -> Bool {
        guard let group = try? repo.getGroup(member.groupId) else { return false }
        do {
            _ = try repo.addMessage(groupId: group.id, from: "system", to: "user", content: Prompts.alertHeader(group) + text, kind: "alert")
            return true
        } catch {
            log("打断告警没能写进去，下次再试：\(error)")
            return false
        }
    }
}
