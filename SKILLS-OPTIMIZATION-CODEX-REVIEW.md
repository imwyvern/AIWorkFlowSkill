# Skills/Optimization Review

## 同意的要点
- **关注点分离** 的思路很清晰：bash 专注检测/执行，把策略、模板、负面指令交给 YAML/CONVENTIONS/skills，符合文章“让 skill 成为活的 SOP”框架。
- **watchdog 规则引擎化 + nudge 模板系统** 扩展性高，尤其 guard/模板分离可让用户只调 YAML 便控制冷却、优先级、文案，避免深入理解 1187 行的大脚本。
- **Cron → 巧用 OpenClaw skill** 也合理，通过 SKILL.md 明确步骤，可以让 Cron payload 只写“调用 skill”，避免 prompt spaghetti，也方便版本控制和复用。
- **负面示例** 补充到 CONVENTIONS.md 可以让 Codex 分辨 “不要做” 的行为，应该能减缓那种“技能精准触发后不触发”的副作用。
- **Compact prompt 精简**：把规则转移到 CONVENTIONS.md，减少重复，符合“单一来源”原则。

## 不完全同意 / 需补充的地方
- watchdog 规则引擎化很棒，但需要考虑 guard/action 之间的**并发/竞态**（例如 manual-task TTL 与 prd-done guard 的复合布尔逻辑）。建议引擎输出“决策 trace”，即每条规则匹配时产出日志，方便调优 guard 顺序。
- nudge 模板的 conditions 语言需要更具体（当前伪表达式如 `phase == 'review' and p0_count > 0`），建议用可扩展的评估器（Lua/JS 或 jq 表达式），否则用户要改就得改代码。
- autopilot-monitor skill 给 Cron 的 instruction 过于简略。如果 skill 失败（jq/monitor-all.sh 出错），cron 仍会抛错。建议 skill 定义明确的重试策略/备用消息格式，并将 Telegram 配置信息外置（`config.yaml`）避免硬编码 chat_id。
- rule guard 依赖 YAML/模板后期要有人维护，文档需要说明 guard 之间的优先级和 default action，避免用户把不兼容的 guards 组合在一起导致 “无规则命中” 的静默失败。

## 补充建议
1. **Rule 规范化**：建议提供一个 rule validation CLI（`scripts/watchdog-validate-rules.sh rules.yaml`）提前 catch “guard 缺参数” 或 `template_key` 不存在的情况。这样规则引擎化不会因为任意 typo 崩溃。
2. **Guard 的可组合性**：可以允许 rule 定义多个 actions，比如 `action: [nudge, sync_status]`，并为某些 guard 提供 `on_skip` 回调（例如 manual task guard 被触发时再发 Telegram 提醒）。
3. **模板变量来源**：nudge template 里提到 `status.json`、`prd_remaining` 等，建议把数据采集封装到 `monitor-all` 的 JSON output，而不是在 rule engine 里直接 shell eval，增强 determinism。
4. **技能注册/版本**：OpenClaw skill 应该带版本号（`skill_version: 1.0.0`），方便未来改动影响范围自测。
5. **安全边界**：既然提出 YAML/skills 载体，就需要明确哪些目录可写、哪些 env 变量会被 skill 读取；建议在 README 补充 `SKILL` 与 `watchdog` 之间的权限/信任模型。

## 结论
整体方案思路方向正确：策略从 bash 中抽离出来、模板化 nudge、引入 skill 及负面示例都显著提升可维护性和可扩展性。建议在推进 engine/skill 之前，先把 rule/guard 模型的语义、优先级、变量来源等写成 Spec，并加个 rule 验证工具；模板系统要支持 condition 语言可复用；skill 的失败/重试机制也需在 SKILL.md 里约定。这样迁移才不至于带来新的盲区。
