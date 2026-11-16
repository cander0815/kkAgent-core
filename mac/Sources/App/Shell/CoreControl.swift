// 通过 launchctl 控制后台核心：启动、停止、重启、登录时自动启动。
// 核心注册在 ~/Library/LaunchAgents/com.kk.kkagent.core.plist（由 scripts/install.sh core 生成）。
import Foundation

enum CoreControl {
    static let label = "com.kk.kkagent.core"
    static let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/\(label).plist"
    static let logPath = "\(NSHomeDirectory())/.kkagent/core.log"

    private static var domain: String { "gui/\(getuid())" }
    private static var target: String { "\(domain)/\(label)" }

    /// 核心有没有安装（plist 在不在）
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// launchd 里当前有没有加载这个服务
    static var isLoaded: Bool { launchctl(["print", target]).ok }

    /// 登录时会不会自动启动（launchctl disable 过就不会）
    static var autoStartEnabled: Bool {
        !launchctl(["print-disabled", domain]).output.contains("\"\(label)\" => disabled")
    }

    /// 启动核心。返回错误信息，成功返回 nil
    static func start() -> String? {
        guard isInstalled else { return "核心还没安装，先在终端执行：mac/scripts/install.sh core" }
        if isLoaded { return launchctl(["kickstart", target]).error }
        // 关了「登录时自动启动」的服务，launchd 会拒绝加载；手动启动时临时放行一下，再恢复原设置
        let wasDisabled = !autoStartEnabled
        if wasDisabled { _ = launchctl(["enable", target]) }
        let result = launchctl(["bootstrap", domain, plistPath])
        if wasDisabled { _ = launchctl(["disable", target]) }
        return result.error
    }

    /// 停止核心：从 launchd 卸载，到下次登录（或手动启动）前不会自动拉起
    static func stop() -> String? {
        isLoaded ? launchctl(["bootout", target]).error : nil
    }

    /// 重启核心：中转会话会冷启动，投递中的消息会标记失败
    static func restart() -> String? {
        isLoaded ? launchctl(["kickstart", "-k", target]).error : start()
    }

    static func setAutoStart(_ enabled: Bool) -> String? {
        launchctl([enabled ? "enable" : "disable", target]).error
    }

    // ---------- 小工具 ----------

    private struct Result {
        let ok: Bool
        let output: String
        var error: String? { ok ? nil : (output.isEmpty ? "launchctl 执行失败" : output) }
    }

    private static func launchctl(_ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return Result(ok: false, output: error.localizedDescription)
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return Result(ok: p.terminationStatus == 0, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
