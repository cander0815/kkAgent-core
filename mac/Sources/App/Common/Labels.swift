// 显示用的文案和颜色：核心只给事实，怎么说给人听全在这里决定
import SwiftUI

enum Labels {
    /// 解散确认框里的说明。集群和子群要讲清楚后台进程和 worktree 会怎样
    static func dissolveMessage(_ group: GroupSummary?) -> String {
        guard let group else { return "" }
        if group.cluster {
            return "群主和全部子群的聊天记录都会删除，后台正在干活的 coder / tester 会被停掉。各子群的 git worktree 和分支保留，需要的话自己删。"
        }
        if !group.parentId.isEmpty {
            return "这个功能的聊天记录会删除，后台正在干活的 coder / tester 会被停掉。git worktree 和分支保留：\(group.worktree)"
        }
        return "群里的成员和聊天记录都会删除，各个会话本身不受影响。还没送出的消息不会再投递。"
    }
}

extension MemberDetail {
    /// 状态点的颜色：绿=空闲，橙=忙，红=有问题
    var statusColor: Color {
        // kkAgent 托管的会话刚建、还没写出会话文件：按第一条投递的进度显示，不当成「找不到会话文件」
        if state.startup == "starting" { return .orange }
        if !state.transcriptFound { return .red }
        // tmux 里的 Claude 有状态 hook：等授权要人去处理，用红色；状态未知时不敢说它空闲
        switch state.agentStatus {
        case "waitingPermission": return .red
        case "working", "unknown": return .orange
        case "idle": return .green
        default: break
        }
        if state.delivering || state.codexBusy { return .orange }
        // shell：这一轮已经结束、只是后台还有命令在跑，和 idle 一样算空闲（见 Readiness.swift）
        if member.agent == .claude && state.claudeLive && !["idle", "shell"].contains(state.claudeLiveStatus) { return .orange }
        return .green
    }

    /// 一两个词的短状态，用在头像提示和成员详情标题下
    var statusLabel: String {
        if state.startup == "starting" { return "正在启动" }
        if state.startup == "failed" { return "启动失败" }
        if !state.transcriptFound { return "找不到会话文件" }
        switch state.agentStatus {
        case "waitingPermission": return "等授权"
        case "working": return "正在干活"
        case "idle": return "空闲"
        case "unknown": return "状态未知"
        default: break
        }
        if state.delivering { return "正在处理群消息" }
        switch member.agent {
        case .codex:
            return state.codexBusy ? "工作中" : "空闲"
        case .claude:
            return state.claudeLive ? "开着" : "未打开"
        }
    }

    /// 消息怎么送进这个会话，用一句完整的话说明
    var deliveryNote: String {
        if !member.tmux.isEmpty {
            return "它常驻在 tmux 会话里，消息等它空闲了再合并送进去；暂停自动投递、等授权、状态未知、或者有「已写入未确认」的消息时，"
                + "后面的消息继续排队。核心重启、界面关掉都不影响它。"
        }
        switch member.agent {
        case .codex:
            return "消息会投进 Codex 桌面端里的这个会话。桌面端没打开它时，消息会排队等你打开。"
        case .claude where state.claudeLive:
            return "会话开着，消息会实时出现在它的窗口里。"
        case .claude:
            return "会话没打开，消息会在后台续接会话处理。重新打开这个会话才看得到这些内容。"
        }
    }

    /// 需要提醒用户的情况
    var statusHint: String? {
        if state.startup == "starting" {
            return member.agent == .codex
                ? "正在新建 Codex 会话（先跑一轮把会话建出来，十几秒到一分钟），这期间发给它的消息会先排着。"
                : "正在虚拟机里启动 Claude，界面就绪后会自动收到入群说明。"
        }
        if state.startup == "failed" {
            let reason = state.startupError.isEmpty ? "" : "（\(state.startupError.prefix(200))）"
            return member.agent == .codex
                ? "会话没能建起来\(reason)。发给它的消息先排着，可以把它移出群后重新新建。"
                : "启动没成功\(reason)。可以点「重新打开会话」，打开后排着的消息会自动送进去。"
        }
        if !state.transcriptFound {
            return member.vm.isEmpty
                ? "在本机找不到这个会话的记录文件，可能已被删除。"
                : "在虚拟机 \(member.vm) 里找不到这个会话的记录文件，可能是虚拟机没开着，或者文件已被删除。"
        }
        return nil
    }

    /// 会话在哪台机器上
    var machineLabel: String {
        member.vm.isEmpty ? "物理机" : "虚拟机 \(member.vm)"
    }
}

extension AgentKind {
    var displayName: String { self == .claude ? "Claude" : "Codex" }
}

/// from / to 里的特殊名字
func displayName(_ alias: String) -> String {
    ["user": "我", "all": "所有人", "system": "入群说明"][alias] ?? alias
}

extension DeliveryStatus {
    var label: String {
        switch self {
        case .pending: return "⏳ 排队"
        case .running: return "⏳ 投递中"
        case .delivered: return "✓ 已送达"
        case .failed: return "✗ 失败"
        case .unconfirmed: return "？已写入未确认"
        }
    }

    var color: Color {
        switch self {
        case .delivered: return .green
        case .failed: return .red
        default: return .orange
        }
    }
}

extension TranscriptKind {
    var label: String {
        switch self {
        case .user: return "收到"
        case .text: return "回复"
        case .thinking: return "思考"
        case .tool: return "调用工具"
        case .toolResult: return "工具结果"
        }
    }

    var color: Color {
        switch self {
        case .user: return .accentColor
        case .text: return .green
        default: return .secondary
        }
    }

    var isTool: Bool { self == .tool || self == .toolResult }
}

extension TranscriptEvent {
    /// Claude Code 自己记进会话的内部记录（本地命令、/exit 等），不是对话内容，不显示
    var isClaudeCodeInternal: Bool {
        guard kind == .user else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("<local-command") || t.hasPrefix("<command-name>") || t.hasPrefix("<command-message>")
    }
}

/// 核心存的是 ISO 时间（带毫秒），显示成本地时间
enum TimeText {
    private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(_ iso: String) -> Date? {
        parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    static func time(_ iso: String) -> String {
        date(iso)?.formatted(date: .omitted, time: .standard) ?? ""
    }

    static func dateTime(_ iso: String) -> String {
        date(iso)?.formatted(date: .numeric, time: .shortened) ?? ""
    }

    /// 日期分隔线用：「11月10日 星期一」
    static func day(_ iso: String) -> String {
        date(iso)?.formatted(.dateTime.month().day().weekday(.wide)) ?? ""
    }

    /// 群建了多久：只到分钟，超过一天也按小时算（「3 分钟」「2 小时 15 分」「30 小时 5 分」）
    static func age(_ iso: String, now: Date = Date()) -> String {
        guard let d = date(iso) else { return "" }
        let minutes = max(0, Int(now.timeIntervalSince(d) / 60))
        if minutes < 1 { return "刚创建" }
        if minutes < 60 { return "已创建 \(minutes) 分钟" }
        let rest = minutes % 60
        return rest == 0 ? "已创建 \(minutes / 60) 小时" : "已创建 \(minutes / 60) 小时 \(rest) 分"
    }

    /// 群列表用：今天的只显示时间，更早的显示日期
    static func relative(_ iso: String) -> String {
        guard let d = date(iso) else { return "" }
        return Calendar.current.isDateInToday(d)
            ? d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.month().day())
    }
}
