# AIWorkFlow — Codex Autopilot System

> 多项目 AI 编码助手自动化监控与任务编排系统

## 架构

```
launchd (10s) → watchdog.sh (守护进程)
                  ├── codex-status.sh (状态检测)
                  ├── tmux-send.sh (消息发送)
                  ├── task-queue.sh (任务队列)
                  └── consume-review-trigger.sh (代码审查)

cron (10min) → monitor-all.sh (监控报告 → Telegram)
```

### 核心脚本 (`scripts/`)

| 脚本 | 功能 |
|------|------|
| `watchdog.sh` | 主守护进程 — 状态检测、自动 nudge、权限处理、compact 恢复、任务队列调度 |
| `codex-status.sh` | Codex TUI 状态检测 (working/idle/permission/shell/absent) |
| `tmux-send.sh` | 三层 tmux 消息发送 (send-keys/chunked/paste-buffer) |
| `monitor-all.sh` | 10 分钟全局监控 + Telegram 报告 |
| `task-queue.sh` | 任务队列 CRUD (add/list/next/start/done/fail) |
| `consume-review-trigger.sh` | Layer 2 代码审查消费者 |
| `auto-nudge.sh` | 独立 nudge 脚本 (可单独调用) |
| `codex-token-daily.py` | Token 用量统计 |
| `prd_verify_engine.py` | PRD 验证引擎 (checker plugins) |
| `status-sync.sh` | 项目状态自动同步 |

### 防护机制

- **指数退避**: nudge 间隔 300→600→1200→2400→4800→9600s, 6 次后停止 + 告警
- **3 次 idle 确认**: 避免 API 延迟导致误判
- **90s 工作惯性**: 刚检测到 working 的 90s 内不 nudge
- **手动任务保护**: 人工发送的任务 90s 内不被覆盖
- **Compact 上下文快照**: compact 前保存任务状态, compact 后精准恢复
- **原子锁 (mkdir)**: macOS 无 flock, 用 mkdir 实现
- **三层消息发送**: ≤300 send-keys / ≤800 chunked / >800 paste-buffer

## 快速开始

1. 配置 `watchdog-projects.conf`:
```
ProjectName:/path/to/project:default nudge message
```

2. 配置 `config.yaml` (Telegram bot token + chat_id)

3. 启动 tmux session:
```bash
tmux new-session -s autopilot -n ProjectName
# 在每个窗口中启动 codex
```

4. 启动 watchdog:
```bash
bash scripts/watchdog.sh &
```

## Legacy

`lib/` 和 `tests/` 目录包含 Phase 1-3 的 Python 实现 (GUI 模式, 200 个测试)。
当前生产环境使用 `scripts/` 下的 bash 实现 (tmux + CLI 模式)。

## License

MIT
