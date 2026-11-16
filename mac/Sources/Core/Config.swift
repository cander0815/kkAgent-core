// 核心的配置：端口、数据目录、外部命令的位置
import Foundation

enum Config {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let env = ProcessInfo.processInfo.environment

    /// kkAgent 命令行默认连 7788，不要随便改
    static let port = Int(env["KKAGENT_PORT"] ?? "") ?? 7788

    /// 数据目录，默认 ~/.kkagent（和 Node 版共用同一个数据库文件）
    static let dataDir = env["KKAGENT_DATA_DIR"] ?? "\(home)/.kkagent"
    static let dbPath = "\(dataDir)/kkagent.db"
    static let relayDir = "\(dataDir)/relay"

    /// 提示词里让 agent 执行的命令行。正式环境就是 PATH 里的 kkAgent；
    /// 测试核心设成测试专用包装的绝对路径（固定连测试端口），免得测试 agent 回消息时发到正式核心
    static let cli = env["KKAGENT_CLI"] ?? "kkAgent"

    static let codexDesktopBin = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

    /// 后台跑的 Claude 没人点权限确认，默认 auto 模式
    static let claudePermissionMode = env["KK_CLAUDE_PERMISSION_MODE"] ?? "auto"
    /// 集群 tester（Codex）的审批方式：需要越权执行（比如 wechatide 要在宿主机上跑）时可以申请。
    /// 不用 -a never（会封死申请的通道），也不用 full-access 或跳过审批
    /// - tmux 里交互运行：同样交给 Codex 的自动审查（界面上的「帮我批准」）。
    ///   原来用 -a on-request，以为 resume 会沿用建会话时的自动审查，实测不会，会停在确认框等人点
    static let codexInteractiveApproval = ["--approve-for-me"]
    /// - 后台 codex exec：没人点审批，交给 Codex 的自动审查。--approve-for-me 自带 workspace-write 沙箱，不能再加 -s
    static let codexExecApproval = ["--approve-for-me"]
    /// coder 卡在授权框上超过这么多秒还没人处理，再提醒群主一次（开始等的时候已经通知过一次）
    static let permissionRemindAfter = TimeInterval(env["KK_PERMISSION_REMIND_SECONDS"] ?? "") ?? 600
    /// 集群后台 Codex 成员的入群说明那一轮最多跑多少秒，超时直接停掉（见 Delivery.runCodexTurn）
    static let bootstrapTimeout = TimeInterval(env["KK_BOOTSTRAP_TIMEOUT"] ?? "") ?? 180
    /// 新开 tmux 会话后，最多等多少秒让界面就绪（出现输入框）。网络波动时进虚拟机、启动 claude 会慢很多，
    /// 原来的 90 秒容易误报，改成 10 分钟还不行才算失败、通知群主
    static let tmuxReadyTimeout = TimeInterval(env["KK_TMUX_READY_SECONDS"] ?? "") ?? 600
    /// 中转会话的模型：只负责调一次 SendMessage，用最便宜的
    static let relayModel = env["KK_RELAY_MODEL"] ?? "haiku"

    static var claudeBin: String {
        env["KK_CLAUDE_BIN"] ?? ShellEnv.which("claude") ?? "\(home)/.local/bin/claude"
    }

    static var codexBin: String {
        if let bin = env["KK_CODEX_BIN"] { return bin }
        if FileManager.default.fileExists(atPath: codexDesktopBin) { return codexDesktopBin }
        return ShellEnv.which("codex") ?? "codex"
    }
}

/// launchd 启动的进程拿不到终端里的环境变量（PATH、代理、nvm 的 node 等）。
/// 启动时跑一次登录 shell 把环境读出来，之后启动 claude / codex 都用这份环境，
/// 这样后台续接的 Claude 跑测试、调 kkAgent 时，能找到的命令和你在终端里一样。
enum ShellEnv {
    static let environment: [String: String] = load()

    private static func load() -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        let shell = result["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "env -0"] // -i 读 .zshrc（nvm 一般在这里），-l 读 .zprofile
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log("读取登录 shell 环境失败，用当前环境：\(error)")
            return result
        }
        // 最多等 10 秒，shell 配置卡住也不影响核心启动
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            log("读取登录 shell 环境超时，用当前环境")
            return result
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        for entry in data.split(separator: 0) {
            guard let text = String(data: entry, encoding: .utf8), let eq = text.firstIndex(of: "=") else { continue }
            result[String(text[..<eq])] = String(text[text.index(after: eq)...])
        }
        // kkAgent 命令装在 ~/.local/bin，保证一定在 PATH 里
        let localBin = "\(Config.home)/.local/bin"
        if !(result["PATH"] ?? "").contains(localBin) {
            result["PATH"] = "\(localBin):\(result["PATH"] ?? "/usr/bin:/bin")"
        }
        return result
    }

    /// 在登录环境的 PATH 里找命令
    static func which(_ name: String) -> String? {
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

/// 核心内部的通用错误，message 是给人看的中文
struct CoreError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// 日志打到标准输出，launchd 会写进 ~/.kkagent/core.log
/// 日志时间用本机时区，方便直接对照；数据库里的时间仍是 UTC（nowISO），界面显示时再换算
private let logTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.timeZone = .current
    return formatter
}()

func log(_ text: String) {
    print("[\(logTimeFormatter.string(from: Date()))] \(text)")
    fflush(stdout)
}

/// 和 Node 版一致的时间格式：2026-10-22T07:44:22.283Z
func nowISO() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

/// 解析 nowISO 写的时间（也认 Codex 会话记录里的 timestamp，格式一样）；解析不了返回 nil
func parseISO(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}
