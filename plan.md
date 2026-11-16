# Claude Code × Codex 临时 Handoff Console

## 1. 项目目标

我要做一个**本地运行的 Web Handoff Console**，用于连接一个 Claude Code Session 和一个 Codex Session。

它不是一个长期运行的 Multi-Agent Orchestrator，也不是让 Claude 和 Codex 自己持续对话。

它的核心目的非常简单：

> **让 Claude 和 Codex 可以在同一个项目中，由人控制地进行一次性、双向的任务交接，同时让用户能够完整看到双方各自的执行过程，但不要把双方的内部执行过程互相传递。**

典型使用场景：

1. 我让 Claude Code 完成一个开发任务。
2. Claude Code 自己阅读代码、修改代码、运行测试、分析问题。
3. Claude 完成后，形成一个最终结果 / 测试说明 / 验收标准。
4. 我在 Web Console 中查看 Claude 的最终结果。
5. 我确认后，把这份最终结果交给 Codex。
6. Codex 在**同一个项目 / workspace** 中独立进行测试、检查或验证。
7. Codex 完成后生成最终测试结论。
8. 我在 Web Console 中查看 Codex 的最终结果。
9. 我确认后，可以把 Codex 的最终结果交还给 Claude。
10. 整个过程由 Web Console 作为人工可控的中转层。

---

# 2. 最重要的产品原则

整个项目必须遵守下面这个核心原则：

> **Agent 的执行过程可以被 Web Console 看到，但默认不能被另一个 Agent 看到。**

例如：

Claude 在工作过程中可能产生：

- 思考过程
- 文件读取
- 文件搜索
- Shell 命令
- 测试过程
- 调试过程
- 中间结论
- 尝试失败
- 重试
- 大量工具调用

这些内容：

**可以显示在 Web Console 中。**

但是：

**不要实时发送给 Codex。**

同样：

Codex 的：

- 分析过程
- 文件读取
- 测试过程
- 工具调用
- 调试过程
- 中间结论

也：

**可以显示在 Web Console 中。**

但：

**不要实时发送给 Claude。**

只有明确形成的：

> **FINAL / HANDOFF RESULT**

才允许跨 Agent 传递。

---

# 3. 为什么要这样设计

这里有一个非常重要的需求：

我担心的不是 Handoff 文本本身太长。

我真正担心的是：

> Claude 在自己完成任务的过程中产生的大量分析、工具调用、中间结果，被不断转发给 Codex，导致 Codex 消耗大量没有价值的上下文和 Token。

例如 Claude 工作了 20 分钟：

```text
读取文件
↓
搜索代码
↓
分析
↓
修改
↓
测试失败
↓
再次分析
↓
修改
↓
再次测试
↓
发现问题
↓
继续修改
↓
最终完成
```

这些过程对于 Claude 自己完成任务是有意义的。

但 Codex 通常只需要知道：

```text
任务是什么
最终完成了什么
修改了什么
有哪些文件
如何验证
还有什么需要测试
```

因此系统必须把：

**Agent 内部执行过程**

和

**跨 Agent 的最终交接信息**

严格分开。

---

# 4. 产品定位

这个产品应该被理解成：

> **Cross-Agent Handoff Console**

或者：

> **Agent Relay / Handoff Console**

而不是：

> Multi-Agent Orchestrator

它不需要让多个 Agent 自动协作，也不需要自动规划任务，更不需要让 Agent 之间自由聊天。

它更像一个：

> **人可以观察和控制的 Agent 之间的传话板。**

---

# 5. 核心工作流程

## 5.1 Claude 执行阶段

用户启动或连接一个 Claude Code Session。

Claude 正常完成自己的工作。

Web Console 应该能够看到 Claude 的执行过程，例如：

```text
Claude
├── 正在读取 xxx
├── 正在修改 xxx
├── 执行测试
├── 测试失败
├── 修复问题
├── 再次测试
└── 最终完成
```

这里的所有过程主要是给**用户观察**的。

不应该自动发送给 Codex。

---

# 6. Claude → Codex Handoff

当 Claude 完成工作后，需要产生一个明确的最终交接结果。

例如：

```text
任务：
实现 OAuth Login。

完成情况：
已经完成 OAuth 登录功能。

修改内容：
- ...
- ...
- ...

验证情况：
- ...
- ...

测试要求：
请在当前 workspace 中独立验证 OAuth Login。

注意事项：
- ...
```

Web Console 显示这个结果。

此时：

**不要自动立即发送给 Codex。**

应该给用户一个 Handoff Preview。

---

# 7. Handoff Preview

用户在发送之前应该能够看到：

```text
From:
Claude

To:
Codex

Workspace:
当前项目

Handoff Content:
......

Estimated Tokens:
xxxx

[ Edit ]

[ Cancel ]

[ Send to Codex ]
```

也就是说：

> **Agent 之间的消息发送必须经过人的确认。**

用户可以：

### Edit

修改要发送给 Codex 的内容。

例如删掉无关信息，补充测试要求。

### Cancel

取消这次 Handoff。

Claude 的工作结果不受影响。

### Send

确认之后，才真正把内容交给 Codex。

---

# 8. 只传 FINAL，不传 INTERNAL / TOOL

整个系统需要有非常清晰的消息边界。

可以简单理解为三种信息：

### INTERNAL

Agent 自己内部执行过程中产生的信息。

例如：

- 分析
- 中间判断
- 思考
- 临时计划
- 重试
- 中间状态

处理方式：

> **只显示给 Web Console，不跨 Agent。**

---

### TOOL

Agent 使用工具产生的信息。

例如：

- 文件读取
- 文件搜索
- Shell
- 测试
- Git
- 其他工具调用

处理方式：

> **只显示给 Web Console，不跨 Agent。**

---

### FINAL

Agent 最终形成的结果。

例如：

- 完成情况
- 修改说明
- 测试结果
- 问题列表
- 验收标准
- 下一步要求

处理方式：

> **可以进入 Handoff。**

但即使是 FINAL，也应该由用户确认后才发送。

---

# 9. Codex 执行阶段

Codex 收到 Handoff 后，在同一个 workspace 中独立工作。

例如：

```text
Codex
├── 查看项目
├── 查看 Claude 修改
├── 执行测试
├── 发现问题
├── 调查问题
├── 再次测试
└── 得出最终结论
```

这些内容：

**全部可以在 Web Console 中显示。**

但是：

**不要实时发送回 Claude。**

Claude 不需要知道 Codex 当前正在读取哪个文件，也不需要知道 Codex 中间尝试了什么。

---

# 10. Codex → Claude Handoff

Codex 完成后生成最终测试结论。

例如：

```text
测试结果：

OAuth Login 已完成验证。

通过：
- Login flow
- Callback
- Token refresh

发现问题：
- xxx

结论：
基本功能通过，但 xxx 仍需要修复。

建议：
请 Claude 修复 xxx。
```

Web Console 展示这个最终结果。

用户确认后：

```text
[ Edit ]

[ Cancel ]

[ Send to Claude ]
```

然后才把它交给 Claude。

---

# 11. 双向 Handoff

系统应该支持：

```text
Claude
   ↓
FINAL
   ↓
Web Console
   ↓
User Review
   ↓
Codex
   ↓
FINAL
   ↓
Web Console
   ↓
User Review
   ↓
Claude
```

也就是说：

**Claude → Codex**

和：

**Codex → Claude**

都应该是同一种 Handoff 模型。

---

# 12. Session 不需要永久绑定

Claude Session 和 Codex Session 不需要建立永久关系。

例如这一次：

```text
Claude Session A
        ↓
Codex Session B
```

下一次完全可以：

```text
Claude Session A
        ↓
Codex Session C
```

甚至：

```text
Claude Session D
        ↓
Codex Session B
```

因此系统的重点不是：

> “把两个 Agent 永久绑定。”

而是：

> “这一次 Handoff 要从哪个 Session 发送到哪个 Session。”

---

# 13. Workspace 必须是明确的

Handoff 应该和当前项目 / workspace 有明确关系。

例如：

```text
Project:
my-project

Workspace:
/path/to/my-project
```

Claude 和 Codex 应该能够针对同一个项目进行工作。

但需要注意：

> **Workspace 是文件层面的协作方式，Handoff 是信息层面的协作方式。**

不要把这两个概念混在一起。

例如 Claude 修改了代码：

```text
Git / Files
```

这些修改自然可以被 Codex 看到。

但 Claude 的内部分析：

```text
Internal reasoning
```

不应该因为两者共享 workspace 就自动进入 Codex 的上下文。

---

# 14. Web Console 必须做到“可观察”

Web 页面是这个项目非常重要的一部分。

我希望用户能够清楚地看到：

### Claude

```text
Claude Session

Status: Working

Live Output
──────────────
...
...
...

Final Result
──────────────
...

Handoff → Codex
```

### Codex

```text
Codex Session

Status: Testing

Live Output
──────────────
...
...
...

Final Result
──────────────
...

Handoff → Claude
```

我希望看到双方**完整的执行过程**。

但是：

> “Web 页面能看到” ≠ “另一个 Agent 能看到”。

这是整个系统最重要的边界。

---

# 15. Handoff 状态

每一次 Handoff 都应该有明确状态。

例如：

```text
Draft
↓
Ready for Review
↓
Approved
↓
Sent
↓
Received
↓
Completed
```

如果用户取消：

```text
Draft
↓
Cancelled
```

如果发送失败：

```text
Approved
↓
Send Failed
```

用户应该很容易知道：

> 当前到底有没有把信息发送给另一个 Agent。

---

# 16. Token 控制

Web Console 最好能够显示：

```text
Handoff Token Usage

Claude → Codex
Input: 1,284 tokens

Codex → Claude
Input: 736 tokens
```

这里统计的是：

> **真正跨 Agent 传播的 Token。**

而不是 Claude 自己工作时用了多少 Token。

例如：

Claude 自己内部消耗：

```text
50,000 tokens
```

但最终只发送给 Codex：

```text
1,200 tokens
```

那么对于这个系统来说，真正重要的是：

```text
Cross-Agent: 1,200 tokens
```

而不是把 50,000 tokens 也算成 Agent-to-Agent 消耗。

---

# 17. 可选的 Handoff 压缩

可以提供一个可选能力：

```text
Send Final Output
```

或者：

```text
Compress to Handoff
```

例如 Claude 最终输出比较长。

用户可以选择：

> 帮我把最终结果压缩成适合交给 Codex 的 Handoff。

但这个压缩只影响：

> **跨 Agent 发送的内容。**

不能修改 Claude 自己的 Session，也不能破坏 Claude 原本的上下文。

同样，Codex → Claude 也可以使用。

---

# 18. 不需要 Agent 自由聊天

这个项目第一版不要做：

```text
Claude ↔ Codex
实时聊天
```

也不要做：

```text
Claude
  ↓
Codex
  ↓
Claude
  ↓
Codex
  ↓
Claude
```

这种无限循环式 Agent Collaboration。

第一版应该坚持：

```text
Agent
  ↓
Final Result
  ↓
Human Review
  ↓
Other Agent
```

这样系统简单、可控，也更符合这个工具的实际用途。

---

# 19. 用户应该始终拥有最终控制权

任何跨 Agent 的信息发送，都应该是：

> **可见、可编辑、可取消、可确认的。**

不能因为 Claude 输出了某个结果，就自动把它全部推给 Codex。

不能因为 Codex 完成了测试，就自动把全部结果推给 Claude。

系统应该让用户清楚地知道：

```text
什么内容
从哪里
发给谁
什么时候发送
发送了多少 Token
```

---

# 20. 第一版不需要做的东西

为了避免项目变成一个复杂的 Multi-Agent 平台，第一版明确不需要：

- 多 Agent 自动调度
- Agent 自动分配任务
- Agent 自主决定是否联系另一个 Agent
- Agent 无限循环对话
- 长期 Agent Team
- 复杂的任务规划系统
- 复杂的 Agent Memory
- Agent 间实时同步全部上下文
- 把 Claude 和 Codex 的完整 transcript 互相转换
- 让一个 Agent 实时观看另一个 Agent 的内部执行过程

这些都不是当前目标。

---

# 21. 第一版真正需要解决的问题

第一版只需要把下面这条链路做好：

```text
Claude Session
      │
      │ 完整执行过程
      ▼
 Web Console
      │
      │ FINAL
      ▼
Handoff Preview
      │
      │ User Approve
      ▼
 Codex Session
      │
      │ 完整执行过程
      ▼
 Web Console
      │
      │ FINAL
      ▼
Handoff Preview
      │
      │ User Approve
      ▼
 Claude Session
```

其中：

```text
INTERNAL ───────► Web UI
TOOL ───────────► Web UI
FINAL ──────────► Web UI ──► User Approval ──► Other Agent
```

这是整个产品最核心的逻辑。

---

# 22. 用户体验目标

我希望最终使用起来非常简单。

用户不应该需要理解复杂的 Agent Orchestration 概念。

理想体验是：

### 第一步

打开 Web Console。

看到：

```text
Claude Session
Codex Session
```

### 第二步

Claude 开始工作。

用户可以在页面上观察全过程。

### 第三步

Claude 完成。

页面出现：

```text
Claude Final Result

[ Review Handoff ]
```

### 第四步

用户点击。

看到：

```text
Claude → Codex

将发送：

......

Tokens: 1,284

[Edit] [Cancel] [Send]
```

### 第五步

点击 Send。

Codex 开始工作。

### 第六步

用户观察 Codex 的完整执行过程。

### 第七步

Codex 完成。

页面出现：

```text
Codex Final Result

[ Review Handoff ]
```

### 第八步

用户确认后：

```text
Send to Claude
```

整个流程结束。

---

# 23. 最重要的验收标准

项目完成后，我希望至少能够验证以下场景。

### Case 1：Claude → Codex

Claude 完成任务后，可以生成一个最终 Handoff。

用户可以查看、修改、取消或发送。

---

### Case 2：Codex → Claude

Codex 完成测试后，可以生成最终测试结论。

用户可以查看、修改、取消或发送回 Claude。

---

### Case 3：内部过程不泄漏

Claude 在执行过程中产生大量：

- 分析
- 工具调用
- 文件读取
- 测试
- 中间结果

这些内容可以在 Web UI 中看到。

但 Codex 收到的消息中**不能包含这些内部过程**。

反过来也一样。

---

### Case 4：人工确认

任何跨 Agent 的信息发送，都不能绕过 Web Console 的人工确认。

---

### Case 5：Token 可见

用户可以看到：

> 这次真正发送给另一个 Agent 的内容有多少 Token。

---

### Case 6：Session 可以独立存在

Claude 和 Codex 可以分别拥有自己的 Session。

不要求永久绑定。

一次 Handoff 只是建立一次临时的：

```text
Session A → Session B
```

关系。

---

### Case 7：同一个 Workspace

Claude 和 Codex 可以针对同一个项目进行工作。

文件 / Git 修改可以作为双方协作的基础。

但这不意味着双方共享内部上下文。

---

# 24. 一句话总结

这个项目不是要创造一个“让 Claude 和 Codex 自己协作的 AI 团队”。

我要的是一个：

> **人控制的、本地的、可观察的 Claude ↔ Codex Handoff Console。**

核心原则只有一句：

> **完整执行过程给人看，最终结果才给另一个 Agent。**

这样既可以保留 Claude 和 Codex 各自独立工作的能力，又可以让它们在需要的时候通过人工确认进行高质量交接，同时避免把大量无意义的内部执行过程传播给另一个 Agent，造成额外的 Token 消耗。