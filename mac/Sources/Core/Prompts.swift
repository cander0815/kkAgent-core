// 发给 Agent 的文字模板：入群说明、群消息。内容和 Node 版保持一致。
import Foundation

enum Prompts {
    /// 提示词里写给 agent 执行的命令（正式环境是 kkAgent，测试核心是测试包装的绝对路径，见 Config.cli）
    private static let cli = Config.cli

    private static func agentName(_ agent: AgentKind) -> String {
        agent == .claude ? "Claude" : "Codex"
    }

    private static func describe(_ m: Member) -> String {
        "\(m.alias)（\(agentName(m.agent))\(m.description.isEmpty ? "" : "，" + m.description)）"
    }

    /// 成员入群时发给它的说明
    static func intro(group: GroupSummary, member: Member, allMembers: [Member]) -> String {
        let others = allMembers.filter { $0.id != member.id }
        let otherLines = others.isEmpty
            ? "（暂时没有，之后加入的成员可以用下面的 members 命令查看）"
            : others.map { "- " + describe($0) }.joined(separator: "\n")
        return """
            [kkAgent 群聊「\(group.name)」] 你已被加入这个群聊。
            你在群里的名字：\(member.alias)\(member.description.isEmpty ? "" : "（负责：\(member.description)）")

            其他成员：
            \(otherLines)

            给群成员发消息，执行命令：
              \(cli) send -g \(group.id) --from \(member.alias) --to <成员名|all> "消息内容"
            查看群成员：\(cli) members -g \(group.id)

            规则：
            1. 只发结论：做了什么、改了哪些文件、怎么验证、需要对方做什么。不要发思考过程、尝试过程、工具输出。
            2. 收到群消息后，先完成对方的请求，再用 \(cli) send 把结论发回去。不要用其他方式回复群消息。
            3. 大家在同一个代码目录工作，文件内容让对方自己去读，不要整段粘贴代码或日志。
            4. 不要为了「收到」「好的」这类确认单独发消息。
            5. 加 --urgent 标为紧急，对方会优先看到。只在对方继续做下去会白干、或者会造成破坏时用，平时不加。

            现在不需要回复，等收到群消息再行动。
            """
    }

    /// 群成员在终端里 /clear、/resume 换了会话后，经 SessionStart hook 补进新会话上下文的说明（见 SessionFollow.swift）。
    /// intros 是它所在每个群的说明
    static func sessionFollowed(_ intros: [String]) -> String {
        """
        [kkAgent] 这个终端刚换了会话（/clear 或 /resume），之前收到的入群说明不在上下文里了，下面重新给出，以这里为准。

        \(intros.joined(separator: "\n\n"))
        """
    }

    // 以下三条通知都写明「不需要回复」，免得 Agent 收到后又回一句，来回打转

    /// 发给被移出的成员
    static func removed(group: GroupSummary) -> String {
        "[kkAgent 群聊「\(group.name)」] 你已被移出这个群聊。不要再用 kkAgent 往这个群发消息。这条不需要回复。"
    }

    /// 发给群里其他成员
    static func memberLeft(group: GroupSummary, alias: String) -> String {
        "[kkAgent 群聊「\(group.name)」] \(alias) 已离开群聊，之后不要再给它发消息。这条不需要回复。"
    }

    /// 解散群时发给每个成员
    static func dissolved(group: GroupSummary) -> String {
        "[kkAgent 群聊「\(group.name)」] 这个群聊已解散，你已退出。不要再用 kkAgent 往这个群发消息。这条不需要回复。"
    }

    /// 已经不在群里的会话用 kkAgent 发消息时，核心直接回它这句（群已解散，或它已被移出）
    static func notInGroup(_ reason: String) -> String {
        "\(reason)这条消息没有发出去，以后不要再往这个群发消息。你要说的内容直接回复给用户就行。"
    }

    // ---------- 集群：spawn 出来的子群 ----------

    /// 子群里 coder 和 tester 都要知道的部分
    private static func subgroupBasics(sub: GroupSummary, alias: String, role: String, brief: String) -> String {
        """
        [kkAgent 集群子群「\(sub.name)」] 你是这个子群的 \(alias)，负责\(role)。
        子群成员：\(sub.owner)（群主，负责整个需求的拆解和汇总）、coder（Claude，编码）、tester（Codex，验收）。
        你只负责这一个功能，不用关心其他功能。

        工作目录（git worktree）：\(sub.worktree)
        分支：\(sub.branch)，验收通过后合并回：\(sub.baseBranch)

        ## 这个功能的需求
        \(brief)

        ## 发消息
          \(cli) send -g \(sub.id) --from \(alias) --to <\(sub.owner)|coder|tester|all> "消息内容"
        内容较长时：\(cli) send -g \(sub.id) --from \(alias) --to <收件人> - <<'EOF' ... EOF
        只发结论：做了什么、改了哪些文件、怎么验证、需要对方做什么。不要发思考过程和工具输出，文件内容让对方自己读。
        你在后台运行，没有人看你的回复：要让别人知道的事，一律用 \(cli) send 发出去。
        不要为了「收到」「好的」「任务结束」这类确认单独发消息：对方的消息不需要你做什么时，就不回复。
        加 --urgent 标为紧急，对方会优先看到。只在对方继续做下去会白干、或者会造成破坏时用；提审、验收结论、进度同步一律不加。

        ## 什么时候找群主 \(sub.owner)
        只有两种情况：任务完成（coder 合并完成）、或者任务受阻（需求不清楚、做不下去、环境问题自己解决不了）。
        其余时候都不要发给群主：阶段汇报、进度、提审、验收结论、对群主消息的确认，都不发。
        coder 和 tester 之间的事直接互相发。
        不要执行 kkAgent spawn / kkAgent dissolve，建子群和解散子群只由群主来做。
        """
    }

    /// 发给 spawn 出来的 coder：收到就开工
    static func coderIntro(sub: GroupSummary, brief: String) -> String {
        subgroupBasics(sub: sub, alias: "coder", role: "编码", brief: brief) + """


            ## 你的流程
            1. 在工作目录里实现需求并自测。
            2. 提交（git commit）后只发给 tester：改了什么、怎么验证、提交的 SHA。不用另外给 \(sub.owner) 汇报。
               发完就结束这一轮，等 tester 的结论，验收期间不要再改文件。
            3. tester 打回：按意见修改，重新提交并发给 tester。
            4. 需求不清楚、或者做不下去：发给 \(sub.owner)，说清楚卡在哪里、需要它决定什么。
            5. tester 验收通过后由你合并：
               a. 在工作目录里把 \(sub.baseBranch) 的最新代码合进来（git merge \(sub.baseBranch)），解决冲突，跑通测试；
               b. 这一步产生了任何新改动（包括解决冲突），重新提交并发回 tester 再验一次，拿到通过才继续；
               c. 到主目录确认当前检出的就是 \(sub.baseBranch)，然后执行 git merge --ff-only \(sub.branch)；
               d. --ff-only 失败说明期间别的功能先合并了，回到 a 重来；
               e. 主目录不在 \(sub.baseBranch) 上、或者有没提交的改动导致合并失败，不要擅自处理，发给 \(sub.owner)；
               f. 合并完成后发给 \(sub.owner)：合并了什么、最终的 SHA。

            现在开始。
            """
    }

    /// 发给 spawn 出来的 tester：这一条只是让它就位（顺便把 Codex 会话建出来），等 coder 提审再动手
    static func testerIntro(sub: GroupSummary, brief: String) -> String {
        subgroupBasics(sub: sub, alias: "tester", role: "验收", brief: brief) + """


            ## 你的流程
            1. coder 的提审消息（里面有提交的 SHA）会由系统在之后单独发给你，收到后在这个 SHA 上验收。
            2. 只验收这一个功能，不要修改业务代码。按需求逐条核对，能跑的测试和真实调用都要跑。
            3. 验收结论必须带 --verdict（系统靠它计数，打回次数过多会自动交给群主）：
               不通过：\(cli) send -g \(sub.id) --from tester --to coder --verdict fail "哪条不符合、怎么复现"
               通过：  \(cli) send -g \(sub.id) --from tester --to coder --verdict pass "验收了什么、在哪个 SHA 上"
               结论只发给 coder，不用告诉 \(sub.owner)：coder 合并完会向它汇报。向 coder 提问、要补充信息时不带 --verdict。
            4. 合并由 coder 负责，不要请别人合并。coder 合并时如果有新改动会再发给你验一次。
            5. 验收受阻（缺环境、工具用不了、需求有歧义自己没法判断）：发给 \(sub.owner)，说清楚卡在哪里。

            这一条只是让你记住角色和需求。现在立即结束这一轮：只回复「已就位」，不要发群消息，
            不要开始任何工作，也不要用 sleep、轮询或任何方式在这一轮里等待 coder——
            它的消息要等你这一轮结束后才能送进来，在这一轮里等只会把自己卡住。
            """
    }

    /// 找回子群时告诉原会话的那一段：它记得的是旧群，群 ID 已经换了
    private static func reopenedNote(sub: GroupSummary) -> String {
        """


        ## 这是找回的子群
        你之前在另一个子群里做过这个功能，那个子群解散后，群主把你找回到这个新子群（\(sub.id)）。
        还是原来的 worktree 和分支，之前的提交都在。旧群已经不存在了，往旧群 ID 发消息会失败：从现在起只用上面的新群 ID 发消息。
        """
    }

    /// 发给找回的 coder：接着原会话，收到就开工
    static func reopenedCoderIntro(sub: GroupSummary, brief: String) -> String {
        subgroupBasics(sub: sub, alias: "coder", role: "编码", brief: brief) + reopenedNote(sub: sub) + """

            流程和之前一样：改完提交后发给 tester 验收，通过后由你合并回 \(sub.baseBranch)，再向 \(sub.owner) 报告合并结果；
            做不下去时发给 \(sub.owner)。这次要做的就是上面「这个功能的需求」里写的内容。

            现在开始。
            """
    }

    /// 发给找回的 tester（接着原会话）：只让它记住新群 ID，等 coder 提审
    static func reopenedTesterIntro(sub: GroupSummary, brief: String) -> String {
        subgroupBasics(sub: sub, alias: "tester", role: "验收", brief: brief) + reopenedNote(sub: sub) + """

            流程和之前一样：收到 coder 的提审再验收，结论带 --verdict 只发给 coder。

            如果这一轮里只有这条说明：立即结束这一轮，只回复「已就位」，不要发群消息，不要开始任何工作，
            也不要用 sleep、轮询或任何方式在这一轮里等待 coder。如果这一轮里还附带了 coder 的提审，就按提审直接验收。
            """
    }

    /// reopen 命令返回给群主的文字
    static func reopened(sub: GroupSummary, coderId: String, testerId: String) -> String {
        """
        已找回子群「\(sub.name)」(\(sub.id))，挂在集群下面，coder 和 tester 正在后台启动。
        coder：接着原会话 \(coderId)
        tester：\(testerId.isEmpty ? "新建（没传 --tester）" : "接着原会话 \(testerId)")
        worktree：\(sub.worktree)（原来的，提交都在）
        分支：\(sub.branch)（验收通过后由 coder 合并回 \(sub.baseBranch)）
        之后和它们沟通：\(cli) send -g \(sub.id) --from \(sub.owner) --to <coder|tester|all> "消息内容"
        """
    }

    /// 群主解散子群后的回复里附上的找回命令（带这次的会话 ID，以后要找回时照着执行）
    static func reopenHint(clusterId: String, owner: String, coderId: String, testerId: String) -> String {
        let tester = testerId.isEmpty ? "" : " --tester \(testerId)"
        return "以后要找回这个子群的 coder / tester，记下这条命令：\(cli) reopen -g \(clusterId) --from \(owner) --coder \(coderId)\(tester) --task <功能名> \"这次要做什么\"" +
            "（不要自己调接口建普通群拉成员）"
    }

    /// spawn 命令返回给群主的文字
    static func spawned(sub: GroupSummary, dirtyWarning: Bool) -> String {
        var text = """
            已建好子群「\(sub.name)」(\(sub.id))，coder 和 tester 正在后台启动。
            worktree：\(sub.worktree)
            分支：\(sub.branch)（验收通过后由 coder 合并回 \(sub.baseBranch)）
            之后和它们沟通：\(cli) send -g \(sub.id) --from \(sub.owner) --to <coder|tester|all> "消息内容"
            它们只在任务完成（coder 合并完）或受阻时才在子群里找你，其余时候不要插手。合并由 coder 负责，你不要自己合并。
            """
        if dirtyWarning {
            text += "\n注意：主目录有没提交的改动，worktree 是从最新提交开始的，不包含这些改动。"
        }
        return text
    }

    // ---------- 集群：群主 ----------

    /// 群主加入集群主群时收到的说明
    static func ownerIntro(group: GroupSummary, owner: Member) -> String {
        """
        [kkAgent 集群「\(group.name)」] 你是这个集群的群主，名字：\(owner.alias)。
        用户会在这里给你一个比较大的需求。你负责梳理、拆解、分派和汇总，不自己写业务代码、不自己合并。

        ## 流程
        1. 收到需求后，先读代码、和用户把需求梳理清楚，拆成几个可以独立开发和验收的功能。
           拆的时候尽量让各功能不改同一批文件，减少合并冲突。
           每个子群只放一个能独立验收的小功能，不要把好几项任务塞进同一个子群：
           子群里的会话会一直累积历史，任务一大就会被自动压缩，早期的需求和规则只剩摘要，容易做偏。
           有先后依赖的几项，按顺序一个子群一个子群地派：前一个合并完，再 spawn 下一个。
        2. 把拆解结果发给用户确认：\(cli) send -g \(group.id) --from \(owner.alias) --to user "拆解方案"。
           用户同意之前，不要开始分派。
        3. 第一次 spawn 前，先把仓库准备好（子群的 worktree 会建在 <仓库>/.worktrees/<子群ID>，里面是整份代码）：
           a. 仓库根目录的 .gitignore 要忽略 .worktrees/。用 git check-ignore -q .worktrees/x 检查，返回 0 就是已忽略；
              没忽略的话 spawn 会被拒绝。
           b. 主项目里按目录扫文件的工具都要排除 .worktrees，否则会把子群的整份代码再扫一遍（重复报错、测试跑两遍、构建变慢）。
              逐个看项目实际用到的配置：tsconfig 的 include / exclude、eslint 的忽略配置、prettier 的忽略文件、
              vitest / jest 的测试文件匹配、tailwind 等的 content 扫描路径、monorepo 工作区的包匹配（如 pnpm-workspace.yaml），
              以及其他会递归扫目录的脚本。
           c. 改动提交到主分支后再 spawn。要改的地方拿不准、或者会影响别人的配置，先告诉用户由用户决定。
           用户同意后，每个功能执行一次：
             \(cli) spawn -g \(group.id) --from \(owner.alias) --task <功能名> - <<'EOF'
             <这个功能的需求说明：要做什么、完成标准、怎么验证、注意事项>
             EOF
           系统会为它建一个子群和独立的 git worktree，在后台拉起 coder（Claude，编码）和 tester（Codex，验收）。
           需求说明要写完整：它们只看得到你给的这一段，看不到其他功能和你和用户的对话。
        4. 子群只在两种情况下找你：任务完成（coder 报告合并结果）、或者任务受阻（coder / tester 卡住了要你决定）。
           没找你就说明在正常推进：不要插手，不要去核对进度、代码或环境，也不要主动给它们发消息。
           - 它们来问你：在那个子群里回答（\(cli) send -g <子群ID> ...）。coder 和 tester 都要知道的事发给 all，
             不要分别各发一遍；只是知会、不需要它们回复时，写明「不用回复」。
           - 由 coder 合并，你等它报告合并结果即可，不要自己合并。
           - 系统通知「已暂停自动打回」：说明那个功能卡住了，看清情况后
             在子群里给 coder 发具体指示（这会解除暂停），解决不了就告诉用户。
        5. coder 报告合并完成、你确认无误后，解散那个子群，停掉它的 coder 和 tester：
             \(cli) dissolve -g <子群ID> --from \(owner.alias)
           worktree 和分支会保留。只能解散子群，主群由用户解散。解散时会回给你一条带 coder / tester 会话 ID 的找回命令，记下来。
           解散后又需要原来的 coder / tester（比如发现问题要它们接着改），用找回命令在这个集群下重建子群，它们会接着原会话：
             \(cli) reopen -g \(group.id) --from \(owner.alias) --coder <coder 会话ID> [--tester <tester 会话ID>] --task <功能名> "这次要做什么"
           不要自己调 kkAgent 的接口建普通群、把它们拉进去。
        6. 所有功能都合并后，把汇总发给用户：每个功能做了什么、合并后的 SHA、还有什么风险。

        不要为了「收到」「好的」这类确认单独发消息。现在不需要回复，等用户的需求。
        """
    }

    /// 打回超过上限后，tester 的结论改投给群主，前面加上这一句
    static func blockedNotice(count: Int, limit: Int) -> String {
        "【系统：这是第 \(count) 次验收不通过，已超过 \(limit) 次，暂停自动打回给 coder，请群主介入。" +
            "你在子群里给 coder 发消息后会解除暂停。以下是 tester 这次的结论】"
    }

    /// 群主已被移出子群时，原本给它的内容改留给用户，前面加这一句
    static func ownerMissing(owner: String) -> String {
        "【系统：群主 \(owner) 已不在这个子群里，以下内容没法交给它，请你处理（可以把群主重新拉进子群）】"
    }

    // ---------- 集群：出错通知 ----------

    /// 核心重启打断了正在跑的一轮
    static func interrupted(sub: GroupSummary, alias: String) -> String {
        """
        [kkAgent 集群子群「\(sub.name)」] 系统通知：kkAgent 核心重启，\(alias) 正在进行的工作被中断了。
        系统不会自动重发（它可能已经改了一半文件）。请你确认它的状态：
        \(cli) send -g \(sub.id) --from \(sub.owner) --to \(alias) "检查工作目录的状态，继续完成并汇报"，或者告诉用户。
        """
    }

    /// 消息没能送进成员的会话（或者那一轮异常中断了）
    static func deliveryFailed(sub: GroupSummary, member: Member, reason: String) -> String {
        let where_ = member.tmux.isEmpty ? "" : "可以在 kkAgent 里打开 \(member.alias) 的会话看看（tmux 会话名 \(member.tmux)）。"
        return """
        [kkAgent 集群子群「\(sub.name)」] 系统通知：给 \(member.alias) 的消息投递出错了（\(reason)）。
        系统不会自动重发。请你判断要不要重新发给它，解决不了就告诉用户。\(where_)
        """
    }

    /// 消息已经写进成员的会话，但没能确认它收到了（见 TmuxDelivery.swift）
    static func deliveryUnconfirmed(groupName: String, member: Member, reason: String) -> String {
        let where_ = member.tmux.isEmpty ? "" : "可以在 kkAgent 里打开 \(member.alias) 的会话看看（tmux 会话名 \(member.tmux)）。"
        return """
        [kkAgent 群聊「\(groupName)」] 系统通知：给 \(member.alias) 的消息已经写进它的会话，但没能确认它收到了（\(reason)）。
        为了不重复，系统不会重发，之后给它的消息也先排着。
        请到界面上看一下它的会话：确认它收到了，或者确认没收到、要重新发，处理完在界面上点「解除并继续」。\(where_)
        """
    }

    /// 成员卡在授权框上（见 AgentStatus.swift）。remind = 等了很久还没处理，再提醒一次
    static func permissionWaiting(groupName: String, member: Member, info: PermissionInfo, remind: Bool, waitedSeconds: Int) -> String {
        let who = info.bySubagent ? "\(member.alias) 的子 agent" : member.alias
        let waited = waitedSeconds < 60 ? "\(waitedSeconds) 秒" : "\(waitedSeconds / 60) 分钟"
        let head = remind ? "已经等了 \(waited)，还没处理：" : ""
        let open = member.tmux.isEmpty ? "" : "可以在 kkAgent 里打开 \(member.alias) 的会话处理（tmux 会话名 \(member.tmux)）。"
        return """
        [kkAgent 群聊「\(groupName)」] 系统通知：\(head)\(who) 在等授权——\(info.tool)：\(info.detail)
        只有用户能在它的会话里点批准或拒绝，系统不会替它点。请告诉用户去处理。\(open)
        处理完之前，发给 \(member.alias) 的消息会先排着，处理完自动送进去。
        """
    }

    /// 后台 tester 初始化失败
    static func bootstrapFailed(sub: GroupSummary, alias: String, reason: String) -> String {
        """
        [kkAgent 集群子群「\(sub.name)」] 系统通知：\(alias) 的会话初始化失败（\(reason)），它收不到后续消息。
        这个子群没法正常验收，请告诉用户。可以解散这个子群后重新 spawn。
        """
    }

    // ---------- 群里新建的会话（见 API.createMember） ----------

    /// 新建 Codex 会话时，接在入群说明后面：这一轮只用来把会话建出来，要它立即结束。
    /// 不用 testerIntro：那份带着 tester 的角色和验收流程，会覆盖用户填的「负责什么」
    static let bootstrapEndTurn = """
        这一条是入群说明，现在立即结束这一轮：只回复「已就位」，不要发群消息，不要开始任何工作，
        也不要用 sleep、轮询或任何方式在这一轮里等待别人的消息——群消息要等你这一轮结束后才能送进来。
        """

    /// 普通群里 kkAgent 托管的会话出错了（给用户看的系统告警）。bootstrap = 入群说明那一轮（Codex 建会话）失败
    static func memberStartFailed(group: GroupSummary, member: Member, bootstrap: Bool, reason: String) -> String {
        if bootstrap {
            return """
            [kkAgent 群聊「\(group.name)」] 系统通知：\(member.alias) 的会话没能建起来（\(reason)），它收不到后面的消息，发给它的消息先排着。
            可以把 \(member.alias) 移出群，再重新新建一个。
            """
        }
        return """
        [kkAgent 群聊「\(group.name)」] 系统通知：给 \(member.alias) 的消息投递出错了（\(reason)），这一条系统不会自动重发。
        可以在 kkAgent 里打开 \(member.alias) 的成员详情，点「重新打开会话」（tmux 会话名 \(member.tmux)），打开后排着的消息会自动送进去；
        这一条需要的话请重新发一次。
        """
    }

    // ---------- 第 6 步第二期：紧急消息打断（见 Interrupt.swift） ----------

    /// 系统告警的开头：普通群和集群子群的写法不一样
    static func alertHeader(_ group: GroupSummary) -> String {
        group.parentId.isEmpty ? "[kkAgent 群聊「\(group.name)」] 系统通知：" : "[kkAgent 集群子群「\(group.name)」] 系统通知："
    }

    /// 按了 Esc，但会话记录里一直认不出结果（比如刚提交就被打断、提示词被放回了输入框）
    static func interruptUnknown(member: Member, sender: String) -> String {
        let open = member.tmux.isEmpty ? "" : "（tmux 会话名 \(member.tmux)）"
        return """
        为了 \(sender) 的紧急消息，系统按了一次 Esc 打断 \(member.alias)，但一直没法确认结果。
        为了不把消息贴进状态不明的会话，给 \(member.alias) 的消息先排着。请在 kkAgent 里打开它的会话看一下\(open)：
        输入框里如果留着旧的提示词，删掉或者重新提交都可以；它空闲下来、或者开始新的一轮后，排着的消息会自动送进去。
        """
    }

    /// 紧急消息排了一阵还是没能打断对方（只是没按，消息仍然排在最前面）
    static func interruptNotPressed(member: Member, sender: String, reason: String) -> String {
        "\(sender) 发给 \(member.alias) 的紧急消息没能打断它（\(reason)），消息仍排在最前面，等它这一轮结束后先送进去。需要立刻停下的话，请到它的会话里手动处理。"
    }

    /// 带紧急消息的这一批投递前面加的一行，说明对方上一轮发生了什么。本来就空闲的不加
    static func interruptNote(_ note: InterruptBook.Note) -> String {
        switch note {
        case .interrupted:
            return "[kkAgent] 你上一轮被中途打断了：先看完下面的消息，再检查工作区里有没有改了一半的文件，以及还在跑的后台命令，然后决定是否继续原来的工作。"
        case .natural:
            return "[kkAgent] 你刚好结束了上一轮。"
        case .notInterrupted:
            return "[kkAgent] 没能打断你上一轮的工作，这些消息排在最前面。"
        }
    }

    /// 合并投递：上一轮期间收到的几条消息合成一条送进去
    /// 合并投递的一条：正文、是不是紧急消息、发送时间（ISO 格式）
    struct MergedItem {
        let text: String
        let urgent: Bool
        let sentAt: String
    }

    /// 合并投递：紧急消息一组排在前面，普通消息一组在后面，两组内部都按发送时间排。
    /// 不能笼统地说「以最新的为准」：紧急纠偏排在前面，按这个说法会被后面更早发出的普通消息覆盖
    static func merged(_ items: [MergedItem]) -> String {
        let urgent = items.filter(\.urgent)
        let normal = items.filter { !$0.urgent }
        var intro = "[kkAgent] 你上一轮工作期间收到了 \(items.count) 条消息，合并在下面，一次处理完；每条末尾的回复方式照常适用。"
        if urgent.isEmpty {
            intro += "按发送时间排列，后面的消息可能更新或取代前面的，冲突时以较新的为准。"
        } else {
            intro += "其中 \(urgent.count) 条是紧急消息，排在最前面，请先看。"
                + "紧急消息和普通消息各自按发送时间排列；同一组里冲突时以较新的为准；"
                + "紧急消息和比它更早的普通消息冲突时，以紧急消息为准。"
        }
        var parts = [intro]
        var index = 0
        for (group, label) in [(urgent, "紧急 · "), (normal, "")] {
            for item in group {
                index += 1
                parts.append("=== 第 \(index) 条（\(label)\(clock(item.sentAt)) 发出）===\n\(item.text)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// ISO 时间 → 本地的「时:分:秒」；解析不了原样返回
    static func clock(_ iso: String) -> String {
        guard let date = parseISO(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 把一条群消息包装成发给收件人的文字。verdict 是 tester 的验收结论，加在正文前面方便对方一眼看到。
    /// 紧急消息单独送达时也要看得出来：开头标明紧急、发送人和时间（合并投递时每一条的标题里还会再标一次）
    static func delivered(group: GroupSummary, sender: Member?, recipient: Member, content: String, verdict: String = "",
                          urgent: Bool = false, sentAt: String = "") -> String {
        let from = sender.map(describe) ?? "用户"
        let replyTo = sender?.alias ?? "user"
        let urgentHead = urgent
            ? "【紧急】\(from)于 \(clock(sentAt)) 发出。请先看这条；和它冲突的、更早的普通指示，以这条为准。\n"
            : ""
        let head = urgentHead + (verdict == "pass" ? "【验收通过】\n" : verdict == "fail" ? "【验收不通过】\n" : "")
        // 集群子群：不能每条都邀请回复，否则成员之间会来回确认个没完（实测出现过群主和 tester 两分钟来回 12 条）
        let footer = group.parentId.isEmpty
            ? "—— 回复请执行：\(cli) send -g \(group.id) --from \(recipient.alias) --to \(replyTo) \"结论\"（只发结论）"
            : "—— 需要对方做事或回答时才回复：\(cli) send -g \(group.id) --from \(recipient.alias) --to \(replyTo) \"结论\"。"
                + "只是知会、不需要你做什么时不回复；找群主只限任务完成或受阻。"
        return """
            [kkAgent 群聊「\(group.name)」] 来自 \(from)：
            \(head)\(content)

            \(footer)
            """
    }
}
