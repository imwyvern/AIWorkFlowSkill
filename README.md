# 🚀 AI WorkFlow Skill

> 一套为 AI 创业团队设计的开发流程 Skill 体系，覆盖从需求到上线的完整周期。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)

---

## ✨ 特性

- 🔄 **完整工作流闭环**：需求 → 评审 → 开发 → 代码评审
- 🤖 **AI 原生**：每个 Skill 都有 AI 专项检查
- ⚡ **快速模式**：紧急情况下的精简评审流程
- 📋 **任务追踪**：内置任务拆分与进度汇报
- 🏃 **创业友好**：MoSCoW 优先级、技术债管理
- 📐 **SOLID 驱动**：严格遵循设计原则

---

## 🗺️ 工作流总览

```
┌─────────────────────────────────────────────────────────────────┐
│                    软件开发生命周期                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐      ┌─────────────┐                           │
│  │ doc-writing │─────▶│ doc-review  │                           │
│  │ 需求文档撰写  │      │ 需求文档评审  │                          │
│  │ + 任务清单   │      │             │                           │
│  └─────────────┘      └──────┬──────┘                           │
│                              │ 评审通过                          │
│                              ▼                                  │
│  ┌─────────────┐      ┌─────────────┐                           │
│  │ code-review │◀─────│ development │                           │
│  │   代码评审   │      │   开发实现   │                           │
│  │             │      │ + 进度追踪   │                           │
│  └──────┬──────┘      └─────────────┘                           │
│         │ 评审通过                                               │
│         ▼                                                       │
│    🚀 发布上线 ──────────▶ 下一个迭代                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 📦 Skill 清单

| Skill | 用途 | 触发语句 |
|-------|------|---------|
| **[doc-writing](./doc-writing/SKILL.md)** | 撰写 PRD、技术方案、API 设计、AI 功能设计 | "帮我写需求文档" |
| **[doc-review](./doc-review/SKILL.md)** | 评审需求文档，10 维度检查 | "评审这个 PRD" |
| **[development](./development/SKILL.md)** | 开发实现、SOLID 原则、进度追踪 | "帮我实现这个功能" |
| **[code-review](./code-review/SKILL.md)** | 代码评审，9 维度检查 | "review 这个代码" |

---

## 🛠️ 安装

### 方式 1：克隆到全局 skills 目录

```bash
# 克隆仓库
git clone https://github.com/imwyvern/AIWorkFlowSkill.git

# 复制到 Gemini/Antigravity 的 skills 目录
cp -r AIWorkFlowSkill/* ~/.gemini/skills/
```

### 方式 2：直接克隆到 skills 目录

```bash
git clone https://github.com/imwyvern/AIWorkFlowSkill.git ~/.gemini/skills/workflow
```

### 方式 3：项目级使用

```bash
# 在你的项目中
mkdir -p .agent/skills
cp -r AIWorkFlowSkill/* .agent/skills/
```

---

## 🚀 快速开始

### 完整流程

```
1. "帮我写一个 [功能] 的需求文档"
   → 输出 PRD + 任务清单

2. "评审一下这个需求文档"
   → 输出评审报告

3. "帮我实现第一个任务"
   → 开始开发

4. "更新一下任务进度"
   → 进度追踪

5. "review 一下这个代码"
   → 代码评审

6. 合并发布 🚀
```

### 快速模式

```
# 紧急情况下使用快速评审
"快速评审这个需求"    → 只检查 5 个核心维度
"快速 review 这个代码" → 只检查 5 个核心维度
```

---

## 📖 文档模板

### doc-writing 包含以下模板：

| 模板 | 说明 |
|------|------|
| PRD 模板 | 产品需求文档 |
| 技术方案模板 | 架构设计、技术选型 |
| API 设计模板 | RESTful API 规范 |
| 数据库设计模板 | 表结构、ER 图 |
| AI 功能设计模板 | Prompt 设计、模型选型、成本控制 |
| 竞品分析模板 | SWOT 分析、功能对比 |

---

## 🔍 评审维度

### 需求文档评审 (doc-review)

| 维度 | 核心检查 |
|------|---------|
| 完整性 ⚡ | 功能全？边界清？验收明？ |
| 一致性 ⚡ | 术语统一？前后不矛盾？ |
| 可行性 ⚡ | 能做？够时间？依赖稳？ |
| 安全性 ⚡ | 鉴权？越权？数据保护？ |
| AI 专项 ⚡ | 模型？Prompt？成本？降级？ |

### 代码评审 (code-review)

| 维度 | 核心检查 |
|------|---------|
| 功能正确 ⚡ | 需求符合？边界处理？ |
| 代码质量 ⚡ | SOLID？命名？嵌套深度？ |
| 安全性 ⚡ | SQL 注入？XSS？权限？ |
| 性能 ⚡ | N+1 查询？内存泄漏？ |
| AI 专项 ⚡ | Prompt 注入？Token 浪费？ |

> ⚡ 标记的为快速评审必查维度

---

## 🎯 设计理念

### 1. 创业友好
- **MoSCoW 优先级**：快速确定 MVP 范围
- **技术债管理**：允许合理的技术债，但必须记录
- **快速评审模式**：紧急情况下的精简流程

### 2. AI 原生
- **AI 专项检查**：每个 Skill 都有 AI 相关检查项
- **Prompt 管理**：版本控制、注入防护
- **成本控制**：Token 用量估算、用户配额

### 3. SOLID 驱动
- **S**ingle Responsibility：单一职责
- **O**pen/Closed：开闭原则
- **L**iskov Substitution：里氏替换
- **I**nterface Segregation：接口隔离
- **D**ependency Inversion：依赖倒置

---

## 📂 目录结构

```
AIWorkFlowSkill/
├── README.md              # 本文件
├── LICENSE                # MIT 许可证
├── CONTRIBUTING.md        # 贡献指南
├── doc-writing/
│   └── SKILL.md           # 需求技术文档撰写
├── doc-review/
│   └── SKILL.md           # 需求文档评审
├── development/
│   └── SKILL.md           # 开发实现
└── code-review/
    └── SKILL.md           # 代码评审
```

---

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

详见 [CONTRIBUTING.md](./CONTRIBUTING.md)

---

## 📄 许可证

[MIT License](./LICENSE)

---

## 🙏 致谢

感谢所有为这个项目做出贡献的人！

---

**Made with ❤️ for AI Startups**
