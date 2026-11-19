// 投递前判断对方忙不忙：对方在干活或卡在授权框上，消息就先留在核心的排队里，等它空闲了再合并成一条送进去。
// 详见 kktodo/kkAgent-参考Orca改进方案.md 第四节第 2 步。
//
// 忙闲只有三种结果：空闲 / 忙 / 未知。未知一律按「不投」处理，绝不当成空闲。
import Foundation

enum Readiness {
    case idle, busy, unknown
}

enum MemberReadiness {
    /// 判断成员现在能不能接收投递。返回 nil 表示这种投递方式不用等：
    /// 后台续接的 claude -p、codex exec 投递时本来就要等对方这一轮跑完，已经会合并
    static func check(_ member: Member, bootstrap: Bool) -> Readiness? {
        // tmux 里的 coder / tester（tester 的入群说明那一轮除外，它走 codex exec）
        if !member.tmux.isEmpty && !bootstrap {
            // 会话不在：投递时会新开一个，新开的会话等界面就绪后就是空闲的。
            // 绑着单独会话的成员例外：进程归「会话」页管，不由群这边重建，算未知（不投）
            guard Tmux.exists(member.tmux) else { return member.soloId != 0 ? .unknown : .idle }
            let readiness: Readiness
            switch member.agent {
            case .claude: readiness = claudeInTmux(member)
            case .codex: readiness = codex(member)
            }
            // 输入框里有字（有人在打字）也算忙：不进投递流程，免得每次定时检查都白建一条投递尝试再作废
            if readiness == .idle,
               let draft = Composer.draft(agent: member.agent, styledScreen: Tmux.styledScreen(member.tmux)), !draft.isEmpty {
                return .busy
            }
            return readiness
        }
        switch member.agent {
        case .codex:
            // 桌面端 Codex（codex queue 一交出去就算完成）要等；后台 codex exec 不用
            return member.headless ? nil : codex(member)
        case .claude:
            // 开着窗口的 Claude（经中转会话发送）要等；没开着就是后台续接，不用
            let live = Transcript.claudeLiveStatus(sessionId: member.sessionId, vm: member.vm)
            guard live.live && !live.name.isEmpty else { return nil }
            // 明确是 idle 才算空闲；shell 是「这一轮已经结束，只是后台还有命令在跑」，同样能接新消息
            // （实测 Claude 2.1.322：有后台命令时空闲状态写的是 shell，不是 idle）。空值或不认识的值算未知
            switch live.status {
            case "idle", "shell": return .idle
            case "busy": return .busy
            default: return .unknown
            }
        }
    }

    /// tmux 里的 Claude：看状态 hook（AgentStatus.swift）；状态未知（比如核心刚重启）时截屏核对
    private static func claudeInTmux(_ member: Member) -> Readiness {
        switch AgentStatusStore.shared.state(of: member) {
        case .idle: return .idle
        case .working, .waitingPermission: return .busy
        case .unknown:
            // 状态未知（核心刚重启、漏了 Stop）：看屏幕 + 会话记录，两边都能确认这一轮结束了才算空闲
            return claudeScreen(Tmux.styledScreen(member.tmux), turnEnded: claudeTurnEndedWhenUnknown(member))
        }
    }

    /// hook 状态未知时，从会话记录看主回合结束了没有（true 结束 / false 还在进行 / nil 说不清）：
    /// - 有会话记录：看最后一条有意义的记录（Transcript.claudeTurnEnded）；
    /// - 确认一条记录都还没写过（会话刚建、还没提交过任何提示词）：不可能在跑一轮，算结束。
    ///   实际遇到过：第一次投递时界面没按时就绪、投递失败，用户随后「重新打开」会话，这时既没有 hook 事件也没有会话记录，
    ///   不认这一条的话会一直判成未知，群主发的任务永远投不进去；
    /// - 查不了（虚拟机连不上等）：说不清
    static func claudeTurnEndedWhenUnknown(_ member: Member) -> Bool? {
        if let file = Transcript.find(agent: .claude, sessionId: member.sessionId, vm: member.vm) {
            return Transcript.claudeTurnEnded(file: file, vm: member.vm)
        }
        return Transcript.claudeSessionUnwritten(sessionId: member.sessionId, vm: member.vm) == true ? true : nil
    }

    /// 从 Claude 的屏幕（带颜色编码）和会话记录判断忙闲，只在 hook 状态未知时用：
    /// - 有确认框（授权、信任文件夹）、或者正在干活的动画行（形如「✶ Incubating… (1m 10s · ↓ 441 tokens)」）→ 忙；
    /// - 输入框里有字（有人在打字）→ 忙；
    /// - 输入框认得出来、是空的（建议文字不算），并且会话记录显示主回合已经结束 → 空闲；
    /// - 其他情况（看不到输入框、会话记录说还在进行、读不到会话记录）→ 未知（不投）
    /// ignoreDraft：回车前核对时，输入框里本来就是我们刚贴进去的内容，不按「有字 = 忙」算
    static func claudeScreen(_ styled: String, turnEnded: Bool?, ignoreDraft: Bool = false) -> Readiness {
        let dialogs = ["Do you want to", "requires approval", "Yes, I trust this folder", "esc to interrupt"]
        if dialogs.contains(where: styled.contains) { return .busy }
        if styled.range(of: #"…\s*\(\d+[hms]"#, options: .regularExpression) != nil { return .busy }
        guard let draft = Composer.draft(agent: .claude, styledScreen: styled) else { return .unknown }
        if !draft.isEmpty && !ignoreDraft { return .busy }
        switch turnEnded {
        case true: return .idle
        case false: return .busy
        default: return .unknown
        }
    }

    /// Codex：看会话记录里成对的 task_started / task_complete / turn_aborted
    private static func codex(_ member: Member) -> Readiness {
        // 要据此决定能不能投：重新确认正在写的是哪一段（见 isBusy 的 forWrite）
        guard let busy = CodexTurns.shared.isBusy(sessionId: member.sessionId, forWrite: true,
                                                  startedAfter: CodexTurns.processStart(tmux: member.tmux)) else { return .unknown }
        return busy ? .busy : .idle
    }
}

/// 按文件增量跟踪 Codex 会话的回合。
/// 原来的 Transcript.isCodexBusy 只看最后 200KB、判断不出来就当空闲：一轮输出超过 200KB、task_started 落在窗口外时会误判。
/// 这里第一次从头扫完整个文件，之后记住读到的位置，只读新增的部分
final class CodexTurns {
    static let shared = CodexTurns()

    private struct Track {
        var file: String
        var resolvedAt = Date() // 什么时候找的这个文件（桌面端会话会分段写到新文件，隔一会儿要重新找）
        var offset = 0
        var verified = false // 第一行 session_meta 里的会话 ID 核对过了
        var corrupt = false  // 读到了解析不了的行：跟踪结果不可信，一直算未知
        var activeTurns = Set<String>() // 开始了还没结束的回合（turn_id）。只有对应的结束事件才清掉
        var turnStarts: [String: Date] = [:] // 进行中的回合各自的开始时间
        /// 最近结束的回合怎么结束的（第 6 步打断用）：turn_id → "complete"，或 "aborted:<reason>"（比如 aborted:interrupted）
        var endedTurns: [String: String] = [:]
        var endedOrder: [String] = [] // endedTurns 的先后，只留最近 50 个
        var endedAt: [String: Date] = [:] // 这些回合在会话记录里的结束时间（单独会话的结束提醒用）
        /// 最近几条用户消息原文（确认投递时比对编号和全文），以及处理它的那一轮的开始时间：
        /// 写入时有回合在进行，就是最近开始的那一轮；没有，就等下一个开始的回合来认领（nil = 还没有回合接手）
        var userMessages: [(text: String, turnStart: Date?)] = []
        var keepAllMessages = false // 扫描全部分段时打开：用户消息全部保留，平时只留最近 20 条
    }

    /// 全部分段扫描的结果缓存：会话 ID → (扫描时间, 所有用户消息)
    private var segmentScans: [String: (at: Date, messages: [(text: String, turnStart: Date?)])] = [:]

    private let lock = NSLock()
    private var tracks: [String: Track] = [:] // 会话 ID → 跟踪进度
    /// 最近一次没找到会话文件的时间（会话 ID → 时间）。界面每 2 秒给所有成员查一次忙闲，
    /// 文件还没写出来的会话不记住的话，每次都要把 ~/.codex/sessions 整个遍历一遍（还拿着锁，会挡住投递）
    private var missing: [String: Date] = [:]

    /// tmux 里的 Codex 现在这个进程是什么时候启动的（就是 tmux 会话的创建时间），传给下面的 startedAfter。
    /// 不在 tmux 里（桌面端）、或者 tmux 会话不在，返回 nil
    static func processStart(tmux: String) -> Date? {
        tmux.isEmpty ? nil : Tmux.createdAt(tmux)
    }

    /// 这个会话是不是正在跑一轮。返回 nil = 未知：找不到或读不了会话文件、会话 ID 核对不上、有损坏的记录。
    /// forWrite：要据此决定能不能往对方写入。这时不用 30 秒的文件缓存，每次都重新确认正在写的是哪一段——
    /// 切段后旧段停在「空闲」，拿它当依据会往正在干活的会话里投消息。只是界面显示时可以用缓存。
    /// startedAfter：见 liveTurns
    func isBusy(sessionId: String, forWrite: Bool = false, startedAfter: Date? = nil) -> Bool? {
        readTrack(sessionId: sessionId, forceResolve: forWrite).map { !liveTurns($0, startedAfter: startedAfter).isEmpty }
    }

    /// 第 6 步打断用：正在跟踪的分段文件、正在进行的回合，以及最近结束的回合怎么结束的。每次都重新确认正在写的是哪一段。
    /// 跟踪结果不可信（会话身份没核对上、有坏行、末尾半行）返回 nil。startedAfter：见 liveTurns
    func turnSnapshot(sessionId: String, startedAfter: Date? = nil) -> (file: String, active: Set<String>, ended: [String: String])? {
        readTrack(sessionId: sessionId, forceResolve: true).map { ($0.file, liveTurns($0, startedAfter: startedAfter), $0.endedTurns) }
    }

    /// 真正还在进行的回合。startedAfter 是现在这个 Codex 进程的启动时间（tmux 会话的创建时间）：
    /// 早于它开始、又一直没结束的回合，是被杀掉的旧进程留下的（比如子群解散时关掉了 tmux，之后找回子群续接同一个会话），
    /// 永远等不到结束事件，不能再算进行中——否则界面一直显示「工作中」，投递也一直判成「对方在干活」。
    /// 不知道开始时间的回合照旧算进行中（拿不准的不当成空闲）
    private func liveTurns(_ track: Track, startedAfter: Date?) -> Set<String> {
        guard let startedAfter else { return track.activeTurns }
        return track.activeTurns.filter { turn in
            guard let start = track.turnStarts[turn] else { return true }
            return start >= startedAfter
        }
    }

    /// 单独会话的结束提醒用：最近结束的回合，按会话记录里的先后排好，带结束方式（"complete" / "aborted:<原因>"）和结束时间。
    /// 跟踪结果不可信时返回 nil（调用方这一次什么都不认，不能当成「没有结束的回合」）
    func endedTurnsInOrder(sessionId: String) -> [(turn: String, how: String, at: Date?)]? {
        readTrack(sessionId: sessionId).map { track in
            track.endedOrder.compactMap { turn in track.endedTurns[turn].map { (turn, $0, track.endedAt[turn]) } }
        }
    }

    /// 这个会话最近收到的用户消息原文（最多 20 条），以及接手它的那一轮的开始时间（nil = 还没有回合接手）
    func userMessages(sessionId: String) -> [(text: String, turnStart: Date?)] {
        readTrack(sessionId: sessionId)?.userMessages ?? []
    }

    /// 这个会话所有分段文件里的用户消息（补确认用）。核心重启后内存里没有旧段的记录，
    /// 而且最新的一段并不包含全部历史（实测旧段里的消息不在新段里），所以要把每一段都读一遍。
    /// 读的东西比较多，同一个会话 30 秒内只真正扫一次
    func userMessagesInAllSegments(sessionId: String) -> [(text: String, turnStart: Date?)] {
        guard !sessionId.isEmpty else { return [] }
        lock.lock()
        if let cached = segmentScans[sessionId], Date().timeIntervalSince(cached.at) < 30 {
            lock.unlock()
            return cached.messages
        }
        lock.unlock()
        var messages: [(text: String, turnStart: Date?)] = []
        for file in Transcript.codexSessionFiles(sessionId: sessionId) {
            // 每一段单独从头读：会话身份核对、回合归属都按这一段自己的记录算；用户消息全部保留，不只最近 20 条
            var track = Track(file: file)
            track.keepAllMessages = true
            var offset = 0
            while !track.corrupt {
                let (lines, next) = Transcript.readLines(file, from: offset)
                for line in lines {
                    guard let entry = Transcript.parseJSON(line) else { track.corrupt = true; break }
                    apply(entry, to: &track, sessionId: sessionId)
                }
                if next == offset { break }
                offset = next
            }
            // 会话身份对不上的段不算（文件名碰巧含这个 ID）。损坏的段，前面读到的部分仍然可以用来找证据
            if track.verified { messages += track.userMessages }
        }
        lock.lock()
        segmentScans[sessionId] = (Date(), messages)
        lock.unlock()
        return messages
    }

    private func readTrack(sessionId: String, forceResolve: Bool = false) -> Track? {
        guard !sessionId.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // 找文件要遍历 ~/.codex/sessions，比较慢，找到一次就记住；但桌面端的会话会分段写到新文件里，
        // 所以记住的文件超过 30 秒（或者这次要据此决定能不能写入）就重新找一次，换到新的一段就从头读（新的一段开头就是 session_meta）
        var track: Track
        if let known = tracks[sessionId], FileManager.default.fileExists(atPath: known.file),
           !forceResolve, Date().timeIntervalSince(known.resolvedAt) < 30 {
            track = known
        } else {
            // 30 秒内刚找过、没找到：只是显示用的话直接当未知；要据此决定能不能写入（forceResolve）时照样重新找
            if !forceResolve, let at = missing[sessionId], Date().timeIntervalSince(at) < 30 { return nil }
            guard let file = Transcript.find(agent: .codex, sessionId: sessionId) else {
                missing[sessionId] = Date()
                return nil
            }
            missing[sessionId] = nil
            if var known = tracks[sessionId], known.file == file {
                known.resolvedAt = Date() // 还是同一个文件，接着之前的进度读
                track = known
            } else {
                track = Track(file: file)
                // 换到了新的一段：旧段里的用户消息带过来，旧段里收到、还没确认的投递照样能找到证据
                if let old = tracks[sessionId] { track.userMessages = old.userMessages }
            }
        }
        // 读不了（权限等）：未知。readLines 读失败和读到末尾都返回空，所以先单独确认能读
        guard FileManager.default.isReadableFile(atPath: track.file) else { return nil }
        // 文件变短了（被重写过）：从头重新跟踪
        if Transcript.fileSize(track.file) < track.offset { track = Track(file: track.file) }
        // 一次最多读 5MB，循环读到文件末尾（最后不完整的半行留到下次）
        while !track.corrupt {
            let (lines, next) = Transcript.readLines(track.file, from: track.offset)
            for line in lines {
                guard let entry = Transcript.parseJSON(line) else {
                    track.corrupt = true
                    log("Codex 会话 \(sessionId) 的记录里有解析不了的行，忙闲按未知处理")
                    break
                }
                apply(entry, to: &track, sessionId: sessionId)
            }
            if next == track.offset { break }
            track.offset = next
        }
        tracks[sessionId] = track
        // 末尾还有一截没写完的行（Codex 正在写）：没追到完整的边界，这一刻的结论不可信
        let complete = Transcript.fileSize(track.file) == track.offset
        return track.verified && !track.corrupt && complete ? track : nil
    }

    private func apply(_ entry: [String: Any], to track: inout Track, sessionId: String) {
        let type = entry["type"] as? String
        let payload = entry["payload"] as? [String: Any] ?? [:]
        if type == "session_meta" {
            // 第一行：核对会话 ID，对不上说明找错了文件
            track.verified = payload["id"] as? String == sessionId
            return
        }
        let time = parseISO(entry["timestamp"] as? String ?? "")
        switch (type, payload["type"] as? String) {
        case ("event_msg", "task_started"):
            let turn = payload["turn_id"] as? String ?? ""
            track.activeTurns.insert(turn)
            if let time {
                track.turnStarts[turn] = time
                // 先写了用户消息、后开始的回合：还没有回合接手的消息，由这一轮接手
                for i in track.userMessages.indices where track.userMessages[i].turnStart == nil {
                    track.userMessages[i].turnStart = time
                }
            }
        case ("event_msg", "task_complete"), ("event_msg", "turn_aborted"):
            // 只清掉对应的那一轮。没带 turn_id 的是老格式：只能对应同样没带 turn_id 开始的那一轮，
            // 不能把其他已知还在进行的回合也清掉（那样会把正在干活的误判成空闲）
            let turn = payload["turn_id"] as? String ?? ""
            track.activeTurns.remove(turn)
            track.turnStarts[turn] = nil
            if !turn.isEmpty {
                track.endedTurns[turn] = payload["type"] as? String == "task_complete"
                    ? "complete" : "aborted:\(payload["reason"] as? String ?? "")"
                track.endedOrder.append(turn)
                track.endedAt[turn] = time
                if track.endedOrder.count > 50 {
                    let oldest = track.endedOrder.removeFirst()
                    track.endedTurns[oldest] = nil
                    track.endedAt[oldest] = nil
                }
            }
        case ("response_item", "message") where payload["role"] as? String == "user":
            // 实测（codex-cli 0.167）用户消息记成 response_item / message，文字在 input_text 里
            let parts = payload["content"] as? [[String: Any]] ?? []
            let text = parts.filter { $0["type"] as? String == "input_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            // 写入时正有回合在进行：记最近开始的那一轮。之前就在跑的旧回合，开始时间早于这次投递，确认时会被排除
            let current = track.activeTurns.compactMap { track.turnStarts[$0] }.max()
            track.userMessages = Array((track.userMessages + [(text, current)]).suffix(track.keepAllMessages ? Int.max : 20))
        default:
            break
        }
    }
}
