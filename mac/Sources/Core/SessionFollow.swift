// tmux 里托管的 Claude（单独会话、群成员）在终端里 /clear、/resume 之后，进程还是同一个，会话 ID 却变了。
// 这里收 SessionStart hook，跟着换到新会话（方案见 kktodo/会话切换跟随-方案.md）。
//
// 实测（Claude Code 2.1.323）：/clear 时先给旧 ID 发 SessionEnd（reason=clear），再给新 ID 发 SessionStart（source=clear）；
// /resume 一样（reason / source 都是 resume）。启动、/compact 的 SessionStart 带的还是原来的 ID，不用换。
// SessionStart hook 的输出会被加进上下文：换过来的如果是群成员，就把入群说明重新给它。
import Foundation

extension DeliveryQueue {
    /// 处理一条 SessionStart。返回要补进新会话上下文的文字（不是群成员、或者不用换时为空）。
    /// 不抛错：hook 脚本会把回复原样打印进上下文，出错只记日志
    func followSession(owner: StatusOwner, launchId: String, payload: [String: Any]) -> String {
        let newId = payload["session_id"] as? String ?? ""
        let source = payload["source"] as? String ?? ""
        let store = AgentStatusStore.shared
        guard let oldId = store.changedSession(owner: owner, launchId: launchId, newSessionId: newId) else { return "" }

        let label = owner.hookPath // 日志里用：solo/<id> 或 members/<id>
        do {
            // 这个进程原来属于谁：单独会话，或者 tmux 里的群成员
            let soloId: Int64, agent: AgentKind, vm: String, oldCwd: String
            switch owner {
            case .solo(let id):
                guard let solo = try repo.getSolo(id) else { return "" }
                (soloId, agent, vm, oldCwd) = (id, solo.agent, solo.vm, solo.cwd)
            case .member(let id):
                guard let member = try repo.getMember(id) else { return "" }
                (soloId, agent, vm, oldCwd) = (0, member.agent, member.vm, member.cwd)
            }
            let cwd = (payload["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? oldCwd

            // 新会话已经被别处托管着（比如 /resume 到了另一个单独会话或群成员正在用的会话）：不换，一个会话不能两处同时托管。
            // 之后这个进程的事件对不上登记的 ID，照旧被忽略
            if try !repo.membersWithSession(agent: agent, sessionId: newId).isEmpty
                || repo.liveSolos().contains(where: { $0.agent == agent && $0.sessionId == newId && $0.id != soloId }) {
                log("\(label) 在终端里换到了会话 \(newId)（\(source)），但这个会话已经被别的单独会话或群成员用着，不跟着换")
                return ""
            }

            let members = try repo.followSession(soloId: soloId, agent: agent, vm: vm, from: oldId, to: newId, cwd: cwd)
            store.adoptSession(owner: owner, launchId: launchId, sessionId: newId)
            log("\(label) 在终端里换了会话（\(source)）：\(oldId) → \(newId)，同时更新了 \(members.count) 个成员行")
            return try groupContext(members)
        } catch {
            log("\(label) 换会话出错（\(oldId) → \(newId)）：\(error)")
            return ""
        }
    }

    /// 给换过来的新会话补上入群说明：每个所在的群一段。不在群里就是空的
    private func groupContext(_ members: [Member]) throws -> String {
        var intros: [String] = []
        for member in members {
            guard let group = try repo.getGroup(member.groupId) else { continue }
            if group.cluster {
                intros.append(Prompts.ownerIntro(group: group, owner: member)) // 集群主群：群主版的说明
            } else if !group.parentId.isEmpty && member.alias == group.owner {
                continue // 子群里复制来的群主行：主群那段已经说清楚了
            } else {
                intros.append(Prompts.intro(group: group, member: member, allMembers: try repo.listMembers(groupId: group.id)))
            }
        }
        return intros.isEmpty ? "" : Prompts.sessionFollowed(intros)
    }
}
