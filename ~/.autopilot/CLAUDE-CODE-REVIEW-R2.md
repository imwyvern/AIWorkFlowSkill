# CLAUDE Code Review (commit 746df3a7f4b8264f1cf1891785fa3bee3ce0beb6)

## 1. 需求观察
- `scripts/tmux-send.sh` 现在会在自然消息发送后写 `state/manual-task-<window>` 时间戳，作为人工任务标记。
- `watchdog.handle_idle()` 在做任何 nudge 之前会检查这个标记，90 秒内跳过，让人工任务有窗口先展示内容，超时后自动清理。
- `watchdog.send_tmux_message()` 在 watchdog 自己通过 tmux 发送消息前先删除标记，防止自家 nudge 反复占位。

## 2. 验证
1. `tmux-send.sh` 的标记写入在 short/long send 的 `OK` 处理路径里，使用 `SAFE_WINDOW`，能覆盖所有手动任务调用。
2. `handle_idle` 的逻辑位于 `manual_task` 检查块：读取时间戳，若距今 <90s 就跳过 nudge，并额外 `release_lock`（虽 lock 尚未 acquire，但 noop）；否则删除文件并继续判断。确保人工任务发起后不被 watchdog 覆盖。
3. `send_tmux_message` 删除 `manual-task` 标记后再判断 tmux 发送返回，避免 watchdog 发出的自己消息继续阻塞自己。

## 3. 发现的问题
- 说明文档/commit message 仍然提到“5 分钟”，但实际 guard 只有 90 秒；如果 5 分钟描述是为了强调悠悠不催，建议同步注释或 README，避免误导维护者。

## 4. 结论
本次改动完成了“人工发送先行”的防护链，逻辑合理、没有引入新的 P0-P3 失败。建议补充 doc 注释，说明 `manual-task` ttl 是 90 秒而非 5 分钟。
