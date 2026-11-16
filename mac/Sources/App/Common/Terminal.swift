// 用终端软件打开会话的工作目录（设置 → 终端 里选用哪个）。
//
// 怎么知道电脑上装了哪些终端：macOS 没有「终端」这个分类，所以内置一份常见终端的名单，
// 只记 bundle ID 和打开方式，不记安装路径；运行时按 bundle ID 问系统装没装、装在哪。
// 名单外的终端可以在设置里选「其他应用…」，用通用方式打开（只能打开目录）。
//
// 虚拟机里的会话：目录在虚拟机里，要在终端里执行 `ubx shell <机器名> --cd <目录>` 进去。
import AppKit
import SwiftUI

/// 路径后面的终端图标：点一下用设置里选的终端打开这个目录
struct OpenTerminalButton: View {
    let cwd: String
    let vm: String
    var color: Color = .accentColor

    var body: some View {
        Button { TerminalLauncher.open(cwd: cwd, vm: vm) } label: {
            Image(systemName: "terminal").foregroundStyle(color)
        }
        .buttonStyle(.borderless)
        .tip(vm.isEmpty ? "在终端里打开这个目录（终端软件在设置里改）" : "在终端里进虚拟机 \(vm) 并打开这个目录（终端软件在设置里改）")
        .clickable()
    }
}

struct TerminalApp: Identifiable, Hashable {
    let bundleId: String
    let name: String
    let style: Style
    var id: String { bundleId }

    /// 各终端打开目录、执行命令的方式不一样
    enum Style {
        case commandFile // 系统终端、iTerm：目录直接交给它打开；命令写进 .command 脚本交给它运行
        case ghostty     // --working-directory=目录，-e 命令
        case alacritty   // --working-directory 目录，-e 命令
        case kitty       // --directory 目录，命令直接跟在后面
        case wezterm     // start --cwd 目录，start -- 命令
        case generic     // 不认识的终端：只能把目录交给它打开，执行不了命令
    }

    /// 已知的终端名单
    static let known: [TerminalApp] = [
        TerminalApp(bundleId: "com.apple.Terminal", name: "终端", style: .commandFile),
        TerminalApp(bundleId: "com.googlecode.iterm2", name: "iTerm", style: .commandFile),
        TerminalApp(bundleId: "com.mitchellh.ghostty", name: "Ghostty", style: .ghostty),
        TerminalApp(bundleId: "dev.warp.Warp-Stable", name: "Warp", style: .generic),
        TerminalApp(bundleId: "net.kovidgoyal.kitty", name: "kitty", style: .kitty),
        TerminalApp(bundleId: "org.alacritty", name: "Alacritty", style: .alacritty),
        TerminalApp(bundleId: "com.github.wez.wezterm", name: "WezTerm", style: .wezterm),
        TerminalApp(bundleId: "co.zeit.hyper", name: "Hyper", style: .generic),
        TerminalApp(bundleId: "org.tabby", name: "Tabby", style: .generic),
    ]

    static let defaultBundleId = "com.apple.Terminal"

    /// 这个终端装在哪；没装返回 nil
    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }

    /// 按 bundle ID 找终端：在名单里用名单的打开方式，不在名单里（「其他应用…」选的）当作通用终端
    static func find(_ bundleId: String) -> TerminalApp? {
        if let app = known.first(where: { $0.bundleId == bundleId }) { return app }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return TerminalApp(bundleId: bundleId, name: FileManager.default.displayName(atPath: url.path), style: .generic)
    }

    /// 这台电脑上装了的已知终端
    static func installed() -> [TerminalApp] {
        known.filter { $0.url != nil }
    }
}

enum TerminalLauncher {
    /// 设置里选的终端，存在 UserDefaults 的这个键下（值是 bundle ID）
    static let settingKey = "terminalApp"

    /// 用选好的终端打开目录。vm 为空是物理机，否则进那台虚拟机再切到目录
    static func open(cwd: String, vm: String) {
        let chosen = UserDefaults.standard.string(forKey: settingKey) ?? TerminalApp.defaultBundleId
        // 选的终端被卸载了，退回系统终端
        guard let app = TerminalApp.find(chosen) ?? TerminalApp.find(TerminalApp.defaultBundleId),
              let appPath = app.url?.path else { return }

        if vm.isEmpty {
            openDirectory(cwd, app: app, appPath: appPath)
        } else {
            runCommand("ubx shell \(quote(vm)) --cd \(quote(cwd))", app: app, appPath: appPath)
        }
    }

    /// 用选好的终端接入物理机上的一个 tmux 会话（集群 coder / tester 常驻在里面）
    static func attachTmux(_ name: String) {
        let chosen = UserDefaults.standard.string(forKey: settingKey) ?? TerminalApp.defaultBundleId
        guard let app = TerminalApp.find(chosen) ?? TerminalApp.find(TerminalApp.defaultBundleId),
              let appPath = app.url?.path else { return }
        runCommand("tmux attach -t \(quote(name))", app: app, appPath: appPath)
    }

    // ---------- 物理机：直接打开到目录 ----------

    private static func openDirectory(_ dir: String, app: TerminalApp, appPath: String) {
        switch app.style {
        case .commandFile, .generic: runOpen(["-a", appPath, dir])
        case .ghostty: runOpen(["-na", appPath, "--args", "--working-directory=\(dir)"])
        case .alacritty: runOpen(["-na", appPath, "--args", "--working-directory", dir])
        case .kitty: runOpen(["-na", appPath, "--args", "--directory", dir])
        case .wezterm: runOpen(["-na", appPath, "--args", "start", "--cwd", dir])
        }
    }

    // ---------- 虚拟机：在终端里执行进虚拟机的命令 ----------

    private static func runCommand(_ command: String, app: TerminalApp, appPath: String) {
        // 从界面启动的程序拿不到终端里的 PATH（ubx 在 ~/.local/bin），所以用登录 + 交互式 shell 执行，读一遍用户的配置
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let words = [shell, "-ilc", command]
        switch app.style {
        case .commandFile:
            guard let script = writeCommandFile("exec " + words.map(quote).joined(separator: " ")) else { return }
            runOpen(["-a", appPath, script.path])
        case .ghostty, .alacritty: runOpen(["-na", appPath, "--args", "-e"] + words)
        case .kitty: runOpen(["-na", appPath, "--args"] + words)
        case .wezterm: runOpen(["-na", appPath, "--args", "start", "--"] + words)
        case .generic:
            // 不知道怎么让这个终端执行命令：把命令放进剪贴板，打开终端让用户自己粘贴
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            runOpen(["-a", appPath])
            let alert = NSAlert()
            alert.messageText = "已复制要执行的命令"
            alert.informativeText = "\(app.name) 没法自动执行命令，在打开的终端里粘贴执行就行：\n\(command)"
            alert.runModal()
        }
    }

    /// 把命令写成临时的 .command 脚本（加上可执行权限），系统终端和 iTerm 打开它就会运行
    private static func writeCommandFile(_ line: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kkagent-terminal.command")
        do {
            try "#!/bin/sh\n\(line)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    private static func runOpen(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        try? process.run()
    }

    /// 给 shell 用的单引号转义：abc → 'abc'，里面的单引号写成 '\''
    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
