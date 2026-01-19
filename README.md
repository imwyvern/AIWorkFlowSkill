---
name: 通用 Skill 使用指南
description: 全局开发流程 Skill 体系总览和使用说明，支持会话持久化与恢复
version: 1.5.0
updated: 2026-01-19
---

# 通用 Skill 使用指南

> 这是一套为 AI 创业团队设计的开发流程 Skill 体系，覆盖从需求调研到上线的完整周期。

---

## 工作流总览

```
+------------------------------------------------------------------------+
|                        软件开发生命周期                                   |
+------------------------------------------------------------------------+
|                                                                        |
|  +---------------------+                                               |
|  |requirement-discovery|                                               |
|  |     需求调研/发现    |                                               |
|  +----------+----------+                                               |
|             | 产出: 调研报告、RICE评分、AI可行性评估                      |
|             v                                                          |
|  +-------------+      +-------------+                                  |
|  | doc-writing |-----→| doc-review  |                                  |
|  | 需求文档撰写  |      | 需求文档评审  |                                 |
|  | + 任务清单   |      |             |                                  |
|  +-------------+      +------+------+                                  |
|                              | 评审通过                                 |
|                              v                                         |
|                       +-------------+      +----------+                |
|                       | development |←----→| testing  |                |
|                       |   开发实现   |      | 测试设计  |                |
|                       | + Bug修复   | 协同  | + 用例   |                |
|                       +------+------+      +----------+                |
|                              |                                         |
|                              v                                         |
|                       +-------------+                                  |
|                       | code-review |                                  |
|                       |   代码评审   |                                  |
|                       +------+------+                                  |
|                              | 评审通过                                 |
|                              v                                         |
|                         >>> 发布上线 ---------------→ 下一个迭代         |
|                                                                        |
+------------------------------------------------------------------------+
```

---

## Skill 清单

| Skill | 用途 | 触发语句 | 工作流位置 |
|-------|------|---------|-----------|
| **requirement-discovery** | 需求调研、评估优先级、AI可行性 | "帮我调研这个需求" | 起点 |
| **doc-writing** | 撰写需求文档、技术方案、API设计 | "帮我写需求文档" | 第二步 |
| **doc-review** | 评审需求文档，发现问题 | "评审这个PRD" | 第三步 |
| **development** | 开发实现、Bug修复、进度追踪 | "帮我实现这个功能" | 第四步 |
| **testing** | 测试策略、用例设计、覆盖率分析 | "帮我设计测试用例" | 与 development 协同 |
| **code-review** | 代码评审，保证质量 | "review这个代码" | 第五步 |

---

## 快速使用

### 完整流程 (推荐)

```
0. "帮我调研一下这个需求"
   -> 输出 RICE 评分 + AI 可行性评估

1. "帮我写一个 [功能] 的需求文档"
   -> 输出 PRD + 任务清单

2. "评审一下这个需求文档"
   -> 输出评审报告

3. "帮我实现第一个任务"
   -> 开始开发

4. "更新一下任务进度" / "生成进度汇报"
   -> 进度追踪

5. "review 一下这个代码"
   -> 代码评审

6. 合并发布 >>>
```

### Bug修复流程

```
1. "看看这个bug" / "帮我修复这个bug"
   -> 进入Bug修复流程 (development skill 阶段十)

2. 自动执行:
   - 复现确认
   - 深层根因分析 (5 Whys)
   - 文档合规检查
   - 最小改动修复
   - 回归测试
   - 文档反馈更新
```

### 快速模式 (紧急情况)

```
1. "快速评审这个需求"
   -> 只检查 5 个核心维度

2. "快速 review 这个代码"
   -> 只检查 5 个核心维度
```

---

## 核心理念

### 1. 创业友好
- MoSCoW 优先级快速确定 MVP
- 允许合理的技术债 (但必须记录)
- 快速评审模式应对紧急情况
- RICE 评分量化需求优先级

### 2. AI 原生
- 每个 Skill 都有 AI 专项检查
- Prompt 设计和管理规范
- Token 成本控制
- AI 能力边界评估

### 3. 轻量高效
- 任务追踪融入开发流程
- 无需单独的项目管理工具
- 进度汇报一键生成
- 5分钟用户访谈法

### 4. SOLID 驱动
- 开发严格遵循 SOLID 原则
- 代码评审检查 SOLID 合规

### 5. 文档驱动
- Bug修复追溯相关文档
- 发现文档问题及时反馈
- 形成文档-代码闭环

---

## 集成工具

本 Skill 体系集成了来自 [guo-yu/skills](https://github.com/guo-yu/skills) 的实用工具:

| 工具 | 用途 | 使用方式 |
|------|------|---------|
| **port-allocator** | 多项目端口管理，避免冲突 | `/port-allocator` |
| **skill-i18n** | 文档多语言翻译 | `/skill-i18n` |
| **skill-permissions** | 一键授权常用命令 | `/skill-permissions allow development` |

### 安装集成工具

```bash
# 克隆 guo-yu/skills
git clone https://github.com/guo-yu/skills.git ~/Codes/skills

# 创建软链接
ln -sf ~/Codes/skills/skill-i18n ~/.gemini/skills/skill-i18n
ln -sf ~/Codes/skills/port-allocator ~/.gemini/skills/port-allocator
```

---

## Skill 文件位置

```
AIWorkFlowSkill/              <- 主仓库 (建议)
|-- README.md                 <- 本文件 (使用指南)
|-- requirement-discovery/
|   |-- SKILL.md              <- 需求调研与发现
|   |-- references/           <- 模板库
|-- doc-writing/
|   |-- SKILL.md              <- 需求文档撰写
|   |-- references/           <- Mermaid图表等参考
|-- doc-review/
|   |-- SKILL.md              <- 需求文档评审
|   |-- references/           <- 检查清单
|-- development/
|   |-- SKILL.md              <- 开发实现 + Bug修复
|   |-- references/
|   |   |-- session-management.md  <- 会话持久化规范
|   |-- scripts/
|       |-- init-session.sh   <- 初始化三文件
|       |-- check-complete.sh <- 检查完成度
|       |-- session-catchup.py <- 会话恢复
|-- testing/                  <- [NEW]
|   |-- SKILL.md              <- 测试策略与实践
|   |-- references/           <- 测试用例模板
|-- code-review/
    |-- SKILL.md              <- 代码评审
    |-- references/           <- 检查清单

~/.gemini/skills/             <- 软链接到 AIWorkFlowSkill/
```

---

## 版本历史

| 版本 | 日期 | 更新内容 |
|------|------|---------|
| 1.5.0 | 2026-01-19 | 集成 guo-yu/skills 工具(port-allocator, skill-i18n, skill-permissions); 新增危险命令阻止列表; 新增文档国际化支持 |
| 1.4.1 | 2026-01-18 | 新增 testing skill; 各skill添加references目录; 统一版本号 |
| 1.4.0 | 2026-01-18 | 新增会话持久化与恢复; 3-Strike Error Protocol; 5-Question Reboot Test; 自动化脚本 |
| 1.3.0 | 2026-01-17 | 新增文档管理规范; 渐进式讨论快速确认机制; code-review存档决策 |
| 1.2.0 | 2026-01-17 | development skill 新增 Bug修复章节; 移除emoji提升稳定性 |
| 1.1.0 | 2025-01-17 | 新增 requirement-discovery skill |
| 1.0.0 | 2025-01-17 | 初始版本: 4个核心Skill + 速查表 |

---

## 自定义

如需扩展或修改 Skill:

1. **添加项目特定规范**: 在项目的 `.agent/skills/` 中创建
2. **修改全局规范**: 编辑 `AIWorkFlowSkill/` 中的文件
3. **添加新 Skill**: 创建新目录和 SKILL.md 文件

### 版本同步

建议以 `AIWorkFlowSkill/` 为主仓库，`~/.gemini/skills/` 使用软链接：

```bash
# 备份原有 skills
mv ~/.gemini/skills ~/.gemini/skills.backup

# 创建软链接
ln -s /path/to/AIWorkFlowSkill ~/.gemini/skills

# 或者选择性链接核心5个skill
for skill in requirement-discovery doc-writing doc-review development code-review; do
  ln -sf /path/to/AIWorkFlowSkill/$skill ~/.gemini/skills/$skill
done
```

---

**开始使用**: 告诉我你想做什么，比如"帮我调研一下用户登录功能的需求"!
