// 成员详情里和投递有关的几块：状态栏（排队数、暂停自动投递）、等授权提示、「已写入未确认」卡片。
// 文案的意思以 kktodo/kkAgent-参考Orca改进方案.md 第四节第 2～5 步为准。
import SwiftUI

/// 状态栏：现在在干什么、有几条消息在排队，以及「暂停自动投递 / 恢复」开关
struct MemberStatusBar: View {
    @EnvironmentObject private var model: AppModel
    let item: MemberDetail
    let pendingCount: Int

    private var queueText: String {
        if item.member.paused { return pendingCount > 0 ? "已暂停自动投递，\(pendingCount) 条排队" : "已暂停自动投递" }
        return pendingCount > 0 ? "\(pendingCount) 条排队，空闲后合并投递" : "没有排队的消息"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(item.statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.statusLabel).font(.callout.weight(.medium))
                Text(queueText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.setPaused(memberId: item.member.id, paused: !item.member.paused) }
            } label: {
                Label(item.member.paused ? "恢复自动投递" : "暂停自动投递", systemImage: item.member.paused ? "play.fill" : "pause.fill")
            }
            .controlSize(.small)
            .tip(item.member.paused ? "恢复后，排着的消息会在它空闲时合并送进去"
                 : "准备在终端里手动操作时先暂停，消息只排队不投，免得和你的输入撞在一起、回头还得返工")
            .clickable()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// 卡在授权框上时的醒目提示。只有人能在它的终端里点批准或拒绝，系统不会替它点
struct PermissionNotice: View {
    /// 点「到终端处理授权」：切到终端标签页
    let openTerminal: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("在等授权").font(.callout.weight(.semibold))
                Text("只有你能在它的终端里点批准或拒绝，系统不会替它点。处理完之前，发给它的消息先排着。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let openTerminal {
                    Button("到终端处理授权", action: openTerminal).controlSize(.small).clickable()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3)))
        .padding(.horizontal, 14).padding(.bottom, 8)
    }
}

/// 这个成员「已写入未确认」的投递（同一次投递合并了几条消息的，算一张卡片），带「解除并继续」
struct UnconfirmedCards: View {
    @EnvironmentObject private var model: AppModel
    let deliveries: [Delivery] // 只传这个成员的
    @StateObject private var confirming = LocalState<Int64?>(nil) // 正在确认解除的投递尝试

    /// 按投递尝试分组：还没解除的才挡着后面的消息
    private var blocking: [(attemptId: Int64, items: [Delivery])] {
        let unconfirmed = deliveries.filter { $0.status == .unconfirmed && $0.attemptId != 0 && !$0.attemptReleased }
        return Dictionary(grouping: unconfirmed, by: \.attemptId).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        if !blocking.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(blocking, id: \.attemptId) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("？已写入未确认").font(.callout.weight(.semibold)).foregroundStyle(.orange)
                            Text("#\(group.attemptId)").font(Theme.code).foregroundStyle(.secondary)
                            Spacer()
                            Text(TimeText.time(group.items.last?.updatedAt ?? "")).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("内容已写进它的会话，但没能确认它收到了\(group.items.count > 1 ? "（合并了 \(group.items.count) 条消息）" : "")。"
                             + "为了不重复，系统不会重发，后面的消息也先排着。")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                        if let reason = group.items.first?.error, !reason.isEmpty {
                            Text("原因：\(reason)").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Button("解除并继续…") { confirming.value = group.attemptId }.controlSize(.small).clickable()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3)))
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
            .alert("解除 #\(confirming.value ?? 0) 的阻挡并继续？", isPresented: Binding(
                get: { confirming.value != nil }, set: { if !$0 { confirming.value = nil } }
            )) {
                Button("取消", role: .cancel) {}
                Button("解除并继续") {
                    if let id = confirming.value { Task { await model.releaseAttempt(id) } }
                }
            } message: {
                Text("请先在终端里看一眼有没有残留的半条输入，免得后面的消息接在它后面，回头还得返工。\n\n"
                     + "解除后，后面的消息会按正常条件继续投递；如果它还在干活、等授权、暂停或者状态未知，仍会继续排队。\n\n"
                     + "这一条仍然是「已写入未确认」，不会算作送达，也不会重发。")
            }
        }
    }
}
