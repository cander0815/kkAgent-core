// 一条群消息 = 一次交接：发送方 → 接收方，送达状态标在接收方旁边。
// 这是整个群聊页最显眼的地方，其他元素都保持克制。
import SwiftUI

struct HandoffRow: View {
    let message: Message
    let detail: GroupDetail

    private var sender: MemberDetail? { detail.members.first { $0.member.alias == message.from } }
    private var deliveries: [Delivery] { detail.deliveries.filter { $0.messageId == message.id } }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayName(message.from)).font(Theme.nameFont()).foregroundStyle(nameColor(message.from))
                    Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    recipients
                    if message.urgent {
                        Text("紧急").font(.caption.weight(.semibold)).foregroundStyle(.red)
                    }
                    // tester 的验收结论：只用状态色（绿 / 橙）
                    if message.verdict == "pass" {
                        Text("验收通过").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    } else if message.verdict == "fail" {
                        Text("验收不通过").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 8)
                    Text(TimeText.time(message.createdAt)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(message.content)
                    .fixedSize(horizontal: false, vertical: true) // 横向跟随栏宽换行，纵向按内容撑开
                    .textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading) // 一行控制在约 70 个汉字，窗口再宽也不会长得难读
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var avatar: some View {
        if let sender {
            AgentAvatar(member: sender, showStatus: false)
        } else {
            // 用户本人，或已经被移出群的成员
            AgentAvatar(name: message.from == "user" ? "我" : message.from, color: nameColor(message.from))
        }
    }

    /// 接收方：发给所有人时逐个列出，每个人后面跟自己的送达状态
    @ViewBuilder
    private var recipients: some View {
        if message.to == "user" {
            Text("我").font(Theme.nameFont()).foregroundStyle(Theme.you)
        } else if deliveries.isEmpty {
            Text(displayName(message.to)).font(Theme.nameFont()).foregroundStyle(nameColor(message.to))
        } else {
            ForEach(deliveries) { d in
                HStack(spacing: 3) {
                    Text(d.memberAlias).font(Theme.nameFont()).foregroundStyle(nameColor(d.memberAlias))
                    DeliveryMark(delivery: d)
                }
            }
        }
    }

    private func nameColor(_ alias: String) -> Color {
        if alias == "user" { return Theme.you }
        if let m = detail.members.first(where: { $0.member.alias == alias }) { return Theme.color(m.member.agent) }
        return .secondary
    }
}

/// 送达状态的小图标，悬停看文字（失败时看原因）
struct DeliveryMark: View {
    let delivery: Delivery

    var body: some View {
        Image(systemName: icon)
            .font(.caption)
            .foregroundStyle(delivery.status.color)
            .help(delivery.status == .failed ? "投递失败：\(delivery.error)"
                : delivery.status == .unconfirmed ? "已写进对方的会话，但没能确认对方收到：\(delivery.error)"
                : delivery.status.label)
    }

    private var icon: String {
        switch delivery.status {
        case .delivered: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .pending, .running: return "clock"
        case .unconfirmed: return "questionmark.circle.fill"
        }
    }
}

/// 入群说明：缩成一行「xx 加入了群聊」，需要时展开原文
struct JoinNoticeRow: View {
    let message: Message
    @StateObject private var expanded = LocalState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus").foregroundStyle(.tertiary)
                Text("\(message.to) 加入了群聊").foregroundStyle(.secondary)
                Button(expanded.value ? "收起入群说明" : "查看入群说明") { expanded.value.toggle() }
                    .buttonStyle(.link).clickable()
                Spacer()
                Text(TimeText.time(message.createdAt)).foregroundStyle(.tertiary).monospacedDigit()
            }
            .font(.caption)
            if expanded.value {
                Text(message.content)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// 系统提醒 / 告警（投递出错、核心重启打断、初始化失败等）：正文直接显示，不折叠。
/// 用橙色图标标出，和普通的入群 / 离群提示区分开
struct SystemAlertRow: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(message.to == "user" ? "系统 → 我" : "系统 → \(message.to)").foregroundStyle(.secondary)
                Spacer()
                Text(TimeText.time(message.createdAt)).foregroundStyle(.tertiary).monospacedDigit()
            }
            .font(.caption)
            Text(message.content)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.07)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/// 成员离开：一行「xx 已离开群聊」，和入群那行对应
struct LeaveNoticeRow: View {
    let message: Message

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.badge.minus").foregroundStyle(.tertiary)
            Text(message.content).foregroundStyle(.secondary)
            Spacer()
            Text(TimeText.time(message.createdAt)).foregroundStyle(.tertiary).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
