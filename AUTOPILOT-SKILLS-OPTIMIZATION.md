# Autopilot × Skills/Shell/Compaction 深度优化分析

> 基于 OpenAI [Shell + Skills + Compaction](https://developers.openai.com/blog/skills-shell-tips) 对比 autopilot 系统
> v2 — 深度思考版

## 一、文章的核心洞察

文章表面讲的是三个 API 原语，但深层论点是**关注点分离**：

```
Skills  = 声明式 "做什么"（流程、模板、护栏）
Shell   = 命令式 "怎么执行"（运行时、依赖、产物）
Compact = 连续性管理（上下文不丢失）
```

关键引用：
- _"Skills reduce prompt spaghetti by moving stable procedures into a reusable bundle"_
- _"When you need determinism, explicitly tell the model to use the skill"_（确定性 > 智能路由）
- _"Skills become living SOPs: updated as your org evolves, executed consistently by agents"_（Pattern C）
- _"A surprising failure mode: making skills available can initially reduce triggering → fix with negative examples"_

## 二、架构审视：我们的三个 Skill 表面

我们的系统比文章描述的更复杂——有**三层** agent，每层有不同的 "skill" 载体：

| 层 | Agent | 当前 "Skill" 载体 | 问题 |
|----|-------|-------------------|------|
| **Codex 项目 agent** | 4 个 tmux 窗口里的 Codex | CONVENTIONS.md + prd-todo.md | 缺负面示例，compact 后规则可能丢失 |
| **OpenClaw 监控 agent** | cron 隔离 session | cron payload 内嵌 bash | **最严重的 prompt spaghetti** |
| **Bash 编排层** | watchdog.sh 1187 行 | 硬编码逻辑 | 策略和机制完全耦合 |

## 三、深层问题诊断

### 问题 1：watchdog.sh 是一个硬编码的状态机

当前 watchdog 本质上是：
```
for each project:
    status = detect()           # 确定性 ✅
    if status == idle:          # 路由逻辑 ✅
        check 6 guard layers   # 硬编码 ❌
        pick nudge message      # 硬编码 ❌
        send via tmux           # 执行 ✅
```

1187 行中，**~60% 是策略逻辑**（guard 条件、nudge 选择、cooldown 参数）。这些不该在 bash 里。

### 问题 2：Cron payload 是 prompt spaghetti 的教科书案例

```json
"message": "执行以下脚本获取状态并发 Telegram：\n\n```bash\nSUMMARY=$(...)\ncurl ...\n```"
```

每次修改要更新 cron job（API call），不可 git track，不可跨项目复用。

### 问题 3：Nudge 消息缺乏上下文智能

当前 nudge 是静态字符串。但最佳 nudge 取决于：
- 项目当前阶段（dev/review/test/deploy）
- 最近 commit 模式（连续 feat 无 test？连续 fix 无 commit？）
- PRD 剩余项内容
- Review 中的具体 P0/P1 issue

文章的 Pattern B 建议：**把这种 workflow 逻辑编码到 skill 模板中**，而非硬编码。

### 问题 4：负面示例完全缺失

文章明确警告：_"making skills available can initially reduce triggering by ~20%"_，解法是负面示例。

我们的 CONVENTIONS.md 只告诉 Codex "做什么"，从不说"不要做什么"。结果：
- Codex 会无意义地 `git commit` 空改动
- Codex 会在 review 修复期间跑去做新 feature
- Codex 会重复跑刚跑过的 test
- Codex compact 后可能忘记项目上下文

## 四、优化方案

### 方案核心：策略-机制分离

```
Before: bash = 机制 + 策略（1187 行耦合的 watchdog.sh）
After:  bash = 机制（状态检测 + tmux 执行 + 文件锁）~400 行
        yaml = 策略（规则 + 模板 + 参数）可独立调优
        skill = 流程（monitoring, review, nudge）可复用
```

### 4.1 🔴 watchdog 规则引擎化 (最大收益)

**将 watchdog 从硬编码状态机 → 配置驱动的规则引擎**

```yaml
# ~/.autopilot/watchdog-rules.yaml
rules:
  - name: idle-nudge
    match:
      status: [idle, idle_low_context]
      idle_duration_gt: 300
      idle_confirm_probes_ge: 3
    guards:
      - type: manual_task
        ttl_seconds: 90
      - type: prd_done
        cooldown_seconds: 600
        skip_when: review_has_issues
      - type: exponential_backoff
        base_seconds: 300
        max_retries: 6
    action: nudge
    template_key: context_aware  # 引用 nudge-templates.yaml

  - name: low-context-compact
    match:
      status: idle_low_context
      context_pct_le: 25
    guards:
      - type: cooldown
        key: compact
        seconds: 600
    action: compact

  - name: permission-approve
    match:
      status: [permission, permission_with_remember]
    guards:
      - type: cooldown
        key: permission
        seconds: 60
    action: approve

  - name: shell-recover
    match:
      status: shell
    guards:
      - type: cooldown
        key: shell
        seconds: 300
    action: resume

  - name: new-commits-review
    match:
      new_commits_ge: 15
    guards:
      - type: cooldown
        key: review
        seconds: 7200
    action: trigger_review
```

**收益**：
- watchdog.sh 从 1187 → ~400 行（纯机制层：解析 YAML、匹配规则、执行动作）
- 用户 fork 后**改 YAML 就能适配自己的工作流**，不用看 1000 行 bash
- Guard 逻辑可组合，新增 guard 类型不用改主循环
- 规则可 enable/disable，方便 A/B 测试

### 4.2 🔴 Nudge 模板系统

```yaml
# ~/.autopilot/nudge-templates.yaml
templates:
  context_aware:
    # 根据项目上下文自动选择最佳 nudge
    conditions:
      - when: "phase == 'review' and p0_count > 0"
        message: "Review 发现 {p0_count} 个 P0 问题，请优先修复。具体见 status.json"
      - when: "phase == 'dev' and prd_remaining > 0"
        message: "prd-todo.md 还剩 {prd_remaining} 项，继续下一项"
      - when: "last_commit_type == 'feat' and feat_streak >= 3"
        message: "已连续 {feat_streak} 个 feat commit，请补充单元测试确认无 regression"
      - when: "phase == 'test'"
        message: "请运行完整测试套件，确认所有测试通过"
    default: "先 git add -A && git commit 提交改动，然后继续推进下一项任务"

  after_compact:
    message: "Context 已恢复。请读 CONVENTIONS.md 和 prd-todo.md 恢复上下文，然后继续"

  after_review_clean:
    message: "Review CLEAN 🟢 无新 issue。继续推进 prd-todo.md 下一项"
```

### 4.3 🔴 Cron → Skill 驱动

**创建 OpenClaw skill `autopilot-monitor`**：

```
~/.openclaw/skills/autopilot-monitor/
├── SKILL.md
└── templates/
    └── telegram-report.md
```

**SKILL.md**:
```markdown
---
name: autopilot-monitor
description: |
  Monitor all Codex agent sessions and send Telegram status reports.
  Use when: Periodic cron monitoring, manual status check request.
  Don't use when: Sending nudge to idle agent, code review execution.
---

## Steps
1. Run `~/.autopilot/scripts/monitor-all.sh` and capture JSON output
2. Extract `.summary` array from JSON
3. If summary is empty, compose heartbeat: "💓 Autopilot 在线 | 无变化 | {time}"
4. Send to Telegram via curl: chat_id=5321002140
5. Output "Telegram sent" to confirm

## Don't
- Don't parse the JSON manually, use jq
- Don't add commentary, send the summary as-is
- Don't retry on failure more than once
```

**Cron payload 简化为**：
```json
"message": "Use the autopilot-monitor skill."
```

### 4.4 🟡 CONVENTIONS.md 增加负面示例

每个项目的 CONVENTIONS.md 加入 `## Don't Do` section：

```markdown
## Don't Do (负面示例)

1. **不要空 commit** — 如果没有实际代码改动，不要 `git commit`
2. **不要 review 期间切 feature** — 如果 status.json 显示 review 有 P0/P1，先修 bug 再做新功能
3. **不要重复跑 test** — 如果上一个 commit 是 test 且全过，不要再跑一遍
4. **不要忽略 prd-todo.md** — 这是你的任务清单，每次开始工作先读它
5. **不要在 compact 后裸奔** — compact 后第一件事读 CONVENTIONS.md 和 prd-todo.md
6. **不要超过 200 字符的 commit message** — 保持简洁
7. **不要修改 CONVENTIONS.md 本身** — 除非被明确要求
```

### 4.5 🟡 Compact Prompt 精简

当前 compact_prompt 有 9 条规则，是 config.toml 里的大字符串。

**优化**：只保留一条元规则：
```toml
compact_prompt = "Read CONVENTIONS.md and include its full content in the compacted summary. Also include the full remaining task list from prd-todo.md."
```

所有具体规则移入 CONVENTIONS.md（已经在那里了），compact 时自然保留。**单一来源 > 两处维护**。

### 4.6 🟢 安全加固

文章警告：_"Skills + networking = high-risk for data exfiltration"_

我们用 `sandbox_mode = "danger-full-access"`，开源后需要：
1. README 加显眼安全警告
2. 提供 `sandbox_mode = "write-only"` 的保守配置示例
3. 文档说明网络访问的风险边界

## 五、实施路线

| Phase | 内容 | 工作量 | 收益 |
|-------|------|--------|------|
| **P0** | nudge-templates.yaml + watchdog 读取 | 2h | 策略可调，减少硬编码 |
| **P0** | CONVENTIONS.md 加 Don't Do section (4个项目) | 30min | 减少 Codex 误操作 |
| **P0** | compact_prompt 精简为 1 条 | 10min | 单一来源 |
| **P1** | watchdog-rules.yaml + 规则引擎 | 4h | watchdog 1187→~400 行 |
| **P1** | autopilot-monitor skill + cron 简化 | 1h | 消灭 prompt spaghetti |
| **P2** | 安全文档 + 保守配置 | 1h | 开源安全性 |
| **P2** | 开放 nudge A/B 测试框架 | 2h | 可量化优化 |

## 六、预期效果

```
代码量：3100 行 bash → ~1800 行 bash + ~300 行 YAML + 2 个 skill
可维护性：改策略需读 bash → 改 YAML/MD
可移植性：fork 后改 bash → fork 后改 YAML
Codex 效率：盲目 nudge → 上下文感知 nudge + 负面示例减少误操作
开源价值：bash 脚本集 → 配置驱动的 agent 编排框架
```

核心理念：**bash 做它擅长的（确定性检测、文件操作、进程管理），skill/yaml 做它擅长的（流程定义、模板管理、策略配置）**。
