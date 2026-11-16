// 会话浏览（只读）：列出物理机和虚拟机里的历史会话，给界面左边「Claude」「Codex」两个功能用。
// 每个会话只读文件开头一小段，从里面取工作目录和标题，不读全文，列表打开得快。
// 会话的完整内容走 Transcript.readEvents。
import Foundation

enum Sessions {
    private static let fm = FileManager.default
    /// 读文件开头多少字节来找标题和工作目录。
    /// Claude 的第一句用户消息一般在 16KB 左右；Codex 前面塞了很长的系统说明，要读多一点
    private static func headBytes(_ agent: AgentKind) -> Int { agent == .claude ? 64 * 1024 : 256 * 1024 }

    /// 列出会话，最近修改的在前。vm 为空表示物理机；虚拟机里只有 Claude 会话
    static func list(agent: AgentKind, vm: String) -> [SessionSummary] {
        let items: [SessionSummary]
        if !vm.isEmpty {
            items = agent == .claude ? listClaudeInVM(vm) : []
        } else {
            items = agent == .claude ? listClaudeLocal() : listCodexLocal()
        }
        return items.sorted { $0.updatedAt > $1.updatedAt }
    }

    // ---------- 物理机 ----------

    /// ~/.claude/projects/<项目>/<会话ID>.jsonl（子目录里的是子任务的记录，不算会话）
    private static func listClaudeLocal() -> [SessionSummary] {
        let root = "\(Config.home)/.claude/projects"
        var result: [SessionSummary] = []
        for dir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for name in (try? fm.contentsOfDirectory(atPath: "\(root)/\(dir)")) ?? [] where name.hasSuffix(".jsonl") {
                let file = "\(root)/\(dir)/\(name)"
                guard let info = localFileInfo(file) else { continue }
                // Claude 再多读文件末尾一段：开头是大图片时第一句话读不到，要靠末尾的「最近一句提问」当标题
                let head = readHead(file, bytes: headBytes(.claude)) + Data("\n".utf8) + readTail(file, bytes: headBytes(.claude))
                result.append(summarize(agent: .claude, id: String(name.dropLast(6)), vm: "",
                                        head: head, size: info.size, modified: info.modified))
            }
        }
        return result
    }

    /// ~/.codex/sessions/YYYY/MM/DD/rollout-<时间>-<会话ID>.jsonl；会话名在 ~/.codex/session_index.jsonl 里
    private static func listCodexLocal() -> [SessionSummary] {
        let root = "\(Config.home)/.codex/sessions"
        let names = codexThreadNames()
        var result: [SessionSummary] = []
        guard let walker = fm.enumerator(atPath: root) else { return [] }
        for case let path as String in walker where path.hasSuffix(".jsonl") {
            let file = "\(root)/\(path)"
            // 文件名最后 36 个字符就是会话 ID（标准 UUID 长度）
            let id = String(path.dropLast(6).suffix(36))
            guard let info = localFileInfo(file) else { continue }
            var item = summarize(agent: .codex, id: id, vm: "", head: readHead(file, bytes: headBytes(.codex)),
                                 size: info.size, modified: info.modified)
            if let name = names[id], !name.isEmpty {
                item = SessionSummary(id: item.id, agent: .codex, vm: "", title: name, cwd: item.cwd,
                                      updatedAt: item.updatedAt, size: item.size)
            }
            result.append(item)
        }
        return result
    }

    /// Codex 桌面端给每个会话起的名字：会话 ID → 名字（同一个会话改过名的，以后面的为准）
    static func codexThreadNames() -> [String: String] {
        guard let data = fm.contents(atPath: "\(Config.home)/.codex/session_index.jsonl") else { return [:] }
        var names: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let entry = Transcript.parseJSON(String(line)), let id = entry["id"] as? String else { continue }
            names[id] = entry["thread_name"] as? String ?? ""
        }
        return names
    }

    // ---------- 虚拟机 ----------

    /// 虚拟机里的文件这边读不到，让虚拟机一次把所有会话的「路径、大小、修改时间 + 文件开头和末尾」打出来。
    /// 每个文件前面用一行 \036 开头的标记隔开（\036 是 ASCII 里的记录分隔符，正常 JSON 里不会出现）
    private static func listClaudeInVM(_ vm: String) -> [SessionSummary] {
        let script = """
            for f in "$HOME"/.claude/projects/*/*.jsonl; do
              [ -f "$f" ] || continue
              printf '\\036%s\\t%s\\t%s\\n' "$f" "$(stat -c %s "$f")" "$(stat -c %Y "$f")"
              head -c "$1" "$f"
              echo
              tail -c "$1" "$f"
              echo
            done
            true
            """
        guard let data = VM.output(vm, ["sh", "-c", script, "sh", String(headBytes(.claude))]) else { return [] }

        var result: [SessionSummary] = []
        // 按标记把输出切成一个个文件：标记行之后到下一个标记之前，都是这个文件的开头内容
        for block in String(decoding: data, as: UTF8.self).components(separatedBy: "\u{1E}").dropFirst() {
            guard let headerEnd = block.firstIndex(of: "\n") else { continue }
            let header = block[..<headerEnd].split(separator: "\t").map(String.init)
            guard header.count == 3, let size = Int(header[1]), let epoch = Double(header[2]) else { continue }
            let id = String((header[0] as NSString).lastPathComponent.dropLast(6))
            let head = Data(block[block.index(after: headerEnd)...].utf8)
            result.append(summarize(agent: .claude, id: id, vm: vm, head: head, size: size,
                                    modified: Date(timeIntervalSince1970: epoch)))
        }
        return result
    }

    // ---------- 从文件开头（和末尾）取标题和工作目录 ----------

    private static func summarize(agent: AgentKind, id: String, vm: String, head: Data, size: Int, modified: Date) -> SessionSummary {
        var title = ""
        var customTitle = "" // 用户用 /rename 起的名字，改过多次的取最后一次，优先用
        var lastPrompt = ""  // Claude 记的「最近一句提问」，找不到第一句话时用它
        var cwd = ""
        // 首尾被截断的半行解析不了会被跳过，不影响
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n") {
            guard let entry = Transcript.parseJSON(String(line)) else { continue }
            if agent == .claude {
                if cwd.isEmpty, let value = entry["cwd"] as? String { cwd = value }
                if entry["type"] as? String == "custom-title", let value = entry["customTitle"] as? String { customTitle = value }
                if entry["type"] as? String == "last-prompt", let value = entry["lastPrompt"] as? String { lastPrompt = value }
                if title.isEmpty, let text = claudeUserText(entry) { title = firstLine(text) }
            } else {
                let payload = entry["payload"] as? [String: Any] ?? [:]
                if entry["type"] as? String == "session_meta", let value = payload["cwd"] as? String { cwd = value }
                // event_msg 里的 user_message 是用户真正打的字，不含 Codex 自己塞的环境说明
                if title.isEmpty, payload["type"] as? String == "user_message", let text = payload["message"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    title = firstLine(text)
                }
            }
        }
        if !customTitle.isEmpty { title = customTitle }
        if title.isEmpty { title = firstLine(lastPrompt) }
        return SessionSummary(id: id, agent: agent, vm: vm, title: title, cwd: cwd, updatedAt: iso(modified), size: size)
    }

    /// Claude 会话里用户亲手打的一句话；系统插入的内容（isMeta、<command-name> 之类以 < 开头的）返回 nil
    private static func claudeUserText(_ entry: [String: Any]) -> String? {
        guard entry["type"] as? String == "user", entry["isMeta"] as? Bool != true else { return nil }
        let content = (entry["message"] as? [String: Any])?["content"]
        let text = (content as? String)
            ?? (content as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
            ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("<") ? nil : trimmed
    }

    /// 取第一行，最多 80 个字，用作标题
    private static func firstLine(_ text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
        return String(line.prefix(80))
    }

    // ---------- 小工具 ----------

    private static func localFileInfo(_ file: String) -> (size: Int, modified: Date)? {
        guard let attrs = try? fm.attributesOfItem(atPath: file),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return (size, modified)
    }

    private static func readHead(_ file: String, bytes: Int) -> Data {
        guard let handle = FileHandle(forReadingAtPath: file) else { return Data() }
        defer { try? handle.close() }
        return handle.readData(ofLength: bytes)
    }

    private static func readTail(_ file: String, bytes: Int) -> Data {
        guard let handle = FileHandle(forReadingAtPath: file) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return handle.readDataToEndOfFile()
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
