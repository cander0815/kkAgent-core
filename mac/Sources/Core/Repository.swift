// 数据读写：群、成员、消息、投递记录。表结构和 Node 版完全一样，数据可以直接沿用。
import Foundation

final class Repository {
    private let db: SQLite

    init(path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        db = try SQLite(path: path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS groups (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS members (
              id INTEGER PRIMARY KEY AUTOINCREMENT, group_id TEXT NOT NULL, alias TEXT NOT NULL,
              agent TEXT NOT NULL, session_id TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
              cwd TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, UNIQUE (group_id, alias));
            CREATE TABLE IF NOT EXISTS messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT, group_id TEXT NOT NULL, from_alias TEXT NOT NULL,
              to_alias TEXT NOT NULL, content TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS deliveries (
              id INTEGER PRIMARY KEY AUTOINCREMENT, message_id INTEGER NOT NULL, member_id INTEGER NOT NULL,
              status TEXT NOT NULL, error TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL);
            """)
        // 后来加的列：成员的会话在哪台机器上（空 = 物理机）。旧数据库里没有就补上；已经有了这句会报「列重复」，忽略即可
        try? db.exec("ALTER TABLE members ADD COLUMN vm TEXT NOT NULL DEFAULT ''")
        // 集群功能加的列（含义见 Models.swift 的 GroupSummary / Member）
        for column in ["parent_id", "owner", "worktree", "branch", "base_branch"] {
            try? db.exec("ALTER TABLE groups ADD COLUMN \(column) TEXT NOT NULL DEFAULT ''")
        }
        try? db.exec("ALTER TABLE members ADD COLUMN headless INTEGER NOT NULL DEFAULT 0")
        try? db.exec("ALTER TABLE members ADD COLUMN tmux TEXT NOT NULL DEFAULT ''")
        // 用户暂停了自动投递（1 = 暂停，消息只排队）
        try? db.exec("ALTER TABLE members ADD COLUMN paused INTEGER NOT NULL DEFAULT 0")
        // tmux 成员这次启动的令牌（状态 hook 用，见 AgentStatus.swift）
        try? db.exec("ALTER TABLE members ADD COLUMN launch_id TEXT NOT NULL DEFAULT ''")
        for column in ["cluster", "fail_count", "blocked"] {
            try? db.exec("ALTER TABLE groups ADD COLUMN \(column) INTEGER NOT NULL DEFAULT 0")
        }
        try? db.exec("ALTER TABLE messages ADD COLUMN verdict TEXT NOT NULL DEFAULT ''")
        try? db.exec("ALTER TABLE messages ADD COLUMN kind TEXT NOT NULL DEFAULT ''")
        // 紧急消息（第 6 步）：合并投递时排在普通消息前面
        try? db.exec("ALTER TABLE messages ADD COLUMN urgent INTEGER NOT NULL DEFAULT 0")
        // 投递的用途（见 DeliveryPurpose）；attempt 是旧版看门狗的续接次数，已不再使用，留着兼容老库
        try? db.exec("ALTER TABLE deliveries ADD COLUMN purpose TEXT NOT NULL DEFAULT 'task'")
        try? db.exec("ALTER TABLE deliveries ADD COLUMN attempt INTEGER NOT NULL DEFAULT 0")
        // 要送进会话的完整文字：排队的消息合并投递、核心重启后补投时都从这里取
        try? db.exec("ALTER TABLE deliveries ADD COLUMN text TEXT NOT NULL DEFAULT ''")
        // 这条投递属于哪一次投递尝试（attempts 表）；0 = 老记录或不需要确认的投递方式
        try? db.exec("ALTER TABLE deliveries ADD COLUMN attempt_id INTEGER NOT NULL DEFAULT 0")
        // 收件人什么时候把这条消息标成「已处理」（回复时带 --re，或执行 done）；空 = 还没处理，kkAgent inbox 会列出来
        // 加这一列之前的老消息一律当作已处理：它们送进会话时没带编号，对不上号；列出来还可能让 agent 把旧指示再做一遍。
        // 只在加列成功的那一次执行（列已存在时 ALTER 报错，不会走进来）
        if (try? db.exec("ALTER TABLE deliveries ADD COLUMN handled_at TEXT NOT NULL DEFAULT ''")) != nil {
            try db.exec("UPDATE deliveries SET handled_at = updated_at")
        }
        // 投递尝试：一次把（可能合并了好几条的）文字送进对方会话的过程，记录走到了哪一步，见 TmuxDelivery.swift
        try db.exec("""
            CREATE TABLE IF NOT EXISTS attempts (
              id INTEGER PRIMARY KEY AUTOINCREMENT, member_id INTEGER NOT NULL,
              agent TEXT NOT NULL, vm TEXT NOT NULL, session_id TEXT NOT NULL,
              stage INTEGER NOT NULL, released INTEGER NOT NULL DEFAULT 0, text TEXT NOT NULL DEFAULT '',
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
            """)
        // 确认收到之后，有没有看到对方开始处理这一条（没看到之前这个会话仍被占着，不派新的）
        // 加这一列之前已经确认的旧记录当作已开工（否则它们会永久挡住对应的会话）
        if (try? db.exec("ALTER TABLE attempts ADD COLUMN observed INTEGER NOT NULL DEFAULT 0")) != nil {
            try db.exec("UPDATE attempts SET observed = 1 WHERE stage = \(AttemptStage.confirmed.rawValue)")
        }
        // 第 6 步第二期：为紧急消息按 Esc 打断对方的记录，见 Interrupt.swift。
        // 同一个实际会话、同一次启动、同一个目标回合只能登记一次（唯一键），不管是谁发起的
        try db.exec("""
            CREATE TABLE IF NOT EXISTS interrupts (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              agent TEXT NOT NULL, vm TEXT NOT NULL, session_id TEXT NOT NULL,
              launch TEXT NOT NULL, target_turn TEXT NOT NULL,
              member_id INTEGER NOT NULL, sender_key TEXT NOT NULL, exempt INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL, key_may_sent_at TEXT NOT NULL DEFAULT '', alerted INTEGER NOT NULL DEFAULT 0,
              reason TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
              UNIQUE (agent, vm, session_id, launch, target_turn));
            """)
        // 按键前那一刻会话记录的文件、文件身份（inode）和大小：结算时只认这个位置之后写下的结束证据，
        // 文件换了、被截断就不认（见 Interrupt.swift）。Codex 的 log_offset 不用（按 turn_id 认，见那边的说明）
        for column in ["log_file", "log_inode"] {
            try? db.exec("ALTER TABLE interrupts ADD COLUMN \(column) TEXT NOT NULL DEFAULT ''")
        }
        try? db.exec("ALTER TABLE interrupts ADD COLUMN log_offset INTEGER NOT NULL DEFAULT -1")
        // 左边栏「会话」里的单独托管会话（见 Solo.swift）。state：starting / running / failed / ended（结束后不再显示）
        try db.exec("""
            CREATE TABLE IF NOT EXISTS solo_sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT NOT NULL, vm TEXT NOT NULL DEFAULT '',
              session_id TEXT NOT NULL DEFAULT '', cwd TEXT NOT NULL, tmux TEXT NOT NULL DEFAULT '',
              launch_id TEXT NOT NULL DEFAULT '', state TEXT NOT NULL, error TEXT NOT NULL DEFAULT '',
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
            """)
        // 成员绑着哪个单独会话（拉进群的）；0 = 没绑。进程归属以单独会话为准，见 Member.soloId
        try? db.exec("ALTER TABLE members ADD COLUMN solo_id INTEGER NOT NULL DEFAULT 0")
        // 单独会话最近一轮怎么结束的（completed / failed / interrupted）、什么时候结束的（App 拿它判断有没有没看过的结果）
        try? db.exec("ALTER TABLE solo_sessions ADD COLUMN last_outcome TEXT NOT NULL DEFAULT ''")
        try? db.exec("ALTER TABLE solo_sessions ADD COLUMN last_ended_at TEXT NOT NULL DEFAULT ''")
        // 会话在哪些群里用过（群名照抄当时的）。会话浏览按群名搜索用；解散群时不删，子群解散后还能按群名找到当时的会话
        try db.exec("""
            CREATE TABLE IF NOT EXISTS session_groups (
              agent TEXT NOT NULL, session_id TEXT NOT NULL, group_id TEXT NOT NULL, group_name TEXT NOT NULL,
              created_at TEXT NOT NULL, PRIMARY KEY (agent, session_id, group_id));
            """)
    }

    // ---------- 群 ----------

    /// 建群。cluster 是集群主群；parentId / owner / baseBranch 只有集群的子群才填
    func createGroup(name: String, cluster: Bool = false, parentId: String = "", owner: String = "", baseBranch: String = "") throws -> GroupSummary {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        let id = "g" + String((0..<4).map { _ in chars.randomElement()! })
        try db.run("INSERT INTO groups (id, name, created_at, cluster, parent_id, owner, base_branch) VALUES (?, ?, ?, ?, ?, ?, ?)",
                   [.text(id), .text(name), .text(nowISO()), .int(cluster ? 1 : 0), .text(parentId), .text(owner), .text(baseBranch)])
        return try getGroup(id)!
    }

    /// 子群里 tester 又打回了一次：次数 +1，超过上限就置为暂停。一条语句完成，并发请求也不会少算。
    /// 返回加完之后的次数和是否暂停
    func recordFail(groupId: String, limit: Int) throws -> (count: Int, blocked: Bool) {
        let rows = try db.query("""
            UPDATE groups SET fail_count = fail_count + 1,
              blocked = CASE WHEN fail_count + 1 > ? THEN 1 ELSE blocked END
            WHERE id = ? RETURNING fail_count, blocked
            """, [.int(Int64(limit)), .text(groupId)])
        guard let row = rows.first else { return (0, false) }
        return (Int(row.int("fail_count")), row.int("blocked") == 1)
    }

    /// 群主介入：打回次数清零、解除暂停
    func resetFails(groupId: String) throws {
        try db.run("UPDATE groups SET fail_count = 0, blocked = 0 WHERE id = ?", [.text(groupId)])
    }

    /// 记下 / 清掉集群的群主
    func setGroupOwner(_ id: String, owner: String) throws {
        try db.run("UPDATE groups SET owner = ? WHERE id = ?", [.text(owner), .text(id)])
    }

    /// 记下子群的 worktree 路径和分支（worktree 建好之后）
    func setGroupWorktree(_ id: String, worktree: String, branch: String) throws {
        try db.run("UPDATE groups SET worktree = ?, branch = ? WHERE id = ?", [.text(worktree), .text(branch), .text(id)])
    }

    func listSubgroups(parentId: String) throws -> [GroupSummary] {
        try db.query(groupSummarySQL + " WHERE g.parent_id = ?", [.text(parentId)]).map(groupSummary)
    }

    /// 群列表带成员数、消息数、最后活跃时间，按最后活跃倒序
    func listGroups() throws -> [GroupSummary] {
        try db.query(groupSummarySQL + " ORDER BY last_active DESC").map(groupSummary)
    }

    func getGroup(_ id: String) throws -> GroupSummary? {
        try db.query(groupSummarySQL + " WHERE g.id = ?", [.text(id)]).first.map(groupSummary)
    }

    /// 解散群聊：群、成员、消息、投递记录全部删掉（各个会话本身不受影响）
    func deleteGroup(_ id: String) throws {
        try db.exec("BEGIN")
        do {
            try db.run("DELETE FROM deliveries WHERE message_id IN (SELECT id FROM messages WHERE group_id = ?)", [.text(id)])
            try db.run("DELETE FROM messages WHERE group_id = ?", [.text(id)])
            // 这些成员没确认的投递尝试一并解除：群没了，没人能处理它；留着会一直挡住别的群里指向同一会话的成员。
            // 解除不等于送达，它们仍是「已写入未确认」
            try db.run("UPDATE attempts SET released = 1, updated_at = ? WHERE member_id IN (SELECT id FROM members WHERE group_id = ?)",
                       [.text(nowISO()), .text(id)])
            try db.run("DELETE FROM members WHERE group_id = ?", [.text(id)])
            try db.run("DELETE FROM groups WHERE id = ?", [.text(id)])
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    private let groupSummarySQL = """
        SELECT g.*,
          (SELECT COUNT(*) FROM members m WHERE m.group_id = g.id) AS member_count,
          (SELECT COUNT(*) FROM messages msg WHERE msg.group_id = g.id) AS message_count,
          COALESCE((SELECT MAX(created_at) FROM messages msg WHERE msg.group_id = g.id), g.created_at) AS last_active
        FROM groups g
        """

    private func groupSummary(_ r: Row) -> GroupSummary {
        GroupSummary(id: r.text("id"), name: r.text("name"), createdAt: r.text("created_at"),
                     memberCount: Int(r.int("member_count")), messageCount: Int(r.int("message_count")),
                     lastActive: r.text("last_active"), cluster: r.int("cluster") == 1, parentId: r.text("parent_id"),
                     owner: r.text("owner"), worktree: r.text("worktree"), branch: r.text("branch"), baseBranch: r.text("base_branch"),
                     failCount: Int(r.int("fail_count")), blocked: r.int("blocked") == 1)
    }

    // ---------- 成员 ----------

    func addMember(groupId: String, alias: String, agent: AgentKind, sessionId: String, description: String, cwd: String, vm: String,
                   headless: Bool = false, tmux: String = "", soloId: Int64 = 0) throws -> Member {
        let id = try db.run(
            "INSERT INTO members (group_id, alias, agent, session_id, description, cwd, vm, headless, tmux, solo_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [.text(groupId), .text(alias), .text(agent.rawValue), .text(sessionId), .text(description), .text(cwd), .text(vm),
             .int(headless ? 1 : 0), .text(tmux), .int(soloId), .text(nowISO())])
        recordSessionGroup(memberId: id)
        return try getMember(id)!
    }

    /// 更换成员的会话：会话 ID、工作目录、所在机器一起改
    func changeMemberSession(_ id: Int64, sessionId: String, cwd: String, vm: String) throws {
        try db.run("UPDATE members SET session_id = ?, cwd = ?, vm = ? WHERE id = ?", [.text(sessionId), .text(cwd), .text(vm), .int(id)])
        recordSessionGroup(memberId: id)
    }

    /// 记下这个成员现在的会话属于它所在的群（session_groups 表，会话浏览按群名搜索用）。
    /// 每次成员的会话 ID 写进来或者换了都调用；同一个会话在同一个群里只记一次。
    /// 子群里复制的群主行不记：它是根群群主的会话，所有子群共用，记上的话搜任何一个子群名都会搜到它。
    /// 只是辅助搜索，记不进去也不影响建成员，所以不往外抛错
    private func recordSessionGroup(memberId: Int64) {
        guard let member = try? getMember(memberId), !member.sessionId.isEmpty,
              let group = try? getGroup(member.groupId) else { return }
        if !group.parentId.isEmpty && member.alias == group.owner { return }
        _ = try? db.run("INSERT OR IGNORE INTO session_groups (agent, session_id, group_id, group_name, created_at) VALUES (?, ?, ?, ?, ?)",
                        [.text(member.agent.rawValue), .text(member.sessionId), .text(group.id), .text(group.name), .text(nowISO())])
    }

    /// 某一类会话各自用过的群名：会话 ID → 群名（按先后）
    func sessionGroupNames(agent: AgentKind) throws -> [String: [String]] {
        var names: [String: [String]] = [:]
        for row in try db.query("SELECT session_id, group_name FROM session_groups WHERE agent = ? ORDER BY created_at",
                                [.text(agent.rawValue)]) {
            names[row.text("session_id"), default: []].append(row.text("group_name"))
        }
        return names
    }

    /// tmux 里的 Claude 自己换了会话（/clear、/resume，见 SessionFollow.swift）：一个事务里改掉旧会话 ID 的所有登记。
    /// - soloId 不为 0：这个单独会话那一行；
    /// - 同一台机器上、会话 ID 是旧值的所有成员行：成员自己、绑着这个单独会话的成员、被复制进各子群的群主行（照抄的是同一个会话 ID）。
    /// 返回改过之后的成员行
    func followSession(soloId: Int64, agent: AgentKind, vm: String, from oldId: String, to newId: String, cwd: String) throws -> [Member] {
        let ids = try db.query("SELECT id FROM members WHERE agent = ? AND vm = ? AND session_id = ?",
                               [.text(agent.rawValue), .text(vm), .text(oldId)]).map { $0.int("id") }
        try db.exec("BEGIN")
        do {
            if soloId != 0 {
                try db.run("UPDATE solo_sessions SET session_id = ?, cwd = ?, updated_at = ? WHERE id = ?",
                           [.text(newId), .text(cwd), .text(nowISO()), .int(soloId)])
            }
            for id in ids {
                try db.run("UPDATE members SET session_id = ?, cwd = ? WHERE id = ?", [.text(newId), .text(cwd), .int(id)])
            }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        for id in ids { recordSessionGroup(memberId: id) }
        return try ids.compactMap { try getMember($0) }
    }

    /// 所有会话 ID 是这个的成员行（包括绑着单独会话的）
    func membersWithSession(agent: AgentKind, sessionId: String) throws -> [Member] {
        try db.query("SELECT * FROM members WHERE agent = ? AND session_id = ?", [.text(agent.rawValue), .text(sessionId)]).map(member)
    }

    /// 后台 Codex 会话第一轮跑起来后，回填它的会话 ID
    func setMemberSession(_ id: Int64, sessionId: String) throws {
        try db.run("UPDATE members SET session_id = ? WHERE id = ?", [.text(sessionId), .int(id)])
        recordSessionGroup(memberId: id)
    }

    /// 记下 tmux 成员这次启动的令牌（见 AgentStatus.swift）。核心重启后靠它继续认这个会话发来的 hook 事件
    func setMemberLaunch(_ id: Int64, launchId: String) throws {
        try db.run("UPDATE members SET launch_id = ? WHERE id = ?", [.text(launchId), .int(id)])
    }

    /// 所有登记过启动令牌的 tmux 成员：(成员 id, 令牌)
    func memberLaunches() throws -> [(memberId: Int64, launchId: String)] {
        try db.query("SELECT id, launch_id FROM members WHERE tmux != '' AND launch_id != ''")
            .map { ($0.int("id"), $0.text("launch_id")) }
    }

    /// 这个会话是不是已经属于某个后台成员（后台会话只能在它自己的子群里）
    func isHeadlessSession(_ sessionId: String) throws -> Bool {
        !(try db.query("SELECT 1 FROM members WHERE headless = 1 AND session_id = ?", [.text(sessionId)])).isEmpty
    }

    func removeMember(_ id: Int64) throws {
        // 没确认的投递尝试一并解除（理由同 deleteGroup），它们仍是「已写入未确认」，不算送达
        try db.run("UPDATE attempts SET released = 1, updated_at = ? WHERE member_id = ?", [.text(nowISO()), .int(id)])
        try db.run("DELETE FROM members WHERE id = ?", [.int(id)])
    }

    func getMember(_ id: Int64) throws -> Member? {
        try db.query("SELECT * FROM members WHERE id = ?", [.int(id)]).first.map(member)
    }

    func listMembers(groupId: String) throws -> [Member] {
        try db.query("SELECT * FROM members WHERE group_id = ? ORDER BY id", [.text(groupId)]).map(member)
    }

    private func member(_ r: Row) -> Member {
        Member(id: r.int("id"), groupId: r.text("group_id"), alias: r.text("alias"),
               agent: AgentKind(rawValue: r.text("agent")) ?? .claude, sessionId: r.text("session_id"),
               description: r.text("description"), cwd: r.text("cwd"), vm: r.text("vm"), headless: r.int("headless") == 1,
               tmux: r.text("tmux"), paused: r.int("paused") == 1, createdAt: r.text("created_at"), soloId: r.int("solo_id"))
    }

    /// 暂停 / 恢复自动投递：暂停期间消息只排队，不送进去
    func setMemberPaused(_ id: Int64, paused: Bool) throws {
        try db.run("UPDATE members SET paused = ? WHERE id = ?", [.int(paused ? 1 : 0), .int(id)])
    }

    // ---------- 消息 ----------

    /// kind 见 Message.kind：系统提醒 / 告警传 "alert"
    func addMessage(groupId: String, from: String, to: String, content: String, verdict: String = "", kind: String = "",
                    urgent: Bool = false) throws -> Message {
        let id = try db.run("""
            INSERT INTO messages (group_id, from_alias, to_alias, content, verdict, kind, urgent, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(groupId), .text(from), .text(to), .text(content), .text(verdict), .text(kind), .int(urgent ? 1 : 0), .text(nowISO())])
        return try db.query("SELECT * FROM messages WHERE id = ?", [.int(id)]).map(message)[0]
    }

    func listMessages(groupId: String) throws -> [Message] {
        try db.query("SELECT * FROM messages WHERE group_id = ? ORDER BY id", [.text(groupId)]).map(message)
    }

    private func message(_ r: Row) -> Message {
        Message(id: r.int("id"), groupId: r.text("group_id"), from: r.text("from_alias"), to: r.text("to_alias"),
                content: r.text("content"), verdict: r.text("verdict"), kind: r.text("kind"), createdAt: r.text("created_at"),
                urgent: r.int("urgent") != 0)
    }

    // ---------- 投递记录 ----------

    /// 新建一条排队中的投递。text 是要送进会话的完整文字
    func addDelivery(messageId: Int64, memberId: Int64, text: String, purpose: DeliveryPurpose = .task) throws -> Int64 {
        try db.run("INSERT INTO deliveries (message_id, member_id, status, purpose, text, updated_at) VALUES (?, ?, 'pending', ?, ?, ?)",
                   [.int(messageId), .int(memberId), .text(purpose.rawValue), .text(text), .text(nowISO())])
    }

    /// 投递队列要用到的一条投递
    struct QueuedDelivery {
        let id: Int64
        let messageId: Int64
        let memberId: Int64
        let status: DeliveryStatus
        let purpose: DeliveryPurpose
        let text: String // 老记录（加这一列之前建的）为空，要从消息内容重建
        let urgent: Bool // 对应的消息是紧急消息
        let sentAt: String // 消息的发送时间（ISO 格式），合并投递时标在每一条前面
    }

    /// 投递记录连同消息上的紧急标记和发送时间一起取
    private static let queuedSelect = """
        SELECT d.*, COALESCE(msg.urgent, 0) AS urgent, COALESCE(msg.created_at, '') AS sent_at
        FROM deliveries d LEFT JOIN messages msg ON msg.id = d.message_id
        """

    private func queuedDelivery(_ r: Row) -> QueuedDelivery {
        QueuedDelivery(id: r.int("id"), messageId: r.int("message_id"), memberId: r.int("member_id"), status: DeliveryStatus(rawValue: r.text("status")) ?? .failed,
                       purpose: DeliveryPurpose(rawValue: r.text("purpose")) ?? .task, text: r.text("text"),
                       urgent: r.int("urgent") != 0, sentAt: r.text("sent_at"))
    }

    /// 取一条投递；记录不存在（群解散 / 成员移出后被删）返回 nil
    func queuedDelivery(_ id: Int64) -> QueuedDelivery? {
        ((try? db.query(Self.queuedSelect + " WHERE d.id = ?", [.int(id)])) ?? []).first.map(queuedDelivery)
    }

    /// 这个成员所有还在排队的投递，按先后顺序（合并投递用）
    func pendingDeliveries(memberId: Int64) -> [QueuedDelivery] {
        ((try? db.query(Self.queuedSelect + " WHERE d.member_id = ? AND d.status = 'pending' ORDER BY d.id", [.int(memberId)])) ?? [])
            .map(queuedDelivery)
    }

    /// 核心启动时：每个还有排队投递的成员，取最早的一条（重新排进队列，开始时会把其余的一起合并）
    /// 这个成员的第一条投递（入群说明 / bootstrap）现在是什么状态、出错原因。托管会话启动时，界面据此显示「正在启动 / 启动失败」
    func firstDelivery(memberId: Int64) -> (status: DeliveryStatus, error: String)? {
        ((try? db.query("SELECT status, error FROM deliveries WHERE member_id = ? ORDER BY id LIMIT 1", [.int(memberId)])) ?? []).first
            .flatMap { r in DeliveryStatus(rawValue: r.text("status")).map { ($0, r.text("error")) } }
    }

    func firstPendingDeliveryPerMember() -> [(deliveryId: Int64, memberId: Int64)] {
        ((try? db.query("""
            SELECT MIN(d.id) AS id, d.member_id FROM deliveries d JOIN members m ON m.id = d.member_id
            WHERE d.status = 'pending' GROUP BY d.member_id
            """)) ?? []).map { ($0.int("id"), $0.int("member_id")) }
    }

    func getMessage(_ id: Int64) -> Message? {
        ((try? db.query("SELECT * FROM messages WHERE id = ?", [.int(id)])) ?? []).first.map(message)
    }

    // ---------- 收件箱（kkAgent inbox / done / send --re） ----------

    /// 收件箱里的一条：发给某个成员的一条消息，连同送达状态和有没有处理
    struct InboxItem {
        let message: Message
        let groupName: String
        let status: DeliveryStatus
        let handled: Bool
    }

    /// 列出发给这些成员（同一个人在主群和各子群里各有一条成员记录）的消息。
    /// 系统通知（from = system）不算；direct = 只要点名发给自己的，不要 all 群发；
    /// includeHandled = 已处理的也列（只取最近 limit 条）；否则只列还没处理的，全部列出、不截断（最早的那几条最可能是漏掉的）
    func inbox(memberIds: [Int64], direct: Bool, includeHandled: Bool, limit: Int = 30) throws -> [InboxItem] {
        guard !memberIds.isEmpty else { return [] }
        let placeholders = memberIds.map { _ in "?" }.joined(separator: ",")
        var sql = """
            SELECT msg.*, g.name AS group_name, d.status AS delivery_status, d.handled_at FROM deliveries d
            JOIN messages msg ON msg.id = d.message_id
            JOIN groups g ON g.id = msg.group_id
            WHERE d.member_id IN (\(placeholders)) AND msg.from_alias != 'system'
            """
        if direct { sql += " AND msg.to_alias != 'all'" }
        if includeHandled {
            // 取最近的 limit 条，再按时间正序显示
            sql = "SELECT * FROM (\(sql) ORDER BY msg.id DESC LIMIT \(limit)) ORDER BY id"
        } else {
            sql += " AND d.handled_at = '' ORDER BY msg.id"
        }
        return try db.query(sql, memberIds.map { .int($0) }).map { r in
            InboxItem(message: message(r), groupName: r.text("group_name"),
                      status: DeliveryStatus(rawValue: r.text("delivery_status")) ?? .failed, handled: !r.text("handled_at").isEmpty)
        }
    }

    /// 把发给这些成员的几条消息标成已处理。返回实际找到的消息编号（不是发给他们的编号不会出现在里面）
    func markHandled(memberIds: [Int64], messageIds: [Int64]) throws -> [Int64] {
        guard !memberIds.isEmpty, !messageIds.isEmpty else { return [] }
        let members = memberIds.map { _ in "?" }.joined(separator: ",")
        let messages = messageIds.map { _ in "?" }.joined(separator: ",")
        let params: [SQLValue] = memberIds.map { .int($0) } + messageIds.map { .int($0) }
        let found = try db.query("SELECT DISTINCT message_id FROM deliveries WHERE member_id IN (\(members)) AND message_id IN (\(messages))",
                                 params).map { $0.int("message_id") }
        // 已经标过的保留第一次的时间
        try db.run("UPDATE deliveries SET handled_at = ? WHERE handled_at = '' AND member_id IN (\(members)) AND message_id IN (\(messages))",
                   [.text(nowISO())] + params)
        return found
    }


    /// 取消还在排队、要发给这个成员的消息（正在投递中的已经发出去了，拦不住）
    func cancelPendingDeliveries(memberId: Int64) throws {
        try db.run("DELETE FROM deliveries WHERE member_id = ? AND status = 'pending'", [.int(memberId)])
    }

    /// 取消一条还在排队的投递（用户在排队列表里点「取消」）。只删「排队中」的：已经开始送的拦不住
    /// 返回 false = 没删到（这条刚好被投递线程认领、已经在送了）
    func cancelPendingDelivery(_ id: Int64) throws -> Bool {
        try db.update("DELETE FROM deliveries WHERE id = ? AND status = 'pending'", [.int(id)]) > 0
    }

    /// 投递线程认领一条排队中的投递（改成「投递中」）。条件更新：用户刚好取消了（行已删）或别处已认领时返回 false，
    /// 这样「取消」和「送出」只有一方能赢，不会出现显示取消成功、消息却照样送出去
    func claimDelivery(_ id: Int64) -> Bool {
        ((try? db.update("UPDATE deliveries SET status = 'running', error = '', updated_at = ? WHERE id = ? AND status = 'pending'",
                         [.text(nowISO()), .int(id)])) ?? 0) > 0
    }

    func setDeliveryStatus(_ id: Int64, _ status: DeliveryStatus, error: String = "") {
        _ = try? db.run("UPDATE deliveries SET status = ?, error = ?, updated_at = ? WHERE id = ?",
                    [.text(status.rawValue), .text(error), .text(nowISO()), .int(id)])
    }

    func listDeliveries(groupId: String) throws -> [Delivery] {
        try db.query("""
            SELECT d.*, m.alias AS member_alias, COALESCE(a.released, 0) AS attempt_released FROM deliveries d
            JOIN messages msg ON msg.id = d.message_id
            JOIN members m ON m.id = d.member_id
            LEFT JOIN attempts a ON a.id = d.attempt_id
            WHERE msg.group_id = ? ORDER BY d.id
            """, [.text(groupId)]).map { r in
            Delivery(id: r.int("id"), messageId: r.int("message_id"), memberId: r.int("member_id"),
                     memberAlias: r.text("member_alias"), status: DeliveryStatus(rawValue: r.text("status")) ?? .failed,
                     error: r.text("error"), updatedAt: r.text("updated_at"),
                     attemptId: r.int("attempt_id"), attemptReleased: r.int("attempt_released") != 0,
                     isBootstrap: r.text("purpose") == DeliveryPurpose.bootstrap.rawValue)
        }
    }

    /// 核心重启时：上次正在投递（已经送进会话、跑到一半）的记录标成失败，不自动重发，因为可能已经改了一半文件。
    /// 还在排队、没开始的不动，启动后重新排队补投（见 main.swift）。
    /// 返回被打断的后台成员 id（去重），要通知它们的群主
    /// 核心启动时调用，处理上次核心退出时还在「投递中」的记录。
    /// 返回被打断的后台成员（interrupted）和被记成「已写入未确认」的成员（unconfirmed），启动后分别通知
    func failUnfinishedDeliveries() throws -> (interrupted: [Int64], unconfirmed: [Int64]) {
        // 有投递尝试的（tmux / codex queue / 中转会话这几种「交出去就算完成」的投递）按走到的那一步分开处理：
        // - 还没开始写入：对方没收到任何东西，改回「排队中」，启动后照常补投；
        // - 已经开始写入：可能已经送进去了，记成「已写入未确认」，不重投（等迟到的确认或人工处理）
        // - 已经确认送达的（确认后、改投递状态前核心崩了）：先恢复成「已送达」，不能被下面误标成未确认
        try repairConfirmedDeliveries()
        let unconfirmed = try db.query("""
            SELECT DISTINCT member_id FROM deliveries WHERE status = 'running' AND attempt_id IN
              (SELECT id FROM attempts WHERE stage IN (\(AttemptStage.writeStarted.rawValue), \(AttemptStage.inputAccepted.rawValue)))
            """).map { $0.int("member_id") }
        try db.run("""
            UPDATE deliveries SET status = 'pending', updated_at = ? WHERE status = 'running' AND attempt_id IN
              (SELECT id FROM attempts WHERE stage <= \(AttemptStage.preparing.rawValue))
            """, [.text(nowISO())])
        try db.run("""
            UPDATE deliveries SET status = 'unconfirmed', error = '核心重启时已经写进对方会话，没能确认对方收到', updated_at = ?
            WHERE status = 'running' AND attempt_id IN
              (SELECT id FROM attempts WHERE stage IN (\(AttemptStage.writeStarted.rawValue), \(AttemptStage.inputAccepted.rawValue)))
            """, [.text(nowISO())])
        // 其余的是后台续接（claude -p / codex exec）：进程被核心停掉了，可能改了一半文件，记失败并通知群主
        let headless = try db.query("""
            SELECT DISTINCT d.member_id FROM deliveries d JOIN members m ON m.id = d.member_id
            WHERE d.status = 'running' AND m.headless = 1
            """).map { $0.int("member_id") }
        try db.run("UPDATE deliveries SET status = 'failed', error = '核心重启，投递中断', updated_at = ? WHERE status = 'running'",
                   [.text(nowISO())])
        return (headless, unconfirmed)
    }

    // ---------- 投递尝试（见 TmuxDelivery.swift） ----------

    struct Attempt {
        let id: Int64
        let memberId: Int64
        let agent: AgentKind // 投递当时的会话（成员之后可能换会话，补确认要用当时的）
        let vm: String
        let sessionId: String
        let stage: AttemptStage
        let released: Bool // 人工点了「解除并继续」：只解除调度上的阻挡，投递本身仍是「已写入未确认」
        let observed: Bool // 确认收到后，看到对方开始处理这一条了
        let text: String   // 送进去的完整文字（带编号行），确认时拿它和对方收到的比对
        let createdAt: Date // 这次尝试开始的时间：比它早开始的回合不可能是在处理这一条
    }

    private func attempt(_ r: Row) -> Attempt {
        Attempt(id: r.int("id"), memberId: r.int("member_id"), agent: AgentKind(rawValue: r.text("agent")) ?? .claude,
                vm: r.text("vm"), sessionId: r.text("session_id"),
                stage: AttemptStage(rawValue: Int(r.int("stage"))) ?? .cancelled,
                released: r.int("released") != 0, observed: r.int("observed") != 0, text: r.text("text"),
                // 解析不了就当「很远的将来」：任何回合都不会被误算成在处理这一条（宁可等人工解除）
                createdAt: parseISO(r.text("created_at")) ?? .distantFuture)
    }

    /// 新建一次投递尝试（准备阶段），并把这批投递记录关联上它
    func createAttempt(member: Member, deliveryIds: [Int64]) throws -> Int64 {
        let now = nowISO()
        let id = try db.run("""
            INSERT INTO attempts (member_id, agent, vm, session_id, stage, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [.int(member.id), .text(member.agent.rawValue), .text(member.vm), .text(member.sessionId),
                  .int(Int64(AttemptStage.preparing.rawValue)), .text(now), .text(now)])
        for deliveryId in deliveryIds {
            try db.run("UPDATE deliveries SET attempt_id = ? WHERE id = ?", [.int(id), .int(deliveryId)])
        }
        return id
    }

    func setAttemptText(_ id: Int64, text: String) throws {
        try db.run("UPDATE attempts SET text = ? WHERE id = ?", [.text(text), .int(id)])
    }

    /// 推进到下一步。只进不退：当前阶段比新阶段靠前才更新（比如 hook 先到、已经确认了，之后的「已回车」不能把它降回去）。
    /// 返回 true = 这次推进了，false = 已经在这一步或更靠后。数据库出错、或者这次尝试已经作废，抛错——
    /// 调用方据此决定能不能继续：「开始写入」没记进库就绝不能往对方终端里写，否则崩溃后会被当成没写过而重投
    @discardableResult
    func advanceAttempt(_ id: Int64, to stage: AttemptStage) throws -> Bool {
        let changed = try db.update("UPDATE attempts SET stage = ?, updated_at = ? WHERE id = ? AND stage >= 0 AND stage < ?",
                                    [.int(Int64(stage.rawValue)), .text(nowISO()), .int(id), .int(Int64(stage.rawValue))])
        if changed > 0 { return true }
        guard let row = try db.query("SELECT stage FROM attempts WHERE id = ?", [.int(id)]).first else {
            throw CoreError(message: "投递尝试 \(id) 不存在")
        }
        guard row.int("stage") >= Int64(stage.rawValue) else { throw CoreError(message: "投递尝试 \(id) 已作废，不能再推进") }
        return false
    }

    /// 确认送达：先把阶段推进到「已确认」，再把投递改成「已送达」。
    /// 顺序很重要：标「未确认」的语句带着「阶段还没到已确认」的条件（见 markAttemptUnconfirmed），
    /// 阶段先变，之后就不会再被改回未确认；万一两步之间核心崩了，启动时 repairConfirmedDeliveries 会补上第二步
    /// observed：确认的证据本身就说明对方已经开始处理这一条（比如 Claude 的 UserPromptSubmit）。
    /// 只是「收到了」的（中转会话的回执）传 false，之后看到开工再调 markAttemptObserved
    func confirmAttempt(_ id: Int64, observed: Bool) throws {
        try advanceAttempt(id, to: .confirmed)
        try db.run("UPDATE deliveries SET status = 'delivered', error = '', updated_at = ? WHERE attempt_id = ? AND status != 'delivered'",
                   [.text(nowISO()), .int(id)])
        if observed { try markAttemptObserved(id) }
    }

    func markAttemptObserved(_ id: Int64) throws {
        try db.run("UPDATE attempts SET observed = 1, updated_at = ? WHERE id = ?", [.text(nowISO()), .int(id)])
    }

    /// 已经确认收到、还没看到对方开工的投递尝试（定时检查用来补「开工」的证据）
    func unobservedAttempts() -> [Attempt] {
        ((try? db.query("SELECT * FROM attempts WHERE released = 0 AND observed = 0 AND stage = ? ORDER BY id",
                        [.int(Int64(AttemptStage.confirmed.rawValue))])) ?? []).map(attempt)
    }

    /// 写进去了但没能确认：把投递标成「已写入未确认」。已经确认送达的不改（补确认可能抢先一步）。
    /// 返回真的改成了未确认没有：补确认抢先了就返回 false，调用方不用再报「未确认」
    @discardableResult
    func markAttemptUnconfirmed(_ id: Int64, reason: String) throws -> Bool {
        try db.update("""
            UPDATE deliveries SET status = 'unconfirmed', error = ?, updated_at = ?
            WHERE attempt_id = ? AND (SELECT stage FROM attempts WHERE id = ?) < \(AttemptStage.confirmed.rawValue)
            """, [.text(reason), .text(nowISO()), .int(id), .int(id)]) > 0
    }

    /// 阶段已经是「已确认」、投递却还不是「已送达」的（确认后核心崩了）：改成已送达
    func repairConfirmedDeliveries() throws {
        try db.run("""
            UPDATE deliveries SET status = 'delivered', error = '', updated_at = ?
            WHERE status != 'delivered' AND attempt_id IN (SELECT id FROM attempts WHERE stage = \(AttemptStage.confirmed.rawValue))
            """, [.text(nowISO())])
    }

    /// 还没开始写入就放弃了（对方忙了、输入框里有人在打字）：标成作废，这批投递改回排队。
    /// evenIfWriteStarted：已经记了「开始写入」、但确定一个字节都还没往终端写（粘贴前的最后检查没通过）时，也可以作废
    func cancelAttempt(_ id: Int64, evenIfWriteStarted: Bool = false) {
        let maxStage = evenIfWriteStarted ? AttemptStage.writeStarted : AttemptStage.preparing
        _ = try? db.run("UPDATE attempts SET stage = ?, updated_at = ? WHERE id = ? AND stage >= ? AND stage <= ?",
                        [.int(Int64(AttemptStage.cancelled.rawValue)), .text(nowISO()), .int(id),
                         .int(Int64(AttemptStage.preparing.rawValue)), .int(Int64(maxStage.rawValue))])
        // 只有确实作废了才把投递改回排队：阶段已经往后走了（可能已经写进去）的不能重投
        _ = try? db.run("""
            UPDATE deliveries SET status = 'pending', attempt_id = 0, updated_at = ?
            WHERE attempt_id = ? AND (SELECT stage FROM attempts WHERE id = ?) = \(AttemptStage.cancelled.rawValue)
            """, [.text(nowISO()), .int(id), .int(id)])
    }

    func getAttempt(_ id: Int64) -> Attempt? {
        ((try? db.query("SELECT * FROM attempts WHERE id = ?", [.int(id)])) ?? []).first.map(attempt)
    }

    /// 这个会话上挡着后面投递的尝试（没被人工解除的）：已写入还没确认的；或者确认收到了、还没看到对方开工的
    /// （中转会话的回执只说明送到了，对方这时可能还显示空闲，不挡住的话会接着再投一条）。
    /// 读库出错时抛错：调用方要当成「有阻挡」处理，不能当成没有
    func blockingAttempt(agent: AgentKind, vm: String, sessionId: String) throws -> Attempt? {
        try db.query("""
            SELECT * FROM attempts WHERE agent = ? AND vm = ? AND session_id = ? AND released = 0
              AND (stage IN (?, ?) OR (stage = ? AND observed = 0)) ORDER BY id LIMIT 1
            """, [.text(agent.rawValue), .text(vm), .text(sessionId),
                  .int(Int64(AttemptStage.writeStarted.rawValue)), .int(Int64(AttemptStage.inputAccepted.rawValue)),
                  .int(Int64(AttemptStage.confirmed.rawValue))])
            .first.map(attempt)
    }

    /// 所有「已写入、还没确认、也没被解除」的投递尝试（定时检查用来补确认）
    func openAttempts() -> [Attempt] {
        ((try? db.query("SELECT * FROM attempts WHERE released = 0 AND stage IN (?, ?) ORDER BY id",
                        [.int(Int64(AttemptStage.writeStarted.rawValue)), .int(Int64(AttemptStage.inputAccepted.rawValue))])) ?? [])
            .map(attempt)
    }

    /// 卡住了、要人去看的投递尝试：已写入、没确认、也没被人工解除，并且已经记成了「已写入未确认」
    /// （正在投的那 8～15 秒里投递状态还是「投递中」，不算）。强制发送时对方在忙的那种是意料之中的，不算。
    /// 同一次尝试合并了几条消息的，只算一次。App 用来弹「消息没能确认送达」的横幅
    func stuckAttempts(excludingReason: String) -> [(attemptId: Int64, memberId: Int64, reason: String)] {
        let rows = (try? db.query("""
            SELECT a.id, a.member_id, MAX(d.error) AS error
            FROM attempts a JOIN deliveries d ON d.attempt_id = a.id
            WHERE a.released = 0 AND a.stage IN (?, ?) AND d.status = 'unconfirmed' AND d.error != ?
            GROUP BY a.id ORDER BY a.id
            """, [.int(Int64(AttemptStage.writeStarted.rawValue)), .int(Int64(AttemptStage.inputAccepted.rawValue)),
                  .text(excludingReason)])) ?? []
        return rows.map { ($0.int("id"), $0.int("member_id"), $0.text("error")) }
    }

    /// 已经写进对方会话、投递却还是「投递中」的尝试：正常情况下投递方会马上记成已送达或未确认，
    /// 留在这里说明当时记录状态时数据库出错了，由定时检查补记（调用方要排除正在投递的成员）
    func unrecordedAttempts() -> [Attempt] {
        ((try? db.query("""
            SELECT * FROM attempts WHERE released = 0 AND stage IN (?, ?)
              AND id IN (SELECT attempt_id FROM deliveries WHERE status = 'running') ORDER BY id
            """, [.int(Int64(AttemptStage.writeStarted.rawValue)), .int(Int64(AttemptStage.inputAccepted.rawValue))])) ?? [])
            .map(attempt)
    }

    /// 这次尝试现在还是「已写入未确认」吗（没被补确认、也没被人工解除）。补发未确认通知前核对用
    func isAttemptUnconfirmed(_ id: Int64) throws -> Bool {
        try !db.query("""
            SELECT 1 FROM attempts WHERE id = ? AND released = 0 AND stage < ?
              AND id IN (SELECT attempt_id FROM deliveries WHERE status = 'unconfirmed')
            """, [.int(id), .int(Int64(AttemptStage.confirmed.rawValue))]).isEmpty
    }

    /// 人工「解除并继续」：只解除调度上的阻挡，这次尝试仍是「已写入未确认」，绝不改成送达，也不重投
    func releaseAttempt(_ id: Int64) throws {
        try db.run("UPDATE attempts SET released = 1, updated_at = ? WHERE id = ?", [.text(nowISO()), .int(id)])
    }

    // ---------- 打断记录（第 6 步第二期，见 Interrupt.swift） ----------

    struct InterruptRecord {
        let id: Int64
        let agent: AgentKind
        let vm: String
        let sessionId: String
        let launch: String
        let targetTurn: String
        let memberId: Int64
        let senderKey: String
        let state: InterruptState
        let alerted: Bool
        let createdAt: Date
        let logFile: String  // 按键前会话记录的文件
        let logInode: String // 它的文件身份
        let logOffset: Int   // 按键前的文件大小；-1 = 没记（还没走到按键那一步）
    }

    private func interrupt(_ r: Row) -> InterruptRecord {
        InterruptRecord(id: r.int("id"), agent: AgentKind(rawValue: r.text("agent")) ?? .claude, vm: r.text("vm"),
                        sessionId: r.text("session_id"), launch: r.text("launch"), targetTurn: r.text("target_turn"),
                        memberId: r.int("member_id"), senderKey: r.text("sender_key"),
                        state: InterruptState(rawValue: r.text("state")) ?? .unknown, alerted: r.int("alerted") != 0,
                        createdAt: parseISO(r.text("created_at")) ?? Date(),
                        logFile: r.text("log_file"), logInode: r.text("log_inode"), logOffset: Int(r.int("log_offset")))
    }

    func getInterrupt(_ id: Int64) throws -> InterruptRecord? {
        try db.query("SELECT * FROM interrupts WHERE id = ?", [.int(id)]).first.map(interrupt)
    }

    /// 按键前记下会话记录的位置（只在 registered 时能记）。记不进库抛错：调用方不按
    func setInterruptLog(_ id: Int64, file: String, inode: String, offset: Int) throws {
        let changed = try db.update("""
            UPDATE interrupts SET log_file = ?, log_inode = ?, log_offset = ?, updated_at = ? WHERE id = ? AND state = 'registered'
            """, [.text(file), .text(inode), .int(Int64(offset)), .text(nowISO()), .int(id)])
        guard changed > 0 else { throw CoreError(message: "打断记录 \(id) 已不是登记状态") }
    }

    /// 登记一次打断（registered）。同一会话、同一次启动、同一回合已经登记过（唯一键冲突）返回 nil，这一回合不再按。
    /// 数据库出错抛错：调用方一律不按
    func registerInterrupt(member: Member, launch: String, targetTurn: String, senderKey: String, exempt: Bool) throws -> Int64? {
        let now = nowISO()
        let changed = try db.update("""
            INSERT OR IGNORE INTO interrupts (agent, vm, session_id, launch, target_turn, member_id, sender_key, exempt, state, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(member.agent.rawValue), .text(member.vm), .text(member.sessionId), .text(launch), .text(targetTurn),
                  .int(member.id), .text(senderKey), .int(exempt ? 1 : 0), .text(InterruptState.registered.rawValue), .text(now), .text(now)])
        guard changed > 0 else { return nil }
        return try db.query("SELECT id FROM interrupts WHERE agent = ? AND vm = ? AND session_id = ? AND launch = ? AND target_turn = ?",
                            [.text(member.agent.rawValue), .text(member.vm), .text(member.sessionId), .text(launch), .text(targetTurn)])
            .first?.int("id")
    }

    /// 这个发起人对这个实际会话，since 之后有没有「可能按过 Esc」的记录（冷却）。
    /// 按 key_may_sent_at 查，不看现在的 state：sent 之后不管结算成什么，按过的事实都还在
    func interruptCooling(senderKey: String, agent: AgentKind, vm: String, sessionId: String, since: Date) throws -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try !db.query("""
            SELECT 1 FROM interrupts WHERE sender_key = ? AND agent = ? AND vm = ? AND session_id = ?
              AND key_may_sent_at != '' AND key_may_sent_at > ? LIMIT 1
            """, [.text(senderKey), .text(agent.rawValue), .text(vm), .text(sessionId), .text(formatter.string(from: since))]).isEmpty
    }

    /// 改状态：只在当前状态是 from 里的某一个时才改，返回改成了没有。
    /// 改成 sent 时同一条语句写上 key_may_sent_at（这一步写不进去就不按键）
    @discardableResult
    func moveInterrupt(_ id: Int64, from: [InterruptState], to: InterruptState, reason: String = "") throws -> Bool {
        let now = nowISO()
        let placeholders = from.map { _ in "?" }.joined(separator: ", ")
        // 没给原因就保留原来的
        var sets = "state = ?, updated_at = ?"
        var params: [SQLValue] = [.text(to.rawValue), .text(now)]
        if !reason.isEmpty {
            sets += ", reason = ?"
            params.append(.text(reason))
        }
        if to == .sent {
            sets += ", key_may_sent_at = ?"
            params.append(.text(now))
        }
        params.append(.int(id))
        params += from.map { .text($0.rawValue) }
        return try db.update("UPDATE interrupts SET \(sets) WHERE id = ? AND state IN (\(placeholders))", params) > 0
    }

    /// 这个实际会话上还没结算的打断（registered / sent / unknown）。读库出错抛错：调用方当成「有阻挡」
    func unsettledInterrupt(agent: AgentKind, vm: String, sessionId: String) throws -> InterruptRecord? {
        try db.query("""
            SELECT * FROM interrupts WHERE agent = ? AND vm = ? AND session_id = ? AND state IN ('registered', 'sent', 'unknown')
            ORDER BY id LIMIT 1
            """, [.text(agent.rawValue), .text(vm), .text(sessionId)]).first.map(interrupt)
    }

    /// 所有还没结算的打断（定时检查用）
    func unsettledInterrupts() throws -> [InterruptRecord] {
        try db.query("SELECT * FROM interrupts WHERE state IN ('registered', 'sent', 'unknown') ORDER BY id").map(interrupt)
    }

    /// 「结果未知」的告警发过了（每条记录只发一次）
    func markInterruptAlerted(_ id: Int64) throws {
        try db.run("UPDATE interrupts SET alerted = 1, updated_at = ? WHERE id = ?", [.text(nowISO()), .int(id)])
    }

    // ---------- 单独托管会话（左边栏「会话」，见 Solo.swift） ----------

    struct SoloRecord {
        let id: Int64
        let agent: AgentKind
        let vm: String
        let sessionId: String
        let cwd: String
        let tmux: String
        let launchId: String
        let state: String // starting / running / failed / ended
        let error: String
        let createdAt: String
        let lastOutcome: String // 最近一轮怎么结束的：completed / failed / interrupted；还没结束过一轮为空
        let lastEndedAt: String // 最近一轮结束的时间（ISO）
    }

    private func solo(_ r: Row) -> SoloRecord {
        SoloRecord(id: r.int("id"), agent: AgentKind(rawValue: r.text("agent")) ?? .claude, vm: r.text("vm"),
                   sessionId: r.text("session_id"), cwd: r.text("cwd"), tmux: r.text("tmux"), launchId: r.text("launch_id"),
                   state: r.text("state"), error: r.text("error"), createdAt: r.text("created_at"),
                   lastOutcome: r.text("last_outcome"), lastEndedAt: r.text("last_ended_at"))
    }

    /// 记下单独会话这一轮怎么结束的
    func setSoloOutcome(_ id: Int64, outcome: String, endedAt: String) throws {
        try db.run("UPDATE solo_sessions SET last_outcome = ?, last_ended_at = ?, updated_at = ? WHERE id = ?",
                   [.text(outcome), .text(endedAt), .text(nowISO()), .int(id)])
    }

    /// 新建一条单独会话记录（starting）。tmux 名用 id：kk-solo-<id>
    func createSolo(agent: AgentKind, vm: String, cwd: String, sessionId: String) throws -> SoloRecord {
        let now = nowISO()
        let id = try db.run("INSERT INTO solo_sessions (agent, vm, session_id, cwd, state, created_at, updated_at) VALUES (?, ?, ?, ?, 'starting', ?, ?)",
                            [.text(agent.rawValue), .text(vm), .text(sessionId), .text(cwd), .text(now), .text(now)])
        try db.run("UPDATE solo_sessions SET tmux = ? WHERE id = ?", [.text("kk-solo-\(id)"), .int(id)])
        return try getSolo(id)!
    }

    func getSolo(_ id: Int64) throws -> SoloRecord? {
        try db.query("SELECT * FROM solo_sessions WHERE id = ?", [.int(id)]).first.map(solo)
    }

    /// 还没结束的单独会话（正在启动、运行中、启动失败），按创建时间从新到旧
    func liveSolos() throws -> [SoloRecord] {
        try db.query("SELECT * FROM solo_sessions WHERE state IN ('starting', 'running', 'failed') ORDER BY id DESC").map(solo)
    }

    /// 运行中的单独会话里，会话 ID 是这个的（拉进群时用）
    func runningSolo(agent: AgentKind, sessionId: String) throws -> SoloRecord? {
        try db.query("SELECT * FROM solo_sessions WHERE agent = ? AND session_id = ? AND state = 'running' LIMIT 1",
                     [.text(agent.rawValue), .text(sessionId)]).first.map(solo)
    }

    func setSoloLaunch(_ id: Int64, launchId: String) throws {
        try db.run("UPDATE solo_sessions SET launch_id = ?, updated_at = ? WHERE id = ?", [.text(launchId), .text(nowISO()), .int(id)])
    }

    func setSoloSessionId(_ id: Int64, sessionId: String) throws {
        try db.run("UPDATE solo_sessions SET session_id = ?, updated_at = ? WHERE id = ?", [.text(sessionId), .text(nowISO()), .int(id)])
    }

    /// 改状态。from 不为空时只在当前状态是其中之一时才改（比如启动完成时它已经被销毁了，就不能再改回 running）。返回改成了没有
    @discardableResult
    func setSoloState(_ id: Int64, _ state: String, error: String = "", from: [String] = []) throws -> Bool {
        var sql = "UPDATE solo_sessions SET state = ?, error = ?, updated_at = ? WHERE id = ?"
        var params: [SQLValue] = [.text(state), .text(error), .text(nowISO()), .int(id)]
        if !from.isEmpty {
            sql += " AND state IN (\(from.map { _ in "?" }.joined(separator: ", ")))"
            params += from.map { .text($0) }
        }
        return try db.update(sql, params) > 0
    }

    /// 用着这个会话的群成员（不算绑着单独会话的）。解散群、移出成员都会删掉成员行，所以查到的都在现存的群里
    func membersUsing(agent: AgentKind, sessionId: String) throws -> [Member] {
        try db.query("SELECT * FROM members WHERE agent = ? AND session_id = ? AND solo_id = 0",
                     [.text(agent.rawValue), .text(sessionId)]).map(member)
    }

    /// 绑着这个单独会话的群成员（同一时间最多一个）
    func memberBound(toSolo soloId: Int64) throws -> Member? {
        try db.query("SELECT * FROM members WHERE solo_id = ? LIMIT 1", [.int(soloId)]).first.map(member)
    }

    /// 核心启动时：上次登记了还没按的改成 aborted（一定没按过）；可能已经按了、还没结算的改成 unknown，
    /// 都不会对同一回合再按一次。unknown 的之后由定时检查按证据结算
    func recoverInterruptsOnStartup() throws {
        try db.run("UPDATE interrupts SET state = 'aborted', reason = '核心重启，登记后还没按键', updated_at = ? WHERE state = 'registered'",
                   [.text(nowISO())])
        try db.run("UPDATE interrupts SET state = 'unknown', reason = '核心重启时结果还没确认', updated_at = ? WHERE state = 'sent'",
                   [.text(nowISO())])
    }
}

/// 打断记录的状态（存数据库的文字）
enum InterruptState: String {
    case registered  // 已登记，还没按
    case aborted     // 按键前复查没通过，没按（这一回合以后也不再按）
    case sent        // Esc 可能已经发出（不代表成功）
    case confirmed   // 确认打断成功
    case natural     // 目标回合自己结束了
    case superseded  // 已经开了新的一轮
    case unknown     // 结果没法确认，等定时检查按证据结算或人工处理
}

/// 投递尝试走到了哪一步（存数据库的整数，越大越靠后）
enum AttemptStage: Int {
    case cancelled = -1    // 还没写入就放弃了
    case preparing = 1     // 准备中：还没往对方会话里写任何东西
    case writeStarted = 2  // 开始写入：第一个字节可能已经进了对方的终端
    case inputAccepted = 3 // 已回车 / 已交给 codex queue、中转会话
    case confirmed = 4     // 确认对方收到了这一条
}
