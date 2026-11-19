// 读会话记录（transcript）：只读，不改任何东西。
// Claude：~/.claude/projects/<项目>/<sessionId>.jsonl
// Codex ：~/.codex/sessions/YYYY/MM/DD/rollout-...-<sessionId>.jsonl
import Foundation

enum Transcript {
    private static let fm = FileManager.default
    private static let maxText = 3000 // 单条内容太长时截断

    /// 找到会话文件的路径，找不到返回 nil。vm 不为空时到那台虚拟机里找（只有 Claude 会话会在虚拟机里）
    static func find(agent: AgentKind, sessionId: String, vm: String = "") -> String? {
        guard !sessionId.isEmpty else { return nil }
        if !vm.isEmpty {
            guard agent == .claude else { return nil }
            // 会话 ID 作为 $1 传进去，不拼进命令里，带特殊字符也不会被 shell 当成命令
            let found = VM.output(vm, ["sh", "-c", "ls \"$HOME\"/.claude/projects/*/\"$1\".jsonl", "sh", sessionId])
            return found.flatMap { String(decoding: $0, as: UTF8.self).split(separator: "\n").first.map(String.init) }
        }
        switch agent {
        case .claude:
            let projects = "\(Config.home)/.claude/projects"
            for dir in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
                let file = "\(projects)/\(dir)/\(sessionId).jsonl"
                if fm.fileExists(atPath: file) { return file }
            }
            return nil
        case .codex:
            // 实测桌面端的会话会分段：后来的记录写进新文件，旧文件不再更新。取最后修改的那个（正在写的那一段）
            return codexSessionFiles(sessionId: sessionId).last
        }
    }

    /// Claude 会话最近一次是在哪种系统上运行的：物理机 "darwin"，虚拟机 "linux"，找不到返回空。
    /// 虚拟机的 ~/.claude/projects 是指向物理机的软链接（ExitBox 在 2026-11-16 改的），两边的会话文件放在同一个目录里，
    /// 「文件在哪台机器上找得到」已经分不出会话属于谁，只能看会话自己的记录：
    /// Claude 只在会话启动、resume 时写一条 environment 记录，里面有 platform，取最后一条（在另一台机器上 resume 过的话，以最近一次为准）。
    ///
    /// 这条记录常常在文件中间，所有会话加起来有几个 GB，每次都扫一遍太慢。会话文件只会往后追加，
    /// 所以记住每个文件扫到了哪里、当时的结果，下次只扫新写的部分。第一次扫用内存映射、从末尾往前找，只读到找到为止。
    static func lastClaudePlatform(file: String) -> String {
        platformLock.lock()
        let cached = platformCache[file]
        platformLock.unlock()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .alwaysMapped) else { return "" }
        var start = cached?.scannedTo ?? 0
        if start > data.count { start = 0 } // 文件变短了（被重写过）：从头再扫
        // 只扫到最后一个换行：最后一行可能还没写完，留到下次再看
        guard let lastNewline = data[start...].lastIndex(of: 0x0A) else { return cached?.platform ?? "" }
        let scanned = start..<(lastNewline + 1)

        var platform = cached?.platform ?? ""
        // 只认未转义的 "type":"environment"：会话内容里引用到的同样文字在 JSON 字符串里是 \"type\":\"environment\"，不会误中
        if let env = data.range(of: Data("\"type\":\"environment\"".utf8), options: .backwards, in: scanned) {
            let lineEnd = data[env.upperBound..<scanned.upperBound].firstIndex(of: 0x0A) ?? scanned.upperBound
            if let key = data.range(of: Data("\"platform\":\"".utf8), in: env.upperBound..<lineEnd),
               let end = data[key.upperBound..<lineEnd].firstIndex(of: UInt8(ascii: "\"")) {
                platform = String(decoding: data[key.upperBound..<end], as: UTF8.self)
            }
        }
        platformLock.lock()
        platformCache[file] = (scanned.upperBound, platform)
        platformLock.unlock()
        return platform
    }

    /// 会话文件路径 → （扫到第几个字节，那时最后一条记录的 platform）
    private static var platformCache: [String: (scannedTo: Int, platform: String)] = [:]
    private static let platformLock = NSLock() // 几个请求可能同时列会话

    /// 用户在 Claude 里用 /rename 起的会话名（改过多次取最后一次），没起过或读不到返回空。
    /// 会话文件可能很大，用 grep 只挑出改名记录；会话 ID 作为 $1 传进去，不拼进命令里
    static func claudeCustomTitle(sessionId: String, vm: String = "") -> String {
        guard !sessionId.isEmpty else { return "" }
        let script = "cat \"$HOME\"/.claude/projects/*/\"$1\".jsonl 2>/dev/null | grep '\"type\":\"custom-title\"' | tail -n 1"
        let data: Data?
        if vm.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script, "sh", sessionId]
            p.environment = ShellEnv.environment
            let output = Pipe()
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = output
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            data = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
        } else {
            data = VM.output(vm, ["sh", "-c", script, "sh", sessionId])
        }
        guard let data, let entry = parseJSON(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { return "" }
        return entry["customTitle"] as? String ?? ""
    }

    /// Claude 会话是不是一条记录都还没写过：确认会话记录文件不存在返回 true，存在返回 false，
    /// 查不了（虚拟机连不上、命令出错）返回 nil。find 在「不存在」和「查不了」时都返回 nil，分不出来，所以单独查。
    /// Claude 在第一条提示词提交时才建这个文件，文件不存在就说明它还没开始过任何一轮
    static func claudeSessionUnwritten(sessionId: String, vm: String = "") -> Bool? {
        guard !sessionId.isEmpty else { return nil }
        if !vm.isEmpty {
            // 每个项目目录都要能读、能进去，才能说「这里没有」；进不去的目录（权限、挂载问题）里可能就有这个文件，
            // 这时输出 error，不能当成不存在。只认整次扫描跑完后的 found / missing
            let script = """
                cd "$HOME/.claude/projects" 2>/dev/null || { echo error; exit 0; }
                # 能进去不代表能列出里面有什么：列不了的话 */ 展不开，会被误当成空目录
                { [ -r . ] && [ -x . ]; } || { echo error; exit 0; }
                for d in */; do
                  [ "$d" = "*/" ] && break
                  { [ -r "$d" ] && [ -x "$d" ]; } || { echo error; exit 0; }
                  [ -e "$d$1.jsonl" ] && { echo found; exit 0; }
                done
                echo missing
                """
            let output = VM.output(vm, ["sh", "-c", script, "sh", sessionId]).map { String(decoding: $0, as: UTF8.self) } ?? ""
            switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "missing": return true
            case "found": return false
            default: return nil
            }
        }
        let projects = "\(Config.home)/.claude/projects"
        guard let dirs = try? fm.contentsOfDirectory(atPath: projects) else { return nil }
        for dir in dirs {
            let path = "\(projects)/\(dir)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil } // 列出来了却看不到：查不了
            guard isDir.boolValue else { continue }                                   // 不是目录（零散文件）不用看
            // 进不去的目录：里面可能就有这个文件，说不清
            guard access(path, R_OK | X_OK) == 0 else { return nil }
            if fm.fileExists(atPath: "\(path)/\(sessionId).jsonl") { return false }
        }
        return true
    }

    /// Codex 会话的所有分段文件，按最后修改时间从早到晚排（最后一个是正在写的那一段）。
    /// Codex 按日期分目录；桌面端的会话写满一段后会接着写新文件「rollout-…-<sessionId>_<分段id>.jsonl」，
    /// 旧文件不再更新，而且新段并不包含旧段的全部内容
    static func codexSessionFiles(sessionId: String) -> [String] {
        guard !sessionId.isEmpty else { return [] }
        let root = "\(Config.home)/.codex/sessions"
        guard let walker = fm.enumerator(atPath: root) else { return [] }
        var files: [(path: String, modified: Date)] = []
        for case let path as String in walker where path.hasSuffix(".jsonl") && path.contains(sessionId) {
            let full = "\(root)/\(path)"
            files.append((full, (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date) ?? .distantPast))
        }
        return files.sorted { $0.modified < $1.modified }.map(\.path)
    }

    /// 从会话文件里读出工作目录
    static func readCwd(agent: AgentKind, file: String, vm: String = "") -> String {
        for line in readLines(file, from: 0, maxBytes: 200 * 1024, vm: vm).lines {
            guard let entry = parseJSON(line) else { continue }
            if agent == .claude, let cwd = entry["cwd"] as? String { return cwd }
            if agent == .codex, entry["type"] as? String == "session_meta" {
                return (entry["payload"] as? [String: Any])?["cwd"] as? String ?? ""
            }
        }
        return ""
    }

    /// 文件里第一次出现 text 的那一行从第几个字节开始；没找到返回 nil
    static func lineOffset(of text: String, in file: String, vm: String = "") -> Int? {
        if !vm.isEmpty {
            // grep -b 输出「行首字节偏移:整行」，-F 按普通字符串找（[ ] # 不当正则），-m1 找到第一处就停。
            // 在虚拟机里用 cut 只留偏移数字：那一行可能有好几 MB（贴了截图），不要整行传回来
            let output = VM.output(vm, ["sh", "-c", "grep -b -F -m1 -- \"$1\" \"$2\" | cut -d: -f1", "sh", text, file])
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let data = fm.contents(atPath: file), let found = data.range(of: Data(text.utf8)) else { return nil }
        // 往前找到这一行的开头（上一个换行符之后）
        let lineStart = data[data.startIndex..<found.lowerBound].lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex
        return lineStart - data.startIndex
    }

    static func fileSize(_ file: String, vm: String = "") -> Int {
        if !vm.isEmpty {
            let text = VM.output(vm, ["stat", "-c", "%s", file]).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return ((try? fm.attributesOfItem(atPath: file))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// 从 offset 字节开始读新增内容，转成统一格式的事件。
    /// fullText 为 true 时（会话浏览）对话和思考保留全文，只截断工具调用和工具结果；否则每条都截断
    static func readEvents(agent: AgentKind, file: String, offset: Int, vm: String = "", fullText: Bool = false) -> TranscriptChunk {
        let (lines, next) = readLines(file, from: offset, vm: vm)
        var events: [TranscriptEvent] = []
        var tokens = TokenTally()
        for line in lines {
            guard let entry = parseJSON(line) else { continue }
            let parsed = agent == .claude ? parseClaude(entry) : parseCodex(entry)
            for event in parsed where !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let isTool = event.kind == .tool || event.kind == .toolResult
                events.append(fullText && !isTool ? event : TranscriptEvent(time: event.time, kind: event.kind, text: clip(event.text)))
            }
            if agent == .claude { tokens.addClaude(entry) } else { tokens.addCodex(entry) }
        }
        return TranscriptChunk(events: events, offset: next, models: tokens.models,
                               usageByMessage: agent == .claude ? tokens.claudeByMessage : nil, usageTotal: tokens.codexTotal,
                               source: file)
    }

    /// 一段会话里的模型和 token 用量
    private struct TokenTally {
        var models: [String] = []
        var claudeByMessage: [String: TokenUsage] = [:] // Claude：回复 ID → 用量
        var codexTotal: TokenUsage?                       // Codex：最后一次记录的累计总量

        mutating func addModel(_ name: String) {
            // <synthetic> 是 Claude Code 自己生成的提示（比如出错说明），不是真的模型
            if !name.isEmpty && name != "<synthetic>" && !models.contains(name) { models.append(name) }
        }

        /// Claude 一条回复会拆成好几行（每段文字、每个工具调用各一行），每行都带着同一份用量；
        /// 压缩上下文后还会把之前的回复再记一遍。所以按回复 ID 记，重复的合并成一条。
        /// 重记的那份用量有时是 0，所以同一个 ID 取用量最大的那份
        mutating func addClaude(_ entry: [String: Any]) {
            guard entry["type"] as? String == "assistant", let message = entry["message"] as? [String: Any] else { return }
            addModel(message["model"] as? String ?? "")
            guard let u = message["usage"] as? [String: Any],
                  let id = message["id"] as? String ?? entry["uuid"] as? String else { return }
            let usage = TokenUsage(input: u["input_tokens"] as? Int ?? 0,
                                   cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                                   cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0,
                                   output: u["output_tokens"] as? Int ?? 0)
            if usage.total >= claudeByMessage[id]?.total ?? 0 { claudeByMessage[id] = usage }
        }

        /// Codex：模型记在每轮开头的 turn_context 里；token_count 记的是累计总量，
        /// 同一个数会重复记好几次，所以不能逐条相加，取最后一次就行。
        /// Codex 的 input_tokens 里已经包含了走缓存的部分，这里拆开，和 Claude 的口径一致
        mutating func addCodex(_ entry: [String: Any]) {
            let payload = entry["payload"] as? [String: Any] ?? [:]
            if entry["type"] as? String == "turn_context" { addModel(payload["model"] as? String ?? "") }
            guard payload["type"] as? String == "token_count",
                  let total = (payload["info"] as? [String: Any])?["total_token_usage"] as? [String: Any] else { return }
            // input_tokens 是全部输入，读缓存、写缓存都是它的一部分
            let input = total["input_tokens"] as? Int ?? 0
            let cached = total["cached_input_tokens"] as? Int ?? 0
            let written = total["cache_write_input_tokens"] as? Int ?? 0
            codexTotal = TokenUsage(input: max(0, input - cached - written), cacheRead: cached, cacheWrite: written,
                                    output: total["output_tokens"] as? Int ?? 0)
        }
    }

    /// 从 Claude 会话最近一段记录里，找授权已经处理过的证据（只看主线，不含子 agent）：
    /// - resultIds：已经有 tool_result 的 tool_use_id。批准和拒绝授权都会写 tool_result，所以它只能说明「授权框没了」；
    /// - endedByInterrupt：主线上最后一条有意义的记录是打断标记（拒绝授权时是「[Request interrupted by user for tool use]」），
    ///   说明这一轮已经结束。之后只要出现 assistant 回复或者新的用户消息，旧的打断证据就作废。
    ///   拒绝授权不触发任何 hook，只能靠它判断回合结束
    static func claudePermissionEvidence(file: String, vm: String = "") -> (resultIds: Set<String>, endedByInterrupt: Bool) {
        let markers: Set<String> = ["[Request interrupted by user]", "[Request interrupted by user for tool use]"]
        let (lines, _) = readLines(file, from: max(0, fileSize(file, vm: vm) - 256 * 1024), vm: vm)
        var ids = Set<String>()
        var endedByInterrupt = false
        for line in lines {
            guard let entry = parseJSON(line), entry["isSidechain"] as? Bool != true else { continue }
            let type = entry["type"] as? String
            if type == "assistant" { endedByInterrupt = false } // 又有了新回复：这一轮在继续，或者已经开始了新一轮
            guard type == "user", let message = entry["message"] as? [String: Any] else { continue }
            // 用户消息的 content 可能是纯文本，也可能是分段的数组
            let parts = message["content"] as? [[String: Any]] ?? [["type": "text", "text": message["content"] as? String ?? ""]]
            for part in parts {
                switch part["type"] as? String {
                case "tool_result":
                    if let id = part["tool_use_id"] as? String { ids.insert(id) }
                case "text":
                    // 精确匹配两种打断标记；其他文字是新的用户消息，新一轮开始了，旧的打断证据作废
                    endedByInterrupt = markers.contains(part["text"] as? String ?? "")
                default:
                    break
                }
            }
        }
        return (ids, endedByInterrupt)
    }

    /// Claude 会话的主回合是不是已经结束（只看主线，不含子 agent），给 hook 状态未知时兜底：
    /// - 最后一条有意义的记录是 assistant，带着明确的结束标记（stop_reason 是 end_turn / stop_sequence），
    ///   并且没有要调用的工具 → 结束。还在思考、正在输出的记录 stop_reason 是空的，不算结束；
    /// - 最后是打断标记（拒绝授权、按了 Esc）→ 结束；
    /// - 最后是工具结果、或者新的用户消息 → 还在进行；
    /// - 上下文压缩后写入的摘要（isCompactSummary）不是新消息，跳过，沿用压缩前的状态：
    ///   空闲时自动压缩，压缩前是正常结束 → 仍然空闲；干活中途压缩，压缩前是工具结果 → 仍在进行；
    /// - 读不到任何记录 → nil（未知）
    static func claudeTurnEnded(file: String, vm: String = "") -> Bool? {
        let markers: Set<String> = ["[Request interrupted by user]", "[Request interrupted by user for tool use]"]
        let size = fileSize(file, vm: vm)
        // 先看最后 256KB。里面一条能判断状态的记录都没有时（比如末尾只有一大段压缩摘要和附件），
        // 把窗口扩大到 4 倍重新读，直到找到或者读到文件开头
        var window = 256 * 1024
        while true {
            let start = max(0, size - window)
            if let ended = claudeTurnEnded(lines: readLines(file, from: start, maxBytes: size - start, vm: vm).lines, markers: markers) {
                return ended
            }
            if start == 0 { return nil }
            window *= 4
        }
    }

    /// 按顺序看一段记录，返回最后一条能判断状态的记录说明的结果；没有这样的记录返回 nil
    private static func claudeTurnEnded(lines: [String], markers: Set<String>) -> Bool? {
        var ended: Bool?
        for line in lines {
            guard let entry = parseJSON(line), entry["isSidechain"] as? Bool != true, entry["isCompactSummary"] as? Bool != true,
                  let message = entry["message"] as? [String: Any] else { continue }
            let parts = message["content"] as? [[String: Any]] ?? [["type": "text", "text": message["content"] as? String ?? ""]]
            switch entry["type"] as? String {
            case "assistant":
                let stop = message["stop_reason"] as? String ?? ""
                ended = ["end_turn", "stop_sequence"].contains(stop) && !parts.contains { $0["type"] as? String == "tool_use" }
            case "user":
                if parts.contains(where: { $0["type"] as? String == "tool_result" }) {
                    ended = false
                } else if let text = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
                    ended = markers.contains(text)
                }
            default:
                break
            }
        }
        return ended
    }

    /// 某一轮（按 promptId 认）现在怎么样了，第 6 步第二期打断用（见 Interrupt.swift）
    enum ClaudeTurnOutcome: Equatable {
        case running(hasAssistant: Bool) // 还在进行；hasAssistant：这一轮已经有 assistant 回复了
        case interrupted                 // 这一轮被打断了（有它自己的打断标记）
        case natural                     // 这一轮自己正常结束了
        case superseded                  // 后面已经开了新的一轮
    }

    /// 按 promptId 判断 Claude 的某一轮现在怎么样了。实测（Claude 2.1.322）：
    /// - 这一轮所有 user 记录（提示词、tool_result、打断标记）都带同一个 promptId；assistant 记录不带，
    ///   要顺着 parentUuid 往上找到第一条 user 记录，看它的 promptId，才知道是哪一轮的（不按文件位置猜）；
    /// - 打断标记是 content 里 type=text 的一段，整段等于两种固定文字之一，正文里引用这句话不算；
    /// - 文件里在它之后出现了别的 promptId 的 user 记录 = 开了新的一轮（包括后台命令结束后 Claude 自己开的
    ///   task-notification 那一轮）。
    /// 只看主线（子 agent 的 isSidechain 记录不算），压缩摘要不算。
    /// 证据要严格：读到的必须是完整的行（最后一行写完了）、每一行都能解析，读的期间文件没变短；
    /// 还要读到这一轮的起点（它真正的提示词），没读到就把窗口往前扩大。任何一项不满足都返回 nil：
    /// 证据不足，调用方不按、不结算
    static func claudeTurnOutcome(file: String, vm: String = "", promptId: String) -> ClaudeTurnOutcome? {
        claudeTurnEvidence(file: file, vm: vm, promptId: promptId)?.outcome
    }

    struct ClaudeTurnEvidence {
        let outcome: ClaudeTurnOutcome
        let version: [Int]? // 这一轮 user 记录上写的 Claude 版本（正在跑的进程的版本，核心重启后也拿得到）
        let size: Int       // 这次读到的文件大小（正好落在完整的行尾），按键前记下它，之后只认这个位置之后的结束证据
    }

    /// 同上，另外带回版本和读到的文件大小。
    /// after：只认这个字节位置之后写下的结束证据（打断标记、正常结束）；nil = 不限制。文件比它还短（被截断、换了）返回 nil
    static func claudeTurnEvidence(file: String, vm: String = "", promptId: String, after: Int? = nil) -> ClaudeTurnEvidence? {
        guard !promptId.isEmpty else { return nil }
        let size = fileSize(file, vm: vm)
        guard size > 0 else { return nil }
        if let after, after > size { return nil }
        // 先看最后 256KB，没读到这一轮的起点就把窗口扩大 4 倍，直到读到文件开头
        var window = 256 * 1024
        while true {
            let start = max(0, size - window)
            guard let lines = completeLines(file, from: start, to: size, vm: vm) else { return nil }
            switch scanTurn(lines, target: promptId, after: after) {
            case .bad:
                return nil
            case .found(let outcome, let version):
                return ClaudeTurnEvidence(outcome: outcome, version: version, size: size)
            case .notStarted:
                if start == 0 { return nil }
                window *= 4
            }
        }
    }

    /// 读文件的 [from, to) 这一段，切成带起始字节位置的行。必须正好读满、并且以换行结尾（最后一行写完整了），
    /// 否则返回 nil（读失败、文件在读的期间变短、末尾还有半行没写完）。
    /// from 不在文件开头时，窗口可能切在一行中间，第一段丢掉不用
    private static func completeLines(_ file: String, from: Int, to: Int, vm: String) -> [(offset: Int, text: String)]? {
        let count = to - from
        guard count > 0 else { return nil }
        let data: Data
        if vm.isEmpty {
            guard let handle = FileHandle(forReadingAtPath: file) else { return nil }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(from))) != nil else { return nil }
            data = handle.readData(ofLength: count)
        } else {
            guard let out = VM.output(vm, ["sh", "-c", "tail -c +\"$2\" \"$1\" | head -c \"$3\"", "sh", file, String(from + 1), String(count)]) else {
                return nil
            }
            data = out
        }
        guard data.count == count, data.last == 0x0A else { return nil }
        var lines: [(offset: Int, text: String)] = []
        var lineStart = data.startIndex
        var skipFirst = from > 0
        for i in data.indices where data[i] == 0x0A {
            if skipFirst {
                skipFirst = false
            } else if i > lineStart {
                lines.append((from + (lineStart - data.startIndex), String(decoding: data[lineStart..<i], as: UTF8.self)))
            }
            lineStart = i + 1
        }
        return lines
    }

    private enum TurnScan {
        case bad                                    // 有解析不了的行
        case notStarted                             // 窗口里还没读到这一轮的起点
        case found(ClaudeTurnOutcome, [Int]?)
    }

    private static func scanTurn(_ lines: [(offset: Int, text: String)], target: String, after: Int?) -> TurnScan {
        let markers: Set<String> = ["[Request interrupted by user]", "[Request interrupted by user for tool use]"]
        var records: [String: (type: String, parent: String?, promptId: String)] = [:] // uuid → 记录类型、parentUuid、promptId
        var started = false // 读到了这一轮的起点（它真正的提示词：不是 tool_result，也不是打断标记）
        var newer = false
        var interrupted = false
        // 这一轮最后一条对话记录：assistant 的话记下它是不是正常结束（有结束标记、没有要调用的工具），以及它在文件里的位置
        var lastInTurn: (isAssistant: Bool, endedCleanly: Bool, offset: Int)?
        var hasAssistant = false
        var version: [Int]? // 这一轮 user 记录上写的 Claude 版本，形如 2.1.322
        let isAfter = { (offset: Int) in after.map { offset >= $0 } ?? true }

        /// assistant 记录属于哪一轮：顺着 parentUuid 往上，第一条 user 记录的 promptId（最多找 50 级，记录残缺时不绕圈）
        func turnOf(parent: String?) -> String? {
            var current = parent
            for _ in 0..<50 {
                guard let uuid = current, let record = records[uuid] else { return nil }
                if record.type == "user" { return record.promptId }
                current = record.parent
            }
            return nil
        }

        for (offset, line) in lines {
            // 有解析不了的行：说不清主线上发生了什么，整个结论作废
            guard let entry = parseJSON(line) else { return .bad }
            guard entry["isSidechain"] as? Bool != true, entry["isCompactSummary"] as? Bool != true else { continue }
            let type = entry["type"] as? String ?? ""
            let uuid = entry["uuid"] as? String
            let parent = entry["parentUuid"] as? String
            let recordPromptId = entry["promptId"] as? String ?? ""
            if let uuid { records[uuid] = (type, parent, recordPromptId) }
            guard let message = entry["message"] as? [String: Any] else { continue }
            let parts = message["content"] as? [[String: Any]] ?? [["type": "text", "text": message["content"] as? String ?? ""]]
            switch type {
            case "user":
                if recordPromptId == target {
                    let isToolResult = parts.contains { $0["type"] as? String == "tool_result" }
                    let isMarker = parts.contains { $0["type"] as? String == "text" && markers.contains($0["text"] as? String ?? "") }
                    if !isToolResult && !isMarker { started = true }
                    guard started else { continue } // 起点之前的同轮记录（窗口切在这一轮中间）不算，扩大窗口再读
                    if let text = entry["version"] as? String {
                        let numbers = text.split(separator: ".").compactMap { Int($0) }
                        if numbers.count == 3 { version = numbers }
                    }
                    if isMarker && isAfter(offset) { interrupted = true }
                    lastInTurn = (false, false, offset)
                } else if started && !recordPromptId.isEmpty {
                    newer = true
                }
            case "assistant":
                guard started, turnOf(parent: parent) == target else { continue }
                hasAssistant = true
                let stop = message["stop_reason"] as? String ?? ""
                let clean = ["end_turn", "stop_sequence"].contains(stop) && !parts.contains { $0["type"] as? String == "tool_use" }
                lastInTurn = (true, clean, offset)
            default:
                break
            }
        }
        guard started else { return .notStarted }
        let outcome: ClaudeTurnOutcome
        if newer {
            outcome = .superseded
        } else if interrupted {
            outcome = .interrupted
        } else if let last = lastInTurn, last.isAssistant, last.endedCleanly, isAfter(last.offset) {
            outcome = .natural
        } else {
            outcome = .running(hasAssistant: hasAssistant)
        }
        return .found(outcome, version)
    }

    /// 文件身份（inode）：按键前记下，结算时核对没换文件。读不到返回 nil
    static func fileIdentity(_ file: String, vm: String = "") -> String? {
        if !vm.isEmpty {
            let text = VM.output(vm, ["stat", "-c", "%i", file]).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let inode = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return inode.isEmpty ? nil : inode
        }
        return ((try? fm.attributesOfItem(atPath: file))?[.systemFileNumber] as? NSNumber)?.stringValue
    }

    /// Claude 会话最近一段记录里，主线上的用户消息（不含工具结果、不含子 agent），确认投递和观察开工时用：
    /// - text：消息原文。经中转会话（SendMessage）送来的，原文在 origin.body 里（实测：type=user、isMeta、origin.kind=peer）；
    /// - answered：有 assistant 回复在回应这一条，说明对方已经开始处理它。判断方法：从每条 assistant 记录顺着 parentUuid
    ///   往上找，跳过中间的 attachment 等非对话记录（实测用户消息和第一条回复之间常夹着一条 attachment），
    ///   找到的第一条对话记录（user / assistant）正好是这条用户消息才算。
    ///   不能只看「后面出现了 assistant」：旧一轮还在输出的片段也排在后面，但往上找会先碰到旧的 assistant 记录
    /// - tag：投递编号（如 [kk#11]）。对方收到后可能又干了很久，那条消息早已不在文件末尾，
    ///   所以先找到编号第一次出现的那一行，从那里一段段读到文件末尾（第一次出现的可能只是别的消息引用了这个编号，
    ///   真正的那条在更后面）；文件里没有这个编号就不用读了
    static func claudeUserRecords(file: String, vm: String = "", tag: String) -> [(text: String, answered: Bool)] {
        guard var offset = lineOffset(of: tag, in: file, vm: vm) else { return [] }
        var users: [(uuid: String, text: String)] = []
        var parents: [String: (type: String, parent: String?)] = [:] // uuid → 记录类型和它的 parentUuid
        var assistantParents: [String] = []                          // 每条 assistant 记录的 parentUuid
        var lines: [String] = []
        while true {
            // 一次最多读 5MB。超长的一行 readLines 会跳过去（返回空但偏移往前走），所以读到空不代表读完了，
            // 偏移不再前进才是到了文件末尾
            let chunk = readLines(file, from: offset, vm: vm)
            lines += chunk.lines
            if chunk.offset <= offset { break }
            offset = chunk.offset
        }
        for line in lines {
            guard let entry = parseJSON(line), entry["isSidechain"] as? Bool != true else { continue }
            let type = entry["type"] as? String ?? ""
            if let uuid = entry["uuid"] as? String { parents[uuid] = (type, entry["parentUuid"] as? String) }
            if type == "assistant" {
                if let parent = entry["parentUuid"] as? String { assistantParents.append(parent) }
                continue
            }
            guard type == "user", let uuid = entry["uuid"] as? String, let message = entry["message"] as? [String: Any] else { continue }
            if let origin = entry["origin"] as? [String: Any], origin["kind"] as? String == "peer", let body = origin["body"] as? String {
                users.append((uuid, body))
            } else if let text = message["content"] as? String {
                users.append((uuid, text))
            } else if let parts = message["content"] as? [[String: Any]] {
                let text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !text.isEmpty { users.append((uuid, text)) }
            }
        }
        // 每条 assistant 往上找到的第一条对话记录，就是它回应的那一条（最多往上找 20 级，防止记录残缺时绕圈）
        var answeredUuids = Set<String>()
        for start in assistantParents {
            var current: String? = start
            for _ in 0..<20 {
                guard let uuid = current, let record = parents[uuid] else { break }
                if record.type == "user" || record.type == "assistant" {
                    if record.type == "user" { answeredUuids.insert(uuid) }
                    break
                }
                current = record.parent // attachment 等非对话记录：接着往上找
            }
        }
        return users.map { ($0.text, answeredUuids.contains($0.uuid)) }
    }

    struct ClaudeLive {
        var live = false
        var status = ""
        var name = "" // 会话之间互发消息用的地址，中转投递要用
    }

    /// Claude 会话是否正开在终端或 VSCode 里：看 ~/.claude/sessions/<pid>.json 的登记，并确认进程还活着
    static func claudeLiveStatus(sessionId: String, vm: String = "") -> ClaudeLive {
        if !vm.isEmpty { return vmClaudeLiveStatus(sessionId: sessionId, vm: vm) }
        let dir = "\(Config.home)/.claude/sessions"
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".json") {
            guard let data = fm.contents(atPath: "\(dir)/\(name)"),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  info["sessionId"] as? String == sessionId,
                  let pid = info["pid"] as? Int32 ?? (info["pid"] as? Int).map(Int32.init),
                  kill(pid, 0) == 0 // 信号 0 不会真的发信号，只检查进程在不在
            else { continue }
            return ClaudeLive(live: true, status: info["status"] as? String ?? "", name: info["name"] as? String ?? "")
        }
        return ClaudeLive()
    }

    /// 虚拟机里的同一件事：进程在不在只有虚拟机自己知道，所以让它把「进程还活着」的登记文件一行一个打出来，这边再挑
    private static func vmClaudeLiveStatus(sessionId: String, vm: String) -> ClaudeLive {
        // 登记文件名就是进程号（<pid>.json）；结尾的 true 保证最后一个进程不在时命令也算成功
        let script = """
            for f in "$HOME"/.claude/sessions/*.json; do
              name=${f##*/}
              kill -0 "${name%.json}" 2>/dev/null && cat "$f" && echo
            done
            true
            """
        let text = VM.output(vm, ["sh", "-c", script]).map { String(decoding: $0, as: UTF8.self) } ?? ""
        for line in text.split(separator: "\n") {
            guard let info = parseJSON(String(line)), info["sessionId"] as? String == sessionId else { continue }
            return ClaudeLive(live: true, status: info["status"] as? String ?? "", name: info["name"] as? String ?? "")
        }
        return ClaudeLive()
    }

    // ---------- 两种格式的解析 ----------

    private static func parseClaude(_ entry: [String: Any]) -> [TranscriptEvent] {
        guard let type = entry["type"] as? String, type == "user" || type == "assistant" else { return [] }
        let time = entry["timestamp"] as? String ?? ""
        let content = (entry["message"] as? [String: Any])?["content"]
        let textKind: TranscriptKind = type == "user" ? .user : .text
        if let text = content as? String { return [TranscriptEvent(time: time, kind: textKind, text: text)] }
        guard let parts = content as? [[String: Any]] else { return [] }

        var events: [TranscriptEvent] = []
        for part in parts {
            switch part["type"] as? String {
            case "text":
                events.append(TranscriptEvent(time: time, kind: textKind, text: part["text"] as? String ?? ""))
            case "thinking":
                events.append(TranscriptEvent(time: time, kind: .thinking, text: part["thinking"] as? String ?? ""))
            case "tool_use":
                // withoutEscapingSlashes：路径显示成 /Users/name，而不是 \/Users\/name
                let input = (try? JSONSerialization.data(withJSONObject: part["input"] ?? [:], options: .withoutEscapingSlashes))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                events.append(TranscriptEvent(time: time, kind: .tool, text: "\(part["name"] as? String ?? "") \(input)"))
            case "tool_result":
                events.append(TranscriptEvent(time: time, kind: .toolResult, text: stringify(part["content"])))
            default:
                break
            }
        }
        return events
    }

    private static func parseCodex(_ entry: [String: Any]) -> [TranscriptEvent] {
        guard entry["type"] as? String == "response_item", let p = entry["payload"] as? [String: Any] else { return [] }
        let time = entry["timestamp"] as? String ?? ""
        switch p["type"] as? String {
        case "message":
            let role = p["role"] as? String
            guard role == "user" || role == "assistant" else { return [] } // developer 等系统消息不显示
            let text = ((p["content"] as? [[String: Any]]) ?? []).map { $0["text"] as? String ?? "" }.joined(separator: "\n")
            // Codex 会把环境信息、AGENTS.md 指令也作为 user 消息塞进去，这些不显示
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if role == "user" && (trimmed.hasPrefix("<") || trimmed.hasPrefix("# AGENTS.md")) { return [] }
            return [TranscriptEvent(time: time, kind: role == "user" ? .user : .text, text: text)]
        case "reasoning":
            let text = ((p["summary"] as? [[String: Any]]) ?? []).map { $0["text"] as? String ?? "" }.joined(separator: "\n")
            return [TranscriptEvent(time: time, kind: .thinking, text: text)]
        case "function_call", "custom_tool_call", "local_shell_call":
            let name = p["name"] as? String ?? (p["type"] as? String ?? "")
            let args = p["arguments"] as? String ?? p["input"] as? String ?? stringify(p["action"])
            return [TranscriptEvent(time: time, kind: .tool, text: "\(name) \(args)")]
        case "function_call_output", "custom_tool_call_output":
            return [TranscriptEvent(time: time, kind: .toolResult, text: stringify(p["output"]))]
        default:
            return []
        }
    }

    // ---------- 小工具 ----------

    /// 从 offset 开始读，只返回完整的行（最后半行留到下次读）。Readiness.swift 跟踪 Codex 回合时也用它
    static func readLines(_ file: String, from offset: Int, maxBytes: Int = 5 * 1024 * 1024, vm: String = "") -> (lines: [String], offset: Int) {
        let data: Data
        if vm.isEmpty {
            let size = fileSize(file)
            guard offset < size, let handle = FileHandle(forReadingAtPath: file) else { return ([], min(offset, size)) }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(offset))
            data = handle.readData(ofLength: min(size - offset, maxBytes))
        } else {
            // tail -c +N 是从第 N 个字节开始（从 1 数），所以要加 1；head -c 限制一次最多读多少
            data = VM.output(vm, ["sh", "-c", "tail -c +\"$2\" \"$1\" | head -c \"$3\"", "sh", file, String(offset + 1), String(maxBytes)]) ?? Data()
        }
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            // 读满了一整段还没碰到换行：是一行超长的记录（比如贴了好几张截图），跳过这一段。
            // 下次从这里接着读，这一行剩下的部分解析不了会被丢掉，后面的内容照常显示。
            // 没读满说明到了文件末尾、最后一行还没写完，原地等下次
            return ([], data.count >= maxBytes ? offset + data.count : offset)
        }
        let text = String(decoding: data[data.startIndex..<lastNewline], as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (lines, offset + (lastNewline - data.startIndex) + 1)
    }

    static func parseJSON(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func stringify(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let parts = value as? [Any] {
            return parts.map { ($0 as? String) ?? (($0 as? [String: Any])?["text"] as? String ?? "") }.joined(separator: "\n")
        }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: .withoutEscapingSlashes) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func clip(_ text: String) -> String {
        text.count > maxText ? String(text.prefix(maxText)) + "\n…（共 \(text.count) 字，已截断）" : text
    }
}
