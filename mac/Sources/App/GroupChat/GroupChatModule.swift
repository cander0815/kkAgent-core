// 群聊功能：群列表 | 对话 | 成员详情（点头像才出现）
// 三栏都用固定宽度 + 中间自适应，不用 HSplitView / .inspector（之前分别导致过内容溢出和布局死循环崩溃）。
// 成员详情的宽度可以拖它左边的分隔线调整（里面有终端，经常要拉宽），宽度记在本机
import SwiftUI

struct GroupChatModule: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("inspectorWidth") private var inspectorWidth: Double = 360
    /// 拖动开始时的宽度：拖动过程中按「开始宽度 - 横向位移」算，不会越拖越偏
    @StateObject private var dragStartWidth = LocalState<Double?>(nil)

    /// 成员详情最窄多宽
    private let minInspector: Double = 320

    var body: some View {
        // 成员详情最宽只能占到「窗口宽度 - 群列表 - 对话区最小宽度」，不然整个布局会撑出窗口、左右两边都被截掉
        GeometryReader { geo in
            let maxInspector = max(minInspector, geo.size.width - 220 - 420 - 2)
            HStack(spacing: 0) {
                GroupListColumn().frame(width: 220)
                Divider()
                if let detail = model.detail {
                    ConversationView(detail: detail).frame(minWidth: 420, maxWidth: .infinity)
                    if let member = detail.members.first(where: { $0.member.id == model.selectedMemberId }) {
                        resizeHandle(maxWidth: maxInspector)
                        // 记下的宽度比现在能给的还宽（窗口缩小了）就先按能给的显示，窗口拉大后恢复。
                        // clipped：里面哪个子视图偏宽，也只会被裁掉，不会把整栏撑出窗口
                        MemberInspector(item: member).frame(width: min(inspectorWidth, maxInspector)).clipped()
                    }
                } else {
                    GroupEmptyState().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// 成员详情左边的分隔线：左右拖动改宽度（鼠标变成左右调整的形状）。最窄 320，最宽到对话区剩 420 为止
    private func resizeHandle(maxWidth: Double) -> some View {
        Divider()
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 7).contentShape(Rectangle())) // 加宽可拖动的范围，线本身还是 1 像素
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth.value ?? min(inspectorWidth, maxWidth)
                        dragStartWidth.value = start
                        // 往左拖（位移为负）变宽
                        inspectorWidth = min(maxWidth, max(minInspector, start - value.translation.width))
                    }
                    .onEnded { _ in dragStartWidth.value = nil }
            )
    }
}

/// 没有群、或还没选群时
struct GroupEmptyState: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var showNew = LocalState(false)

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 36)).foregroundStyle(.tertiary)
            if model.groups.isEmpty {
                Text("还没有群聊").font(.title3)
                Text("新建一个群，把开着的 Claude、Codex 会话拉进来，让它们互相交接结论。")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                Button("新建群聊") { showNew.value = true }.controlSize(.large).clickable()
            } else {
                Text("在左边选一个群聊").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showNew.value) { NewGroupSheet().environmentObject(model) }
    }
}
