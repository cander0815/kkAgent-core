// 集群子群后台成员（coder / tester）的出错通知。
// 不再自动催促、续接：成员该汇报却没汇报的，由群主自己判断要不要追问。核心只在下面几种情况告诉群主：
// - 后台 tester 初始化失败
// - 消息没能送进成员的会话（投递出错）
// - 核心重启打断了正在跑的一轮（不自动重发，可能已经改了一半文件）
import Foundation

/// 投递的用途
enum DeliveryPurpose: String {
    case bootstrap // 后台 tester 的入群说明：要单独送一轮（只有它能新建 Codex 会话）
    case notice    // 通知类（入群说明、离群、发给群主的系统通知）
    case instruction // 群主或用户发来的指示
    case task      // coder 和 tester 之间的消息（提审、验收结论）、coder 的开工说明
}

extension DeliveryQueue {
    /// 每一轮投递结束后调用。error 为空表示这一轮正常结束，什么都不用做
    func afterTurn(member: Member, purpose: DeliveryPurpose, error: Error?) {
        guard member.headless, !isStopping, let error else { return }
        // 这一轮期间被移出、或者群被解散了：什么都不用做
        guard (try? repo.getMember(member.id)) != nil, let sub = try? repo.getGroup(member.groupId) else { return }
        let reason = String(String(describing: error).prefix(300)) // 错误信息可能带一大段 stderr，只留开头
        // 普通群里新建的会话（没有群主）：直接记一条系统告警给用户看，说清楚卡在哪、可以怎么办
        if sub.parentId.isEmpty {
            _ = try? repo.addMessage(groupId: sub.id, from: "system", to: "user",
                                     content: Prompts.memberStartFailed(group: sub, member: member, bootstrap: purpose == .bootstrap, reason: reason),
                                     kind: "alert")
            return
        }
        if purpose == .bootstrap {
            notifyOwner(sub: sub, text: Prompts.bootstrapFailed(sub: sub, alias: member.alias, reason: reason))
        } else {
            notifyOwner(sub: sub, text: Prompts.deliveryFailed(sub: sub, member: member, reason: reason))
        }
    }

    /// 消息写进去了但没能确认：子群的后台成员告诉群主；其他成员记一条系统告警给用户看（界面上看得到）
    /// 返回通知有没有写进库（写不进去调用方要稍后补发）
    @discardableResult
    func reportUnconfirmed(member: Member, reason: String) -> Bool {
        guard let group = try? repo.getGroup(member.groupId) else { return false }
        let text = Prompts.deliveryUnconfirmed(groupName: group.name, member: member, reason: reason)
        log("给 \(member.alias) 的投递已写入但未确认：\(reason)")
        if member.headless && !group.parentId.isEmpty {
            return notifyOwner(sub: group, text: text)
        }
        do {
            _ = try repo.addMessage(groupId: group.id, from: "system", to: "user", content: text, kind: "alert")
            return true
        } catch {
            log("记录未确认告警失败：\(error)")
            return false
        }
    }

    /// 成员卡在授权框上（每次等待通知一次，等太久再提醒一次）：子群的后台成员告诉群主；其他成员记一条系统告警给用户看。
    /// 只通知，绝不替人批准、回车或重贴
    func reportPermission(memberId: Int64, info: PermissionInfo, remind: Bool) {
        guard let member = try? repo.getMember(memberId), let group = try? repo.getGroup(member.groupId) else { return }
        let text = Prompts.permissionWaiting(groupName: group.name, member: member, info: info, remind: remind,
                                             waitedSeconds: Int(Config.permissionRemindAfter))
        log("\(member.alias) 在等授权（\(info.tool)：\(info.detail)）\(remind ? "，已等很久，再提醒一次" : "")")
        if member.headless && !group.parentId.isEmpty {
            notifyOwner(sub: group, text: text)
        } else {
            _ = try? repo.addMessage(groupId: group.id, from: "system", to: "user", content: text, kind: "alert")
        }
    }

    /// 核心启动时调用：上次被重启打断的后台成员，告诉它们的群主
    func reportInterrupted(memberIds: [Int64]) {
        for id in memberIds {
            guard let member = try? repo.getMember(id), let sub = try? repo.getGroup(member.groupId) else { continue }
            log("\(member.alias)（子群 \(sub.id)）的投递被核心重启打断，通知群主")
            notifyOwner(sub: sub, text: Prompts.interrupted(sub: sub, alias: member.alias))
        }
    }

    /// 以系统消息的形式发给子群的群主（界面上看得到）。
    /// 群主被移出了子群：改成发给用户的系统告警，至少界面上看得到，不能只记日志
    /// 返回通知有没有写进库
    @discardableResult
    func notifyOwner(sub: GroupSummary, text: String) -> Bool {
        guard let owner = (try? repo.listMembers(groupId: sub.id))?.first(where: { $0.alias == sub.owner }) else {
            log("子群 \(sub.id) 找不到群主 \(sub.owner)，通知改发给用户")
            return (try? repo.addMessage(groupId: sub.id, from: "system", to: "user",
                                         content: Prompts.ownerMissing(owner: sub.owner) + "\n\n" + text, kind: "alert")) != nil
        }
        do {
            let message = try repo.addMessage(groupId: sub.id, from: "system", to: owner.alias, content: text, kind: "alert")
            enqueue(deliveryId: try repo.addDelivery(messageId: message.id, memberId: owner.id, text: text, purpose: .notice), member: owner)
            return true
        } catch {
            log("通知群主失败（子群 \(sub.id)）：\(error)")
            return false
        }
    }
}
