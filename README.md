# kkAgent

macOS 上的多 Agent 协作工具：把已经开着的 Claude Code / Codex 会话拉进同一个群聊，让它们**只互发结论**，执行过程只给人看；还能直接新建单独会话、浏览历史会话、一键开 ssh 端口转发。

> 这份 README 同时写给人和 Claude Code 读。Claude Code 接手这个项目时，先读本文件，再读根目录的 `CLAUDE.md`（项目规则，必须遵守）。

## 它由什么组成

```text
kkAgent 核心（kkagent-core）               kkAgent 界面（kkAgent.app）
  launchd 后台服务，开机自启、崩溃拉起 ◀── HTTP 127.0.0.1:7788 ──▶ SwiftUI 窗口 + 菜单栏图标
  数据库 / 投递队列 / tmux 会话 / 读会话记录                        只是遥控器，退出不影响核心
        ▲
        └── kkAgent 命令行（bin/kkAgent）：Agent 用它往群里发消息
```

- 核心和界面是两个独立进程，**重装界面不会重启核心**，tmux 里的会话和排队中的消息不受影响。
- 全部用 Swift 写，用 `swiftc` 直接编译，不用 Xcode 工程，也不用 SwiftPM、node。
- 数据都在 `~/.kkagent/`（数据库 `kkagent.db`、hook 脚本、日志 `core.log`、隧道配置 `tunnels.json`）。

## 运行前提

| 需要 | 说明 |
| --- | --- |
| macOS 15 及以上 | 核心和界面都只在 macOS 上跑（`Info.plist` 里写了最低版本 15.0） |
| Swift 编译器 | 装 Xcode 或命令行工具（`xcode-select --install`）。命令行工具就够，**不需要完整 Xcode** |
| tmux | 单独会话和集群成员都跑在 tmux 里：`brew install tmux` |
| Claude Code（`claude` 命令） | 终端里能直接执行 `claude`；也可用环境变量 `KK_CLAUDE_BIN` 指定路径 |
| Codex（可选） | 用到 Codex 成员时才需要。优先用 ChatGPT 桌面端自带的，找不到再用 PATH 里的 `codex`，也可用 `KK_CODEX_BIN` 指定 |
| `ubx`（可选） | 要让虚拟机里的 Claude 会话加进群才需要，见下文「虚拟机」 |
| git | 集群功能会为子群建 git worktree |

检查一下：

```bash
swiftc --version && tmux -V && claude --version
```

## 从零跑起来

下面的命令都在 macOS 上执行，`<项目目录>` 是你 clone 下来的位置。

**1. 编译并安装核心**（注册成 launchd 后台服务，开机自启）

```bash
cd <项目目录>/mac
scripts/install.sh core
```

成功会看到「✓ 核心已在后台运行：http://127.0.0.1:7788」。核心装在 `~/.kkagent/bin/`，登录项在 `~/Library/LaunchAgents/com.kk.kkagent.core.plist`。

**2. 编译并安装界面**

```bash
scripts/install.sh app
```

会装到 `~/Applications/kkAgent.app` 并自动打开。第一次编译会顺带编译第三方终端库 SwiftTerm（要二三十秒，之后有缓存）。想一次装两个，直接 `scripts/install.sh`。

**3. 把命令行放进 PATH**（Agent 靠它往群里发消息）

```bash
mkdir -p ~/.local/bin
ln -sf <项目目录>/bin/kkAgent ~/.local/bin/kkAgent
```

确认 `~/.local/bin` 在 PATH 里。想让 Claude 发消息时不弹权限确认，在 `~/.claude/settings.json` 的权限里放行 `Bash(kkAgent:*)`。

**4. 验证**

```bash
scripts/core.sh status        # 核心在不在
curl -s --noproxy '*' http://127.0.0.1:7788/api/health
```

打开 `~/Applications/kkAgent.app`：左边栏有「群聊 / 会话 / Claude / Codex / 端口」，最下面的「核心」是绿点就说明连上了。顶部菜单栏会有「KK」图标。

数据库首次启动时自动创建，不用手动初始化。

## 日常操作

| 要做的事 | 命令 |
| --- | --- |
| 看核心状态 | `mac/scripts/core.sh status` |
| 重启核心（中转会话会冷启动，投递中的消息会标记失败） | `mac/scripts/core.sh restart` |
| 停 / 启核心 | `mac/scripts/core.sh stop` / `start` |
| 看核心日志 | `mac/scripts/core.sh log`（即 `~/.kkagent/core.log`） |
| 改了核心代码 | `mac/scripts/install.sh core` |
| 改了界面代码 | `mac/scripts/install.sh app`（会先退出旧界面再重开） |
| 只编译不安装 | `mac/scripts/build.sh [core\|app]`，产物在 `mac/build/` |

## 可选：端口转发（「端口」页）

「端口」页用 app 自己起 `ssh -N -L …` 做端口转发，不依赖核心。隧道配置在本机文件 `~/.kkagent/tunnels.json`，**里面是内网地址，不能进 git**。

```bash
cp <项目目录>/mac/Sources/App/Tunnels/tunnels.example.json ~/.kkagent/tunnels.json
# 然后改成自己的隧道，改完重新打开 app
```

- `host` 写 `~/.ssh/config` 里的主机别名，或 `user@ip`；要求免密登录（用了 `BatchMode`，需要输密码的连不上）。
- 没有这个文件时，「端口」页会提示原因和怎么办，不影响别的功能。
- 详细规则见 `CLAUDE.md` 的「端口」页一节。

## 可选：虚拟机里的 Claude 会话

核心跑在物理机上，读不到虚拟机里的文件，所以涉及虚拟机的操作都经 `ubx run <机器名> <命令>` 进去执行（代码在 `mac/Sources/Core/VM.swift`）。前提：

1. 装了 `ubx`，机器是 **running** 状态（`ubx list`）。
2. 机器没开隔离模式（要能看到 `/Users`，能连到物理机）。
3. 机器里装了 `claude`（nvm 装的也行，启动时走 `bash -i` 读 `.bashrc`）。
4. 机器里能访问核心：经默认网关连 `7788` 端口，`bin/kkAgent` 在 Linux 下会自动这样做。
5. 每台机器做一次：`sudo ln -sf <物理机上 kkAgent 的路径> /usr/local/bin/kkAgent`。

代码只认 `ubx`，不支持别的虚拟化工具。Codex 会话只支持物理机。

## 目录结构

```text
bin/kkAgent                 命令行（纯 sh + curl，Agent 用）
mac/
  scripts/                  build.sh / install.sh / core.sh
  Sources/
    Core/                   核心：HTTP 接口、数据库、投递、tmux、虚拟机、会话记录
    Shared/Models.swift     核心和界面共用的数据结构（改接口两边编译都会检查）
    App/                    界面，按功能分目录
      Shell/                外壳：窗口、左边栏、核心控制、设置
      GroupChat/            群聊      Solo/  单独会话
      Sessions/             Claude / Codex 历史会话浏览
      Tunnels/              端口转发
      Common/               公共组件（主题、终端、鼠标形状、复制按钮…）
  Vendor/SwiftTerm/         第三方终端库源码（MIT，说明见其 README）
  Resources/                Info.plist、图标
kktodo/                     方案、评审记录、使用说明（中文，写给人看）
CLAUDE.md                   项目规则（给 Claude Code，必读）
```

想了解设计和用法，从这几份开始：`kktodo/kkAgent-原生版说明.md`（整体结构、日常使用、虚拟机、集群）、`kktodo/单独会话-方案.md`、`kktodo/kkAgent-集群方案.md`。

## 环境变量

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `KKAGENT_PORT` | `7788` | 核心监听端口（命令行也读它）。**正式环境不要改**，测试核心才用别的端口 |
| `KKAGENT_DATA_DIR` | `~/.kkagent` | 数据目录 |
| `KKAGENT_CLI` | `kkAgent` | 提示词里让 Agent 执行的命令，测试核心要设成测试专用包装，免得回消息发到正式核心 |
| `KK_CLAUDE_BIN` / `KK_CODEX_BIN` | 自动找 | 指定 claude / codex 路径 |
| `KK_CLAUDE_PERMISSION_MODE` | `auto` | 后台 Claude 的权限模式 |
| `KK_TMUX_READY_SECONDS` | `600` | 新开 tmux 会话后等界面就绪的最长秒数 |

核心由 launchd 启动，拿不到终端里的 PATH、代理、nvm。它启动时会跑一次 `$SHELL -ilc env` 读取你登录 shell 的环境，之后启动 claude / codex 都用这份环境。

## 开发和测试

- **不要拿正式核心做实验**。要开发核心，另起一个测试核心：换端口和数据目录，例如 `KKAGENT_PORT=7799 KKAGENT_DATA_DIR=~/.kkagent-test`，再带上指向测试端口的 `KKAGENT_CLI`，直接运行 `mac/build/kkagent-core`。
- 后端功能要**真打接口验证**：起核心 → `curl` 打真实路由 → 查数据库 → 确认下游副作用（投递出去的消息、变化的状态）。只跑单测或自己手写一份等价请求不算验证过。
- 核心只接受本机程序的请求：带 `Origin` 头或 `Host` 不是 `127.0.0.1` / `localhost` 的会返回 403，用脚本调接口时不要加 `Origin`。
- 界面改动要自己打开 app 看一眼，编译通过不等于界面对。

## 给 Claude Code 的注意事项

1. **先读 `CLAUDE.md`**：里面有鼠标形状规则（能点的地方都加 `.clickable()`）和「端口」页规则。
2. **改文件用 Edit / Write**，不要用脚本批量改。
3. **新写的文件保持组件化**，单个文件不要超过 2000 行；代码让新手也能看懂，在合适的位置写注释，沿用现有风格。
4. **敏感信息不进 git**：数据库地址、跳板机 IP、账号密码、令牌一律不要写进代码、文档或提交信息。隧道配置只放 `~/.kkagent/tunnels.json`，仓库里只有假地址的示例。
5. **用户可见的文案**讲「省下来的工」（少走弯路、不用返工），不讲钱；费用告知照常保留。
6. 方案、评审记录、使用说明写成中文 Markdown，放在 `kktodo/`。
7. 编译环境只有命令行工具时，SwiftUI 的 `@State` 宏编不了，用 `mac/Sources/App/Common/LocalState.swift` 里的 `@StateObject` 包装代替。

## 常见问题

| 现象 | 处理 |
| --- | --- |
| 界面提示「kkAgent 核心没有运行」 | `mac/scripts/core.sh start`，或点界面里的「启动核心」；没装过先 `scripts/install.sh core` |
| 核心起不来 | `tail -n 30 ~/.kkagent/core.log` 看报错；端口被占用可以 `lsof -i :7788` |
| 编译报找不到 SwiftTerm | 删掉 `mac/build/swiftterm` 重新 `scripts/build.sh app`，会重新编译 |
| 安装界面时 `open` 报 -600 | 旧界面没退干净，`pkill -f kkAgent.app/Contents/MacOS/kkAgentApp` 后再装 |
| 「端口」页提示没有配置文件 | 按上面「端口转发」一节复制示例文件 |
| 提示「找不到 ubx 命令」 | 没装 `ubx`，或它不在核心能看到的 PATH 里；不用虚拟机可以忽略 |
