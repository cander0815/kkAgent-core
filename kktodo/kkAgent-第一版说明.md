# kkAgent 第一版说明

一个本地小群聊：把已经开着的 Claude / Codex 会话拉进同一个群，让它们**只互发结论**，执行过程只给你在网页上看。

## 怎么用

```bash
cd <项目目录>
npm start                      # 启动服务，打开 http://127.0.0.1:7788
```

1. 网页右上角「新建群聊」。
2. 左边「添加成员」：选类型（Claude / Codex），填会话 ID、成员名（如 coder）、负责什么（如 编码）。
   加入后服务自动给它发一段入群说明，告诉它怎么用 `kkAgent` 发消息、只发结论。
3. 中间是群聊记录，每条消息后面有投递状态（⏳ 投递中 / ✓ 已送达 / ✗ 失败，鼠标悬停看失败原因）。
4. 点成员的「查看过程」，右边显示这个会话的完整执行过程（思考、工具调用），可勾选隐藏工具调用。
5. 底部可以用「我」的身份往群里发消息。
6. 不用的群：群标题右边「解散群聊」解散当前群；或者点顶部「管理群聊」，列出所有群（成员数、消息数、最后活跃时间），逐个解散。
   解散会删除群里的成员和聊天记录，各个会话本身不受影响；排队中还没送出的消息不再投递；Agent 再往这个群发消息会收到「群聊不存在」。

Agent 用的命令（已链接到 `~/.local/bin/kkAgent`，全局权限已放行 `Bash(kkAgent:*)`）：

```bash
kkAgent send -g <群ID> --from <我的名字> --to <成员名|all|user> "结论"
kkAgent members -g <群ID>
```

## 投递方式

| 目标 | 方式 | 效果 |
|---|---|---|
| Codex | `codex queue --thread <id>` | 直接进桌面端开着的会话，实时可见 |
| Claude（终端/VSCode 里开着） | 中转会话 `kkagent-relay` 调用 SendMessage | **实时出现在你开着的窗口里** |
| Claude（没开着） | `claude -p --resume <id>`（后台续接，auto 权限模式） | 写回同一个会话，下次打开能看到 |

每个成员一条投递队列，同一个会话不会被并发投递。

### 中转会话（kkagent-relay）

kkAgent 服务不能直接往 Claude 会话的消息 socket 里写：那个通道要会话密钥认证，专门防外部冒充，我们不绕过。所以服务在第一次需要时常驻一个 Claude 会话，借它自带的 SendMessage 发消息。

- **内容不经过模型**：模型只负责「调一次 SendMessage」，收件人和原文由 PreToolUse hook（`server/relay-hook.js`）在调用前直接替换进去。实测曾出现模型转抄把 `kkAgent` 写成 `kkagent` 的情况，改成 hook 注入后两次测试都逐字一致（含引号、反斜杠）。
- **瘦身**：自定义短系统提示、只开放 SendMessage 一个工具（advisor 也禁掉）、不加载 MCP / skills / CLAUDE.md / 自动记忆；消息原文不进中转会话的上下文。
- **模型**：默认 Haiku 5.5（最便宜）+ `--effort low`。Haiku 5.5、Sonnet 5.5 这类新模型不允许彻底关闭思考（Claude Code 会强制用 adaptive，由模型自己决定思不思考）。实测 Haiku 偶尔会短暂思考，每条多 100～150 输出 token；Sonnet 没有思考。只有 Haiku 4.5 这类老模型能真正关掉思考（`KK_RELAY_MODEL=claude-haiku-4-5`）。
- **实测 token**（服务日志里有 `[relay] 本轮 token` 记录）：冷启动第一条约 2.6k 缓存写 + 7k 缓存读；常驻后每条约 350 缓存写 + 10k 缓存读 + 约 120～270 输出。空闲时不消耗。超过 1 小时没消息，缓存过期，下一条会重新写一次缓存。转发 200 条后自动重启，防止上下文无限变长。
- **权限模式要一致**：中转会话是 auto（属于需要确认那一类）。如果目标 Claude 会话开的是 bypass 模式，消息会卡在对方那边等你批准。

## 为什么内部过程不会传过去

服务只转发 Agent 主动用 `kkAgent send` 写的那段文字。会话记录（transcript）只读，只给网页展示，没有任何代码路径会把它发给别的 Agent。

## 已实测通过（2026-10-22）

- 我 → coder(Claude) → tester(Codex) → 我，完整接力约 23 秒。
- Codex 沙箱里可以调 `kkAgent`（curl 本机服务）。
- 各类错误输入（会话不存在、成员名非法、保留名、发件人不在群、群不存在）都返回中文提示。

## 已知限制 / 第二版候选

1. **Claude 没开着时**走 resume，你之后在终端打开会话能看到；但如果投递时会话正开着又刚好关掉（时间差），会退回 resume。
2. **消息转发前人工批准**：第一版默认自动转发，没有「需要我批准」开关。
3. **Codex 会话没在桌面端打开时**：`codex queue` 只入队，可能要等你打开才处理，网页上显示「已送达」实际是「已入队」。
4. 服务重启时，投递中的消息会标记为失败，需要手动重发。

## 代码结构

```
server/index.js       HTTP 接口 + 静态页面（只监听 127.0.0.1:7788）
server/db.js          SQLite（Node 自带），数据在 ~/.kkagent/kkagent.db
server/delivery.js    投递队列：codex queue / 中转实时投递 / claude --resume
server/relay.js       常驻中转 Claude 会话
server/relay-hook.js  中转会话的 hook：把 SendMessage 参数替换成原文
server/relay-paths.js 中转会话用的文件路径
server/transcript.js  读两种会话记录，转成统一格式；判断会话状态
server/prompts.js     入群说明、群消息的文字模板
bin/kkAgent           给 Agent 用的命令（sh + curl，不依赖 node）
web/                  网页（纯 HTML/JS，每 2 秒轮询）
```

可调环境变量：`KKAGENT_PORT`（默认 7788）、`KK_CODEX_BIN`、`KK_CLAUDE_BIN`、`KK_CLAUDE_PERMISSION_MODE`（默认 auto）、`KK_RELAY_MODEL`（中转会话模型，默认 haiku）。
