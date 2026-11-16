// 复制按钮：点一下把文字放进剪贴板，图标变成绿色对勾 1.5 秒，让人知道复制成功了
import SwiftUI

struct CopyButton: View {
    let text: String
    var icon = "doc.on.doc"
    let help: String
    var color: Color = .accentColor

    @StateObject private var copied = LocalState(false)

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied.value = true
            // 1.5 秒后变回原来的图标；连点时以最后一次为准也没关系
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied.value = false }
        } label: {
            Image(systemName: copied.value ? "checkmark" : icon)
                .foregroundStyle(copied.value ? .green : color)
        }
        .buttonStyle(.borderless)
        .tip(copied.value ? "已复制" : help)
        .clickable()
    }
}
