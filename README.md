# AIWorkFlow — Full-Cycle AI Development Automation System

English · [中文](README_zh.md)

> A complete development toolchain for AI startup teams: **6 Development Workflow Skills** + **Codex Autopilot Multi-Project Automation Engine** + **OpenClaw Intelligent Orchestration Layer**

---

## 🏗 System Architecture

This project consists of three major modules:

### 1. Development Workflow Skill System (v1.5.0)

Covers the entire development lifecycle from requirement research to release, integrable with AI coding assistants like Gemini / Codex / Claude.

### 2. Codex Autopilot Engine

A multi-project parallel Codex CLI automation monitoring and task orchestration system, achieving 24/7 unattended development via tmux + launchd.

### 3. OpenClaw Intelligent Orchestration Layer

Provides higher-level intelligent orchestration capabilities through [OpenClaw](https://github.com/openclaw/openclaw), including cron scheduled tasks, Claude sub-agent code review, Telegram messaging channel, and cross-AI-engine collaborative orchestration.

---

## 📋 Development Workflow Skills

```
Requirement   → Doc        → Doc       → Development ←→ Test      → Code     → Release
Research        Writing      Review       + Bug Fix       Design     Review
   │              │            │            │               │          │
   ▼              ▼            ▼            ▼               ▼          ▼
requirement    doc-         doc-        development      testing    code-
-discovery     writing      review      + Bug Fix                   review
```

| Skill | Purpose | Trigger Example |
|-------|---------|-----------------|
| **requirement-discovery** | Requirement research, RICE scoring, AI feasibility assessment | "Research this requirement" |
| **doc-writing** | Write PRDs, technical specs, API designs, task checklists | "Write a requirements doc" |
| **doc-review** | Review requirement docs, identify gaps and risks | "Review this PRD" |
| **development** | Implementation, bug fixes (5 Whys root cause analysis), progress tracking | "Implement this feature" |
| **testing** | Test strategy, test case design, coverage analysis | "Design test cases for this" |
| **code-review** | Three-layer defense code review (automated checks → incremental review → full audit) | "Review this code" |

### Usage

Link skill directories to your AI assistant:

```bash
# Gemini
ln -sf /path/to/AIWorkFlowSkill/development ~/.gemini/skills/development

# Codex (reference in AGENTS.md)
# Claude (Skills directory)
```

### Core Principles

- **Startup-Friendly** — MoSCoW for rapid MVP prioritization; reasonable tech debt allowed (must be documented)
- **AI-Native** — Each skill includes AI-specific checks, prompt standards, and token cost controls
- **SOLID-Driven** — Development and review strictly follow SOLID principles
- **Doc-Closed-Loop** — Bug fixes trace back to docs; issues feed back promptly

---

## 🤖 Codex Autopilot Engine

### Architecture

```
                    ┌─────────────────────────────────────┐
                    │        Codex Autopilot Engine         │
                    └─────────────────────────────────────┘

  Trigger Layer       Detection Layer     Decision Layer      Execution Layer
┌──────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ launchd  │───→│codex-status  │───→│ watchdog.sh  │───→│ tmux-send.sh │
│  (10s)   │    │   .sh        │    │  (~1700 LOC) │    │ (3-layer send)│
└──────────┘    │ JSON status  │    │ State machine│    └──────────────┘
┌──────────┐    │working/idle/ │    │ Exp backoff/ │    ┌──────────────┐
│  cron    │───→│permission/   │    │ lock/compact │───→│ task-queue.sh│
│ (10min)  │    │shell/absent  │    │ recovery     │    │ (task queue)  │
└──────────┘    └──────────────┘    └──────────────┘    └──────────────┘
                                           │
                 Monitoring Layer          ▼             Review Layer
            ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
            │monitor-all.sh│    │  Telegram     │    │consume-review│
            │ + token stats │───→│  Alerts/      │    │-trigger.sh   │
            └──────────────┘    │  Reports      │    └──────────────┘
                                └──────────────┘
```

### OpenClaw Orchestration Layer

The Autopilot engine deeply integrates with [OpenClaw](https://github.com/openclaw/openclaw), forming a three-tier collaboration:

```
┌─────────────────────────────────────────────────────────┐
│                    OpenClaw Gateway                      │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌────────┐ │
│  │  Cron    │  │  Claude   │  │ Telegram  │  │ Task   │ │
│  │ Schedule │  │ Sub-agent │  │  Channel  │  │ Queue  │ │
│  └────┬─────┘  └────┬─────┘  └─────┬─────┘  └───┬────┘ │
└───────┼──────────────┼──────────────┼────────────┼──────┘
        │              │              │            │
        ▼              ▼              ▼            ▼
   monitor-all.sh  Code Review   Alerts/Reports  User-submitted tasks
   (10min reports) (dual-path)   (status push)   (dispatched when idle)
```

**Key Capabilities Provided by OpenClaw:**

| Capability | Description |
|------------|-------------|
| **Cron Scheduling** | 10-min monitoring reports, daily work summaries, automated PRD verification, competitor monitoring |
| **Claude Sub-agent** | Independent Claude instance for code review, forming **dual-path cross-review** with Codex |
| **Telegram Channel** | Real-time status push, alert notifications, task intake (user sends Telegram → Claude writes to queue → Codex executes) |
| **Cross-Engine Collaboration** | Claude (review/analysis) + Codex (coding/fixing), each with clear responsibilities, coordinated via trigger files |
| **Conversational Management** | Chat with Claude via Telegram to query project status, dispatch tasks, or trigger reviews on demand |

**Typical Collaboration Flow:**

```
User (Telegram) → "ReplyHer has a white-screen bug"
       ↓
Claude (OpenClaw) → writes to task-queue → waits for Codex idle
       ↓
Watchdog detects idle → dequeues task → tmux send-keys to Codex
       ↓
Codex fixes → commit → watchdog detects commit count threshold met
       ↓
Triggers Claude sub-agent code review → finds issues → dispatches back to Codex
       ↓
Review CLEAN → Telegram notifies user "✅ White-screen bug fixed"
```

### Core Scripts

| Script | LOC | Function |
|--------|-----|----------|
| `scripts/watchdog.sh` | ~1700 | Main daemon — status detection, smart nudge, permission handling, compact recovery, task queue scheduling, task tracking & notifications |
| `scripts/codex-status.sh` | ~200 | Codex TUI status detection (BFS process tree), outputs JSON (working/idle/permission/shell/absent) |
| `scripts/tmux-send.sh` | ~480 | Three-layer message sending + task tracking (`--track` auto-records task source, watchdog notifies on completion) |
| `scripts/monitor-all.sh` | ~450 | 10-min global monitoring + Telegram report (commits, context, lifecycle) |
| `scripts/task-queue.sh` | ~350 | Task queue CRUD — supports priority, concurrency locks, timeout recovery, source tracking |
| `scripts/consume-review-trigger.sh` | ~450 | Layer 2 code review consumer (trigger-file driven, output completeness checks) |
| `scripts/discord-notify.sh` | ~180 | Discord notifications — project-to-channel mapping (config.yaml driven) |
| `scripts/autopilot-lib.sh` | ~350 | Shared function library — project loading, Discord mapping, file utilities |
| `scripts/autopilot-constants.sh` | ~50 | Status constant definitions (version, status strings) |
| `scripts/prd_verify_engine.py` | ~500 | PRD verification engine — checker plugin system, "proof of done" |
| `scripts/codex-token-daily.py` | ~380 | Token usage statistics (extracted from Codex JSONL sessions) |

### Smart Nudge Decision Tree (v0.5.0)

```
Codex idle
│
├─ PRD complete + no pending issues?
│   ├─ Review has issues? → nudge #N/5 (5-attempt backoff cap, pause if no commits)
│   ├─ Queue has tasks? → bypass cooldown, consume queue
│   └─ Truly nothing to do → 🛑 stop nudging entirely (don't waste tokens)
│
├─ Priority 1: compact just finished? → resume nudge (with context snapshot)
├─ Priority 2: queue has tasks? → consume queue, send task to Codex
├─ Priority 3: autocheck/PRD has issues? → nudge to fix
├─ Fallback: nothing pending → 💤 skip (no more "find work" smart nudge)
└─ Dirty tree? → prompt to commit (overrides above nudge content)
```

**Core Principle: Nudge only when there's work; stay quiet when there isn't.**

### Task Tracking & Completion Notifications

Solves the problem of saying "I'll notify you when done" but never actually delivering:

```
User assigns task → tmux-send.sh (auto --track) → writes tracked-task.json
→ watchdog checks every 10s
→ new commit + Codex idle = ✅ Discord notification to source channel
→ 1 hour without progress = ⚠️ "task may be stuck" notification
```

- External calls to tmux-send.sh enable tracking by default
- Internal watchdog calls auto-disable tracking (`--no-track`)
- Task source (Discord channel) auto-mapped from config.yaml

### Discord ↔ Autopilot Routing

```yaml
# config.yaml
discord_channels:
  shike:
    channel_id: "1473294169203150941"
    tmux_window: "Shike"
    project_dir: "/Users/wes/Shike"
```

- Project commit → auto-push to corresponding Discord channel
- Manual task completion → notification sent back to source channel
- Supports `--by-window` reverse channel lookup

### Safety Mechanisms

| Mechanism | Description |
|-----------|-------------|
| **Smart Nudge** | No nudge without tasks; review issues capped at 5 attempts with backoff; prevents idle token waste |
| **Exponential Backoff** | Nudge intervals: 300→600→1200→2400→4800→9600s; stops after 6 attempts + alert |
| **3× Idle Confirmation** | Prevents false positives from API latency |
| **90s Work Inertia** | No nudge within 90s of detecting "working" state |
| **Manual Task Protection** | Human-sent tasks protected from watchdog override for 300s |
| **Task Tracking** | Manual tasks auto-tracked; user notified on completion or timeout |
| **Queue Concurrency Lock** | Atomic mkdir lock to prevent concurrent read/write corruption |
| **Queue Timeout Recovery** | In-progress tasks >3600s auto-fail and re-queue |
| **Compact Context Snapshot** | Saves task state before compact, enables precise recovery after |
| **Atomic Lock (mkdir)** | macOS lacks flock; uses mkdir with expiry-based recovery |
| **Runtime File Isolation** | status.json and runtime files gitignored to prevent dirty repo blocking Codex |

### Quick Start

```bash
# 1. Configure projects
cat > watchdog-projects.conf << EOF
ProjectA:/path/to/project-a:Default nudge message
ProjectB:/path/to/project-b:Default nudge message
EOF

# 2. Configure Telegram (config.yaml)
telegram:
  bot_token: "your-bot-token"
  chat_id: "your-chat-id"

# 3. Create tmux session
tmux new-session -s autopilot -n ProjectA
# Start in the window: codex --full-auto

# 4. Start watchdog
nohup bash scripts/watchdog.sh &

# 5. (Optional) Set up cron monitoring
# Run monitor-all.sh every 10 minutes
*/10 * * * * bash ~/.autopilot/scripts/monitor-all.sh
```

### Task Queue

Submit tasks while Codex is busy; they are automatically dispatched when idle:

```bash
# Add a task
bash scripts/task-queue.sh add myproject "Fix login page white-screen bug" high

# View queue
bash scripts/task-queue.sh list myproject

# Global overview
bash scripts/task-queue.sh summary
```

Watchdog automatically dequeues and dispatches tasks when Codex becomes idle.

---

## 📁 Project Structure

```
AIWorkFlowSkill/
├── README.md                    # This file
├── CONVENTIONS.md               # Project conventions (required reading for Codex)
├── CONTRIBUTING.md              # Contribution guide
├── LICENSE                      # MIT
│
├── requirement-discovery/       # Skill: Requirement Research
│   ├── SKILL.md
│   └── references/
├── doc-writing/                 # Skill: Doc Writing
│   ├── SKILL.md
│   └── references/
├── doc-review/                  # Skill: Doc Review
│   ├── SKILL.md
│   └── references/
├── development/                 # Skill: Development
│   ├── SKILL.md
│   ├── references/
│   └── scripts/                 # Session management scripts
├── testing/                     # Skill: Test Design
│   ├── SKILL.md
│   └── references/
├── code-review/                 # Skill: Code Review
│   ├── SKILL.md
│   └── references/
│
├── scripts/                     # Autopilot Engine
│   ├── watchdog.sh              # Main daemon
│   ├── codex-status.sh          # Status detection
│   ├── tmux-send.sh             # Message sending
│   ├── monitor-all.sh           # Monitoring reports
│   ├── task-queue.sh            # Task queue
│   ├── consume-review-trigger.sh
│   ├── prd_verify_engine.py     # PRD verification
│   └── ...
│
├── watchdog-projects.conf       # Project configuration
├── config.yaml                  # Telegram & other config
├── prd-items.yaml               # PRD verification definitions
│
├── lib/                         # Phase 1-3 Python (legacy)
└── tests/                       # Phase 1-3 tests (200 tests)
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| **0.5.0** | 2026-03-03 | Smart nudge (no nudge without tasks), task tracking notifications, Discord routing, queue concurrency lock/timeout recovery, review backoff, BFS process tree detection |
| **0.4.0** | 2026-03-01 | ClawHub release, Discord→Autopilot routing, security fixes |
| **2.0.0** | 2026-02-12 | Autopilot engine: watchdog v6, three-layer tmux sending, task queue, compact context snapshot, PRD verification engine |
| 1.5.0 | 2026-01-19 | Integrated guo-yu/skills tools; added dangerous command blocklist |
| 1.4.1 | 2026-01-18 | Added testing skill; session persistence & recovery |
| 1.3.0 | 2026-01-17 | Doc management standards; progressive discussion quick confirmation |
| 1.2.0 | 2026-01-17 | Development skill bug fix chapter |
| 1.1.0 | 2025-01-17 | Added requirement-discovery skill |
| 1.0.0 | 2025-01-17 | Initial release: 4 core skills |

---

## License

MIT