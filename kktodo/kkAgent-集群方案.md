# kkAgent 集群方案（草案，2026-11-11）

## 1. 目标

在一个「集群群聊」里有一个群主（owner）。我把复杂需求发给群主，群主和我梳理、拆解后，
为每个功能自动建一个子群，在子群里起一个 coder（Claude）和一个 tester（Codex），把需求发下去。
coder 和 tester 只看得到自己那个功能，做完由 tester 验收，结果报给群主，群主汇总后报给我。

## 2. 已定的决策

| 问题 | 决定 |
| --- | --- |
| 子群 | 要。子群就是普通群，多一个 `parent_id`；群主是每个子群的成员，是唯一的桥 |
| 子会话运行方式 | 后台运行，不弹终端；界面上可以「在终端打开」插手 |
| 会话连续性 | 靠会话记录文件，不靠进程常驻：每条消息续接一轮，跑完就退出 |
| 并行开发 | 每个子群一个 git worktree + 分支，coder 和 tester 共用 |
| coder | Claude，只在虚拟机里创建（2026-11-11 定：禁止在物理机上建 Claude），跟着群主所在的虚拟机 |
| tester | Codex（默认） |
| 打回上限 | tester 打回 coder 超过 8 次，核心停止转发，交给群主介入（核心计数，不靠 Agent 自觉） |
| 拆解后开工前 | 群主先在主群把拆解结果发给我确认，我同意才建子群 |

| 合并 | 验收通过后由 coder 合并回主分支，冲突也由 coder 处理（见第 4 节） |

## 3. 结构

```text
集群「订单重构」(主群)：我 + owner
 ├─ 子群「1-导出接口」：owner + coder-1(Claude) + tester-1(Codex)，worktree: ../<项目>-wt/1-导出接口
 ├─ 子群「2-权限校验」：owner + coder-2 + tester-2
 └─ ...
```

## 4. 流程

```text
1. 我 → owner：需求
2. owner 拆解 → 发给我确认
3. owner 执行 kkAgent spawn（每个功能一次）
   → 核心：建 worktree → 建子群 → 新建 coder、tester 会话 → 拉进子群 → 发入群说明（带角色和需求）
4. coder 实现 → 发给 tester
5. tester 验收 → 不通过打回 coder（第 9 次打回时转给 owner）
6. tester 验收通过 → 通知 coder 和 owner
7. coder 合并：先在自己的 worktree 里把主分支最新代码合进来、解决冲突、跑通测试，
   再到主目录 git merge --ff-only 自己的分支 → 报给 owner
   （解决冲突时改动了业务逻辑，要先发回 tester 再验一次）
8. owner 汇总 → 报给我
```

合并的注意点：主目录是我平时工作的目录，如果里面有没提交的改动导致合并失败，coder 不要擅自处理，报给 owner。

## 5. 两种 Agent 的后台运行方式

### Claude（coder，也可以是 owner）

```text
新建：claude -p --session-id <核心生成的 UUID> --output-format stream-json --verbose --permission-mode auto   （提示词走 stdin，cwd = worktree）
续接：claude -p --resume <同一个 ID> ...                                                                      （现有「会话没开着」的投递路径）
```

- 会话 ID 由核心预先生成，不用事后去找。
- 会话在终端里开着时，投递自动改走中转会话实时送进窗口（现有逻辑）。

### Codex（tester）——tester 已实测（Codex 0.167.0-alpha.3.2，用的是桌面端自带的 codex）

```text
新建：<codex> -a never exec --json -s workspace-write -C <worktree> -
续接：<codex> -a never exec --json -s workspace-write -C <worktree> resume <ID> -
```

- 提示词走 stdin，写完关闭。权限、目录参数必须放在 `resume` 前面。
- 会话 ID：从 stdout 第一行 `{"type":"thread.started","thread_id":"..."}` 里取，拿到马上落库。
  不支持预先指定 ID（传 `--session-id` 会以退出码 2 退出）；不要靠扫描最新的会话文件来对应。
- 不要加 `--ephemeral`（会话不落盘就续接不了），不要用 `--last`（多个成员时会接错）。
- 实测续接后能记得上一轮的内容，也能在目录里正常执行命令、写文件。
- 后台成员统一走 `exec`，不再用 `codex queue`：queue 只代表「送进去了」，唤醒失败也只是警告，没法知道这一轮做完没有。
- 后台建的会话存在和桌面端同一个 `~/.codex` 里，用 app-server 的 `thread/read` 能读回来（已实测）。
  桌面端侧栏会不会显示、怎么打开指定会话还没验收（只观察到当时侧栏前 10 条里没有它）。
  人工插手用 `codex resume <ID>`（交互式终端）。

### 一轮怎么算结束、成功

| | Claude | Codex |
| --- | --- | --- |
| 结束 | 进程退出 | 进程退出 |
| 成功 | 退出码 0 | 退出码 0 + 收到 `turn.completed` + 没有 `turn.failed` |
| 失败 | 退出码非 0，看 stderr | 同左；参数错误可能只在 stderr、没有任何 JSON |

注意：「一轮成功」只说明进程正常跑完，**不等于验收通过**。验收结论靠 tester 发的群消息。

## 6. 核心要补的「看门狗」

| 情况 | 处理 |
| --- | --- |
| 一轮结束了但这一轮没发过群消息（干到一半就停） | 自动续接一句「你这一轮结束了还没汇报，继续做完并汇报」，最多 2 次，还不行通知 owner |
| 进程异常退出 / 核心重启打断 | 投递标失败；自动续接一次「继续上次没做完的工作」，再失败通知 owner；界面加「重试」 |
| 打回超过 8 次 | 停止转发给 coder，把情况发给 owner |
| 后台正在跑一轮时我要在终端打开 | 提示等这一轮结束再打开，避免两个进程同时写一个会话 |

超时之后不要直接把同一条提示词再投一遍：上一轮可能已经改了文件。

## 7. 要改的代码

1. **数据库**：`groups` 加 `parent_id`、`kind`（普通 / 集群 / 子群）、`worktree`；`members` 加 `mode`（后台 / 人工接管）。
2. **核心接口 + 命令行**：`kkAgent spawn -g <主群> --task <功能名> --brief -`：
   建 worktree → 建子群 → 新建两个会话（Codex 解析 thread_id）→ 加成员 → 发角色入群说明。
3. **Delivery.swift**：
   - Codex 后台成员改走 `exec resume`；
   - `run()` 现在把 stdout 丢掉，要改成同时读 stdout 和 stderr（只读一根管道，输出多了会把进程卡死），逐行解析 JSON；
   - 每一轮的状态落库，看门狗据此判断。
4. **Prompts.swift**：owner / coder / tester 三份角色入群说明；owner 的说明里写拆解、确认、spawn、汇总的流程。
5. **界面**：群列表显示成树；子群标出 worktree 和所属集群；成员加「在终端打开」「重试」。

## 8. 权限（无人值守）

- Claude：`--permission-mode auto`（现有配置 `KK_CLAUDE_PERMISSION_MODE`）。
- Codex：`-a never -s workspace-write`，不用 `--dangerously-bypass-approvals-and-sandbox`。
  注意 `workspace-write` 并不是「只能碰 worktree」：默认还能写临时目录、能读目录外的文件，按当前用户配置也能联网。
  tester 要调 `kkAgent` 往本机核心发消息，所以**不能关网络**。要更严格的隔离，得另外套沙箱，不在本期范围。

## 9. 推进顺序和验收

```text
1. 数据库 + spawn 接口 + 命令行；Codex exec 新建 / 续接；Delivery 改造
   → 验收：真实执行 kkAgent spawn，worktree、子群、两个会话都建出来，入群说明真的送到，Codex 续接能记得上下文
2. 角色入群说明 + 看门狗 + 打回计数
   → 验收：真实跑一个小功能，走完 我 → owner → coder ⇄ tester → owner → 我
3. 界面：树形群列表、在终端打开、重试
   → 验收：我来看效果
4. 单独验收：后台建的 Codex 会话能否在桌面端打开接管
```

## 10. 参考

- tester 的实测记录（原始 JSON、stderr、协议 schema）：`/private/tmp/kkagent-codex-probe/`（临时目录，重启会清掉）
- Codex 官方非交互模式文档：https://learn.chatgpt.com/docs/non-interactive-mode
