# Autopilot UX + 技术 Review

## 1. Wesley 日常使用痛点（UX 角度）
1. **nudge/手动任务冲突太容易发生** — `scripts/tmux-send.sh` 手工发送会被 watchdog `handle_idle` 在 90 秒内静默拦截，说明实际体验里常常需要等才能看到结果，刚刚的 fix 也说明之前存在覆盖问题。
2. **Cron Telegram 报告错过“心跳”** — `monitor-all.sh` 在无变化时直接输出 `{"changes":false}`，导致 cron agent 认为不需要发消息（如今改完善心跳但还需保证 cron 真正调用 message 工具），Wesley 常常看不到每天/两小时的“系统在线”提醒。
3. **watchdog guard 复杂、冷却长、反馈慢** — 倍增退避 + manual-task + prd-done 造成工作完成后最多要等 10+ 分钟才再被催促，使 Wesley 在看到 Codex idle 时仍得等一会才能重新干活。
4. **缺乏负面示例与触发透明度** — `CONVENTIONS.md` 与 prd + review 工具大多告诉 Codex “该做什么”，缺乏“不要做”的约束，结果 Wesley 仍需频繁看 logs/`state/.last_report` 确认 Codex 没做错事。
5. **状态追踪分散** — 监控数据分散在 `state/*.json`、`state/.last_report`、`logs/watchdog.log`，手工查询不便；Cron skill 优化方案能改善，但当前流程仍需手动拼 `jq`。

## 2. 技术角度：遗漏的 bug / 闭环断点
1. **rule/guard 组合缺乏可视化** — `watchdog.sh` 本质是状态巡检+ guard 叠加，目前 guard 条件写死在 bash 中，导致冷却/优先级难以测试（例如 manual-task + prd-done + exponential 一起叠加会延迟 nudge）。如果每层 guard 的触发/skip 都没 log trace，难以定位为何某次 nudge 没发生。
2. **monitor-all 与 consume-review-trigger 之间的等待逻辑** — Cron 先写 review trigger、`monitor-all` 后台消费并等待 `layer2-review-*` 输出；若 review 卡住，consume-review-trigger 会在 90s 之外再处理，造成 watchdog/cron 之间没有及时回报，影响 idle review 闭环。
3. **Codex 状态检测仍靠 grep/返回码** — 虽然 `codex-status.sh` 增加了 `emit_json`、替换 grep，依赖 `jq` 仍代表一个单点失败，如果 jq 不可用/输出不规范，整条监控会报错，由于整个脚本对 `set -uo pipefail`，任何 `grep` 失败前后考虑异常还是必要的。
4. **nudge template 不灵活** — 目前 nudge 文案分散在 `watchdog.sh`，很难根据 review状态/PRD/commit type 生成动态内容。规则引擎+模板建议能让 cron/guard 输出更多上下文提醒。
5. **技能/cron 的“message tool”调用不明确** — Cron prompt 仅发 Telegram 说明，agent 可能只回应文本；需要明确指令 `message tool(action=send, target=..., channel=telegram)` 来保证通知闭环。
6. **状态记录/heartbeat 聚合分离不足** — `state/watchdog-activity/*`、`state/watchdog-cooldown/*` 等数据写的频繁但缺乏 versioned schema，若 future 版本更换 guard 逻辑现有文件会被遗留。

## 3. 整体结论与建议
- 建议将 watchodog guard + nudge 模板配置化（`watchdog-rules.yaml` + `nudge-templates.yaml`），保留 bash 负责执行/lock；并添加 rule 验证工具，防止 guard/模板语法错误导致冷却失效。
- Cron 可考虑注册 skill（`autopilot-monitor`）而非 inline shell block，使得 Telegram 发送明确触发 message tool，同时 skill 里可配置失败重试、body cast log。
- 增加“负面示例”/“不要做”的文档片段（© `CONVENTIONS.md`）帮助 Codex 避免重复行为，减少 Wesley 查看日志的频率。
- 把 key 状态汇总放入 `state/.last_report`，并在 Telegram 报告中引用 (`lifecycle_phase_counts`, `review_status_counts`, `progress`)，便于 Wesley 一眼看到系统健康度。

以上 review 基于对 `scripts/*.sh`、`state/*.json` 以及 logs/ 表现的观察，并结合当前已部署 guard/cron/Telegram 流程。
