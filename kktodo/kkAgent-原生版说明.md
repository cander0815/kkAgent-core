# kkAgent 原生版说明（macOS）

替代 Node 版（已于 2026-10-22 从仓库删除）。功能一样，不再占终端、不依赖 node。

## 结构：两个进程

```text
kkAgent 核心（kkagent-core）              kkAgent 界面（kkAgent.app）
  launchd 后台服务，开机自启、崩溃拉起  ◀──HTTP 127.0.0.1:7788──▶  SwiftUI 窗口 + 菜单栏图标
  数据库 / 投递队列 / 中转会话 / 读会话记录                         只是遥控器，退出不影响核心
        ▲
        └── kkAgent 命令行（Agent 发消息用，没变）
```

- 改界面、重装界面都不会重启核心，中转会话和排队中的投递不受影响。
- 核心只返回事实数据（会话开没开、在不在忙），显示文案全部在界面里（`Sources/App/Labels.swift`）。
- 接口数据结构在 `Sources/Shared/Models.swift`，同时编进核心和界面，改了接口两边编译都会检查。
- 核心只接受本机程序的请求：带 `Origin` 头（浏览器网页发的）或 Host 不是 `127.0.0.1/localhost:7788` 的一律 403，防止网页冒充用户给群发消息。自己写脚本调接口时别加 Origin 头。
- 数据库沿用 `~/.kkagent/kkagent.db`，Node 版的群和聊天记录都还在。切换前的备份：`~/.kkagent/kkagent.db.bak-node-20261022-165046`。

## 日常使用

- 打开界面：`~/Applications/kkAgent.app`。顶部菜单栏显示「KK」，变淡 = 核心没在跑；点它可以重新打开窗口。
- 程序坞图标只在窗口开着时出现，关掉窗口后只剩顶部的 KK（Info.plist 里 `LSUIElement`，窗口开关时在 `KKAgentApp.swift` 里切换）。
- 核心不用管，开机自动起来。关掉界面、关掉所有终端都不影响 Agent 之间收发消息。
- 控制核心：功能栏最下面的「核心」，或 ⌘,。可以看状态、启动 / 停止 / 重启、开关「登录时自动启动」、打开日志。
- 群聊：群列表右上角 + 新建群；对话区右上角 + 拉成员；点成员头像在右侧看它的执行过程和会话信息；⋯ 里解散群。
- 移出成员：还在排队、要发给它的消息会取消（正在投递的那条拦不住）；它本人收到「你已被移出」；其他成员收到「xx 已离开群聊」，群聊记录里也显示这一行。
- 解散群：每个成员都收到「群聊已解散，你已退出」，然后群的全部记录删除。以上通知都写明「不需要回复」，避免 Agent 来回打转。
- Claude 会话没开着时，「你已被移出」「群已解散」这两种通知直接跳过（日志记一行），不在后台唤醒它。Codex 分不出开没开，照常用 `codex queue` 排队。
- 会话以后被重新打开、又往不存在的群发消息，或者它已经不在群里时，核心不投递，直接回复它：「群已解散 / 你已不在群里，这条没发出去，以后不要再往这个群发，要说的内容直接回复给用户」。
- 群列表里右键一个群：置顶 / 取消置顶、解散并删除。置顶的群排最上面（按置顶先后），其余按最近活跃排；置顶只记在本机界面（UserDefaults），不经过核心。

## 虚拟机里的 Claude 会话（2026-11-10 加）

核心仍然跑在物理机上，虚拟机（ExitBox 的 ubx 机器）里的 Claude 会话可以直接加进群，用法和物理机的会话一样。

- 加成员时不用选机器：核心先在物理机找会话 ID，找不到再到正在运行的虚拟机里找，找到后把机器名记在成员上（`members.vm`，空 = 物理机）。成员详情的「会话信息」里能看到「所在机器」。
- 核心读不到虚拟机里的文件，凡是涉及虚拟机的操作都经 `ubx run <机器名> <命令>` 进去做：找会话文件、读执行过程、判断会话开没开着、后台续接（`claude -p --resume`）。代码在 `Sources/Core/VM.swift`。
- 每台机器各有一个中转会话：SendMessage 只能发给同一台机器上的会话，所以虚拟机里另起一个 `kkagent-relay`（第一次往虚拟机里开着的会话投递时才启动，核心退出时跟着退出）。它的 hook 和配置放在 `~/.kkagent/relay-<机器名>/`，这个目录在 `/Users` 下，虚拟机里同样的路径能直接读到。
- 虚拟机里访问核心：经默认网关（就是物理机）连 `7788` 端口，请求头 Host 写成 `127.0.0.1:7788`。`bin/kkAgent` 在 Linux 下自动这样做，中转会话的 hook 也是。
- 每台虚拟机要做一次的准备：`sudo ln -sf ~/.local/bin/kkAgent /usr/local/bin/kkAgent`，让里面的会话能找到 `kkAgent` 命令。想让它发消息时不弹权限确认，在虚拟机的 `~/.claude/settings.json` 里放行 `Bash(kkAgent:*)`。
- 前提：虚拟机没开隔离模式（要能看到 `/Users`、能连物理机），并且虚拟机里装了 `claude`（nvm 装的也行，启动时走 `bash -i` 读 `.bashrc`）。
- Codex 会话仍然只支持物理机上的。

已用真实会话实测：虚拟机里开着的会话（中转实时投递，内容逐字一致）、没开着的会话（后台续接）、虚拟机里用 `kkAgent send / members`、读执行过程、解散群通知、重启核心后虚拟机里的中转会话跟着退出。

## 集群（2026-11-11 加）

方案和实测记录：`kktodo/kkAgent-集群方案.md`（产品决策）、`kktodo/kkAgent-集群-实现方案.md`（代码改法 + 实测）。

- 新建群时勾「集群群聊」。集群主群只能有一个成员：群主（加进来的第一个会话，名字不能是 coder / tester），它会收到群主版入群说明。
- 群主说明里要求每个子群只放一个能独立验收的小功能：后台会话会一直累积历史，任务大了会被自动压缩（实测子群 F
  装了 T01–T06，coder 已压缩 2 次、每次调用读约 20 万 token），早期的需求和规则只剩摘要。有依赖的按顺序一个个派。
- 你把大需求发给群主 → 群主拆解后发给你确认 → 你同意后，群主每个功能执行一次
  `kkAgent spawn -g <主群> --from <群主> --task <功能名> "需求"`。
- spawn：建子群（挂在主群下面）、从群主工作目录所在仓库的当前分支建 worktree（`<仓库>-kkwt/<子群ID>`，分支 `kkagent/<子群ID>`），
  后台新建 coder（Claude，`claude -p --session-id`）和 tester（Codex，`codex exec`），群主也自动进子群。
- **coder 只在虚拟机里创建，禁止在物理机上建 Claude**：群主在哪台虚拟机就用哪台；群主在物理机上时只有一台虚拟机在运行才用它，
  没有或有多台都直接报错，不退回物理机。所以仓库必须在 `/Users` 下（虚拟机看不到 `/private/tmp`）。
  tester 仍在物理机（Codex 只支持物理机）。虚拟机里的 coder 读的是虚拟机的 `CLAUDE.md`，实测它会自己用 `mac bash -lc` 在宿主机上跑测试和 git。
  核心停掉 coder 时结束的是物理机上的 `ubx run`，实测虚拟机里的 claude 会跟着退出。
- coder / tester **只在任务完成（coder 合并完）或受阻时找群主**，其余时候（提审、验收结论、进度、确认）都不发给群主；
  群主没被找就不插手。子群里的消息末尾不再邀请回复，只是知会时不回复。
- 流程：coder 实现并提交 → 发给 tester → tester 用 `kkAgent send --verdict pass|fail` 把结论发给 coder → 通过后 coder 合并回主分支
  （先把主分支合进自己的分支、有新改动就重验、再 `--ff-only`）→ 报给群主 → 群主汇总给你。
- **coder 和 tester 常驻在物理机的 tmux 会话里**（2026-11-12 起，参考 claudeStatusLight）：会话名 `kk-<子群ID>-coder` / `kk-<子群ID>-tester`。
  - coder：tmux 里执行 `ubx shell <虚拟机> --cd <worktree> -- claude …`，Claude 仍跑在虚拟机里；第一次打开新 worktree 时核心替你确认「信任这个文件夹」。
  - tester：先用 `codex exec` 建会话拿到 ID（bootstrap，最多 180 秒，`KK_BOOTSTRAP_TIMEOUT`），再在 tmux 里 `codex resume <ID>`。
  - 消息投递：把文字粘贴进 tmux 再回车。对方正在干活时也能当场收到（实测 coder 在跑 `sleep 90`，停止指令 8 秒内生效），不会堆积。
  - 核心重启、界面关掉都不影响 tmux 里的会话；tmux 会话没了，下次投递会自动重开并接着原会话。
  - 成员详情里单独有「打开会话」：用设置里的终端执行 `tmux attach -t <名字>`，可以直接交互、按 Esc 打断；Ctrl-b d 退出后它接着跑。
  - 解散子群 / 移出成员会关掉对应的 tmux 会话。
  - 2026-11-12 之前建的子群（比如 F）不在 tmux 里，继续用旧的后台模式（每条消息 `claude -p --resume` / `codex exec resume` 跑一轮，排队消息合并投递）。
- 打回：tester 每次 `--verdict fail` 计一次，超过 8 次后暂停，结论改投给群主；群主在子群里给 coder 发消息即解除。
- 没有看门狗（2026-11-12 去掉）：成员一轮结束没发消息，系统不催、不自动续接，由群主自己判断要不要追问。
  核心只在三种情况通知群主：tester 初始化失败、消息投递出错（不自动重发）、核心重启打断了正在跑的一轮。
- 群主解散子群：`kkAgent dissolve -g <子群ID> --from <群主名字>`，一般在 coder 报告合并完成后执行。会停掉 coder / tester，worktree 和分支保留；
  只能解散自己的子群，主群只能由用户在界面上解散。
- 解散主群：子群一起解散，后台进程停掉；worktree 和分支保留，自己删。移出后台成员同样会停掉它的进程。
- 后台会话不能再被加到别的群。核心退出时会停掉所有投递进程（launchd 不会替我们停）。
- 界面：子群缩进显示在主群下面，第二行是分支或打回次数（暂停时橙色）；子群顶部能复制 worktree 路径、在终端打开；验收结论在消息行上标绿 / 橙。

## 界面结构和设计规范

```text
功能栏 | 当前功能的内容
群聊   | 群列表 | 对话（成员头像在顶部） | 成员详情（点头像才出现）
```

- 外壳：`Sources/App/Shell/RootView.swift` 里的 `AppModule`。加新功能 = 加一个枚举值 + 一个新目录（像 `GroupChat/` 一样），不动已有功能。
- 颜色只用来分清「谁」：Claude `#6E56CF`、Codex `#0F766E`、「我」系统强调色；状态只用系统绿 / 橙 / 红。都在 `Common/Theme.swift`。
- 字体：系统 SF Pro；名字和头像字母用 SF Pro Rounded；等宽字体只用于工具调用、会话 ID 这类真正是代码的内容。
- 群聊页最显眼的是「交接」：发送方 → 接收方 + 送达状态。消息不加卡片框，正文一行最多约 70 个汉字。
- 不写中点拼接的元信息（「A · B」），状态用短词，解释用完整句子。
- 布局用固定宽度 + 中间自适应。不要用 `HSplitView`（长消息会把内容撑出窗口）和 `.inspector`（和窗口约束冲突会让 AppKit 布局死循环崩溃），这两个坑都踩过。

## 开发 / 维护命令（在 `mac/` 目录下）

```bash
scripts/install.sh app     # 改了界面：重新编译安装界面（不动核心）
scripts/install.sh core    # 改了核心：重新编译安装并重启核心
scripts/core.sh status     # 核心状态
scripts/core.sh restart    # 重启核心（中转会话会冷启动，投递中的消息会标记失败）
scripts/core.sh log        # 看核心日志（~/.kkagent/core.log），含中转每轮的 token 用量
```

## 编译环境说明

开发时本机只有命令行工具（后来装了完整 Xcode），当时 SwiftPM 自带库版本对不上、`@State` 宏插件缺失，所以：

- 不用 SwiftPM，`scripts/build.sh` 直接调用 `swiftc` 编译（界面会收集 `Sources/App/` 下所有子目录的 .swift）。
- 界面里的局部状态用 `LocalState`（`@StateObject` 包一层），写法见 `Sources/App/Common/LocalState.swift`。
- 现在已装完整 Xcode，这两条限制理论上已经不存在，但现有写法继续可用，没有改回去。

## 已实测通过（2026-10-22，新核心跑在 launchd 下）

- 接口：各类正常和错误输入，命令行表单里的空格、`&`、`+`、`=`、中文、引号都能正确解码。
- 读到了 Node 版留下的全部数据。
- launchd：`kill -9` 核心后 1 秒自动恢复。
- 三条投递路径都用真实会话跑通：
  - Codex：`codex queue`。
  - Claude 没开着：后台续接 `claude -p --resume`。
  - Claude 开着：中转会话实时投递，内容逐字一致。
- 完整接力：我 → coder(Claude) → tester(Codex) → 我，用时 19 秒。
- 中转 token：冷启动约 2.2k 缓存写 + 6.8k 缓存读；常驻后每条约 350 缓存写 + 9.3k 缓存读 + 120 输出。

## 和 Node 版的差别 / 还没做的

- 界面截图没法自动验证（这台机器上我拿不到屏幕录制权限），界面效果需要人看。
- Node 版代码（`server/`、`web/`、`package.json`）已删除。`bin/kkAgent` 命令行只依赖 sh + curl，继续使用。
- 其余限制同 Node 版：Codex 会话没在桌面端打开时 queue 只入队；Claude 会话不要用 bypass 权限模式；转发前没有人工批准开关。

## 代码结构

```text
mac/Sources/Shared/Models.swift     接口数据结构（核心和界面共用）
mac/Sources/Core/                   核心
  main.swift        入口、信号处理
  Config.swift      端口、路径、登录 shell 环境（launchd 下拿到和终端一样的 PATH/代理）
  HTTPServer.swift  极简 HTTP 服务（只监听 127.0.0.1）
  API.swift         接口路由和业务逻辑
  Repository.swift  数据库读写（表结构同 Node 版）
  SQLite.swift      系统 SQLite 的薄封装
  Delivery.swift    投递队列（每个成员一条串行队列）
  Relay.swift       常驻中转 Claude 会话 + hook
  Transcript.swift  读两种会话记录
  Prompts.swift     入群说明、群消息模板
mac/Sources/App/                    界面（SwiftUI）
  Shell/      外壳：入口（窗口 + 菜单栏 + 设置）、功能栏、界面状态、调核心接口、核心控制
  Common/     各功能共用：Theme（颜色、头像）、Labels（文案）、LocalState
  GroupChat/  群聊功能：群列表、对话、交接消息行、成员详情、加成员
mac/scripts/  build.sh / install.sh / core.sh
```
