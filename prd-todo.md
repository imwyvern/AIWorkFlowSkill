# Autopilot 优化 PRD

## 第一批 ✅
- M-1 Layer2 review clean 误判 ✅
- M-2 发送失败仍进冷却 ✅
- M-5 Layer2 trigger 非 idle 被消费 ✅
- M-6 .last-review-commit 无条件推进 ✅
- M-9 PROJECTS 硬编码两处 ✅

## 第二批 ✅
- M-3 两套状态机统一 ✅
- M-4 指令生效闭环 ✅
- M-7 status.json 自动更新 ✅
- M-8 互斥锁 ✅

## 第三批
- M-10 低 context 阈值不一致 (15 vs 25)
- M-11 Layer2 文件列表上限 10 个
- M-12 tsc --noEmit 无 timeout
- M-13 review 历史按日期覆盖
- M-14 watchdog 仅 set -u，关键命令失败继续
- M-15 md5 管道优先级
- M-16 tmux paste-buffer 竞态

## 全面 review
- 双路 review (Claude + Codex) 直到 P0/P1 = 0
