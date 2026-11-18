// 核心和界面之间的接口数据结构（JSON）。
// 这个文件会同时编进核心和界面两个程序，接口约定改了，两边编译都会检查。
// 原则：核心只返回事实数据，显示用的文案全部由界面自己拼，这样改界面不用动核心。
import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
}

/// 群聊（列表里用，带统计数字）
public struct GroupSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let createdAt: String
    public let memberCount: Int
    public let messageCount: Int
    public let lastActive: String
    // 集群相关：普通群这几项都是空字符串 / false / 0
    public let cluster: Bool          // 集群主群：群主可以用 kkAgent spawn 拆出子群
    public let parentId: String       // 子群：所属集群（主群）的 id；顶层群为空
    public let owner: String          // 集群的群主成员名（主群里加入的第一个成员）
    public let worktree: String       // 子群：git worktree 的绝对路径
    public let branch: String         // 子群：worktree 上的分支
    public let baseBranch: String     // 子群：验收通过后要合并回去的分支
    public let failCount: Int         // 子群：tester 已打回 coder 的次数（群主介入后清零）
    public let blocked: Bool          // 子群：打回超过上限，已暂停自动打回，等群主介入

    public init(id: String, name: String, createdAt: String, memberCount: Int, messageCount: Int, lastActive: String,
                cluster: Bool, parentId: String, owner: String, worktree: String, branch: String, baseBranch: String,
                failCount: Int, blocked: Bool) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.memberCount = memberCount
        self.messageCount = messageCount
        self.lastActive = lastActive
        self.cluster = cluster
        self.parentId = parentId
        self.owner = owner
        self.worktree = worktree
        self.branch = branch
        self.baseBranch = baseBranch
        self.failCount = failCount
        self.blocked = blocked
    }
}

public struct Member: Codable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let groupId: String
    public let alias: String          // 群里的称呼，如 coder / tester
    public let agent: AgentKind
    public let sessionId: String
    public let description: String
    public let cwd: String
    public let vm: String             // 会话在哪台机器上：空 = 物理机，否则是 ubx 虚拟机的名字
    public let headless: Bool         // 集群 spawn 出来、由核心在后台运行的会话
    public let tmux: String           // 常驻在物理机哪个 tmux 会话里（集群 coder / tester）；空 = 不在 tmux 里
    public let paused: Bool           // 用户暂停了自动投递：消息只排队，不送进去（人在终端里手动操作时用）
    public let createdAt: String
    /// 绑着的单独托管会话（左边栏「会话」里建的）；0 = 没绑。绑着的成员不负责这个会话的进程：
    /// 移出成员、解散群只解绑，只有在「会话」页销毁或用户 exit 才结束，核心也不会替它重建 tmux
    public let soloId: Int64

    public init(id: Int64, groupId: String, alias: String, agent: AgentKind, sessionId: String, description: String, cwd: String, vm: String,
                headless: Bool, tmux: String, paused: Bool, createdAt: String, soloId: Int64 = 0) {
        self.soloId = soloId
        self.id = id
        self.groupId = groupId
        self.alias = alias
        self.agent = agent
        self.sessionId = sessionId
        self.description = description
        self.cwd = cwd
        self.vm = vm
        self.headless = headless
        self.tmux = tmux
        self.paused = paused
        self.createdAt = createdAt
    }

    /// 老核心返回的成员里没有 soloId，按 0（没绑）处理
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        groupId = try c.decode(String.self, forKey: .groupId)
        alias = try c.decode(String.self, forKey: .alias)
        agent = try c.decode(AgentKind.self, forKey: .agent)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        description = try c.decode(String.self, forKey: .description)
        cwd = try c.decode(String.self, forKey: .cwd)
        vm = try c.decode(String.self, forKey: .vm)
        headless = try c.decode(Bool.self, forKey: .headless)
        tmux = try c.decode(String.self, forKey: .tmux)
        paused = try c.decode(Bool.self, forKey: .paused)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        soloId = try c.decodeIfPresent(Int64.self, forKey: .soloId) ?? 0
    }
}

/// 左边栏「会话」里的单独托管会话（不属于任何群，由 kkAgent 托管在 tmux 里，见 Core/Solo.swift）
public struct SoloSession: Codable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let agent: AgentKind
    public let vm: String
    public let sessionId: String // Codex 建好会话之前为空
    public let cwd: String
    public let tmux: String
    public let state: String     // starting 正在启动 / running 运行中 / failed 启动失败（ended 的不返回）
    public let error: String     // 启动失败的原因
    public let createdAt: String
    public let boundGroupId: String   // 绑在哪个群里（拉进群后），没绑为空
    public let boundGroupName: String
    public let boundAlias: String
    public let title: String          // 会话名：Claude 里 /rename 起的、Codex 桌面端的；没有为空
    public let activity: String       // 现在在干什么：working / waitingPermission / idle / unknown（Codex 不检测人工审批）
    public let lastOutcome: String    // 最近一轮怎么结束的：completed / failed / interrupted；还没结束过一轮为空
    public let lastEndedAt: String    // 最近一轮结束的时间（ISO）。App 记下看过的是哪个时间，不一样就是有没看过的结果

    public init(id: Int64, agent: AgentKind, vm: String, sessionId: String, cwd: String, tmux: String, state: String, error: String,
                createdAt: String, boundGroupId: String, boundGroupName: String, boundAlias: String, title: String,
                activity: String, lastOutcome: String, lastEndedAt: String) {
        self.activity = activity
        self.lastOutcome = lastOutcome
        self.lastEndedAt = lastEndedAt
        self.id = id
        self.agent = agent
        self.vm = vm
        self.sessionId = sessionId
        self.cwd = cwd
        self.tmux = tmux
        self.state = state
        self.error = error
        self.createdAt = createdAt
        self.boundGroupId = boundGroupId
        self.boundGroupName = boundGroupName
        self.boundAlias = boundAlias
        self.title = title
    }
}

public struct CreateSoloRequest: Codable, Sendable {
    public let agent: AgentKind
    public let cwd: String
    // 下面两个只在「继续沟通」时带：接着这个已有的会话打开（不新建），在会话原来所在的机器上（空 = 物理机）
    public let sessionId: String?
    public let vm: String?

    public init(agent: AgentKind, cwd: String, sessionId: String? = nil, vm: String? = nil) {
        self.agent = agent
        self.cwd = cwd
        self.sessionId = sessionId
        self.vm = vm
    }
}

/// 成员当前状态：只有事实，没有文案
public struct MemberState: Codable, Hashable, Sendable {
    public let transcriptFound: Bool  // 本机能找到会话文件
    public let delivering: Bool       // 核心正在往它投递消息
    public let codexBusy: Bool        // Codex 正在跑一轮
    public let claudeLive: Bool       // Claude 会话正开在终端 / VSCode 里
    public let claudeLiveName: String // 开着时的会话名（中转投递的地址）
    public let claudeLiveStatus: String // 开着时的 idle / busy
    public let agentStatus: String      // tmux 里的 Claude 由 hook 上报的状态：unknown / working / waitingPermission / idle；其他成员为空
    public let tmuxRunning: Bool        // tmux 成员的会话现在在不在（在终端里 exit 了就不在，可以点「重新打开会话」）
    public let openError: String        // 最近一次「重新打开会话」失败的原因；没失败过为空
    public let openErrorSeq: Int        // 那次失败的是第几号打开请求（和 POST /open 返回的序号对照）；没失败过为 0
    /// kkAgent 托管的会话（群里新建的、集群子群的）还没写出会话文件时，看它的第一条投递走到哪了：
    /// "starting" 还在启动；"failed" 启动失败（原因在 startupError）；其他情况为空
    public let startup: String
    public let startupError: String

    public init(transcriptFound: Bool, delivering: Bool, codexBusy: Bool, claudeLive: Bool, claudeLiveName: String, claudeLiveStatus: String,
                agentStatus: String, tmuxRunning: Bool, openError: String, openErrorSeq: Int, startup: String = "", startupError: String = "") {
        self.startup = startup
        self.startupError = startupError
        self.transcriptFound = transcriptFound
        self.delivering = delivering
        self.codexBusy = codexBusy
        self.claudeLive = claudeLive
        self.claudeLiveName = claudeLiveName
        self.claudeLiveStatus = claudeLiveStatus
        self.agentStatus = agentStatus
        self.tmuxRunning = tmuxRunning
        self.openError = openError
        self.openErrorSeq = openErrorSeq
    }

    /// 老核心返回的状态里没有 startup 两项，按空处理
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcriptFound = try c.decode(Bool.self, forKey: .transcriptFound)
        delivering = try c.decode(Bool.self, forKey: .delivering)
        codexBusy = try c.decode(Bool.self, forKey: .codexBusy)
        claudeLive = try c.decode(Bool.self, forKey: .claudeLive)
        claudeLiveName = try c.decode(String.self, forKey: .claudeLiveName)
        claudeLiveStatus = try c.decode(String.self, forKey: .claudeLiveStatus)
        agentStatus = try c.decode(String.self, forKey: .agentStatus)
        tmuxRunning = try c.decode(Bool.self, forKey: .tmuxRunning)
        openError = try c.decode(String.self, forKey: .openError)
        openErrorSeq = try c.decode(Int.self, forKey: .openErrorSeq)
        startup = try c.decodeIfPresent(String.self, forKey: .startup) ?? ""
        startupError = try c.decodeIfPresent(String.self, forKey: .startupError) ?? ""
    }
}

public struct MemberDetail: Codable, Identifiable, Hashable, Sendable {
    public let member: Member
    public let state: MemberState
    public var id: Int64 { member.id }

    public init(member: Member, state: MemberState) {
        self.member = member
        self.state = state
    }
}

/// from / to：成员名，或 user（用户本人）、system（入群说明）、all（所有人，只用于 to）
public struct Message: Codable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let groupId: String
    public let from: String
    public let to: String
    public let content: String
    public let verdict: String        // 集群子群里 tester 的验收结论：pass / fail；普通消息为空
    public let kind: String           // "alert" = 系统提醒 / 告警（投递出错、重启打断等），界面要直接显示正文；其余为空
    public let createdAt: String
    public let urgent: Bool           // 紧急消息（第 6 步）：投递时排在普通消息前面

    public init(id: Int64, groupId: String, from: String, to: String, content: String, verdict: String, kind: String, createdAt: String,
                urgent: Bool = false) {
        self.id = id
        self.groupId = groupId
        self.from = from
        self.to = to
        self.content = content
        self.verdict = verdict
        self.kind = kind
        self.createdAt = createdAt
        self.urgent = urgent
    }

    // 旧核心返回的消息没有 urgent 字段，按普通消息解码（界面和核心可能不是同一个版本）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        groupId = try c.decode(String.self, forKey: .groupId)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        content = try c.decode(String.self, forKey: .content)
        verdict = try c.decode(String.self, forKey: .verdict)
        kind = try c.decode(String.self, forKey: .kind)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        urgent = try c.decodeIfPresent(Bool.self, forKey: .urgent) ?? false
    }
}

public enum DeliveryStatus: String, Codable, Sendable {
    case pending, running, delivered, failed
    /// 已经写进对方的会话，但没能确认对方收到（不重投，等迟到的确认或人工处理）
    case unconfirmed
}

/// 一条消息发给几个人就有几条投递记录
public struct Delivery: Codable, Identifiable, Hashable, Sendable {
    public let id: Int64
    public let messageId: Int64
    public let memberId: Int64
    public let memberAlias: String
    public let status: DeliveryStatus
    public let error: String
    public let updatedAt: String
    public let attemptId: Int64       // 属于哪一次投递尝试（「解除并继续」要用）；0 = 不需要确认的投递方式
    public let attemptReleased: Bool  // 那次尝试已经被人工「解除并继续」过
    public let isBootstrap: Bool      // 入群说明那一条：不能取消、不能强制发送

    public init(id: Int64, messageId: Int64, memberId: Int64, memberAlias: String, status: DeliveryStatus, error: String, updatedAt: String,
                attemptId: Int64, attemptReleased: Bool, isBootstrap: Bool = false) {
        self.id = id
        self.messageId = messageId
        self.memberId = memberId
        self.memberAlias = memberAlias
        self.status = status
        self.error = error
        self.updatedAt = updatedAt
        self.attemptId = attemptId
        self.attemptReleased = attemptReleased
        self.isBootstrap = isBootstrap
    }

    // 旧核心返回的投递没有 isBootstrap 字段，按普通投递解码（界面和核心可能不是同一个版本）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        messageId = try c.decode(Int64.self, forKey: .messageId)
        memberId = try c.decode(Int64.self, forKey: .memberId)
        memberAlias = try c.decode(String.self, forKey: .memberAlias)
        status = try c.decode(DeliveryStatus.self, forKey: .status)
        error = try c.decode(String.self, forKey: .error)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        attemptId = try c.decode(Int64.self, forKey: .attemptId)
        attemptReleased = try c.decode(Bool.self, forKey: .attemptReleased)
        isBootstrap = try c.decodeIfPresent(Bool.self, forKey: .isBootstrap) ?? false
    }
}

public struct GroupDetail: Codable, Sendable {
    public let group: GroupSummary
    public let members: [MemberDetail]
    public let messages: [Message]
    public let deliveries: [Delivery]

    public init(group: GroupSummary, members: [MemberDetail], messages: [Message], deliveries: [Delivery]) {
        self.group = group
        self.members = members
        self.messages = messages
        self.deliveries = deliveries
    }
}

public enum TranscriptKind: String, Codable, Sendable {
    case user         // 收到的消息
    case text         // 回复
    case thinking     // 思考
    case tool         // 调用工具
    case toolResult = "tool_result"
}

public struct TranscriptEvent: Codable, Hashable, Sendable {
    public let time: String
    public let kind: TranscriptKind
    public let text: String

    public init(time: String, kind: TranscriptKind, text: String) {
        self.time = time
        self.kind = kind
        self.text = text
    }
}

/// token 用量。两家的记法统一成四项：没走缓存的输入、从缓存读的输入、写进缓存的输入、输出
public struct TokenUsage: Codable, Hashable, Sendable {
    public var input: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var output: Int

    public var total: Int { input + cacheRead + cacheWrite + output }

    public init(input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
    }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, cacheRead: a.cacheRead + b.cacheRead,
                   cacheWrite: a.cacheWrite + b.cacheWrite, output: a.output + b.output)
    }
}

/// 执行过程的一段增量；下次带着 offset 来读就只拿新增的
public struct TranscriptChunk: Codable, Sendable {
    public let events: [TranscriptEvent]
    public let offset: Int
    /// 这一段里用到的模型（按出现先后，不重复）
    public let models: [String]?
    /// token 用量，两家记法不同，所以分两个字段：
    ///   Claude 填 usageByMessage：这一段里每条回复（按回复 ID）的用量。
    ///     同一条回复会在会话里重复出现（比如压缩上下文后又记一遍），可能隔得很远、落在不同段里，
    ///     所以要按 ID 合并后再加，同一个 ID 只算一次
    ///   Codex 填 usageTotal：读到这一段末尾时的累计总量，直接替换
    public let usageByMessage: [String: TokenUsage]?
    public let usageTotal: TokenUsage?

    /// 这一段是从哪个文件读的。offset 只在同一个文件里有意义：桌面端 Codex 的会话会分段写到新文件，
    /// 界面下次请求时把它带回来（?source=），文件换了核心就从新文件的起点读，不拿旧文件的偏移量去读新文件
    public let source: String?

    public init(events: [TranscriptEvent], offset: Int, models: [String]? = nil,
                usageByMessage: [String: TokenUsage]? = nil, usageTotal: TokenUsage? = nil, source: String? = nil) {
        self.events = events
        self.offset = offset
        self.models = models
        self.usageByMessage = usageByMessage
        self.usageTotal = usageTotal
        self.source = source
    }
}

/// 本机或虚拟机里的一个历史会话（会话浏览列表用）
public struct SessionSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String        // 会话 ID
    public let agent: AgentKind
    public let vm: String        // 空 = 物理机，否则是 ubx 虚拟机的名字
    public let title: String     // 会话名；没有就用第一句用户消息；都没有时为空
    public let cwd: String       // 工作目录
    public let updatedAt: String // 会话文件最后修改时间（ISO）
    public let size: Int         // 会话文件大小（字节）
    /// 这个会话在 kkAgent 里用过的群名（按先后，解散了的群也在），搜索用。
    /// 可选：旧版核心不返回这个字段，界面照样能解析
    public var groups: [String]?

    public init(id: String, agent: AgentKind, vm: String, title: String, cwd: String, updatedAt: String, size: Int) {
        self.id = id
        self.agent = agent
        self.vm = vm
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.size = size
    }
}

/// 核心的运行信息，界面用来判断核心在不在
public struct CoreHealth: Codable, Sendable {
    public let pid: Int32
    public let startedAt: String
    public let port: Int
    public let relayRunning: Bool

    public init(pid: Int32, startedAt: String, port: Int, relayRunning: Bool) {
        self.pid = pid
        self.startedAt = startedAt
        self.port = port
        self.relayRunning = relayRunning
    }
}

// ---------- 请求体 ----------

public struct CreateGroupRequest: Codable, Sendable {
    public let name: String
    public let cluster: Bool?         // true = 建集群群聊；不带等于 false（老的调用方不用改）
    public init(name: String, cluster: Bool = false) {
        self.name = name
        self.cluster = cluster
    }
}

public struct AddMemberRequest: Codable, Sendable {
    public let agent: AgentKind
    public let sessionId: String // 拉入已有会话时填；新建会话（create == true）时忽略，发空串即可
    public let alias: String
    public let description: String
    /// true = 在群里新建一个会话（由 kkAgent 托管在 tmux 里）；不带或 false = 拉入已有会话（原来的行为）
    public let create: Bool?
    /// 新建会话的工作目录（create == true 时必填）
    public let cwd: String?

    public init(agent: AgentKind, sessionId: String, alias: String, description: String, create: Bool? = nil, cwd: String? = nil) {
        self.agent = agent
        self.sessionId = sessionId
        self.alias = alias
        self.description = description
        self.create = create
        self.cwd = cwd
    }
}

/// 更换成员的会话
public struct ChangeSessionRequest: Codable, Sendable {
    public let sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}

/// 卡在授权框上、需要人去处理的成员（App 用来发系统通知，所有群的都在里面）
public struct AttentionItem: Codable, Hashable, Sendable {
    public let memberId: Int64
    public let groupId: String
    public let groupName: String
    public let alias: String
    public let tool: String       // 卡在什么工具上；同时等好几个时是「N 个授权」
    public let detail: String     // 要做什么（命令、文件路径），截短过
    public let bySubagent: Bool
    public let since: String      // 这次开始等的时间（ISO）。同一次等待不变，App 靠它判断是不是已经通知过
    /// 等授权的是单独会话时它的 id（不管绑没绑进群），否则 0。没绑进群时 groupId 为空、memberId 为 0
    public let soloId: Int64

    public init(memberId: Int64, groupId: String, groupName: String, alias: String, tool: String, detail: String,
                bySubagent: Bool, since: String, soloId: Int64 = 0) {
        self.soloId = soloId
        self.memberId = memberId
        self.groupId = groupId
        self.groupName = groupName
        self.alias = alias
        self.tool = tool
        self.detail = detail
        self.bySubagent = bySubagent
        self.since = since
    }
}

/// 「重新打开会话」请求的结果：这次请求的序号（成员状态里的 openErrorSeq ≥ 它，就说明这次打开失败了）
public struct OpenSessionResult: Codable, Sendable {
    public let seq: Int
    public init(seq: Int) { self.seq = seq }
}

/// 暂停 / 恢复自动投递
public struct PauseRequest: Codable, Sendable {
    public let paused: Bool
    public init(paused: Bool) { self.paused = paused }
}

public struct PostMessageRequest: Codable, Sendable {
    public let from: String
    public let to: String
    public let content: String
    public let verdict: String?       // 只有子群里的 tester 能带：pass / fail；不带等于普通消息
    public let urgent: Bool?          // 紧急消息：对方空闲后排在普通消息前面送进去；不带等于普通消息

    public init(from: String, to: String, content: String, verdict: String? = nil, urgent: Bool? = nil) {
        self.from = from
        self.to = to
        self.content = content
        self.verdict = verdict
        self.urgent = urgent
    }
}

public struct PostMessageResult: Codable, Sendable {
    public let message: Message
    public let recipients: [String]

    public init(message: Message, recipients: [String]) {
        self.message = message
        self.recipients = recipients
    }
}

public struct APIError: Codable, Sendable {
    public let error: String
    public init(error: String) { self.error = error }
}

public struct OkResult: Codable, Sendable {
    public let ok: Bool
    public init() { ok = true }
}

// ---------- 设置 → 模型 ----------

/// 启动 / 续接 Claude、Codex 会话时默认带上的模型和思考强度。空字符串 = 跟随 CLI 自己的默认（不传这个参数）
public struct ModelSettings: Codable, Equatable, Sendable {
    public var claudeModel = ""
    public var claudeEffort = "medium"
    public var codexModel = ""
    public var codexEffort = "medium"

    public init() {}
}

/// CLI 支持的一个模型（从 CLI 的模型目录里读出来的）
public struct ModelOption: Codable, Hashable, Sendable {
    public let id: String          // 传给 --model / -m 的值
    public let name: String        // 显示名，如 Opus 5.5
    public let efforts: [String]   // 支持的思考强度，如 low、medium；空 = 这个模型不支持设置思考强度
    public let main: Bool          // false = 旧版或不常用的，下拉框里排在后面

    public init(id: String, name: String, efforts: [String], main: Bool) {
        self.id = id
        self.name = name
        self.efforts = efforts
        self.main = main
    }
}

/// GET /api/model-settings：当前设置 + 两个 CLI 现在支持的模型
public struct ModelSettingsInfo: Codable, Sendable {
    public let settings: ModelSettings
    public let claudeModels: [ModelOption]
    public let codexModels: [ModelOption]

    public init(settings: ModelSettings, claudeModels: [ModelOption], codexModels: [ModelOption]) {
        self.settings = settings
        self.claudeModels = claudeModels
        self.codexModels = codexModels
    }
}
