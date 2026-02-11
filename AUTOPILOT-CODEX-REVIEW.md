# AUTOPILOT CODEX FLOW REVIEW

审查日期：2026-02-11  
审查人：Codex  
审查范围：
- `~/.autopilot/scripts/watchdog.sh`
- `~/.autopilot/scripts/tmux-send.sh`
- `~/.autopilot/scripts/monitor-all.sh`
- `~/.autopilot/scripts/consume-review-trigger.sh`
- `~/.autopilot/scripts/codex-status.sh`
- `~/.autopilot/scripts/auto-nudge.sh`
- `/Users/wes/Shike/{status.json, prd-todo.md, CONVENTIONS.md}`
- `/Users/wes/projects/agent-simcity/{status.json, prd-todo.md, CONVENTIONS.md}`
- `/Users/wes/replyher_android-2/{status.json, prd-todo.md, CONVENTIONS.md}`

---

## 1) 消息传递可靠性

### [P1] 长消息使用固定 tmux buffer 名，存在并发串消息风险
- 描述：`tmux-send.sh` 在长消息路径固定使用 `autopilot-msg` buffer；多个发送并发时会互相覆盖。
- 证据：`/Users/wes/.autopilot/scripts/tmux-send.sh:50`、`/Users/wes/.autopilot/scripts/tmux-send.sh:51`
- 风险：错发指令、内容串台、review 指令与 nudge 混淆。
- 修复建议：
  - buffer 名改为唯一值（`autopilot-msg-${WINDOW}-$$-$(date +%s%N)`）。
  - 发送流程加项目级锁（与 `watchdog` 同目录锁机制统一）。
  - 发送后立即校验 pane 尾部是否包含发送文本片段（最小 ACK）。

### [P1] watchdog 对发送失败无感知，但仍进入冷却与计数
- 描述：`watchdog` 调用 `tmux-send.sh` 后直接 `set_cooldown` 并记录“已发送”，未检查退出码。
- 证据：`/Users/wes/.autopilot/scripts/watchdog.sh:303`、`/Users/wes/.autopilot/scripts/watchdog.sh:304`、`/Users/wes/.autopilot/scripts/watchdog.sh:319`、`/Users/wes/.autopilot/scripts/watchdog.sh:320`、`/Users/wes/.autopilot/scripts/watchdog.sh:337`、`/Users/wes/.autopilot/scripts/watchdog.sh:338`
- 风险：实际没发出去，但 5 分钟或更久不重试，造成“假推进”。
- 修复建议：
  - 封装 `send_message()`，统一返回 `success/fail`。
  - 只有成功才写 cooldown/递增 nudge-count；失败写 `send-failed` 计数并短退避重试。

### [P2] 关键信息被静默吞掉，定位失败原因困难
- 描述：`watchdog` 调用 `tmux-send.sh` 时把 stdout/stderr 全部重定向到 `/dev/null`。
- 证据：`/Users/wes/.autopilot/scripts/watchdog.sh:303`、`/Users/wes/.autopilot/scripts/watchdog.sh:319`、`/Users/wes/.autopilot/scripts/watchdog.sh:337`
- 风险：`tmux-send.sh` 明确报错（窗口不存在、pane 是 shell）也不可见。
- 修复建议：
  - 保留 stderr 到 `watchdog.log`，并带 window/action 前缀。
  - 失败时输出结构化日志字段：`{"event":"send_failed","window":"...","reason":"..."}`。

### [P3] 结论确认
- 描述：所有 nudge 路径均已走 `tmux-send.sh`，没有直接 `send-keys` 的 nudge 分支。
- 证据：`/Users/wes/.autopilot/scripts/watchdog.sh:303`、`/Users/wes/.autopilot/scripts/watchdog.sh:319`、`/Users/wes/.autopilot/scripts/watchdog.sh:337`
- 建议：保留此一致性，继续把“发送、校验、重试”收敛为单入口（SRP）。

---

## 2) 状态检测准确性

### [P1] 存在两套状态机，规则分裂
- 描述：`watchdog.sh::detect_state()` 与 `codex-status.sh` 独立维护，判定条件和状态枚举不一致。
- 证据：
  - `watchdog` 状态机：`/Users/wes/.autopilot/scripts/watchdog.sh:162`
  - `codex-status` 状态机：`/Users/wes/.autopilot/scripts/codex-status.sh:1`
- 风险：同一时刻 `monitor-all` 判定为 working，但 `watchdog` 判 idle，导致误 nudge/漏处理。
- 修复建议：
  - 单一事实源：`watchdog` 直接调用 `codex-status.sh` 或抽出共享库脚本。
  - 统一状态枚举及阈值，禁止分叉实现（OCP + DRY）。

### [P2] 低 context 阈值不一致（15 vs 25）
- 描述：`watchdog` 在 `<=15` 才进入 `idle_low_context`，`codex-status` 是 `<=25`。
- 证据：`/Users/wes/.autopilot/scripts/watchdog.sh:193`、`/Users/wes/.autopilot/scripts/codex-status.sh:102`
- 风险：compact 时机不一致，监控与守护动作不对齐。
- 修复建议：提取统一常量（例如 `LOW_CONTEXT_THRESHOLD=20`）并被两侧共享。

### [P2] watchdog 缺失 `permission_with_remember` 显式状态
- 描述：`codex-status` 区分 `permission` 与 `permission_with_remember`，`watchdog` 仅识别 `permission`。
- 证据：`/Users/wes/.autopilot/scripts/codex-status.sh:87`、`/Users/wes/.autopilot/scripts/watchdog.sh:171`
- 风险：权限交互策略难以统一演进，未来扩展易引入行为回归。
- 修复建议：统一状态全集并在 action 层处理差异，而不是检测层丢信息（ISP）。

### [P3] shell 判定依赖提示符正则，存在边界误判可能
- 描述：`watchdog` 通过最后一行匹配 `$/%/❯` 判定 shell。
- 证据：`/Users/wes/.autopilot/scripts/watchdog.sh:182`
- 风险：当模型输出文本恰好匹配提示符样式时可能误判。
- 修复建议：优先使用 `pane_current_command`（`codex-status` 的方式）作为一类强信号。

---

## 3) 自动推进效果

### [P1] 缺少“指令生效”闭环，只有“发送成功”假设
- 描述：当前只有“已发送 nudge”的日志，无“Codex 已开始执行”的确认信号。
- 证据：`/Users/wes/.autopilot/logs/watchdog.log` 中高频 `auto-nudged`，缺乏对应 ACK 事件。
- 风险：系统以为在推进，实际可能被忽略或被覆盖。
- 修复建议：
  - 增加执行 ACK 机制：发送后 15~30 秒检查 pane 是否出现新活动行（如 `• ...` 或新 commit）。
  - ACK 失败进入重试/升级策略（换短指令、换任务、告警）。

### [P2] 指令质量提升但仍偏文本启发式
- 描述：`get_smart_nudge()` 依赖 commit message + `prd-todo` 文本规则；缺少结构化任务状态。
- 证据：`/Users/wes/.autopilot/scripts/watchdog.sh:531`
- 风险：复杂任务流下容易“重复催促”或跳错步骤。
- 修复建议：
  - 把 PRD 待办改为结构化（YAML/JSON）并记录 `owner/status/updated_at`。
  - nudge 选择器按状态图驱动，而不是 grep 文本（DIP）。

### [P3] 已有改进点可保留
- 描述：已增加“PRD 全部完成则改为测试确认+等待新指令”的分支，缓解 Done 任务反复催促。
- 证据：`/Users/wes/.autopilot/scripts/watchdog.sh:534`、`/Users/wes/.autopilot/scripts/watchdog.sh:541`
- 建议：继续把 `next_task` 的筛选语义与“全部完成”逻辑统一到同一解析函数，避免双重 grep 规则漂移。

---

## 4) review 流程闭环（Layer1 -> Layer2 -> 修复 -> 再 review）

### [P0] Layer2 未完成/未验证时仍可直接判定 review clean 并重置计数
- 描述：`consume-review-trigger.sh` 只要本地 `local_issues` 为空就走 clean+reset；并不等待或解析 Codex Layer2 review 结果。
- 证据：`/Users/wes/.autopilot/scripts/consume-review-trigger.sh:93`、`/Users/wes/.autopilot/scripts/consume-review-trigger.sh:100`、`/Users/wes/.autopilot/scripts/consume-review-trigger.sh:103`
- 风险：review 形同“发了一句指令就算完成”，质量闭环断裂。
- 修复建议：
  - 两阶段状态机：`triggered -> layer2_sent -> layer2_ack -> issues_confirmed -> reset`。
  - 只有拿到 Layer2 结构化结果（例如 JSON 清单）后才允许 reset。

### [P1] Codex 非 idle 时 Layer2 被 defer，但 trigger 仍被消费且流程结束
- 描述：非 idle 时仅记录 defer 日志，随后仍走后续 clean/reset 路径（若 local_issues 为空）。
- 证据：`/Users/wes/.autopilot/scripts/consume-review-trigger.sh:88`、`/Users/wes/.autopilot/scripts/consume-review-trigger.sh:100`
- 风险：本该重试的 review 被“吞单”。
- 修复建议：defer 时保留 trigger，不更新 review cursor，不重置计数，下轮再消费。

### [P1] `.last-review-commit` 无条件推进，可能跳过未审查提交
- 描述：无论 Layer2 是否真正完成，都会写入当前 `review_commit`。
- 证据：`/Users/wes/.autopilot/scripts/consume-review-trigger.sh:108`
- 风险：后续增量 diff 基线前移，导致漏审。
- 修复建议：仅在 `layer2_ack && issues_processed` 成功后更新 cursor。

### [P2] Layer2 文件列表上限 10 个，可能漏掉关键改动
- 描述：增量文件列表 `head -10`。
- 证据：`/Users/wes/.autopilot/scripts/consume-review-trigger.sh:73`、`/Users/wes/.autopilot/scripts/consume-review-trigger.sh:75`
- 风险：跨文件缺陷（依赖链、接口变更）漏检。
- 修复建议：
  - 对超限场景改为“分批审查”或“按风险优先级抽样 + 全量索引”。
  - 日志中记录“截断发生”。

### [P2] consumer 的 `npx tsc --noEmit` 无 timeout，可能阻塞周期任务
- 描述：consumer 层 tsc 没有超时保护。
- 证据：`/Users/wes/.autopilot/scripts/consume-review-trigger.sh:52`
- 风险：monitor/cron 卡住，后续 trigger 积压。
- 修复建议：与 `watchdog` 同步统一 `run_with_timeout`。

### [P3] review 历史按日期覆盖写，单日多次记录会丢失
- 描述：写入 `/.code-review/YYYY-MM-DD.json` 为覆盖模式。
- 证据：`/Users/wes/.autopilot/scripts/consume-review-trigger.sh:115`
- 风险：无法追溯同日多轮 review 演进。
- 修复建议：改为 append JSONL 或 `YYYY-MM-DD-HHMMSS.json`。

---

## 5) `status.json` 维护机制

### [P1] 当前只有读取链路，没有自动写回链路
- 描述：脚本集中仅 `monitor-all.sh` 读取项目 `status.json`，未发现更新逻辑。
- 证据：`/Users/wes/.autopilot/scripts/monitor-all.sh:130`；全局检索仅此处命中。
- 风险：生命周期状态依赖人工维护，容易过期失真。
- 修复建议：
  - 增加 `status-sync.sh`：在 commit/review/test/deploy 事件后自动更新。
  - 设定责任归属：`watchdog` 负责事实采集，`status-sync` 负责投影写入（SRP）。

### [P2] 状态结构未做 schema 校验
- 描述：读取时默认兜底，但缺少格式验证和版本管理。
- 证据：`/Users/wes/.autopilot/scripts/monitor-all.sh:133` 到 `:153`
- 风险：字段拼写变更后静默退化为 `pending/unknown`。
- 修复建议：为 `status.json` 增加 schema version + 校验脚本，异常即告警。

---

## 6) 项目配置同步

### [P2] `PROJECTS` 被多处硬编码，存在漂移风险
- 描述：`watchdog.sh` 与 `monitor-all.sh` 各自维护 `PROJECTS`。
- 证据：`/Users/wes/.autopilot/scripts/watchdog.sh:54`、`/Users/wes/.autopilot/scripts/monitor-all.sh:27`
- 风险：新增/删减项目时容易漏改，导致监控与守护不一致。
- 修复建议：抽成单一配置源（`watchdog-projects.conf` 或 JSON），两脚本共用解析器。

### [P2] 已有 `watchdog-projects.conf` 但未被主流程消费
- 描述：配置文件存在且写明“添加/删除项目只改此文件”，但脚本仍硬编码。
- 证据：`/Users/wes/.autopilot/watchdog-projects.conf:1`
- 风险：认知与实现不一致。
- 修复建议：立刻切换到配置驱动；增加启动时配置一致性检查。

---

## 7) 错误恢复与自愈

### [P1] `monitor-all.sh` / `consume-review-trigger.sh` 缺少进程互斥锁
- 描述：若定时任务重叠执行，可能并发消费 trigger、并发写 state。
- 证据：两脚本未见锁实现（对比 `watchdog` 的 `watchdog-main.lock.d`）。
- 风险：重复消费、状态竞态、统计抖动。
- 修复建议：
  - 为 monitor/consumer 加目录锁（与 watchdog 同实现）。
  - 触发消费改原子“claim -> process -> commit/rollback”。

### [P2] `watchdog.sh` 仅 `set -u`，关键命令失败默认继续执行
- 描述：不启用 `set -e`，多数错误不会中断流程。
- 证据：`/Users/wes/.autopilot/scripts/watchdog.sh:19`
- 风险：出现“半失败半成功”隐蔽状态。
- 修复建议：
  - 保留主循环容错，但关键动作采用显式返回码检查。
  - 对不可恢复错误记录并短路当前 action。

### [P2] 历史 stderr 显示过大量数值比较异常，鲁棒性仍需加固
- 描述：日志中有大量 `integer expression expected` 历史噪音。
- 证据：`/Users/wes/.autopilot/logs/watchdog-stderr.log`
- 风险：状态文件污染时，比较逻辑可能再次失效。
- 修复建议：所有参与算术比较的读取值统一走 `normalize_int()`。

### [P3] 正向观察
- 描述：`watchdog` 已具备主锁、僵尸锁回收、ERR/EXIT trap，自愈基础较好。
- 证据：`/Users/wes/.autopilot/scripts/watchdog.sh:614` 到 `:630`
- 建议：把同级自愈能力扩展到 monitor/consumer。

---

## 8) 日志与可观测性

### [P1] 关键链路缺少“发送失败/执行确认”事件
- 描述：有 `auto-nudged` 但缺少 `send_ok/send_fail/ack_timeout` 分层日志。
- 证据：`/Users/wes/.autopilot/logs/watchdog.log`（大量发送日志，无 ACK 类字段）
- 风险：无法区分“没发出”与“发出未执行”。
- 修复建议：定义统一事件模型：
  - `send_attempt`、`send_ok`、`send_fail`
  - `ack_ok`、`ack_timeout`
  - `action_skipped`（含 reason）

### [P2] review 可观测性不足
- 描述：未记录 Layer2 输出摘要、问题计数、耗时、覆盖文件数。
- 证据：`/Users/wes/.autopilot/scripts/consume-review-trigger.sh:86`、`:94`、`:101`
- 风险：review 流程无法审计质量。
- 修复建议：落盘结构化 review artifact（JSON），monitor 汇总展示。

### [P3] 日志文件分散
- 描述：`watchdog.log`、`watchdog-stderr.log`、launchd `/tmp/autopilot/*.log` 并存。
- 证据：`/Users/wes/.autopilot/com.wes.codex-autopilot.plist:22`、`:25`
- 风险：排障入口不统一。
- 修复建议：统一日志目录与轮转策略，stderr 标准化归集。

---

## 9) 资源管理（内存/磁盘/进程）

### [P1] consumer 的类型检查缺少 timeout，有卡死风险
- 描述：与第 4 维一致，属于资源占用与调度风险。
- 证据：`/Users/wes/.autopilot/scripts/consume-review-trigger.sh:52`
- 修复建议：`timeout 30 npx tsc --noEmit`，并记录超时事件。

### [P2] `monitor-all` 每轮全量统计 `git rev-list --count HEAD`
- 描述：每次输出都遍历全部历史，仓库变大后成本上升。
- 证据：`/Users/wes/.autopilot/scripts/monitor-all.sh:213` 到 `:218`
- 风险：cron 周期内 CPU/IO 增长，可能与主流程争资源。
- 修复建议：缓存总提交数，仅在 HEAD 变化时增量更新。

### [P3] 当前磁盘占用健康，但需防长期增长
- 观测：`logs` 约 164K，`state` 约 112K，文件数约 30。
- 证据：本次审查运行数据。
- 建议：
  - `state/watchdog-commits` 按项目设置历史 TTL。
  - consumer/review artifact 采用按天目录 + 保留策略。

---

## 额外发现（跨维度）

### [P1] review consumer 曾出现 `SCRIPT_DIR` unbound/数值比较异常历史错误
- 证据：`/Users/wes/.autopilot/logs/watchdog.log:578`、`:595`、`:601`
- 说明：当前版本已有修复痕迹，但建议补回归测试防回退。
- 修复建议：为 `consume-review-trigger.sh` 增加最小 smoke test（空 trigger、坏路径、正常路径）。

---

## 汇总结论

当前 autopilot 已具备：
- watchdog 主循环与基础自愈能力
- nudge/compact/shell recovery 自动动作
- commit 驱动 Layer1 检查与 Layer2 trigger 框架

但存在一个核心质量断点：
- **Layer2 review 的“完成判定”与“计数重置”逻辑不闭环（P0）**。这会直接削弱自动审查体系可信度。

---

## 建议优先级（执行顺序）

1. **P0（立即）**：重构 `consume-review-trigger.sh` 为状态机，未拿到 Layer2 有效结果不得 reset。  
2. **P1（本周）**：统一消息发送入口（带返回码/ACK/重试），修复“发送失败仍冷却”。  
3. **P1（本周）**：统一状态检测单一事实源，去除双状态机分叉。  
4. **P1（本周）**：为 monitor/consumer 增加互斥锁与原子消费。  
5. **P2（下周）**：项目配置改为单一配置源（启用 `watchdog-projects.conf`）。  
6. **P2（下周）**：建立 `status.json` 自动写回与 schema 校验。  
7. **P2/P3（持续）**：完善结构化日志与资源指标，形成可观测闭环。

---

## SOLID 对齐建议（落地）

- **S（单一职责）**：
  - `watchdog` 只做检测和调度。
  - `sender` 只做发送+ACK。
  - `review-consumer` 只做 trigger 生命周期管理。
- **O（开闭）**：
  - 状态机和阈值配置化，新增状态不改主流程。
- **L（里氏替换）**：
  - 抽象 `MessageTransport`（tmux、未来 API）后可替换实现。
- **I（接口隔离）**：
  - `StatusProvider`、`ReviewProvider`、`ProjectConfigProvider` 分离。
- **D（依赖反转）**：
  - 主流程依赖接口而非脚本细节，便于测试和回归验证。

