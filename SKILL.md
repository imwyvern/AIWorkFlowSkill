# codex-autopilot

tmux + launchd 多项目 Codex CLI 自动化系统。通过 watchdog 循环驱动，支持权限处理、自动 nudge、状态追踪。

## 安装

```bash
git clone https://github.com/imwyvern/AIWorkFlowSkill.git ~/.autopilot
cd ~/.autopilot && cp config.yaml.example config.yaml
# 编辑 config.yaml 配置项目和通知
```

## 核心组件

- **watchdog.sh** — 主循环引擎，轮询各项目 tmux 窗口
- **tmux-send.sh** — 向 Codex tmux 窗口发送指令
- **autopilot-lib.sh** — 共享函数库（Telegram 通知、锁、超时）
- **autopilot-constants.sh** — 状态常量定义
- **scripts/cleanup-state.py** — state.json 僵尸数据清理

## 依赖

- macOS (launchd)
- tmux, codex CLI, python3, yq
