// 投递：把文字送进目标会话。
// - Codex：codex queue，消息直接进桌面端里开着的那个会话
// - Codex 后台成员（集群 spawn 出来的）：codex exec 新建 / exec resume 续接，跑完一轮进程就退出
// - Claude 开着（终端/VSCode）：通过中转会话的 SendMessage 实时投进窗口
// - Claude 没开着：claude -p --resume，在后台续接会话跑一轮（后台成员第一轮用 --session-id 新建）
// Claude 会话也可以在虚拟机里，两条路一样，只是命令经 ubx run 进虚拟机执行（见 VM.swift）
// 每个会话一条串行队列，同一个会话同一时间只跑一个投递。
//
// 忙时先存着（见 Readiness.swift）：tmux 成员、桌面端 Codex、开着窗口的 Claude 这几种「交出去就算完成」的投递，
// 只在对方空闲时才投。对方忙时消息保持「排队中」，不占队列；等 coder 的 Stop hook 或每 3 秒的定时检查发现它空闲了，
// 再把攒下的消息合并成一条送进去。
import Foundation

final class DeliveryQueue {
    let repo: Repository // 出错通知（Watchdog.swift）也要用
    private let lock = NSLock()
    private var queues: [QueueKey: DispatchQueue] = [:]
    private var running = Set<Int64>()          // 正在投递中的成员 id
    /// 状态已记成「未确认」、通知却没写进库的：尝试 id → (成员 id, 原因)，定时检查补发
    private var pendingUnconfirmedNotices: [Int64: (memberId: Int64, reason: String)] = [:]
    private var processes: [Int64: Process] = [:] // 成员 id → 正在给它跑的后台进程（解散、移出时要停掉）
    private var cancelled = Set<Int64>()          // 已被移出 / 解散的后台成员 id：之后不再给它启动进程（成员 id 不会复用）
    private var allProcesses: [ObjectIdentifier: Process] = [:] // 所有正在跑的投递进程，核心退出时一起停掉
    private var soloProcesses: [Int64: Process] = [:]            // 单独会话 id → 正在跑的启动进程（销毁时停掉，见 Solo.swift）
    private var destroyedSolos = Set<Int64>()                    // 已被销毁的单独会话 id（id 不会复用）
    private var stopping = false // 核心正在退出：不再启动任何投递进程
    private let bootstrapTimeout = Config.bootstrapTimeout

    /// 成员 id → 最近一次「重新打开会话」失败的原因，以及是哪一次请求（序号）失败的（界面要显示出来，让用户知道并能重试）
    private var openErrors: [Int64: (seq: Int, message: String)] = [:]
    /// 「重新打开会话」请求的序号，每次请求加 1
    private var openSeq = 0
    /// 定时检查已经排上、还没执行的唤醒，避免同一个会话的队列里堆满重复的唤醒
    private var wakeScheduled = Set<Int64>()
    private var pollTimer: DispatchSourceTimer?
    /// 第 6 步第二期：紧急消息打断时在内存里记的东西（开头说明、结算排队、告警去重），见 Interrupt.swift
    let interruptBook = InterruptBook()

    /// 串行队列按「会话」分：群主会同时在主群和几个子群里，几行成员指向同一个会话，
    /// 按成员排队的话两条消息会同时续接同一个会话。
    /// 后台 Codex 成员例外，用成员 id：它的会话 ID 要第一轮跑起来才知道，而且它只会在一个子群里（加成员时会拦）
    private enum QueueKey: Hashable {
        case member(Int64)
        case session(agent: AgentKind, vm: String, sessionId: String)
    }

    init(repo: Repository) {
        self.repo = repo
    }

    func isDelivering(_ memberId: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running.contains(memberId)
    }

    /// 排队投递，不等结果；结果写进投递记录。要送的文字和用途（DeliveryPurpose）都记在投递记录里
    func enqueue(deliveryId: Int64, member: Member) {
        queue(for: member).async { self.deliver(deliveryId: deliveryId, memberId: member.id) }
    }

    /// 用户在排队列表里点「强制发送」：不等对方空闲，马上把这一条（只这一条，不合并别的）送进去。
    /// 只放宽「对方正在干活」这一道门；暂停、弹着授权框、有未确认的投递挡着、输入框里有人在打字，这些照样会拦住（消息继续排队）
    /// 最多等 4 秒再返回（界面的请求 5 秒超时）：返回 false = 处理完了这条仍在排队（被上面那些检查拦住了），界面要告诉用户。
    /// 拦截都发生在真正写入之前，通常 1 秒内就有结果；4 秒还没处理完，说明已经在写入或在等对方确认收到，算已开始发送
    func forceSend(deliveryId: Int64, member: Member) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue(for: member).async {
            self.deliver(deliveryId: deliveryId, memberId: member.id, force: true)
            done.signal()
        }
        guard done.wait(timeout: .now() + 4) == .success else { return true }
        return repo.queuedDelivery(deliveryId)?.status != .pending
    }

    private func key(for member: Member) -> QueueKey {
        member.headless && member.agent == .codex
            ? .member(member.id)
            : .session(agent: member.agent, vm: member.vm, sessionId: member.sessionId)
    }

    func queue(for member: Member) -> DispatchQueue {
        let key = key(for: member)
        lock.lock()
        defer { lock.unlock() }
        if let q = queues[key] { return q }
        let q = DispatchQueue(label: "kkagent.delivery")
        queues[key] = q
        return q
    }

    // ---------- 忙时先存着 ----------

    /// 现在能不能往这个成员投。在会话自己的串行队列里调用，所以同一个会话不会有两次判断同时进行。
    /// 上一条交出去后，要么已经确认收到（对方这时已经在干活，会被判成忙），要么记成「已写入未确认」挡在这里，
    /// 所以不需要别的「在途」标记
    private func canDeliverNow(_ member: Member, _ readiness: Readiness, force: Bool = false) -> Bool {
        // 这个会话上有「已写入未确认」的投递：不再派新的，等迟到的确认或人工「解除并继续」。
        // 读库出错时也不投：查不清楚有没有阻挡，宁可等下一次
        do {
            if try repo.blockingAttempt(agent: member.agent, vm: member.vm, sessionId: member.sessionId) != nil { return false }
        } catch {
            log("\(member.alias)：查投递阻挡时数据库出错，这次先不投：\(error)")
            return false
        }
        // 强制发送只放宽「忙」，「状态未知」照样不投；真正写进去之前，TmuxDelivery 里还有一遍检查（授权框、输入框里有字等照样拦）
        return readiness == .idle || (force && readiness == .busy)
    }

    /// 重新打开 tmux 成员的会话（用户在终端里 exit 了），接着原来的会话，不发任何消息。
    /// 放在这个会话自己的投递队列里做，不会和正在进行的投递撞在一起；打开后如果有排队的消息，顺带唤醒。
    /// 每次请求有一个递增的序号（返回给界面）；失败时连同序号一起记下，界面拿「失败记录的序号 ≥ 自己请求的序号」
    /// 判断这次失败了。不能只看失败原因有没有变：同样的错误连续出现两次时，界面可能根本看不到中间的变化
    @discardableResult
    func openSession(_ member: Member) -> Int {
        lock.lock()
        openSeq += 1
        let seq = openSeq
        lock.unlock()
        queue(for: member).async {
            do {
                if try self.ensureTmuxSession(member) { log("已按用户要求重新打开 \(member.alias) 的 tmux 会话") }
                self.setOpenError(member.id, nil)
            } catch {
                log("重新打开 \(member.alias) 的 tmux 会话失败：\(error)")
                self.setOpenError(member.id, (seq, String(describing: error)))
            }
            self.wake(memberId: member.id)
        }
        return seq
    }

    /// 最近一次「重新打开会话」失败的原因和那次请求的序号；没失败过返回 ("", 0)
    func openError(memberId: Int64) -> (message: String, seq: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let failure = openErrors[memberId] else { return ("", 0) }
        return (failure.message, failure.seq)
    }

    private func setOpenError(_ memberId: Int64, _ failure: (seq: Int, message: String)?) {
        lock.lock()
        openErrors[memberId] = failure
        lock.unlock()
    }

    /// 唤醒这个成员排队中的投递（coder 的 Stop hook 用）。对方还没空闲的话，投递开头的判断会让它继续等
    func wake(memberId: Int64) {
        guard let first = repo.pendingDeliveries(memberId: memberId).first, let member = try? repo.getMember(memberId) else { return }
        enqueue(deliveryId: first.id, member: member)
    }

    /// 每 3 秒检查一次所有还有排队消息的成员，空闲了就投。漏掉的唤醒、没有 hook 的成员都靠它
    func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    private func poll() {
        guard !isStopping else { return }
        AgentStatusStore.shared.refreshWaiting(repo: repo)
        confirmLateAttempts()
        observeStarts()
        retryUnconfirmedRecords()
        scheduleInterruptSettles() // 第 6 步：还没结算的打断记录，按会话记录里的证据结算（放进各自会话的队列里做）
        checkSolos()               // 单独会话：用户在终端里 exit 了的收尾（绑着它的成员一起移出，不重建）
        for (deliveryId, memberId) in repo.firstPendingDeliveryPerMember() {
            guard let member = try? repo.getMember(memberId) else { continue }
            // 上一次排上的唤醒还没执行（队列里正在跑一个很久的投递），这次就不再排
            lock.lock()
            let alreadyScheduled = !wakeScheduled.insert(memberId).inserted
            lock.unlock()
            if alreadyScheduled { continue }
            queue(for: member).async {
                self.lock.lock()
                self.wakeScheduled.remove(memberId)
                self.lock.unlock()
                self.deliver(deliveryId: deliveryId, memberId: memberId)
            }
        }
    }

    /// 直接投递一条通知，不记投递记录（用于「你已被移出」「群已解散」这类：收件人已经不在群里了）
    func enqueueNotice(member: Member, text: String) {
        queue(for: member).async {
            // Claude 会话没开着，多半已经做完任务了，不为一句通知在后台把它唤醒。
            // 以后它被重新打开、又往群里发消息时，核心会直接回复它群已不在（见 Prompts.notInGroup）
            if member.agent == .claude && !Transcript.claudeLiveStatus(sessionId: member.sessionId, vm: member.vm).live {
                log("\(member.alias) 的会话没开着，跳过通知")
                return
            }
            self.setRunning(member.id, true)
            defer { self.setRunning(member.id, false) }
            do {
                try self.send(member: member, text: text, bootstrap: false)
                log("通知已送达 \(member.alias)")
            } catch {
                log("通知投递失败（\(member.alias)）：\(error)")
            }
        }
    }

    /// 停掉正在给这个成员跑的后台进程（解散群、移出成员时用）。排队中的投递靠删除投递记录来取消
    func cancel(memberId: Int64) {
        lock.lock()
        cancelled.insert(memberId) // 记下来：检查投递记录之后、进程登记之前才启动的进程，登记时会被立即停掉
        let process = processes[memberId]
        lock.unlock()
        if let process, process.isRunning {
            log("停止成员 \(memberId) 的后台进程（pid \(process.processIdentifier)）")
            process.terminate()
        }
    }

    func isCancelled(_ memberId: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(memberId)
    }

    /// afterInterrupt：刚为紧急消息打断了对方、确认这一轮已经结束，回来重新走一遍（这一遍不再打断）
    /// force：用户要求强制发送这一条，不等对方空闲，也不和别的排队消息合并
    private func deliver(deliveryId: Int64, memberId: Int64, afterInterrupt: Bool = false, force: Bool = false) {
        // 排队期间群被解散、或这个成员被移出了，投递记录会被删掉，这里就不再投递；
        // 已经不是「排队中」，说明它在前面某一轮里被合并送出去了
        guard let first = repo.queuedDelivery(deliveryId), first.status == .pending else { return }
        // 核心正在退出：不再开始新的投递，记录保持「排队中」，下次启动时补投
        guard !isStopping else { return }
        // 投递前重新读一次成员：后台 Codex 成员的会话 ID 是第一轮跑起来才回填的，排队时拿到的那份还是空的
        guard let member = try? repo.getMember(memberId) else { return }

        // 用户暂停了自动投递（准备在终端里手动操作）：消息只排队，恢复后再投。tester 的入群说明那一轮不受影响
        if member.paused && first.purpose != .bootstrap { return }
        // 托管的 Codex 会话还没建出来（入群说明那一轮 bootstrap 还在跑、或者失败了）：后面的消息先排着，
        // 不走普通 tmux 投递（没有会话 ID，tmux 里开不了它）。bootstrap 失败时界面会显示原因，用户处理后再说
        if member.agent == .codex && member.headless && member.sessionId.isEmpty && first.purpose != .bootstrap { return }

        // 第 6 步：这个会话上有还没结算的打断（按了 Esc、结果还没确认），先不投。和 hook 状态无关，读库出错也不投
        if blockedByInterrupt(member) { return }
        // 人在终端里手动按了 Esc、等不到 Stop：hook 一直停在 working 时按会话记录恢复成空闲
        recoverStuckTurn(member)

        // 对方忙、状态未知、或者上一条还在途：消息留在排队里，等唤醒（Stop hook / 定时检查）
        let readiness = MemberReadiness.check(member, bootstrap: first.purpose == .bootstrap)
        if let readiness, !canDeliverNow(member, readiness, force: force) {
            // 对方正在干活、排队里有紧急消息：按一次 Esc 打断。确认这一轮结束了就重新走一遍普通流程（所有门禁照样检查）
            if readiness == .busy, !afterInterrupt, first.purpose != .bootstrap, interruptIfUrgent(member) {
                deliver(deliveryId: deliveryId, memberId: memberId, afterInterrupt: true)
            }
            return
        }

        // 合并投递：这个成员还有别的消息在排队（多半是它上一轮跑的时候别人发来的），一次全部送进去，
        // 不然它要一条消息跑一轮，前面几轮处理的还是已经过时的内容。
        // 要在确认对方空闲之后才取，这样等待期间新来的消息也都会并进来。
        // tester 的入群说明（bootstrap）要单独送：只有它能新建 Codex 会话，而且那一轮要求立即结束
        // 紧急消息（第 6 步）排在前面：紧急一组、普通一组，组内保持原来的先后顺序
        let pending = first.purpose == .bootstrap || force
            ? [first]
            : repo.pendingDeliveries(memberId: member.id).filter { $0.purpose != .bootstrap }
        // 逐条认领（排队中 → 投递中）：这一刻用户刚好点了「取消」的那条认领不到，就不送了
        let batch = (pending.filter(\.urgent) + pending.filter { !$0.urgent }).filter { repo.claimDelivery($0.id) }
        guard !batch.isEmpty else { return }
        let items = batch.map {
            Prompts.MergedItem(text: $0.text.isEmpty ? rebuildText($0, recipient: member) : $0.text, urgent: $0.urgent, sentAt: $0.sentAt)
        }
        var text = items.count == 1 ? items[0].text : Prompts.merged(items)
        // 第 6 步：这批有紧急消息、之前为它们打断过（或者没能打断）时，开头说明对方上一轮发生了什么
        let note = batch.contains(where: \.urgent) ? interruptBook.takeNote(Self.sessionKey(member)) : nil
        if let note { text = Prompts.interruptNote(note) + "\n\n" + text }
        if batch.count > 1 { log("合并投递给 \(member.alias)：\(batch.count) 条排队消息合成一轮") }

        setRunning(member.id, true)
        defer { setRunning(member.id, false) }
        var turnError: Error?
        var attemptId: Int64?
        do {
            if readiness != nil {
                // 「交出去就算完成」的投递：一步步来、每步记库，第一行带投递编号，用来确认对方收到的就是这一条（见 TmuxDelivery.swift）
                let id = try repo.createAttempt(member: member, deliveryIds: batch.map(\.id))
                attemptId = id
                // 文字里的 ESC 换成可见的 ␛：防止夹带的控制字符提前结束括号粘贴、把后半段当命令执行。
                // 库里存的就是这份实际发出去的文字，之后补确认也拿它比对
                let tagged = (Self.attemptTag(id) + "\n" + text).replacingOccurrences(of: "\u{1b}", with: "␛")
                try repo.setAttemptText(id, text: tagged)
                switch try deliverWithAttempt(member: member, attemptId: id, text: tagged, force: force) {
                case .confirmed:
                    break // 确认时已经把投递改成已送达（Repository.confirmAttempt）
                case .unconfirmed(let reason):
                    // 写进去了但没能确认：不重投，这个会话之后的消息先不投，等迟到的确认或人工「解除并继续」。
                    recordUnconfirmed(member: member, attemptId: id, reason: reason)
                case .queuedBehindTurn:
                    // 强制发送、对方还在忙：意料之中的未确认，记库但不通知，等它处理这一条时定时检查会补确认
                    recordUnconfirmed(member: member, attemptId: id, notify: false,
                                      reason: "强制发送时它正在忙，这条排在它当前这一轮之后，等它处理时会自动确认")
                case .deferred(let reason):
                    // 还没写就放弃了：这批消息改回排队，之后再投
                    repo.cancelAttempt(id)
                    if let note { interruptBook.setNote(Self.sessionKey(member), note) } // 开头说明留给下一次
                    log("\(member.alias) 暂时不投：\(reason)")
                }
            } else {
                try send(member: member, text: text, bootstrap: first.purpose == .bootstrap)
                batch.forEach { repo.setDeliveryStatus($0.id, .delivered) }
            }
        } catch {
            // 核心正在退出、进程是被它停掉的：不改状态，保持「投递中」。
            // （写入之后的数据库错误在 recordUnconfirmed 里就地处理，不会走到这里）
            // 下次启动时会统一标成「核心重启，投递中断」并通知群主；这里标成失败的话就漏掉了
            if isStopping { return }
            turnError = error
            log("投递失败（\(member.alias)）：\(error)")
            // 抛错的都是还没开始写入的（写入之后的问题都算「未确认」，不会抛出来），这次尝试作废
            if let attemptId { repo.cancelAttempt(attemptId) }
            let message = String(describing: error).suffix(1000).description
            batch.forEach { repo.setDeliveryStatus($0.id, .failed, error: message) }
        }
        afterTurn(member: member, purpose: first.purpose, error: turnError)
        // 入群说明那一轮只送了它自己。核心重启补投时每个成员只排了一条，后面排队的消息没人再取，这里接着排上
        // （平时每条消息自己都排过，多排一次没关系：已经送出的记录不是「排队中」，开头就返回了）
        if first.purpose == .bootstrap, let next = repo.pendingDeliveries(memberId: member.id).first {
            enqueue(deliveryId: next.id, member: member)
        }
    }

    /// 写进去了但没能确认时记库并通知群主。分三种结果：
    /// - 改成了「已写入未确认」→ 通知群主，界面上出现「解除并继续」；
    /// - 条件没命中 → 等待的这 15 秒里定时补确认已经抢先确认了，不报未确认；
    /// - 写库出错（比如数据库被锁）→ 不在这里硬等。这一条仍是「投递中」、继续挡着后续投递（不能当成已确认），
    ///   定时检查（retryUnconfirmedRecords）会再补记；补记之前已经被补确认的，就不会再被找出来，也就不会误报
    /// notify：false = 意料之中的未确认（强制发送时对方在忙），只记库不通知
    private func recordUnconfirmed(member: Member, attemptId: Int64, notify: Bool = true, reason: String) {
        do {
            guard try repo.markAttemptUnconfirmed(attemptId, reason: reason) else {
                log("投递 \(Self.attemptTag(attemptId)) 等待期间已被补确认，不再报未确认")
                return
            }
        } catch {
            log("投递 \(Self.attemptTag(attemptId)) 记成未确认时数据库出错，稍后定时检查补记：\(error)")
            return
        }
        guard notify else {
            log("给 \(member.alias) 的强制发送已写入，它还在忙，等它处理时再确认：\(Self.attemptTag(attemptId))")
            return
        }
        // 状态记上了，通知本身也要写库：写不进去就放进待补发列表，不能悄悄丢掉
        if !reportUnconfirmed(member: member, reason: reason) {
            lock.lock()
            pendingUnconfirmedNotices[attemptId] = (member.id, reason)
            lock.unlock()
            log("投递 \(Self.attemptTag(attemptId)) 的未确认通知没能写进去，稍后定时检查补发")
        }
    }

    /// 定时检查调用：补上投递方当时因为数据库出错没记成的「未确认」和没发出去的通知
    private func retryUnconfirmedRecords() {
        for attempt in repo.unrecordedAttempts() {
            lock.lock()
            let delivering = running.contains(attempt.memberId) // 正在投的那一次由投递方自己记，不插手
            lock.unlock()
            guard !delivering, let member = try? repo.getMember(attempt.memberId) else { continue }
            recordUnconfirmed(member: member, attemptId: attempt.id, reason: "回车后没能确认对方收到（当时记录状态时数据库出错，现已补记）")
        }
        lock.lock()
        let notices = pendingUnconfirmedNotices
        lock.unlock()
        for (attemptId, notice) in notices {
            // 补发前再核对一次：这期间被补确认或人工解除了，旧通知就作废；查不了（数据库还不行）就下次再说
            guard let stillUnconfirmed = try? repo.isAttemptUnconfirmed(attemptId) else { continue }
            if stillUnconfirmed {
                guard let member = try? repo.getMember(notice.memberId),
                      reportUnconfirmed(member: member, reason: notice.reason) else { continue }
            }
            lock.lock()
            pendingUnconfirmedNotices[attemptId] = nil
            lock.unlock()
        }
    }

    /// 老的投递记录（加 text 列之前建的）没存文字，按消息内容重建：系统消息原样，群消息套上群消息的格式
    private func rebuildText(_ d: Repository.QueuedDelivery, recipient: Member) -> String {
        guard let message = repo.getMessage(d.messageId), let group = try? repo.getGroup(message.groupId) else { return "" }
        if message.from == "system" { return message.content }
        let sender = (try? repo.listMembers(groupId: group.id))?.first { $0.alias == message.from }
        return Prompts.delivered(group: group, sender: sender, recipient: recipient, messageId: message.id, content: message.content, verdict: message.verdict,
                                 urgent: message.urgent, sentAt: message.createdAt)
    }

    /// 核心启动时调用：上次还在排队、没开始的投递重新排进队列（每个成员排一条就够，开始时会把其余的合并进来）
    func requeuePending() {
        for (deliveryId, memberId) in repo.firstPendingDeliveryPerMember() {
            guard let member = try? repo.getMember(memberId) else { continue }
            log("补投 \(member.alias) 上次没送出的排队消息")
            enqueue(deliveryId: deliveryId, member: member)
        }
    }

    /// 把文字送进成员的会话，失败抛错
    private func send(member: Member, text: String, bootstrap: Bool) throws {
        // 常驻 tmux 的成员（集群 coder / tester）的普通消息走 deliverWithAttempt（TmuxDelivery.swift），不会走到这里。
        // 例外是 tester 的入群说明：Codex 的会话 ID 只能靠 exec 建会话拿到，先走下面的 exec，建好后马上起 tmux
        switch member.agent {
        case .codex:
            if member.headless {
                try runCodexTurn(member: member, text: text, bootstrap: bootstrap)
                // 会话 ID 刚回填，重新读一次成员，把 tmux 会话起好，用户马上就能打开。
                // 起不来不算这一轮失败：Codex 会话已经建好了，下一条消息投递时会再起 tmux
                if !member.tmux.isEmpty, let updated = try? repo.getMember(member.id) {
                    do { try ensureTmuxSession(updated) } catch { log("\(member.alias) 的 tmux 会话暂时没起来（下一条消息时再试）：\(error)") }
                }
            } else {
                try run(Config.codexBin, ["queue", "--thread", member.sessionId, "--message", text], cwd: member.cwd)
            }
        case .claude:
            // 会话在虚拟机里时（member.vm 不为空），中转会话和后台续接也都在那台虚拟机里跑
            let live = Transcript.claudeLiveStatus(sessionId: member.sessionId, vm: member.vm)
            if live.live && !live.name.isEmpty {
                try Relay.on(member.vm).send(to: live.name, text: text)
            } else {
                // 后台成员第一轮：会话文件还不存在，用核心预先生成的 ID 新建会话；之后都是续接
                let isNew = member.headless && Transcript.find(agent: .claude, sessionId: member.sessionId, vm: member.vm) == nil
                // 提示词走 stdin：--allowedTools 之类的变长参数会吞掉后面的位置参数，走 stdin 最稳
                let claude = try VM.claudeLaunch(vm: member.vm, cwd: member.cwd, args: [
                    "-p", isNew ? "--session-id" : "--resume", member.sessionId, "--output-format", "stream-json", "--verbose",
                    "--permission-mode", Config.claudePermissionMode,
                ] + ModelSettingsStore.claudeArgs()) // 设置 → 模型 里配的默认模型和思考强度
                try run(claude.executable, claude.args, cwd: claude.cwd, stdin: text, memberId: member.headless ? member.id : nil)
            }
        }
    }

    // ---------- 常驻 tmux 的成员 ----------

    /// tmux 会话不在（第一次、或者会话里的程序退出了）就新建一个，在里面打开交互界面接着这个会话，等界面就绪
    /// 返回 true = 这次新开了会话，并且界面已经就绪（这时状态 hook 还没来得及上报，但可以确定它是空闲的）
    @discardableResult
    func ensureTmuxSession(_ member: Member) throws -> Bool {
        guard !Tmux.exists(member.tmux) else { return false }
        // 绑着单独会话的成员：进程归「会话」页管，它已经结束（销毁或用户 exit）就不能由群这边重建
        if member.soloId != 0 {
            throw CoreError(message: "\(member.alias) 绑着的单独会话已经结束，不再自动重建（需要的话到「会话」页重新新建）")
        }
        let (command, readyMarker) = try tmuxLaunch(agent: member.agent, vm: member.vm, cwd: member.cwd, sessionId: member.sessionId,
                                                    owner: .member(member.id), label: member.alias)
        // 解散 / 移出是「先登记取消、再关 tmux」。启动前后各查一次取消：
        // 关 tmux 时如果会话还没建出来就关不到，所以建好之后再查一遍，被取消了就自己关掉，免得留下没人管的会话
        let gone = CoreError(message: "\(member.alias) 已被移出或子群已解散，不再启动它的 tmux 会话")
        guard !isCancelled(member.id) else { throw gone }
        try Tmux.start(member.tmux, cwd: member.cwd, command: command)
        if isCancelled(member.id) {
            Tmux.kill(member.tmux)
            throw gone
        }
        guard Tmux.waitReady(member.tmux, readyMarker: readyMarker, timeout: Config.tmuxReadyTimeout) else {
            // 等的期间被移出 / 解散（tmux 会话被关掉）：不算界面没就绪
            if isCancelled(member.id) { throw gone }
            guard Tmux.exists(member.tmux) else {
                throw CoreError(message: "tmux 会话 \(member.tmux) 在界面就绪前就退出了（可能是进虚拟机或启动失败）")
            }
            let minutes = Int(Config.tmuxReadyTimeout / 60)
            throw CoreError(message: "tmux 会话 \(member.tmux) 里的界面 \(minutes) 分钟内没就绪，可以 tmux attach -t \(member.tmux) 进去看看")
        }
        if member.agent == .claude { markReadyIfIdle(owner: .member(member.id), tmux: member.tmux) }
        return true
    }

    /// 在 tmux 里打开交互界面要执行的命令，以及「界面已就绪」的标志（群成员和单独会话共用）。
    /// Claude：会话文件还不存在就用预先生成的 ID 新建，存在就接着；每次都换一个新的启动令牌、写 hook 设置（见 AgentStatus.swift）
    func tmuxLaunch(agent: AgentKind, vm: String, cwd: String, sessionId: String, owner: StatusOwner,
                    label: String) throws -> (command: String, readyMarker: String) {
        let q = quote
        switch agent {
        case .claude:
            let isNew = Transcript.find(agent: .claude, sessionId: sessionId, vm: vm) == nil
            let hookArgs = try AgentStatusStore.shared.prepareLaunch(owner: owner, sessionId: sessionId, vm: vm, label: label, repo: repo)
            let claude = ["claude", isNew ? "--session-id" : "--resume", sessionId, "--permission-mode", Config.claudePermissionMode]
                + ModelSettingsStore.claudeArgs() + hookArgs // 设置 → 模型 里配的默认模型和思考强度
            let command: String
            if vm.isEmpty {
                command = claude.map(q).joined(separator: " ")
            } else {
                // 进虚拟机跑：bash -i 读 .bashrc（虚拟机里的 claude 是 nvm 装的），"$@" 把参数原样交给 claude
                guard let ubx = ShellEnv.which("ubx") else { throw CoreError(message: "找不到 ubx 命令，没法进虚拟机 \(vm)") }
                command = ([ubx, "shell", vm, "--cd", cwd, "--", "bash", "-ic", "exec claude \"$@\"", "bash"]
                    + claude.dropFirst()).map(q).joined(separator: " ")
            }
            // 输入框的提示符。注意它后面跟的是不换行空格，不是普通空格，所以只认这一个字符；
            // 信任确认框上也有它，Tmux.waitReady 会先排除确认框
            return (command, "❯")
        case .codex:
            guard !sessionId.isEmpty else { throw CoreError(message: "\(label) 的 Codex 会话还没建好，没法在 tmux 里打开") }
            let command = ([Config.codexBin] + Config.codexInteractiveApproval + ModelSettingsStore.codexArgs()
                + ["-C", cwd, "resume", sessionId]).map(q).joined(separator: " ")
            return (command, "for shortcuts")
        }
    }

    /// 刚启动、界面已就绪、还没来过任何 hook 事件，并且屏幕上正面看得出是空闲的：直接记成空闲
    /// （重新打开会话后排队的消息才能投进去）。waitReady 只看到了提示符，不够：屏幕上还得没有弹框、
    /// 没有忙碌动画、输入框认得出来而且是空的，这里用和「状态未知」时同一套屏幕判断（这一轮当作已结束，只看屏幕）。
    /// 看屏幕和记状态之间要是来了 hook 事件，markReadyAfterLaunch 会因为 revision 变了而不改
    func markReadyIfIdle(owner: StatusOwner, tmux: String) {
        if let launch = AgentStatusStore.shared.launchId(owner: owner),
           MemberReadiness.claudeScreen(Tmux.styledScreen(tmux), turnEnded: true) == .idle {
            AgentStatusStore.shared.markReadyAfterLaunch(owner: owner, launchId: launch)
        }
    }

    /// 给 shell 用的单引号转义：abc → 'abc'，里面的单引号写成 '\''
    private func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func setRunning(_ memberId: Int64, _ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if value { running.insert(memberId) } else { running.remove(memberId) }
    }

    /// 登记刚启动的后台进程。这个成员已经被取消（移出 / 解散）时不登记，直接停掉它并抛错。
    /// 「查取消标记」和「登记」在同一把锁里做，cancel 不会漏掉夹在中间启动的进程
    private func register(_ memberId: Int64?, _ process: Process) throws {
        lock.lock()
        // 核心正在退出时也拒绝登记：terminateAll 已经拿走了要停的进程名单，这时登记进来的会被漏掉
        let rejected = stopping || (memberId.map { cancelled.contains($0) } ?? false)
        if !rejected {
            allProcesses[ObjectIdentifier(process)] = process
            if let memberId { processes[memberId] = process }
        }
        let reason = stopping ? "核心正在退出，已停止" : "成员已被移出或群已解散，已停止"
        lock.unlock()
        if rejected {
            process.terminate()
            throw CoreError(message: reason)
        }
    }

    var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func unregister(_ memberId: Int64?, _ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        allProcesses[ObjectIdentifier(process)] = nil
        if let memberId { processes[memberId] = nil }
    }

    /// 单独会话启动用的进程（Codex 建会话的 codex exec）：按单独会话 id 登记，销毁时能马上停掉；
    /// 同时进 allProcesses，核心退出时一起回收。已经被销毁或核心正在退出时不登记，直接停掉并抛错。
    /// 「查销毁标记」和「登记」在同一把锁里，terminateSolo 不会漏掉夹在中间启动的进程
    func registerSolo(_ soloId: Int64, _ process: Process) throws {
        lock.lock()
        let rejected = stopping || destroyedSolos.contains(soloId)
        if !rejected {
            allProcesses[ObjectIdentifier(process)] = process
            soloProcesses[soloId] = process
        }
        lock.unlock()
        if rejected {
            process.terminate()
            throw CoreError(message: stopping ? "核心正在退出，已停止" : "单独会话已被销毁，已停止")
        }
    }

    func unregisterSolo(_ soloId: Int64, _ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        allProcesses[ObjectIdentifier(process)] = nil
        if soloProcesses[soloId] === process { soloProcesses[soloId] = nil }
    }

    /// 销毁单独会话时停掉它还在跑的启动进程，并记下它已销毁（之后它的启动进程一律登记不进来）
    func terminateSolo(_ soloId: Int64) {
        lock.lock()
        destroyedSolos.insert(soloId)
        let process = soloProcesses.removeValue(forKey: soloId)
        lock.unlock()
        if let process, process.isRunning {
            log("单独会话 #\(soloId) 被销毁，停止它的启动进程 pid \(process.processIdentifier)")
            process.terminate()
        }
    }

    /// 核心退出前调用：停掉所有正在跑的投递进程。
    /// 实测 launchd 重启核心时不会替我们停掉它们，留下的进程会继续改代码，和重启后的新投递撞在一起
    func terminateAll() {
        // 先在锁里标记「正在退出」再拿名单：之后队列里排着的投递不会再启动，也登记不进来，名单不会漏
        lock.lock()
        stopping = true
        let running = Array(allProcesses.values)
        lock.unlock()
        for p in running where p.isRunning {
            log("核心退出，停止投递进程 pid \(p.processIdentifier)")
            p.terminate()
        }
        // 最多等 3 秒让它们自己退出，还不退就强制结束
        let deadline = Date().addingTimeInterval(3)
        while running.contains(where: { $0.isRunning }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        for p in running where p.isRunning {
            log("投递进程 pid \(p.processIdentifier) 3 秒内没退出，强制结束")
            kill(p.processIdentifier, SIGKILL)
        }
    }

    /// 在另一个线程把 stdin 写完并关闭。和读 stdout / stderr 同时进行：
    /// 先同步写完再读的话，提示词很大、子进程又先输出了很多内容时，两边会互相等着卡死
    private func writeInBackground(_ text: String, to pipe: Pipe) {
        DispatchQueue.global().async {
            // 子进程提前退出时写会失败，忽略即可，退出码和 stderr 会说明原因
            try? pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try? pipe.fileHandleForWriting.close()
        }
    }

    /// 跑一个命令并等它结束，退出码非 0 就抛错（带上 stderr 末尾，方便排查）。
    /// memberId 不为空时记下这个进程，解散 / 移出时可以停掉它
    private func run(_ executable: String, _ args: [String], cwd: String, stdin: String? = nil, memberId: Int64? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = ShellEnv.environment
        if !cwd.isEmpty { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let input = Pipe()
        let errors = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errors
        try p.run()
        try register(memberId, p)
        defer { unregister(memberId, p) }
        writeInBackground(stdin ?? "", to: input)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw CoreError(message:"退出码 \(p.terminationStatus)：\(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // ---------- 后台 Codex 成员 ----------

    /// 让后台 Codex 成员跑一轮：会话 ID 为空时新建（只有 bootstrap 那条可以），否则续接。
    /// 成功 = 退出码 0 + 收到 turn.completed + 没有 turn.failed
    private func runCodexTurn(member: Member, text: String, bootstrap: Bool) throws {
        // 审批交给 Codex 的自动审查（见 Config.codexExecApproval），只能在工作目录（worktree）里写；提示词写 - 表示从 stdin 读
        var args = ["exec", "--json"] + Config.codexExecApproval + ModelSettingsStore.codexArgs() + ["-C", member.cwd]
        if !member.sessionId.isEmpty {
            args += ["resume", member.sessionId]
        } else if !bootstrap {
            // 不是入群说明却没有会话 ID：说明第一轮失败了。这里不能新建，否则会悄悄多出第二个会话
            throw CoreError(message: "\(member.alias) 的 Codex 会话还没建好（第一轮没跑成功），这条消息没有投递")
        }
        args.append("-")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Config.codexBin)
        p.arguments = args
        p.environment = ShellEnv.environment
        p.currentDirectoryURL = URL(fileURLWithPath: member.cwd)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        try p.run()
        try register(member.id, p)
        defer { unregister(member.id, p) }

        // stdout 和 stderr 要同时读：只读一根的话，另一根写满缓冲区后进程会卡住
        var stderrData = Data()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            stderrData = errors.fileHandleForReading.readDataToEndOfFile()
            stderrDone.signal()
        }
        writeInBackground(text, to: input)

        // 入群说明那一轮只是让它记住角色、顺便建出会话，应该很快结束。
        // 模型偶尔会误以为要在这一轮里等 coder（调 sleep 一直不退出），后面的消息就全被堵在队列里，
        // 所以给这一轮一个时限，到点直接停掉。会话 ID 已经回填的话，下一条消息照样能续接
        // timedOut 在计时线程里写、在这里读，用锁保护
        var timedOut = false
        let timeoutLock = NSLock()
        if bootstrap {
            DispatchQueue.global().asyncAfter(deadline: .now() + bootstrapTimeout) {
                timeoutLock.lock()
                defer { timeoutLock.unlock() }
                if p.isRunning {
                    timedOut = true
                    p.terminate()
                }
            }
        }

        // stdout 是一行一个 JSON 事件，边读边处理
        var completed = false
        var problems: [String] = [] // turn.failed / error / 会话 ID 对不上，任何一条都算这一轮失败
        var sessionId = member.sessionId
        func handle(_ line: Data) {
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            switch event["type"] as? String {
            case "thread.started":
                let id = event["thread_id"] as? String ?? ""
                if sessionId.isEmpty && !id.isEmpty {
                    // 拿到就马上存，即使这一轮后面失败了，下次也能接着这个会话
                    do {
                        try repo.setMemberSession(member.id, sessionId: id)
                        sessionId = id
                        log("\(member.alias) 的 Codex 会话已建好：\(id)")
                    } catch {
                        problems.append("会话 ID \(id) 保存失败：\(error)")
                    }
                } else if id != sessionId {
                    problems.append("续接的会话 ID 不一致：应为 \(sessionId)，实际 \(id)")
                }
            case "turn.completed":
                completed = true
            case "turn.failed":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "未知原因"
                problems.append("这一轮失败：\(message)")
            case "error":
                problems.append("出错：\(event["message"] as? String ?? "未知原因")")
            default:
                break
            }
        }
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break } // 读到结尾：进程关掉了 stdout
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                handle(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { handle(buffer) }
        stderrDone.wait()
        p.waitUntilExit()

        let stderrTail = String(decoding: stderrData.suffix(1500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        timeoutLock.lock()
        let wasTimedOut = timedOut
        timeoutLock.unlock()
        if wasTimedOut {
            // 超时前已经记录到明确的错误（turn.failed、会话 ID 不对等），按失败处理，不能因为超时就当成功
            guard problems.isEmpty else {
                throw CoreError(message: "入群说明那一轮超时被停止，之前已出错：\(problems.joined(separator: "\n"))")
            }
            guard !sessionId.isEmpty else {
                throw CoreError(message: "入群说明那一轮超过 \(Int(bootstrapTimeout)) 秒没结束，已停止，而且没拿到会话 ID")
            }
            // 没有已知错误、会话 ID 已保存，只是没自己结束：会话可以续接，这条投递算送达，日志里写明是超时停掉的
            log("\(member.alias) 的入群说明那一轮超过 \(Int(bootstrapTimeout)) 秒没结束，已停止；会话已建好，后续消息照常续接")
            return
        }
        if p.terminationStatus != 0 {
            throw CoreError(message: "退出码 \(p.terminationStatus)：\((problems + [stderrTail]).joined(separator: "\n"))")
        }
        if !problems.isEmpty { throw CoreError(message: problems.joined(separator: "\n")) }
        if !completed { throw CoreError(message: "进程正常退出，但没收到 turn.completed：\(stderrTail)") }
    }
}
