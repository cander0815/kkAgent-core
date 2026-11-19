// 集群子群的 coder / tester 常驻在物理机的 tmux 会话里（参考 claudeStatusLight 的做法）：
// - 会话一直在：核心重启、界面关掉都不影响；用户随时 `tmux attach -t <名字>` 进去直接交互，Ctrl-b d 退出后它接着跑。
// - coder（Claude）跑在虚拟机里：tmux 里执行 `ubx shell <虚拟机> --cd <目录> -- claude ...`，拿到的是真正的终端。
// - 投递消息：把文字粘贴进 tmux 再按回车。对方正在干活时也能当场收到（实测 Claude、Codex 都会在同一轮里一起处理），不会堆积。
import Foundation

enum Tmux {
    /// 子群成员的 tmux 会话名，比如 kk-g96pt-coder（tmux 名字里不能有 . 和 :）
    static func sessionName(groupId: String, alias: String) -> String {
        "kk-\(groupId)-\(alias)"
    }

    static func exists(_ name: String) -> Bool {
        (try? run(["has-session", "-t", name])) != nil
    }

    /// 会话是什么时候建的（精确到秒）。会话里的程序是建会话时一起启动的，所以这也是它的启动时间。会话不在返回 nil
    static func createdAt(_ name: String) -> Date? {
        guard let text = try? run(["display-message", "-p", "-t", name, "#{session_created}"]),
              let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 建会话时的窗口大小（列 × 行）。给大一点，界面不会挤成一团
    static let width = 220
    static let height = 50

    /// 新建一个后台 tmux 会话，在 cwd 里执行 command（交给 shell 解释）
    static func start(_ name: String, cwd: String, command: String) throws {
        try run(["new-session", "-d", "-s", name, "-x", "\(width)", "-y", "\(height)", "-c", cwd, command])
        log("已在 tmux 会话 \(name) 里启动：\(command.prefix(160))")
    }

    /// 没人 attach 着、窗口却比建会话时小，就放大到至少建会话时的大小（只放大、不缩小），放大了返回 true。
    /// 为什么要恢复：界面里的终端面板很窄，attach 时窗口会跟着缩到 50 来列（window-size latest），断开后 tmux 保持这个大小。
    /// 窗口太窄时几百字的消息会折成几十行，超出 Codex 输入框的高度、开头被滚出屏幕，投递就确认不了「贴完整了」。
    /// 有人 attach 着时不动，免得打乱正在看的画面。
    /// resize-window 会把这个窗口的 window-size 改成 manual（之后再 attach 就不跟着变大小了），
    /// 所以紧接着取消这个窗口自己的设置，回到全局设置（默认 latest；终端面板每次 attach 时也会再设一次 latest）
    static func restoreSizeIfDetached(_ name: String) -> Bool {
        guard let info = try? run(["display-message", "-p", "-t", name, "#{session_attached} #{window_width} #{window_height} #{session_name}"])
        else { return false }
        let fields = info.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 3).map(String.init)
        guard fields.count == 4, let attached = Int(fields[0]), let w = Int(fields[1]), let h = Int(fields[2]) else { return false }
        guard attached == 0, w < width || h < height else { return false }
        // 每一边只放大不缩小：比如原来 250×40，变成 250×50，不能把宽度缩回 220
        let (newW, newH) = (max(w, width), max(h, height))
        guard (try? run(["resize-window", "-t", name, "-x", "\(newW)", "-y", "\(newH)"])) != nil else { return false }
        _ = try? run(["set-option", "-w", "-u", "-t", name, "window-size"])
        log("tmux 会话 \(fields[3]) 的窗口被挤小了（\(w)×\(h)），已放大到 \(newW)×\(newH)")
        return true
    }

    static func kill(_ name: String) {
        if (try? run(["kill-session", "-t", name])) != nil { log("已关闭 tmux 会话 \(name)") }
    }

    /// 当前屏幕上的文字（判断界面有没有就绪、有没有弹出确认框）
    static func screen(_ name: String) -> String {
        (try? run(["capture-pane", "-p", "-t", name])) ?? ""
    }

    /// 带颜色编码的屏幕：Claude 在空输入框里显示的建议文字是变暗的（ESC[2m），靠它和真正打的字区分开
    static func styledScreen(_ name: String) -> String {
        (try? run(["capture-pane", "-e", "-p", "-t", name])) ?? ""
    }

    /// 会话里当前那个窗格的身份（窗格 id + 里面进程的 pid）。粘贴前、回车前各核对一次，
    /// 变了说明会话被重建过或者里面的程序换了，不能往里写
    static func paneIdentity(_ name: String) -> String? {
        (try? run(["display-message", "-p", "-t", name, "#{pane_id} #{pane_pid}"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把文字载入 tmux 的缓冲区（还没进对方的终端）
    static func loadBuffer(_ name: String, text: String) throws {
        try run(["load-buffer", "-b", bufferName(name), "-"], stdin: text)
    }

    /// 把缓冲区粘贴进会话，不按回车。用括号粘贴模式（-p），多行内容会作为一条消息，不会被当成一行行敲回车
    static func pasteBuffer(_ name: String) throws {
        try run(["paste-buffer", "-p", "-d", "-b", bufferName(name), "-t", name])
    }

    static func pressEnter(_ name: String) throws {
        try run(["send-keys", "-t", name, "Enter"])
    }

    /// 按一次 Esc（第 6 步：紧急消息打断对方正在跑的一轮）。只按一次，不重试
    static func pressEscape(_ name: String) throws {
        try run(["send-keys", "-t", name, "Escape"])
    }

    private static func bufferName(_ name: String) -> String { "kkagent-\(name)" }

    /// 等交互界面就绪（屏幕上出现 readyMarker），最多等 timeout 秒，就绪返回 true。
    /// Claude 第一次打开一个新目录会问「信任这个文件夹吗」：worktree 是 kkAgent 从用户自己的仓库建出来的，
    /// 这里替用户选「Yes, I trust this folder」（默认选中的是 No，所以先按一下向下键）
    /// 会话在等的期间退出了（启动失败、被解散时关掉），不再干等到超时，直接返回 false
    static func waitReady(_ name: String, readyMarker: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var answeredTrust = false
        while Date() < deadline {
            guard exists(name) else { return false }
            let text = screen(name)
            // 先看是不是信任确认框：它上面也有「❯ No, exit」，不能误当成界面已就绪
            if text.contains("Yes, I trust this folder") {
                // 确认框刚画出来时按键可能还没生效，这时按回车选中的是默认的「No, exit」，Claude 会直接退出。
                // 所以每一圈先看当前选中的是哪一项（那一行前面是 ❯）：选中了「Yes」才按回车，否则只按向下键，下一圈再看
                if !answeredTrust {
                    let yesSelected = text.split(separator: "\n")
                        .contains { $0.contains("❯") && $0.contains("Yes, I trust this folder") }
                    if yesSelected {
                        _ = try? run(["send-keys", "-t", name, "Enter"])
                        answeredTrust = true
                        log("tmux 会话 \(name)：已确认信任工作目录")
                    } else {
                        _ = try? run(["send-keys", "-t", name, "Down"])
                    }
                }
            } else if text.contains(readyMarker) {
                return true
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    // ---------- 执行 tmux 命令 ----------

    private static var bin: String { ShellEnv.which("tmux") ?? "/opt/homebrew/bin/tmux" }

    /// 跑一条 tmux 命令，返回标准输出；退出码非 0 抛错
    @discardableResult
    private static func run(_ args: [String], stdin: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.environment = ShellEnv.environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        p.standardOutput = output
        p.standardError = errors
        try p.run()
        if let stdin {
            try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        // tmux 这几个命令输出都很少，先读 stdout 再读 stderr 不会卡住
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw CoreError(message: "tmux \(args.first ?? "") 失败：\(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return out
    }
}
