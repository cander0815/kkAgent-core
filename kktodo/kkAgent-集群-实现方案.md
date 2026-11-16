# kkAgent 集群：实现方案（第 2 版，已按 tester 审核意见修改，2026-11-11）

产品层面的决策见 `kktodo/kkAgent-集群方案.md`。本文是落到代码上的具体改法，分两步：
- **第 1 步**：能 spawn 出子群、两个后台会话真的跑起来，按正确顺序收发消息；
- **第 2 步**：结构化验收结论、打回上限、看门狗，让流程能无人值守地走完。

界面（树形群列表等）放第 3 步，本文不展开。文末第 3 节列出审核意见里**没采纳**的部分和原因。

---

## 0. 现状（改动前）

- 核心：`mac/Sources/Core/`，launchd 后台服务，HTTP 127.0.0.1:7788，请求并发处理。
- 投递：`Delivery.swift`，每个成员（member.id）一条串行队列，普通投递和通知共用。
  - Codex：`codex queue --thread <id> --message <文本>`
  - Claude 开着：中转会话实时送进窗口；Claude 没开着：`claude -p --resume <id>`
- 群表只有 `id/name/created_at`；成员表有 `session_id/cwd/vm`。
- `SQLite.swift` 的锁只保护单条语句，不保护多条语句组成的事务。

---

## 第 1 步：spawn + 后台会话

### 1.1 数据库（`Repository.swift`，沿用现有补列写法）

| 表 | 新列 | 含义 |
| --- | --- | --- |
| groups | `parent_id` | 空 = 顶层群；否则是所属集群（主群）的 id |
| groups | `owner` | 主群：群主的成员名（第一次 spawn 的成员成为群主，之后只有它能 spawn）。子群：同一个名字 |
| groups | `worktree` / `branch` / `base_branch` | 子群的 worktree 路径、分支、要合并回去的目标分支 |
| members | `headless` | 1 = 核心在后台建、后台运行的会话 |

`GroupSummary` 加 `parentId / owner / worktree / branch / baseBranch`，`Member` 加 `headless`（`Shared/Models.swift`）。

审核提到「两份方案里 kind / mode / headless 不统一」：统一成上表。集群主群用「有子群 / 有 owner」识别，不另加 kind；人工接管不另加状态（见 1.5）。

### 1.2 命令行和接口

```text
kkAgent spawn -g <主群ID> --from <群主名字> --task <功能名> "需求说明"      # 需求说明写 - 时从 stdin 读
→ POST /api/groups/:id/spawn   表单 from/task/content
← 立即返回纯文本：子群ID、成员、worktree、分支、「两个会话正在启动，之后用 kkAgent send -g <子群ID> 沟通」
   主目录有没提交的改动时额外提示：「worktree 从最新提交开始，不包含主目录里没提交的改动」
```

返回时**不声称会话已就绪**：会话启动是异步的，启动失败会显示在群聊的投递状态里（现有界面已经能看到失败的投递和原因）。

### 1.3 spawn 的处理顺序（新文件 `Core/Cluster.swift`）

1. **校验**：主群存在且本身不是子群；`from` 是主群成员；主群已有 owner 时 `from` 必须是 owner；
   群主名字不能是 `coder` / `tester`；`task`、需求说明不为空。
2. **仓库目录** = 群主会话的 `cwd`。要求这个目录在物理机上存在（群主在虚拟机里也行，`/Users` 下两边是同一份）。
   `git rev-parse --show-toplevel` 取仓库根目录，`git symbolic-ref --short HEAD` 取当前分支作为 `base_branch`；
   不是 git 仓库、或处于分离 HEAD 状态，就报错。spawn 出来的会话一律跑在物理机上。
3. **建子群**（`parent_id`、`owner`、`base_branch` 一起写入）。
4. **建 worktree**：路径 `<仓库根的上一级>/<仓库名>-kkwt/<子群ID>`，分支 `kkagent/<子群ID>`，从 `base_branch` 最新提交开始。
   失败就删掉刚建的子群，把 git 报错原样返回。成功后写回路径和分支。
5. **群主进子群**：成员行照抄群主在主群的那一行（alias / agent / session_id / vm / cwd / **headless 也照抄**），不发入群说明。
6. **加 coder 成员**：Claude，核心生成 UUID 作 `session_id`，`cwd = worktree`，`headless = 1`。
7. **加 tester 成员**：Codex，`session_id` 先留空，`cwd = worktree`，`headless = 1`。
8. **发入群说明，顺序固定：先 tester，再 coder**（见 1.4 (c)）。
   - tester：角色说明 + 需求说明 +「等 coder 发来再行动，这一条不需要回复」。这条投递标记为 **bootstrap**，负责建出 Codex 会话。
   - coder：角色说明 + 需求说明 + worktree/分支 + 合并规则。这条会让 coder 立刻开工。

第 6~8 步是本地数据库写入，失败的可能性很低；真失败了就把错误返回给群主，子群和 worktree 保留，方便排查（不擅自删可能已有改动的 worktree）。

### 1.4 投递改造（`Delivery.swift`）

**(a) 投递前重新读一次成员。** tester 的 `session_id` 是第一轮跑起来才回填的，排队时捕获的那份是空的。成员已被移出就不投。

**(b) 串行队列的 key 改成「会话」，普通投递和通知用同一套。**
群主同时是主群和多个子群的成员，几行成员指向同一个会话，按成员排队会并发续接同一个会话。

```text
key = headless 的 Codex 成员：成员 id          （ID 跑起来才知道，排队时无从按会话归类）
      其他成员：             (agent, vm, session_id) 三元组，用结构体做 key，不拼字符串
```

headless Codex 用成员 id 的前提是「这个会话只有这一行成员」。为保证这一点：
**`addMember` 拒绝加入已经属于某个 headless 成员的会话**（报错「这是集群后台会话，不能再加到别的群」）。
tester 回填会话 ID 后也不换队列，避免旧队列里还有积压。

**(c) 初始化顺序。** spawn 时 tester 的 bootstrap 先进 tester 队列，coder 的说明后进 coder 队列。
coder 干完发给 tester 的消息一定排在 bootstrap 后面（同一条串行队列，先进先出），不会抢先成为 tester 的第一轮。

**(d) 只有 bootstrap 投递能新建 Codex 会话。**
headless Codex 成员 `session_id` 为空时，非 bootstrap 的投递直接失败（「tester 会话还没建好」），不会悄悄建出第二个会话。
`thread.started` 拿到的 ID 和已有的非空 ID 不一致，也按失败处理。

**(e) Claude 后台成员第一轮**：会话文件还不存在时用 `--session-id <uuid>`，存在时用 `--resume <uuid>`。

**(f) Codex 后台成员改走 exec**（非 headless 的 Codex 成员仍用 `codex queue`，不动）：

```text
新建：<codex> -a never exec --json -s workspace-write -C <worktree> -
续接：<codex> -a never exec --json -s workspace-write -C <worktree> resume <thread_id> -
```

- 提示词写进 stdin 后关闭；`currentDirectoryURL` 也设成 worktree。
- 新增 `runCapturing()`：stderr 在另一个线程读到底，主线程逐行读 stdout，最后 `waitUntilExit()`。
- `thread.started`：回填 `session_id`；`turn.completed` / `turn.failed` / `error` 记下来。
- **成功** = 退出码 0 且收到 `turn.completed` 且没有 `turn.failed`；否则投递标失败，带上 stderr 末尾。
- 模型在这一轮里输出的文字不会自动变成群消息，群消息只来自 `kkAgent send`。
- tester 实测：workspace-write 下在 worktree 里跑 `git status` / `git diff` 正常，不需要额外的 `writable_roots`。

**(g) 记住正在跑的后台进程**：`DeliveryQueue` 保存「成员 id → 正在运行的 Process」，提供 `cancel(memberId)`（terminate）。
用于解散和移出（1.5）。

### 1.5 解散、移出、人工接管

- **解散主群**：子群一起解散。对 headless 成员：取消排队、终止正在跑的进程，**不发「已解散」通知**
  （它们是专门为这个任务建的会话，任务没了就停下，不用再唤醒一次）。非 headless 成员（群主）照常通知。
- **移出 headless 成员**：同样取消排队并终止进程。
- **worktree 和分支不删**，解散的返回结果里列出路径，由人决定。
- **人工接管**：第 1 步不做专门的接管状态。想插手时，先在界面上把这个成员移出（会停掉后台进程），再用 `claude --resume` / `codex resume` 在终端打开。
  「先停、再接管」保证不会两个进程同时写一个会话。专门的「暂停 / 接管」按钮放到第 3 步界面里做。
- **核心重启**：launchd 停掉核心时会连同它启动的子进程一起结束（实现时实测确认，确认不了就在启动时清理）。

### 1.6 第 1 步需要的最小角色说明（`Prompts.swift`）

不先有角色说明，「coder 改完发给 tester」这条链路就验不了，所以放在第 1 步：

- **coder**：只做这一个功能；在 worktree 里改代码、自测；**提交（commit）后**发给 tester，写清改了什么、怎么验证、提交的 SHA；
  发完就结束这一轮，等 tester 的结论，不要在 tester 验收期间继续改文件。
- **tester**：只验这一个功能；不改业务代码；在 coder 给的 SHA 上验收；
  结论发给 coder，验收通过时同时发给 owner（`--to all`）。
- 合并规则（coder）：验收通过后，
  1. 在自己的 worktree 里把 `base_branch` 最新代码合进来，解决冲突，跑通测试；
  2. 合并主分支后有任何新改动（包括解决冲突），重新提交并发回 tester 再验一次，拿到通过才继续；
  3. 确认主目录当前检出的就是 `base_branch`，然后执行 `git merge --ff-only kkagent/<子群ID>`；
  4. `--ff-only` 失败说明这期间别的功能先合并了，回到第 1 步重来；
  5. 主目录不在 `base_branch` 上，或者有没提交的改动导致合并失败，不要擅自处理，报给 owner；
  6. 合并完报给 owner。

### 1.7 第 1 步怎么验收（真实链路，不用 mock）

1. 装核心，建一个测试群，拉一个真实的 Claude 会话当 owner。
2. 执行 `kkAgent spawn -g <群> --from owner --task 小功能 "在某个测试文件末尾加一行 hello"`。
3. 检查：
   - 数据库：子群的 `parent_id / owner / worktree / branch / base_branch` 正确，三个成员；`git worktree list` 里有新 worktree；
   - tester 的 bootstrap 先跑，`session_id` 被回填；
   - coder 在 worktree 里改文件、提交，用 `kkAgent send` 发给 tester；
   - tester 用 `exec resume` 续上（能说出第一轮里的需求），在 SHA 上验收，用 `kkAgent send` 发回结论（顺便验证沙箱下能访问本机核心）；
   - coder 合并：主分支确实前进到了 coder 的提交；
   - owner 收到子群消息。
4. 解散主群：子群消失，后台进程被终止，worktree 还在。
5. 把同一个 tester 会话 ID 手动加到别的群：被拒绝。

### 1.8 第 1 步实现结果（2026-11-11）

已实现并用真实会话跑通（测试仓库 `/private/tmp/kkcluster-demo`，群主是那里新建的一个真实 Claude 会话）：

| 验收项 | 结果 |
| --- | --- |
| spawn 错误输入（非成员、缺 --task、群不存在） | 返回对应中文错误 |
| 子群、worktree、分支、三个成员落库 | 正确；tester 的 Codex 会话 ID 在 bootstrap 里回填 |
| coder 实现 → 提交 → 发 tester | 通过 |
| tester 用 exec resume 续接、在 SHA 上验收、经 kkAgent 发结论（沙箱能访问本机核心） | 通过 |
| coder 合并回 main、报给 owner、owner 汇总给 user | 通过（第 2 轮由群主自己执行 spawn，全链路无失败投递） |
| 后台会话重复加到别的群 | 被拒绝 |
| 解散主群：子群一起删、正在跑的 coder / tester 进程被停、worktree 保留 | 通过 |

第 1 轮发现并已修正的提示词问题：
- tester 说了「请 owner 合并」，群主就自己合并了（coder 合并时已经是最新）。→ tester 说明里写明合并由 coder 负责；spawn 返回给群主的文字里写明群主不要自己合并。
- 子群成员之间互发「收到」「任务结束」。→ 子群说明里加上不发确认消息的规则。修正后第 2 轮没有再出现。

和方案的出入：解散的返回结果没有列出 worktree 路径（界面调用的接口只返回 ok），路径记在核心日志里。

**tester 验收第 1 次不通过**（它自己跑的一轮里复现）：tester 的入群说明那一轮把「等 coder 的消息」理解成在这一轮里等，
一直调用 sleep 不退出，后面的提审被堵在队列里。另指出取消竞态和管道读写顺序两个问题。修复：

| 问题 | 修复 | 复验（真实链路） |
| --- | --- | --- |
| 入群说明那一轮不退出 | 说明里写明「立即结束这一轮、只回复已就位、不要 sleep / 轮询等待」；再加时限（默认 180 秒，`KK_BOOTSTRAP_TIMEOUT`），超时停掉进程，会话 ID 已回填就算成功 | A：初始化 5 秒自己结束（task_complete、回复「已就位」）→ coder 提审 → tester resume 验收 → coder 合并 → 报 owner，无失败投递。B：时限设 3 秒，超时停掉后 coder 的提审照样 resume 成功并验收通过 |
| 移出 / 解散和进程启动之间的取消竞态 | 记取消标记；「查标记 + 登记进程」在同一把锁里，已取消的成员新启动的进程立即停掉 | 只做了代码层面的修复，竞态窗口很小，没有强制命中 |
| 先写完 stdin 再读输出，大输入可能卡死 | 先启动 stdout / stderr 读取，stdin 在另一个线程写 | 普通链路照常；没做大输入压测 |
| **核心重启后后台进程残留（复验中新发现）** | 方案 1.5 假设「launchd 会连同子进程一起停」，实测不会：进程被 launchd 接管继续跑。改为核心收到退出信号时停掉所有投递进程，最多等 3 秒 | C：coder 正在跑时重启核心，coder 进程和它起的子进程都已退出，日志有「停止投递进程」 |

**tester 复验：正常链路通过，退出清理仍有问题**（它用原版源码 + 模拟 codex 的隔离测试复现）：

| 问题 | 修复 | 验证 |
| --- | --- | --- |
| terminateAll 停掉当前进程后，队列里排着的下一条会接着启动，成为孤儿 | 加 `stopping` 标记：terminateAll 先在锁里置位再取名单；deliver 和 register 都拒绝新的执行；3 秒后还活着的进程发 SIGKILL | 用 tester 的隔离测试重跑：退出后状态 `[failed, pending]`（第二条没启动），无残留进程。SIGKILL 分支没能触发：用 sh / perl 写的忽略 SIGTERM 的模拟进程，在 Foundation 的 terminate 下都立即以 15 退出 |
| bootstrap 超时分支掩盖已记录的 turn.failed | 超时分支先检查已记录的错误，有就按失败处理；`timedOut` 加锁 | 隔离测试：先 turn.failed 再超时 → 投递为 failed，错误信息包含原因 |
| （回归）管道压力 | — | 3MiB stdin + 2MiB stderr 仍然 delivered |
| （回归）真实链路 | — | 装新核心后真实跑一轮「平方函数」：bootstrap → 提审 → 验收 → 合并 → 报 owner，无失败投递 |

仍未做：人工接管时「等进程真正退出再允许 resume」（放到第 3 步界面里的接管按钮）。

---

## 第 2、3 步实现结果（2026-11-11）

和下面第 2 步原方案的出入：
- 集群改成**建群时指定**（`groups.cluster`），集群主群只能有一个成员（群主），加入时发群主版说明；只有集群群聊能 spawn。
- `--verdict`：pass 必须发给 all，fail 必须发给 coder，只有子群里的 tester 能带。
- 看门狗判断「汇报」：只看这一轮里它有没有发过消息，tester 不额外要求带 verdict（tester 向 coder 提问也是正常结束）。
- 看门狗只管 coder ↔ tester 之间的消息和 coder 的开工说明（`purpose = task`）。实测发现群主说「不用回复」时 coder 正确地没回复，
  却被看门狗催了，所以群主 / 用户发的消息改成 `instruction`，不归看门狗管。
- 核心退出时被停掉的那一轮，状态保持「投递中」，下次启动统一标成「核心重启，投递中断」并通知群主（之前会被标成失败，导致漏通知）。

真实链路实测（测试仓库 `/private/tmp/kkcluster-demo`，群主是真实 Claude 会话）：

| 验收项 | 结果 |
| --- | --- |
| 集群群聊规则：群主不能叫 coder、只能有一个成员、普通群不能 spawn、普通群不能带 verdict | 都返回对应错误 |
| 群主收到大需求 → 拆成 2 个功能发给用户确认 → 用户同意后 spawn 2 个子群 | 通过，确认前没有分派 |
| 2 个子群并行开发，tester 用 `--verdict pass` | 通过，数据库 verdict 列正确 |
| 先合并的直接 ff；后合并的 ff 失败 → 把 main 合进自己分支 → 发回 tester 复验 → 通过后合并 | 通过，main 最终包含两个功能，ALL PASS |
| verdict 校验：coder 带 verdict、fail 发给 all、乱写 | 都被拒绝 |
| 连续 9 次 fail：前 8 次投给 coder，第 9 次改投群主并附说明，`fail_count=9, blocked=1` | 通过 |
| 群主给 coder 发消息解除暂停 | `0|0` |
| 看门狗提醒：coder 8 轮都没回复，队列里还有消息时不催，最后一轮后才催；催 2 次后 coder 汇报 | 通过 |
| 看门狗失败续接：kill -9 coder 进程 → 下一条是 retry（attempt 1） | 通过 |
| 核心重启打断 → 进程被停、记录标「核心重启，投递中断」、群主收到系统通知 | 修复后通过 |
| 群主说「不用回复」→ 不再被看门狗催 | 修复后通过 |
| 全过程无意外的失败投递 | 通过 |

没覆盖到：看门狗「续接 2 次后仍不汇报 → 通知群主」这条分支（coder 每次都在第 2 次提醒后汇报了）；界面效果需要人看。

---

## 第 2 步：验收结论、打回上限、看门狗

### 2.1 结构化验收结论

- `kkAgent send` 增加 `--verdict pass|fail`。messages 表加 `verdict` 列。
- 核心校验：带 verdict 的消息，发送人必须是这个子群的 `tester`，否则拒绝。
- 消息正文仍然要写清结论和 SHA；界面上按 verdict 显示「验收通过 / 验收不通过」。

### 2.2 打回上限

- groups（子群）加 `fail_count`、`blocked`。
- tester 发 `--verdict fail` 给 coder：`fail_count + 1`（用一条 `UPDATE ... SET fail_count = fail_count + 1` 原子完成）。
- `fail_count > 8` 时置 `blocked = 1`。**blocked 期间，所有发给 coder 的 fail 结论都不投给 coder**，改投给 owner，
  附一句「这是第 N 次打回，已暂停自动打回，请介入」。
- owner 在子群里发消息给 coder：清零并解除 blocked（一条 UPDATE 完成）。

### 2.3 看门狗（只管 headless 成员）

投递加两列：`purpose`（`bootstrap` / `notice` / `task`）和 `retries`。只有 `task` 类投递需要汇报。

| 情况 | 处理 |
| --- | --- |
| task 投递这一轮正常结束，但没有「汇报」 | 续一句「这一轮结束了还没汇报，继续做完并汇报」 |
| 这一轮失败（退出码非 0 / turn.failed） | 续一句「继续上次没做完的工作」 |
| 上面两种情况**合计**续了 2 次还不行 | 停止续接，通知 owner |
| 核心重启打断 | 启动时把没投完的投递标失败（现有），**并通知对应子群的 owner**（新增），不自动重投 |

「汇报」的判断：投递开始时记下当时最大的 message.id，结束后看子群里有没有 `id` 更大、发送人是该成员的消息；
tester 还要求其中有带 verdict 的。后台会话没有人会手动替它发消息，所以不需要更细的归因。

续接是新的一条投递（原投递和失败原因保留），排在队列末尾；如果这时队列里已经有新的 task 投递，就不再续接，
直接处理新任务（新任务本身就会让它继续干活）。

---

## 3. 审核意见中没采纳的部分和原因

| 意见 | 处理 | 原因 |
| --- | --- | --- |
| 每轮执行带 runId，经环境变量传给 kkAgent 来归因消息 | 不做，用「开始时最大 message.id」 | 后台会话没有人替它发消息，基线足够；runId 要改命令行、接口、表结构，代价不成比例 |
| verdict 带 reviewId 去重 | 不做 | 重复只会多计一次打回，上限是 8 次，影响有限；需要时再加 |
| spawn 带 requestId 幂等 | 不做 | 群主重复执行会多一个子群，界面上看得见、可以解散；不值得加一套幂等机制 |
| 按仓库给合并加互斥锁 | 不做，靠 `--ff-only` | `--ff-only` 本身就是乐观锁：别人先合并了，这次就会失败，coder 重新集成再合；git 自己的 index.lock 防同一时刻并发 |
| 子群阶段状态机（coder 运行→tester 验收→coder 修复） | 不做，靠角色说明约定「提审后结束这一轮等结果」 | coder 发完消息这一轮基本就结束了；状态机要改投递调度，等真出现抢跑再加 |
| 所有多语句操作改成连接级事务 | 只对计数用单条原子 UPDATE | spawn 的几次插入失败概率极低，失败时保留现场即可；全面加事务会改动 SQLite 封装和现有代码 |
| 补列不用 `try?`，改用 `PRAGMA table_info` | 不改 | 沿用现有写法（外科手术式修改） |
| 群短 ID 碰撞重试 | 不改 | 现有逻辑，36⁴ 种组合，本次不碰 |
| 后台进程超时 | 暂缓 | 第 1 步先跑通；超时时间不好定，第 2 步跑过真实任务后按实际耗时再加 |
