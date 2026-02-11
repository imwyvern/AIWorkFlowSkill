# Autopilot 合并审查报告 — Claude + Codex 双路 Review

> 2026-02-11 06:30 PST | 合并自 AUTOPILOT-E2E-REVIEW.md (Claude) + AUTOPILOT-CODEX-REVIEW.md (Codex)

## 已修复（本轮不需要再改）

| # | 问题 | 来源 | 修复 |
|---|------|------|------|
| ✅ | Nudge 风暴无退避 | Claude C-1 | 指数退避 + max 6 + Telegram 告警 |
| ✅ | `（Done）` 任务不被过滤 | Claude C-2 | grep -vi 'done\|完成' |
| ✅ | PRD 全完成仍强制写测试 | Claude C-8 | PRD-complete guard |
| ✅ | `\n` 未渲染 | Claude C-5 | $'\n' |
| ✅ | normalize_int 全覆盖 | 历史 P0-3 | 已验证 |
| ✅ | wait -n 兼容 | 历史 P0-2 | wait 2>/dev/null |
| ✅ | pid 锁 + ERR trap | 历史 P0-2 | kill -0 + trap |

## 待修复 — P0

| # | 问题 | 来源 | 说明 |
|---|------|------|------|
| M-1 | Layer2 review clean 误判 | Codex §4 P0 | Layer2 未完成/失败时仍判定 clean 并重置 commit 计数。必须检查 review 输出文件存在且非空。 |

## 待修复 — P1

| # | 问题 | 来源 | 说明 |
|---|------|------|------|
| M-2 | 发送失败仍进入冷却+计数 | Codex §1 P1 | tmux-send.sh 返回非 0 时，不应 set_cooldown 也不应递增 nudge_count |
| M-3 | 两套状态机规则分裂 | Codex §2 P1 | watchdog.sh 和 codex-status.sh 各有独立状态判定逻辑，应统一为单一来源 |
| M-4 | 缺少指令生效闭环 | Codex §3 P1 | nudge 发出后无法确认 Codex 是否开始执行。建议: nudge 后 60s 检查是否有新 commit 或 context% 变化 |
| M-5 | Layer2 trigger 非 idle 时被消费但流程终止 | Codex §4 P1 | 应保留 trigger 文件等 Codex idle 后再消费 |
| M-6 | .last-review-commit 无条件推进 | Codex §4 P1 | 应仅在 review 真正完成后推进 |
| M-7 | status.json 只读不写 | Codex §5 P1 + Claude C-4 | 两份报告都指出。要么废弃，要么加自动更新钩子（commit 后更新 phase） |
| M-8 | monitor-all/consume-review 缺互斥锁 | Codex §7 P1 | 加 mkdir 原子锁 |
| M-9 | PROJECTS 硬编码两处 | Codex §6 P2 + Claude C-6 | 抽取到 projects.conf，source 共享 |

## 待修复 — P2

| # | 问题 | 来源 |
|---|------|------|
| M-10 | 低 context 阈值不一致 (15 vs 25) | Codex §2 |
| M-11 | Layer2 文件列表上限 10 个 | Codex §4 |
| M-12 | tsc --noEmit 无 timeout | Codex §4 |
| M-13 | review 历史按日期覆盖 | Codex §4 |
| M-14 | watchdog 仅 set -u，关键命令失败继续 | Codex §7 |
| M-15 | md5 管道优先级 | Claude C-9 |
| M-16 | tmux paste-buffer 竞态（理论风险低） | Claude C-3 |

## 修复优先级

**第一批（必须修）**: M-1, M-2, M-5, M-6, M-9
**第二批（应修）**: M-3, M-4, M-7, M-8
**第三批（可观察）**: M-10 ~ M-16
