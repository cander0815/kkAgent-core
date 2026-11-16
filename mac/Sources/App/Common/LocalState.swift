// 视图自己的局部状态（输入框内容、弹窗开关等）。
// 新版 SDK 里 @State 是用宏实现的，宏插件只随完整版 Xcode 提供，命令行工具编不了；
// 所以用 @StateObject 包一层，效果一样：
//   @StateObject private var draft = LocalState("")
//   TextField("…", text: $draft.value)
import SwiftUI

final class LocalState<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
