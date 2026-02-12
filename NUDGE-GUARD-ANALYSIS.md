# Nudge Guard Analysis (commit 6ee1da5aae58937a3eebacfdbd6002d0e0a8b531)

## 当前策略概览
1. `manual-task` 从 5 分钟降到 90 秒，目的是在人工/Claude 直接用 `tmux-send` 发送任务之后迅速恢复 watchdog 的催促。
2. `prd-done` guard 由 30 分钟降至 10 分钟，同时只有当 PRD 完成且 Layer2 review 清洁时才启用；若 review 有 issues 仍使用常规频率。
3. 其它 guard（指数退避、idle 确认）仍存在，因此单次 nudge 间隔仍可能累积，但典型路径比原来短得多。

## 是否合理？
- ✅ 降低 manual-task guard 有助于避免 Codex 长时间处于人类 task 之后的“沉默期”。90 秒足够让人类发出任务、Codex 进行确认，之后即可恢复自动 nudging。
- ✅ PRD guard 与 review 结果联动合理：只有当 review clean 且 PRD 无 issues 时才降低频率，避免在 review-loop 中错过 issue 反馈；10 分钟的低频窗口为稳定监控提供气氛，但仍不会阻塞常规 nudge 流程。
- ✅ 所有 guard 还有 `idle_state_confirmed()`、指数退避等辅助，组合起来虽然复杂但其作用互补：手动任务避免覆盖、PRD guard避免重复无效 nudge、指数退避限制突发连续失败。

## 风险与进一步优化
- 即便 guard 调小，指数退避仍会把冷却推到 300s/600s/1200s...，在 Codex 连续无响应时仍会等待较久。建议考虑在 nudge count reset 的逻辑中更积极地响应“review issues 解决/手动 ack”事件，以便 watchdog 早早重启冷却。
- `manual-task` TTL 现在 90 秒，但如果手动任务需要更长时间（如复查多个窗口），可能仍被 watchdog 误判。可考虑在 `tmux-send` 里在手动任务成功 ACK 后再删除标记（当前 rely on TTL），或提供可扩展界面让人工可选延长 guard。

## 结论
方案总体合理，明显提高了敏捷性；唯一补充建议是：让指数退避在 review success 后主动 reset（若还没做），并在 `tmux-send` 旁添加可配置 guard TTL/延长接口，以适应不同的 manual workflow。
