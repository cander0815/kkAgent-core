// 集群：群主在主群里执行 kkAgent spawn，核心为一个功能建好子群、git worktree，
// 并在后台新建 coder（Claude）和 tester（Codex）两个会话拉进子群。
// coder 只在虚拟机里创建（禁止在物理机上建 Claude）；tester 在物理机上（Codex 只支持物理机）。
// worktree 建在项目的 .worktrees/<子群 id>（要求主仓库已经忽略 .worktrees/），项目在 /Users 下，物理机和虚拟机看到的是同一份代码。
//
// 顺序很重要：tester 的入群说明要比 coder 先排队。coder 干完发给 tester 的消息排在它后面，
// 不会抢先成为 tester 的第一轮（Codex 会话是第一轮跑起来才建出来的）。
import Foundation

final class Cluster {
    private let repo: Repository
    private let delivery: DeliveryQueue

    init(repo: Repository, delivery: DeliveryQueue) {
        self.repo = repo
        self.delivery = delivery
    }

    /// 建一个子群，返回给群主看的文字
    /// spawn / reopen 共用的校验：必须是集群主群，from 必须是它的群主。返回群和群主的成员行
    private func requireOwner(groupId: String, from: String, command: String) throws -> (GroupSummary, Member) {
        guard let group = try repo.getGroup(groupId) else { throw UserError("群聊 \(groupId) 不存在") }
        guard group.parentId.isEmpty else { throw UserError("子群里不能 \(command)，请在主群「\(group.parentId)」里执行") }
        guard group.cluster else { throw UserError("群聊「\(group.name)」不是集群群聊，不能 \(command)（新建群时选「集群」）") }
        // 群主在加入集群主群时就定下了（见 API.addMember），名字也在那时校验过不是 coder / tester
        guard !group.owner.isEmpty, group.owner == from,
              let owner = try repo.listMembers(groupId: groupId).first(where: { $0.alias == from }) else {
            throw UserError(group.owner.isEmpty ? "这个集群还没有群主，先把群主会话拉进群" : "这个集群的群主是 \(group.owner)，只有群主能 \(command)")
        }
        return (group, owner)
    }

    /// 仓库根目录：用群主会话的工作目录。群主在虚拟机里也行，/Users 下的目录物理机上看得到
    private func ownerRepoRoot(_ owner: Member) throws -> String {
        guard FileManager.default.fileExists(atPath: owner.cwd) else {
            throw UserError("群主的工作目录 \(owner.cwd) 在物理机上看不到，暂不支持（worktree 和 tester 都在物理机上）")
        }
        return try git(["rev-parse", "--show-toplevel"], in: owner.cwd)
    }

    /// coder（Claude）一律跑在虚拟机里，禁止在物理机上创建：
    /// 群主在哪台虚拟机就用哪台；群主在物理机上时，只有一台虚拟机在运行才用它，否则不建（不退回物理机）
    private func coderVM(for owner: Member) throws -> String {
        if !owner.vm.isEmpty { return owner.vm }
        let running = VM.running()
        guard running.count == 1 else {
            throw UserError(running.isEmpty
                ? "没有正在运行的虚拟机。coder（Claude）只在虚拟机里创建，请先启动虚拟机"
                : "群主在物理机上，且有多台虚拟机在运行（\(running.joined(separator: "、"))），不知道把 coder 建在哪台。请把那台虚拟机里的会话拉进来当群主")
        }
        return running[0]
    }

    func spawn(groupId: String, from: String, task: String, brief: String) throws -> String {
        // 1. 校验
        let (_, owner) = try requireOwner(groupId: groupId, from: from, command: "spawn")
        guard !task.isEmpty else { throw UserError("--task 功能名不能为空") }
        guard !brief.isEmpty else { throw UserError("需求说明不能为空") }

        // 2. 找仓库和 coder 用的虚拟机
        let root = try ownerRepoRoot(owner)
        let coderVM = try coderVM(for: owner)
        // worktree 建在仓库里的 .worktrees/ 下，虚拟机只看得到 /Users 下的目录
        guard root.hasPrefix("/Users/") else {
            throw UserError("仓库 \(root) 不在 /Users 下，虚拟机里看不到，coder 没法在里面工作")
        }
        guard let baseBranch = try? git(["symbolic-ref", "--short", "HEAD"], in: root) else {
            throw UserError("主目录 \(root) 当前不在任何分支上（分离 HEAD），先切到要合并回去的分支")
        }
        let dirty = !(try git(["status", "--porcelain"], in: root)).isEmpty

        // 3. 建子群（先登记拿到 id，worktree 路径要用它）
        var sub = try repo.createGroup(name: task, parentId: groupId, owner: from, baseBranch: baseBranch)

        // 4. worktree 建在项目自己的 .worktrees/<子群 id>：Node 往上找依赖能找到主项目的 node_modules，
        //    依赖和 lockfile 没变时可以直接复用（改了依赖仍要安装）。
        //    主仓库必须忽略这个目录：不忽略的话它会出现在 git status 里，主目录一直算有改动，也可能被误提交。
        //    检查的是这次真正要建的目录（带斜杠按目录判断，否定规则也会算进去），不能拿一个固定的探测路径代替。
        //    没忽略就撤掉刚登记的子群，不建 worktree、不拉 agent，交给群主处理
        let worktree = "\(root)/.worktrees/\(sub.id)"
        guard isIgnored(worktree + "/", in: root) else {
            try? repo.deleteGroup(sub.id)
            throw UserError("""
                主仓库 \(root) 没有忽略 .worktrees/，子群的 worktree 要建在这里（里面是整份代码）。请先把仓库准备好再重新 spawn：
                1. 在仓库根目录的 .gitignore 里加一行 .worktrees/；
                2. 主项目里按目录扫文件的工具都排除 .worktrees（tsconfig 的 include/exclude、eslint、prettier 的忽略配置、
                   vitest / jest 的测试匹配、tailwind 等的 content 路径、pnpm-workspace.yaml 的包匹配、其他递归扫目录的脚本），
                   否则会把子群的代码再扫一遍，重复报错、测试跑两遍；
                3. 改动提交到主分支。拿不准的地方先告诉用户，由用户决定。
                """)
        }
        // 路径和分支只用子群 id，功能名可能有中文和空格
        let branch = "kkagent/\(sub.id)"
        do {
            _ = try git(["worktree", "add", "-b", branch, worktree, baseBranch], in: root)
        } catch {
            try? repo.deleteGroup(sub.id) // worktree 没建成，子群也不要了
            throw error
        }
        try repo.setGroupWorktree(sub.id, worktree: worktree, branch: branch)
        sub = try repo.getGroup(sub.id)!

        // 5~7. 加成员。群主照抄它在主群里的那一行（包括运行方式），coder / tester 是后台会话
        _ = try repo.addMember(groupId: sub.id, alias: owner.alias, agent: owner.agent, sessionId: owner.sessionId,
                               description: owner.description, cwd: owner.cwd, vm: owner.vm, headless: owner.headless)
        // 两个都常驻在物理机的 tmux 会话里（见 Tmux.swift），用户随时能打开直接交互
        let coder = try repo.addMember(groupId: sub.id, alias: "coder", agent: .claude, sessionId: UUID().uuidString.lowercased(),
                                       description: "编码", cwd: worktree, vm: coderVM, headless: true,
                                       tmux: Tmux.sessionName(groupId: sub.id, alias: "coder"))
        // Codex 不能预先指定会话 ID，先留空，第一轮跑起来后回填
        let tester = try repo.addMember(groupId: sub.id, alias: "tester", agent: .codex, sessionId: "",
                                        description: "验收", cwd: worktree, vm: "", headless: true,
                                        tmux: Tmux.sessionName(groupId: sub.id, alias: "tester"))

        // 8. 发入群说明：先 tester（bootstrap，建出 Codex 会话），再 coder（收到就开工）
        try sendIntro(sub: sub, member: tester, text: Prompts.testerIntro(sub: sub, brief: brief), purpose: .bootstrap)
        // coder 收到就开工，算任务
        try sendIntro(sub: sub, member: coder, text: Prompts.coderIntro(sub: sub, brief: brief), purpose: .task)

        log("集群 \(groupId) 建了子群 \(sub.id)「\(task)」，worktree \(worktree)")
        return Prompts.spawned(sub: sub, dirtyWarning: dirty)
    }

    /// 找回已解散的子群（kkAgent reopen，方案见 kktodo/找回子群-方案.md）：群主传原来的 coder（必填）和 tester（可选）会话 ID，
    /// 在原集群下重建子群，用原来的 worktree 和分支，coder / tester 接着原会话在 tmux 里运行。没传 tester 就像 spawn 一样新建一个。
    /// worktree 取 coder 会话记录里的工作目录；同一个会话不能被两个进程同时写，已经被群成员或单独会话占着的拒绝
    func reopen(groupId: String, from: String, task: String, brief: String, coderId: String, testerId: String) throws -> String {
        // 1. 校验
        let (_, owner) = try requireOwner(groupId: groupId, from: from, command: "reopen")
        guard !coderId.isEmpty else { throw UserError("--coder 必填：原来 coder 的会话 ID") }
        guard !task.isEmpty else { throw UserError("--task 功能名不能为空") }
        guard !brief.isEmpty else { throw UserError("需求说明不能为空") }
        let root = try ownerRepoRoot(owner)
        let coderVM = try coderVM(for: owner)

        // 2. 找会话，worktree 用 coder 会话的工作目录
        guard let coderFile = Transcript.find(agent: .claude, sessionId: coderId, vm: coderVM) else {
            throw UserError("在虚拟机 \(coderVM) 里找不到 coder 会话 \(coderId)，检查会话 ID 是否写对")
        }
        let worktree = Transcript.readCwd(agent: .claude, file: coderFile, vm: coderVM)
        var isDir: ObjCBool = false
        guard !worktree.isEmpty, FileManager.default.fileExists(atPath: worktree, isDirectory: &isDir), isDir.boolValue else {
            throw UserError("coder 会话的工作目录 \(worktree.isEmpty ? "（读不到）" : worktree) 已经不在了，worktree 可能被删了，没法找回")
        }
        // 必须是群主仓库的一个 worktree（不是主目录本身），并且检出了一个分支
        let commonDir = { (dir: String) in try self.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir) }
        guard (try? git(["rev-parse", "--show-toplevel"], in: worktree)) == worktree, worktree != root,
              (try? commonDir(worktree)) == (try commonDir(root)) else {
            throw UserError("coder 会话的工作目录 \(worktree) 不是仓库 \(root) 的 worktree，不能当子群找回")
        }
        guard let branch = try? git(["symbolic-ref", "--short", "HEAD"], in: worktree) else {
            throw UserError("worktree \(worktree) 当前不在任何分支上（分离 HEAD），先切回原来的子群分支")
        }
        if let using = try repo.listGroups().first(where: { $0.worktree == worktree }) {
            throw UserError("worktree \(worktree) 正在被子群「\(using.name)」(\(using.id)) 使用，不用找回，直接在那个子群里沟通")
        }
        if !testerId.isEmpty {
            guard let testerFile = Transcript.find(agent: .codex, sessionId: testerId) else {
                throw UserError("在物理机上找不到 tester 会话 \(testerId)，检查会话 ID 是否写对；不传 --tester 会新建一个 tester")
            }
            let testerCwd = Transcript.readCwd(agent: .codex, file: testerFile)
            guard testerCwd == worktree else {
                throw UserError("tester 会话的工作目录是 \(testerCwd)，和 coder 的 \(worktree) 不一样，不是同一个子群的")
            }
        }

        // 3. 占用检查：会话已经在别的群里、或者在「会话」页里开着，就不能再接着它开一个
        for (role, agent, id) in [("coder", AgentKind.claude, coderId), ("tester", AgentKind.codex, testerId)] where !id.isEmpty {
            if let member = try repo.membersUsing(agent: agent, sessionId: id).first {
                let name = (try? repo.getGroup(member.groupId))?.name ?? member.groupId
                throw UserError("\(role) 会话 \(id) 现在是群聊「\(name)」(\(member.groupId)) 的成员 \(member.alias)，同一个会话不能两边同时用。请让用户先解散那个群或把它移出")
            }
            if try repo.liveSolos().contains(where: { $0.agent == agent && $0.sessionId == id }) {
                throw UserError("\(role) 会话 \(id) 正在 kkAgent 左边栏「会话」页里开着，请让用户先在那里销毁它")
            }
        }

        // 4. 建子群：用原来的 worktree 和分支，不新建
        let baseBranch = (try? git(["symbolic-ref", "--short", "HEAD"], in: root)) ?? ""
        var sub = try repo.createGroup(name: task, parentId: groupId, owner: from, baseBranch: baseBranch)
        try repo.setGroupWorktree(sub.id, worktree: worktree, branch: branch)
        sub = try repo.getGroup(sub.id)!
        _ = try repo.addMember(groupId: sub.id, alias: owner.alias, agent: owner.agent, sessionId: owner.sessionId,
                               description: owner.description, cwd: owner.cwd, vm: owner.vm, headless: owner.headless)
        // 会话 ID 用原来的：第一次投递打开 tmux 时，Claude 会话文件已经在就用 --resume，Codex 用 resume <ID>
        let coder = try repo.addMember(groupId: sub.id, alias: "coder", agent: .claude, sessionId: coderId,
                                       description: "编码", cwd: worktree, vm: coderVM, headless: true,
                                       tmux: Tmux.sessionName(groupId: sub.id, alias: "coder"))
        let tester = try repo.addMember(groupId: sub.id, alias: "tester", agent: .codex, sessionId: testerId,
                                        description: "验收", cwd: worktree, vm: "", headless: true,
                                        tmux: Tmux.sessionName(groupId: sub.id, alias: "tester"))

        // 5. 入群说明（原会话记得的是旧群 ID，要告诉它们新的）：先 tester 再 coder，和 spawn 一样
        if testerId.isEmpty {
            try sendIntro(sub: sub, member: tester, text: Prompts.testerIntro(sub: sub, brief: brief), purpose: .bootstrap)
        } else {
            try sendIntro(sub: sub, member: tester, text: Prompts.reopenedTesterIntro(sub: sub, brief: brief), purpose: .notice)
        }
        try sendIntro(sub: sub, member: coder, text: Prompts.reopenedCoderIntro(sub: sub, brief: brief), purpose: .task)

        log("集群 \(groupId) 找回子群 \(sub.id)「\(task)」：coder 接着会话 \(coderId)，tester \(testerId.isEmpty ? "新建" : "接着会话 \(testerId)")，worktree \(worktree)")
        return Prompts.reopened(sub: sub, coderId: coderId, testerId: testerId)
    }

    /// 入群说明作为 system 消息记进子群（界面上看得到），再排队投递
    private func sendIntro(sub: GroupSummary, member: Member, text: String, purpose: DeliveryPurpose) throws {
        let message = try repo.addMessage(groupId: sub.id, from: "system", to: member.alias, content: text)
        delivery.enqueue(deliveryId: try repo.addDelivery(messageId: message.id, memberId: member.id, text: text, purpose: purpose),
                         member: member)
    }

    /// 这个路径在仓库里是不是被 .gitignore 忽略了。git check-ignore：忽略返回 0，没忽略返回 1，出错（128）也当没忽略
    private func isIgnored(_ path: String, in dir: String) -> Bool {
        (try? git(["check-ignore", "-q", path], in: dir)) != nil
    }

    /// 在物理机上跑 git，返回去掉首尾空白的输出；失败时把 git 的报错原样告诉调用方
    private func git(_ args: [String], in dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        p.environment = ShellEnv.environment
        let output = Pipe(), errors = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = output
        p.standardError = errors
        try p.run()
        // git 这几个命令输出都很少，先读 stdout 再读 stderr 不会卡住
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UserError("git \(args.joined(separator: " ")) 失败：\(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
