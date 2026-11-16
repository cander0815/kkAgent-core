// 整个 App 正文的字号（设置 → 显示 里改）。
// 用法：主窗口最外层套上 .appTextSize()，没有单独指定字体的文字（群聊消息、会话内容、列表里的名字、输入框）都跟着它变；
// 时间、状态这类说明文字仍按各自的 .caption / .callout 显示。内嵌终端的字体另外在「终端」里设置，不受这里影响。
import SwiftUI

enum AppTextSize {
    static let key = "appTextSize"
    static let defaultSize = 14.0 // 系统默认是 13，看着偏小
    static let range = 12.0...20.0
}

private struct AppTextSizeModifier: ViewModifier {
    @AppStorage(AppTextSize.key) private var size = AppTextSize.defaultSize

    func body(content: Content) -> some View {
        content.environment(\.font, .system(size: size))
    }
}

extension View {
    /// 让里面没有单独指定字体的文字用设置里的字号
    func appTextSize() -> some View { modifier(AppTextSizeModifier()) }
}

/// 设置 → 显示
struct DisplaySettingsView: View {
    @AppStorage(AppTextSize.key) private var size = AppTextSize.defaultSize

    var body: some View {
        Form {
            Section("文字") {
                Stepper(value: $size, in: AppTextSize.range, step: 1) {
                    Text("正文字号：\(Int(size))")
                }
                .clickable()
                Text("群聊消息、会话内容、列表里的名字和输入框用这个字号，改完马上生效。时间、状态这类说明文字保持原来的小字号；App 里终端的字体在「终端」里单独设置。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("恢复默认（14）") { size = AppTextSize.defaultSize }
                    .disabled(size == AppTextSize.defaultSize)
                    .clickable()
            }
        }
        .formStyle(.grouped)
    }
}
