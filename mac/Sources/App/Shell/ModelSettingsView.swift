// 设置 → 模型：kkAgent 启动 / 续接 Claude、Codex 会话时默认用的模型和思考强度。
// 设置和模型列表都找核心要（核心读 CLI 的模型目录、把设置存到 ~/.kkagent），所以核心没运行时这一页用不了。
import SwiftUI

struct ModelSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var info = LocalState<ModelSettingsInfo?>(nil)
    @StateObject private var settings = LocalState(ModelSettings())
    @StateObject private var message = LocalState("")

    /// 模型选「跟随 CLI 默认」时，不知道 CLI 会用哪个模型，思考强度给两边都通用的几档
    private static let commonEfforts = ["low", "medium", "high", "xhigh", "max"]

    var body: some View {
        Form {
            if let info = info.value {
                agentSection("Claude", models: info.claudeModels, modelKey: \.claudeModel, effortKey: \.claudeEffort,
                             note: "列表来自 Claude Code 缓存的模型目录；读不到时只列 opus、sonnet 这类别名。")
                agentSection("Codex", models: info.codexModels, modelKey: \.codexModel, effortKey: \.codexEffort,
                             note: "列表来自 codex debug models。")
                Section {
                    Text("群成员和「会话」页的会话，每次启动或续接都会带上这里的设置，所以续接旧会话时也会换成这里的模型。改完从下一次启动或续接开始生效，已经开着的会话不受影响。中转会话不受这里影响。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !message.value.isEmpty {
                        Text(message.value).font(.caption).foregroundStyle(.orange)
                    }
                }
            } else {
                Text(message.value.isEmpty ? "正在读取…" : message.value).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .task { await load() }
    }

    /// 一个 CLI 的两个下拉框：模型、思考强度
    private func agentSection(_ title: String, models: [ModelOption],
                              modelKey: WritableKeyPath<ModelSettings, String>,
                              effortKey: WritableKeyPath<ModelSettings, String>, note: String) -> some View {
        let chosen = settings.value[keyPath: modelKey]
        let efforts = effortOptions(modelId: chosen, models: models)
        let main = models.filter(\.main)
        let others = models.filter { !$0.main }
        return Section(title) {
            Picker("模型", selection: Binding(get: { settings.value[keyPath: modelKey] }, set: { newModel in
                var next = settings.value
                next[keyPath: modelKey] = newModel
                next[keyPath: effortKey] = fittedEffort(next[keyPath: effortKey], options: effortOptions(modelId: newModel, models: models))
                save(next)
            })) {
                Text("跟随 CLI 默认").tag("")
                // 之前选的模型现在列表里没有了（下线了，或者读不到目录），也留着显示，不然下拉框是空白
                if !chosen.isEmpty && !models.contains(where: { $0.id == chosen }) {
                    Text("\(chosen)（列表里没有）").tag(chosen)
                }
                ForEach(main, id: \.id) { Text($0.name).tag($0.id) }
                if !others.isEmpty {
                    Divider()
                    ForEach(others, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            .clickable()
            Picker("思考强度", selection: Binding(get: { settings.value[keyPath: effortKey] }, set: { newEffort in
                var next = settings.value
                next[keyPath: effortKey] = newEffort
                save(next)
            })) {
                Text("跟随 CLI 默认").tag("")
                ForEach(efforts, id: \.self) { Text(Self.effortName($0)).tag($0) }
            }
            .disabled(efforts.isEmpty)
            .clickable()
            if efforts.isEmpty {
                Text("这个模型不支持设置思考强度。").font(.caption).foregroundStyle(.secondary)
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 某个模型能选的思考强度
    private func effortOptions(modelId: String, models: [ModelOption]) -> [String] {
        guard !modelId.isEmpty else { return Self.commonEfforts }
        return models.first { $0.id == modelId }?.efforts ?? Self.commonEfforts
    }

    /// 换了模型后，原来的思考强度新模型不支持时换一档：优先「中」，没有「中」就取第一档；新模型不支持思考强度就清空
    private func fittedEffort(_ current: String, options: [String]) -> String {
        if options.isEmpty { return "" }
        if current.isEmpty || options.contains(current) { return current }
        return options.contains("medium") ? "medium" : options[0]
    }

    private static func effortName(_ effort: String) -> String {
        switch effort {
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "超高"
        case "max": "最高"
        case "ultra": "极限"
        default: effort
        }
    }

    private func load() async {
        do {
            let result: ModelSettingsInfo = try await model.api.get("/api/model-settings")
            settings.value = result.settings
            info.value = result
            message.value = ""
        } catch {
            message.value = "读取失败：\(error.localizedDescription)。核心运行时才能设置模型。"
        }
    }

    /// 改了马上存；存失败就退回原来的值，并说明原因
    private func save(_ next: ModelSettings) {
        let previous = settings.value
        settings.value = next
        Task {
            do {
                let _: OkResult = try await model.api.post("/api/model-settings", next)
                message.value = ""
            } catch {
                settings.value = previous
                message.value = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}
