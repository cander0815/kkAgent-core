// 会话全部内容（会话浏览的右边）。按「一问一答」排版：
//   我的提问   —— 最显眼：「我」的头像 + 浅色卡片
//   它的回复   —— 每轮开头一次头像和名字，正文正常字号
//   思考 / 工具调用 / 工具结果 —— 缩进成一行小字，点开才看全文，不抢版面
// 跨天的地方插一条日期分隔线，方便翻历史。
import SwiftUI

struct SessionDetailView: View {
    @ObservedObject var browser: SessionBrowserModel
    let session: SessionSummary
    let continueSession: (SessionSummary) async -> String?
    @AppStorage("hideTools") private var hideTools = false // 和群聊的执行过程共用这个开关
    @StateObject private var confirmContinue = LocalState(false)
    @StateObject private var continuing = LocalState(false)
    @StateObject private var continueError = LocalState<String?>(nil)
    @StateObject private var isAtBottom = LocalState(true)
    @StateObject private var scrolledSession = LocalState<String?>(nil) // 已经自动滚到底过的会话

    private var color: Color { Theme.color(session.agent) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            transcript
        }
        // 会话可能还在进行：每 2 秒看一次有没有新内容，换会话或离开页面时自动停。早就结束的会话不轮询
        .task(id: session.id) {
            guard browser.isRecentlyActive(session) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await browser.loadTranscript()
            }
        }
    }

    // ---------- 顶部：标题和会话信息 ----------

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentTile(agent: session.agent, size: 34)
            VStack(alignment: .leading, spacing: 8) {
                Text(browser.displayTitle(session).isEmpty ? "没有文字内容的会话" : browser.displayTitle(session))
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    MetaChip(icon: session.vm.isEmpty ? "desktopcomputer" : "shippingbox",
                             text: session.vm.isEmpty ? "物理机" : "虚拟机",
                             help: session.vm.isEmpty ? "会话在物理机上" : "会话在虚拟机 \(session.vm) 里")
                    pathChip
                    sessionIdChip
                }
                usageStrip
            }
            Spacer(minLength: 0)
            if !session.cwd.isEmpty {
                Button { confirmContinue.value = true } label: {
                    Label(continuing.value ? "正在打开…" : "继续沟通", systemImage: "bubble.left.and.bubble.right")
                }
                .disabled(continuing.value)
                .tip("在后台 tmux 里接着这个会话打开，到左边栏「会话」页直接和它聊")
                .clickable()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06))
        .confirmationDialog("接着这个会话继续沟通？", isPresented: $confirmContinue.value) {
            Button("继续沟通") { startContinue() }
        } message: {
            Text("会在\(session.vm.isEmpty ? "物理机" : "虚拟机 \(session.vm) ")上的 tmux 里接着这个会话打开，然后切到左边栏「会话」页，直接在终端里聊。它会一直在后台运行，点「销毁」或在终端里 exit 才结束。\n如果这个会话还在别的终端或桌面端开着，先关掉那边，两边同时写同一个会话会乱。")
        }
        .alert("没能打开", isPresented: Binding(get: { continueError.value != nil }, set: { if !$0 { continueError.value = nil } })) {
            Button("好") { continueError.value = nil }
        } message: {
            Text(continueError.value ?? "")
        }
    }

    private func startContinue() {
        continuing.value = true
        Task {
            let failure = await continueSession(session)
            continuing.value = false
            continueError.value = failure
        }
    }

    /// 工作目录：显示缩短的路径，悬停看完整路径，点后面的按钮复制完整路径
    private var pathChip: some View {
        HStack(spacing: 5) {
            Label(session.cwd.isEmpty ? "未知目录" : shortPath(session.cwd), systemImage: "folder")
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(session.cwd)
            if !session.cwd.isEmpty {
                CopyButton(text: session.cwd, help: "复制工作目录", color: color)
                OpenTerminalButton(cwd: session.cwd, vm: session.vm, color: color)
            }
        }
        .font(.caption)
        .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }

    /// 在终端里接着这个会话聊的命令（需要先自己切到工作目录，claude 只在会话所属的目录下找得到它）
    private var resumeCommand: String {
        switch session.agent {
        case .claude: "claude --resume \(session.id)"
        case .codex: "codex resume \(session.id)"
        }
    }

    /// 会话 ID 完整显示，后面两个按钮：复制会话 ID、复制恢复命令
    private var sessionIdChip: some View {
        HStack(spacing: 5) {
            Text("会话 ID").foregroundStyle(.secondary)
            Text(session.id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(1)
            CopyButton(text: session.id, help: "复制会话 ID", color: color)
            CopyButton(text: resumeCommand, icon: "doc.on.clipboard", help:"复制恢复命令：\(resumeCommand)", color: color)
        }
        .font(.caption)
        .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
        .layoutPriority(1) // 空间不够时先缩短路径，会话 ID 保持完整
    }

    /// 用的模型 + token 用量。会话很长时要读完才是最终数字，读取中会标出来
    @ViewBuilder
    private var usageStrip: some View {
        if !browser.models.isEmpty || browser.usage != nil {
            HStack(spacing: 14) {
                ForEach(browser.models, id: \.self) { model in
                    Label(model, systemImage: "cpu")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(color.opacity(0.12)))
                        .help("这个会话用到的模型")
                }
                if let usage = browser.usage {
                    TokenStat(label: "token 总计", value: usage.total, strong: true)
                    TokenStat(label: "输入", value: usage.input)
                    if usage.cacheRead > 0 { TokenStat(label: "缓存读取", value: usage.cacheRead) }
                    if usage.cacheWrite > 0 { TokenStat(label: "缓存写入", value: usage.cacheWrite) }
                    TokenStat(label: "输出", value: usage.output)
                }
                if browser.loadingTranscript {
                    Text("统计中").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // ---------- 工具条 ----------

    private var toolbar: some View {
        HStack(spacing: 10) {
            Toggle("隐藏工具调用", isOn: $hideTools).toggleStyle(.checkbox).font(.caption).clickable()
            Spacer()
            if browser.loadingTranscript {
                ProgressView().controlSize(.small)
                Text("正在读取，已读 \(browser.events.count) 条").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("共 \(browser.events.count) 条").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 32)
    }

    // ---------- 内容 ----------

    private var transcript: some View {
        let items = displayItems()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = browser.transcriptError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).padding(.bottom, 10)
                    }
                    if items.isEmpty && !browser.loadingTranscript {
                        Text("这个会话里没有可显示的内容").foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            if let day = item.newDay { DaySeparator(day: day) }
                            switch item.event.kind {
                            case .user: UserTurnRow(event: item.event)
                            case .text: ReplyRow(event: item.event, agent: session.agent, showSpeaker: item.showSpeaker)
                            default: ProcessRow(event: item.event)
                            }
                        }
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(maxWidth: 820, alignment: .leading) // 窗口再宽，一行也不会长得难读
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 记下用户是不是停在底部（离底部 60 点以内都算）
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
            } action: { _, atBottom in
                isAtBottom.value = atBottom
            }
            // 读取过程中不跳动；读完后滚到最新的内容一次
            .onChange(of: browser.loadingTranscript) { _, loading in
                if !loading && scrolledSession.value != session.id, let last = items.last {
                    scrolledSession.value = session.id
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            // 之后来了新内容：用户本来就停在底部才跟着滚，正往上翻历史时不打扰
            .onChange(of: items.count) {
                if !browser.loadingTranscript && isAtBottom.value, let last = items.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// 一条要显示的内容，带上排版需要的信息：要不要先插日期线、要不要显示说话人
    private struct DisplayItem: Identifiable {
        /// 它在全部内容里的位置。内容只会往后追加，这个位置不会变，
        /// 所以切换「隐藏工具调用」后，每行的展开状态还跟着原来那一行
        let id: Int
        let event: TranscriptEvent
        let newDay: String?
        let showSpeaker: Bool
    }

    private func displayItems() -> [DisplayItem] {
        var items: [DisplayItem] = []
        var lastDay = ""
        var lastSpeaker: TranscriptKind? // 上一个说话的是「我」还是它
        for (index, event) in browser.events.enumerated() {
            if event.isClaudeCodeInternal || (hideTools && event.kind.isTool) { continue }
            let day = DayCache.day(event.time)
            let newDay = !day.isEmpty && day != lastDay ? day : nil
            if newDay != nil { lastDay = day; lastSpeaker = nil }
            // 回复的头像和名字只在每轮开头出现一次；我的提问每条都显示
            let showSpeaker = event.kind == .user || (event.kind == .text && lastSpeaker != .text)
            if event.kind == .user || event.kind == .text { lastSpeaker = event.kind }
            items.append(DisplayItem(id: index, event: event, newDay: newDay, showSpeaker: showSpeaker))
        }
        return items
    }
}

/// 日期换算有点慢，几千条内容每次刷新都算一遍会卡。按「到小时」的时间前缀缓存（时区偏移都是整点）
@MainActor
private enum DayCache {
    static var cache: [Substring: String] = [:]

    static func day(_ iso: String) -> String {
        let key = iso.prefix(13) // 2026-11-10T08
        if let hit = cache[key] { return hit }
        let value = TimeText.day(iso)
        cache[key] = value
        return value
    }
}

// ---------- 各种行 ----------

/// 顶部的小标签：图标 + 文字
private struct MetaChip: View {
    let icon: String
    let text: String
    let help: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.1)))
            .help(help)
    }
}

/// 一项 token 数：上面是数字，下面是名称；悬停看精确数字
private struct TokenStat: View {
    let label: String
    let value: Int
    var strong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.short(value))
                .font(.system(size: strong ? 14 : 12, weight: strong ? .bold : .medium))
                .monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .help("\(label)：\(value.formatted()) token")
    }

    /// 1.03 亿、12.3 万、8,512
    static func short(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.2f 亿", Double(n) / 100_000_000) }
        if n >= 10_000 { return String(format: "%.1f 万", Double(n) / 10_000) }
        return n.formatted()
    }
}

/// 跨天时的日期线
private struct DaySeparator: View {
    let day: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
            Text(day).font(.caption.weight(.semibold)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
        }
        .padding(.top, 18)
        .padding(.bottom, 4)
    }
}

/// 我的提问：头像 + 名字 + 时间，内容放在浅色卡片里。特别长的（比如贴进去的文档）先收起
private struct UserTurnRow: View {
    let event: TranscriptEvent
    @StateObject private var expanded = LocalState(false)

    private var isLong: Bool { event.text.count > 1200 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(name: "我", color: Theme.you, size: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("我").font(Theme.nameFont()).foregroundStyle(Theme.you)
                    Text(TimeText.time(event.time)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.text)
                        .lineSpacing(3)
                        .lineLimit(isLong && !expanded.value ? 16 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if isLong {
                        Button(expanded.value ? "收起" : "展开全文（\(event.text.count) 字）") { expanded.value.toggle() }
                            .buttonStyle(.link).font(.caption).clickable()
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.you.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.you.opacity(0.2)))
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

/// 它的回复：每轮第一段带头像和名字，后面的段落和正文对齐
private struct ReplyRow: View {
    let event: TranscriptEvent
    let agent: AgentKind
    let showSpeaker: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showSpeaker {
                AgentAvatar(name: agent.displayName, color: Theme.color(agent), size: 26)
            } else {
                Color.clear.frame(width: 26, height: 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                if showSpeaker {
                    HStack(spacing: 8) {
                        Text(agent.displayName).font(Theme.nameFont()).foregroundStyle(Theme.color(agent))
                        Text(TimeText.time(event.time)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Text(event.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
    }
}

/// 思考、工具调用、工具结果：一行小字的摘要，点一下看全文
private struct ProcessRow: View {
    let event: TranscriptEvent
    @StateObject private var expanded = LocalState(false)

    private var icon: String {
        switch event.kind {
        case .thinking: return "brain"
        case .tool: return "wrench.and.screwdriver"
        default: return "arrow.turn.down.right"
        }
    }

    /// 工具调用的文本是「工具名 参数」，把工具名单独拿出来加粗
    private var parts: (label: String, rest: String) {
        switch event.kind {
        case .thinking: return ("思考", event.text)
        case .tool:
            let name = event.text.prefix { $0 != " " }
            return (String(name), String(event.text.dropFirst(name.count)).trimmingCharacters(in: .whitespaces))
        default: return ("结果", event.text)
        }
    }

    var body: some View {
        let (label, rest) = parts
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.value.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 10)).frame(width: 14)
                    Text(label).font(.caption.weight(.semibold))
                    if !expanded.value {
                        Text(rest.split(separator: "\n").first.map(String.init) ?? "")
                            .font(event.kind == .thinking ? .caption.italic() : .system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded.value ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickable()
            .help(expanded.value ? "收起" : "展开全文")

            if expanded.value {
                Text(rest)
                    .font(event.kind == .thinking ? .callout.italic() : .system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(event.kind == .thinking ? 0.04 : 0.07)))
        .padding(.leading, 36) // 和回复的正文对齐，一眼看出是它干活的过程
        .padding(.vertical, 2)
    }
}
