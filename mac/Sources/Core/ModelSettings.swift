// 设置 → 模型：启动 / 续接 Claude、Codex 会话时默认带上的模型和思考强度。
// 设置存在 ~/.kkagent/model-settings.json，每次启动会话时现读，所以在设置里改完马上生效，不用重启核心。
// 中转会话不受影响，它固定用 Config.relayModel。
import Foundation

enum ModelSettingsStore {
    static var path: String { "\(Config.dataDir)/model-settings.json" }

    /// 读设置；文件不存在（从没改过）或读不出来，就用默认值（模型跟随 CLI，思考强度「中」）
    static func load() -> ModelSettings {
        guard let data = FileManager.default.contents(atPath: path),
              let settings = try? JSONDecoder().decode(ModelSettings.self, from: data) else { return ModelSettings() }
        return settings
    }

    static func save(_ settings: ModelSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// 加在 claude 命令后面的参数，如 ["--model", "claude-opus-5-5", "--effort", "medium"]
    static func claudeArgs() -> [String] {
        let s = load()
        var args: [String] = []
        if !s.claudeModel.isEmpty { args += ["--model", s.claudeModel] }
        if !s.claudeEffort.isEmpty { args += ["--effort", s.claudeEffort] }
        return args
    }

    /// 加在 codex 命令里的参数。Codex 没有思考强度的专门参数，用 -c 临时覆盖 config.toml 里的 model_reasoning_effort。
    /// 要放在 resume 子命令前面（实测 exec 和交互界面都认）
    static func codexArgs() -> [String] {
        let s = load()
        var args: [String] = []
        if !s.codexModel.isEmpty { args += ["-m", s.codexModel] }
        if !s.codexEffort.isEmpty { args += ["-c", "model_reasoning_effort=\"\(s.codexEffort)\""] }
        return args
    }
}

/// 两个 CLI 现在支持哪些模型
enum ModelCatalog {
    /// 读不到 Claude 的模型目录时，退回到 --help 里写明的别名（指向该系列最新版）
    private static let claudeAliases = ["opus", "fable", "sonnet", "haiku"]
    private static let commonEfforts = ["low", "medium", "high", "xhigh", "max"]

    /// Claude 没有列模型的命令，只能读 Claude Code 自己缓存的模型目录：
    /// ~/.claude/cache/model-catalog/<组织ID>-<账号ID>-cc.json（内部格式，没有文档，升级后可能变）。
    /// 换过账号会有多个，取最近更新的那个
    static func claude() -> [ModelOption] {
        let dir = "\(Config.home)/.claude/cache/model-catalog"
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix("-cc.json") }
            .map { "\(dir)/\($0)" }
        let modified = { (path: String) in (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast }
        if let latest = files.max(by: { modified($0) < modified($1) }),
           let data = fm.contents(atPath: latest),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let catalog = root["catalog"] as? [String: Any],
           let config = catalog["config"] as? [String: Any],
           let models = config["models"] as? [[String: Any]] {
            let options = models.compactMap { m -> ModelOption? in
                guard let id = m["id"] as? String else { return nil }
                let runtime = m["runtime"] as? [String: Any]
                return ModelOption(id: id, name: m["name"] as? String ?? id,
                                   efforts: runtime?["effort_levels"] as? [String] ?? [],
                                   main: m["section"] as? String == "main")
            }
            if !options.isEmpty { return options }
        }
        log("读不到 Claude 的模型目录（\(dir)），模型下拉框只列别名")
        return claudeAliases.map { ModelOption(id: $0, name: $0, efforts: commonEfforts, main: true) }
    }

    /// Codex 有现成命令：codex debug models 输出模型目录（读本地缓存，不联网，很快）。
    /// 只要 visibility 为 list 的，和 Codex 界面里能选的一致
    static func codex() -> [ModelOption] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Config.codexBin)
        p.arguments = ["debug", "models"]
        p.environment = ShellEnv.environment
        let output = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            log("跑 codex debug models 失败：\(error)")
            return []
        }
        // 正常 0.1 秒内结束，卡住超过 10 秒就停掉，免得设置页一直转圈
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if p.isRunning { p.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            log("codex debug models 的输出读不出来（退出码 \(p.terminationStatus)）")
            return []
        }
        return models.compactMap { m in
            guard let id = m["slug"] as? String, m["visibility"] as? String == "list" else { return nil }
            let levels = (m["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
            return ModelOption(id: id, name: m["display_name"] as? String ?? id, efforts: levels, main: true)
        }
    }
}
