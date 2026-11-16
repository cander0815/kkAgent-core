// 鼠标形状规则（见项目根目录 CLAUDE.md）：
//   能点的（按钮、菜单、选择器、勾选框、列表行）→ .clickable()，鼠标变成手指
//   能拖的 → 用对应形状，比如上下拖改高度用 .pointerStyle(.rowResize)
//   能输入的文本框保持系统默认的 I 形光标，不要加
import SwiftUI

extension View {
    /// 鼠标放上去变成手指
    func clickable() -> some View {
        pointerStyle(.link)
    }
}
