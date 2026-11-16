// 设置 → 核心：查看后台核心状态，启动 / 停止 / 重启，登录时自动启动，打开日志
import AppKit
import SwiftUI

struct CoreSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var autoStart = LocalState(CoreControl.autoStartEnabled)
    @StateObject private var message = LocalState("")
    @StateObject private var confirmStop = LocalState(false)

    var body: some View {
        Form {
            Section("状态") {
                LabeledContent("核心") {
                    HStack(spacing: 6) {
                        Circle().fill(model.coreOnline ? Color.green : Color.red).frame(width: 8, height: 8)
                        Text(model.coreOnline ? "运行中" : "未运行")
                    }
                }
                if let h = model.health, model.coreOnline {
                    LabeledContent("进程", value: "pid \(h.pid) · 端口 \(h.port)")
                    LabeledContent("启动于", value: TimeText.dateTime(h.startedAt))
                    LabeledContent("中转会话", value: h.relayRunning ? "运行中" : "未启动（第一次需要实时投递时才启动）")
                }
            }

            Section("控制") {
                HStack {
                    Button("启动") { run(CoreControl.start, done: "已启动") }.disabled(model.coreOnline)
                    Button("重启") { run(CoreControl.restart, done: "已重启") }.disabled(!model.coreOnline)
                    Button("停止") { confirmStop.value = true }.disabled(!model.coreOnline)
                }
                .clickable()
                Toggle("登录时自动启动", isOn: Binding(get: { autoStart.value }, set: { enabled in
                    if let error = CoreControl.setAutoStart(enabled) {
                        message.value = "设置失败：\(error)"
                    } else {
                        autoStart.value = enabled
                    }
                }))
                .clickable()
                Text("关掉界面不会停止核心。核心停止后，Agent 用 kkAgent 发消息会报错，排队中的投递会标记失败。")
                    .font(.caption).foregroundStyle(.secondary)
                if !message.value.isEmpty {
                    Text(message.value).font(.caption)
                }
            }

            Section("日志") {
                LabeledContent("位置", value: CoreControl.logPath).textSelection(.enabled)
                Button("打开日志") { NSWorkspace.shared.open(URL(fileURLWithPath: CoreControl.logPath)) }.clickable()
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .confirmationDialog("停止 kkAgent 核心？", isPresented: $confirmStop.value) {
            Button("停止", role: .destructive) { run(CoreControl.stop, done: "已停止。到下次登录或手动启动前，核心不会自动恢复。") }
        } message: {
            Text("停止后 Agent 发不了群消息，排队中的投递会标记失败。到下次登录或在这里手动启动前，核心不会自动恢复。")
        }
    }

    /// 执行一个控制动作，显示结果，然后让界面马上刷新状态
    private func run(_ action: () -> String?, done: String) {
        message.value = action().map { "失败：\($0)" } ?? done
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 等核心起来或退出
            await model.refresh()
        }
    }
}
