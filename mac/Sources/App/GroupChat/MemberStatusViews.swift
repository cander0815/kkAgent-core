// 成员详情里和投递有关的几块：状态栏（排队数、暂停自动投递）、等授权提示、「已写入未确认」卡片。
// 文案的意思以 kktodo/kkAgent-参考Orca改进方案.md 第四节第 2～5 步为准。
import SwiftUI

/// 状态栏：现在在干什么、有几条消息在排队，以及「暂停自动投递 / 恢复」开关
struct MemberStatusBar: View {
    @EnvironmentObject private var model: AppModel
    let item: MemberDetail
    let pending: [Delivery] // 这个成员还在排队的投递
    @StateObject private var showPending = LocalState(false)

    private var pendingCount: Int { pending.count }

    private var queueText: String {
        if item.member.paused { return pendingCount > 0 ? "已暂停自动投递，\(pendingCount) 条排队" : "已暂停自动投递" }
        return pendingCount > 0 ? "\(pendingCount) 条排队，空闲后合并投递" : "没有排队的消息"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(item.statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.statusLabel).font(.callout.weight(.medium))
                HStack(spacing: 4) {
                    Text(queueText).font(.caption).foregroundStyle(.secondary)
                    // 有排队的消息时，点这个图标看具体排着哪几条
                    if pendingCount > 0 {
                        Button { showPending.value = true } label: {
                            Image(systemName: "list.bullet.rectangle").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .tip("查看排队中的消息")
                        .clickable()
                    }
                }
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
        .sheet(isPresented: $showPending.value) {
            PendingDeliveriesSheet(alias: item.member.alias, memberId: item.member.id).environmentObject(model)
        }
    }
}

/// 排队中的消息列表（状态栏里点图标弹出）。直接读界面已经拿到的群详情，排队有变化时会跟着刷新
struct PendingDeliveriesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let alias: String
    let memberId: Int64
    @StateObject private var expanded = LocalState<Set<Int64>>([]) // 展开着的消息 id
    @StateObject private var busy = LocalState(false)               // 正在取消 / 强制发送
    @StateObject private var errorText = LocalState<String?>(nil)   // 上一次操作失败的原因

    /// 还在排队的消息，按排队先后；找不到原文的（理论上不会）跳过
    private var items: [Message] {
        guard let detail = model.detail else { return [] }
        let messages = Dictionary(uniqueKeysWithValues: detail.messages.map { ($0.id, $0) })
        return detail.deliveries
            .filter { $0.memberId == memberId && $0.status == .pending }
            .sorted { $0.id < $1.id }
            .compactMap { messages[$0.messageId] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(alias) 排队中的消息（\(items.count) 条）").font(.title3)
            Text("等它空闲后会合并成一轮送进去；紧急消息排在前面。也可以取消某条，或不等它空闲、强制单独送进去。")
                .font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("没有排队的消息了，可能刚刚已经送出去。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, message in
                            row(index: index, message: message)
                        }
                    }
                }
                .frame(maxHeight: 460)
            }
            if let error = errorText.value {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).clickable()
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// 只有一条时直接展开；多条时默认收起，点哪条展开哪条
    private func isExpanded(_ id: Int64) -> Bool { items.count == 1 || expanded.value.contains(id) }

    /// 一条排队消息：标题行（序号、谁发给谁、紧急、时间、展开箭头）+ 正文（收起时只显示前两行）
    private func row(index: Int, message: Message) -> some View {
        let open = isExpanded(message.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if expanded.value.contains(message.id) { expanded.value.remove(message.id) } else { expanded.value.insert(message.id) }
            } label: {
                HStack(spacing: 6) {
                    Text("\(index + 1)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.secondary.opacity(0.15)))
                    Text("\(displayName(message.from)) → \(displayName(message.to))").font(.caption.weight(.medium))
                    if message.urgent {
                        Text("紧急").font(.caption2.weight(.medium)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                    }
                    Spacer()
                    Text(TimeText.time(message.createdAt)).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    if items.count > 1 {
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle()) // 整行都能点，不只是文字
            }
            .buttonStyle(.plain)
            .clickable()
            .allowsHitTesting(items.count > 1) // 只有一条时一直展开，标题行不用点

            Text(message.content)
                .font(.callout)
                .lineLimit(open ? nil : 2)
                .foregroundStyle(open ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // 取消：这条不再发给它；强制发送：不等它空闲，马上单独送进去
            if let deliveryId = deliveryId(of: message.id) {
                HStack(spacing: 8) {
                    Spacer()
                    Button("取消") { run { await model.cancelDelivery(deliveryId) } }
                        .tip("这条不再发给 \(alias)")
                        .clickable()
                    Button("强制发送") { run { await model.forceSendDelivery(deliveryId) } }
                        .tip("不等 \(alias) 空闲，马上把这一条送进去")
                        .clickable()
                }
                .controlSize(.small)
                .disabled(busy.value) // 处理期间不让连点（强制发送最多要等几十秒）
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    /// 这条消息发给这个成员的那条投递的 id；入群说明那条不能取消、不能强制发送，返回 nil（不显示按钮）
    private func deliveryId(of messageId: Int64) -> Int64? {
        model.detail?.deliveries.first {
            $0.memberId == memberId && $0.messageId == messageId && $0.status == .pending && !$0.isBootstrap
        }?.id
    }

    /// 执行取消 / 强制发送：期间按钮置灰，失败的原因显示在弹窗里
    private func run(_ action: @escaping () async -> String?) {
        busy.value = true
        errorText.value = nil
        Task {
            errorText.value = await action()
            busy.value = false
        }
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
