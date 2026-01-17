---
name: 开发实现
description: 指导高质量的代码开发，遵循 SOLID 原则，规范的分支管理和提交流程
version: 1.1.0
updated: 2025-01-17
---

# 开发实现 Skill

> 写出可维护、可扩展、可测试的代码。

## ⚡ 速查表

| 我想... | 跳转到 |
|---------|--------|
| **理解项目结构** | [项目理解](#阶段零项目理解-) |
| 组件拆分原则 | [组件拆分](#03-组件拆分原则) |
| 复习 SOLID | [SOLID 原则](#21-solid-原则-) |
| 查命名规范 | [命名规范](#22-命名规范) |
| AI 开发规范 | [AI 开发规范](#阶段三ai-开发规范-) |
| 分支命名 | [分支管理](#阶段四分支管理) |
| 提交规范 | [Conventional Commits](#阶段五提交规范) |
| 密钥管理 | [密钥管理](#阶段六密钥管理-) |
| 更新进度 | [进度追踪](#-进度追踪) |
| 生成汇报 | [进度汇报模板](#进度汇报模板) |

**开发流程**：项目理解 → 开发前准备 → 代码编写 → 提交 → 评审

---

## 🔗 关联 Skill

| Skill | 关系 | 说明 |
|-------|------|------|
| **doc-writing** | 前置 | 需求文档是开发的输入 |
| **doc-review** | 前置 | 文档评审通过后才开始开发 |
| **code-review** | 下一步 | 开发完成后进行代码评审 |

**工作流**：`doc-writing` → `doc-review` → `development` → `code-review`

---

## 🎯 使用场景

- "帮我实现这个功能"
- "写一个 XXX 的代码"
- "开发 XXX 模块"
- "帮我理解这个项目结构"

---

## 📋 开发流程

### 阶段零：项目理解 🔍

> **开发前必做**：先理解项目结构，再动手写代码

#### 0.1 项目结构扫描

在动手写代码前，必须先理解项目：

**检查清单**：
- [ ] 阅读项目 README
- [ ] 了解目录结构约定
- [ ] 查看现有组件/模块
- [ ] 理解命名规范
- [ ] 找到类似功能的参考代码

**触发方式**：
```
"帮我理解这个项目结构"
"扫描一下项目目录"
"这个项目的组件是怎么组织的"
```

#### 0.2 项目结构说明书模板

当用户说"帮我理解项目结构"时，输出以下格式：

```markdown
# 项目结构说明书

## 📁 目录结构
[扫描并列出关键目录]

## 🧩 现有组件/模块
| 组件 | 位置 | 职责 |
|------|------|------|
| ... | ... | ... |

## 📏 命名规范
- 文件命名：[如 PascalCase / kebab-case]
- 组件命名：[规范]
- 变量命名：[规范]

## 🔧 技术栈
- 框架：[如 React / Vue / Next.js]
- 状态管理：[如 Redux / Zustand]
- 样式方案：[如 CSS Modules / Tailwind]

## 📍 新文件放置建议
- 页面组件放：[路径]
- 通用组件放：[路径]
- 工具函数放：[路径]
- API 调用放：[路径]
```

#### 0.3 组件拆分原则

| 原则 | 说明 | 示例 |
|------|------|------|
| **单一职责** | 一个组件只做一件事 | Button 只负责按钮样式和点击 |
| **合理粒度** | 不要太大也不要太碎 | 50-200 行为宜 |
| **可复用性** | 通用的提取为公共组件 | 放到 components/common |
| **内聚性** | 相关的放在一起 | 组件和它的样式、类型放一起 |
| **遵循约定** | 遵循项目现有结构 | 不要自创新目录 |

**组件拆分决策树**：
```
这段代码应该独立成组件吗？
├── 会被多处使用？ → ✅ 提取为公共组件
├── 超过 200 行？ → ✅ 考虑拆分
├── 有独立的职责？ → ✅ 提取
├── 只用一次且简单？ → ❌ 暂不提取
└── 拆分后更难理解？ → ❌ 保持原状
```

#### 0.4 常见目录结构约定

**前端项目（React/Vue/Next.js）**：
```
src/
├── components/          # 通用组件
│   ├── common/          # 基础组件（Button, Input, Modal）
│   ├── layout/          # 布局组件（Header, Footer, Sidebar）
│   └── business/        # 业务组件（UserCard, OrderList）
├── pages/               # 页面（Next.js）或 views/
├── hooks/               # 自定义 hooks
├── utils/               # 工具函数
├── services/            # API 调用
│   └── api/
├── stores/              # 状态管理
├── types/               # TypeScript 类型
└── styles/              # 全局样式
```

**后端项目（Node.js/Express）**：
```
src/
├── controllers/         # 控制器（处理请求）
├── services/            # 业务逻辑
├── models/              # 数据模型
├── routes/              # 路由定义
├── middlewares/         # 中间件
├── utils/               # 工具函数
├── config/              # 配置文件
└── types/               # TypeScript 类型
```

**后端项目（Python/FastAPI）**：
```
app/
├── api/                 # API 路由
│   └── v1/
├── core/                # 核心配置
├── models/              # 数据模型
├── schemas/             # Pydantic schemas
├── services/            # 业务逻辑
├── utils/               # 工具函数
└── main.py
```

#### 0.5 新文件位置决策

创建新文件前，问自己：

| 问题 | 决策 |
|------|------|
| 这是通用的还是特定业务的？ | 通用 → common/，业务 → business/ |
| 只有当前页面用还是多处用？ | 只当前用 → 页面目录，多处用 → components/ |
| 现有项目类似文件放在哪？ | **遵循现有约定** |
| 是否需要新目录？ | 谨慎创建，优先用现有目录 |

---

### 阶段一：开发前准备

#### 1.1 确认清单
- [ ] 需求文档已评审通过？
- [ ] 技术方案已确认？
- [ ] 接口设计已明确？
- [ ] 验收标准清晰？
- [ ] **项目结构已理解？** ← 新增

#### 1.2 环境准备
- [ ] 开发环境就绪？
- [ ] 依赖安装完成？
- [ ] 数据库/服务可访问？

#### 1.3 任务拆分
- 每任务 1-4 小时
- 可独立测试
- 依赖关系明确

---

### 阶段二：代码编写

#### 2.1 SOLID 原则 ⭐

| 原则 | 说明 | 实践 |
|------|------|------|
| **S** 单一职责 | 一个类/函数只做一件事 | 函数 < 50 行考虑拆分 |
| **O** 开闭原则 | 对扩展开放，对修改关闭 | 使用接口和抽象 |
| **L** 里氏替换 | 子类可替换父类 | 继承不改变父类行为 |
| **I** 接口隔离 | 接口小而专 | 避免臃肿接口 |
| **D** 依赖倒置 | 依赖抽象非具体 | 使用依赖注入 |

#### 2.2 命名规范

| 类型 | 风格 | 示例 |
|------|------|------|
| 类/类型 | PascalCase | `UserService` |
| 函数/变量 | camelCase | `getUserById` |
| 常量 | UPPER_SNAKE | `MAX_RETRY` |
| 数据库表 | snake_case | `user_orders` |
| API 路径 | kebab-case | `/api/user-orders` |

#### 2.3 代码结构

```
函数设计：
- 短小（< 30 行）
- 只做一件事
- 参数 ≤ 4 个
- 避免副作用
```

#### 2.4 注释规范

**需要注释**：
- ✅ 复杂业务逻辑
- ✅ 非显而易见的算法
- ✅ TODO / FIXME
- ✅ 公共 API 文档

**不需要**：
- ❌ 显而易见的代码
- ❌ 用注释解释糟糕命名

#### 2.5 错误处理

```javascript
// ✅ 好的错误处理
try {
  const user = await userService.getById(id);
  if (!user) throw new NotFoundError(`User: ${id}`);
  return user;
} catch (error) {
  logger.error('Failed to get user', { id, error });
  throw error;
}

// ❌ 差的错误处理
try {
  return await userService.getById(id);
} catch (e) {
  console.log(e);  // 仅打印不处理
}
```

---

### 阶段三：AI 开发规范 🤖

#### 3.1 Prompt 管理

```javascript
// ✅ Prompt 版本管理
const PROMPTS = {
  CHAT_V1: `你是一个助手...`,
  CHAT_V2: `你是一个专业助手...`,  // 优化版
};

// 使用配置控制版本
const prompt = PROMPTS[config.chatPromptVersion];
```

#### 3.2 AI 调用最佳实践

```javascript
async function callAI(input) {
  // 1. 输入校验
  if (!input || input.length > MAX_INPUT_LENGTH) {
    throw new ValidationError('Invalid input');
  }
  
  // 2. 限流检查
  await rateLimiter.check(userId);
  
  // 3. 调用 AI
  try {
    const result = await aiService.chat({
      prompt: SYSTEM_PROMPT,
      message: sanitize(input),  // 防 Prompt 注入
      maxTokens: 1000,
      timeout: 30000,
    });
    
    // 4. 内容安全检查
    if (await contentFilter.isUnsafe(result)) {
      return { error: 'Content blocked' };
    }
    
    // 5. 记录用量
    await tokenUsage.record(userId, result.tokensUsed);
    
    return result;
  } catch (error) {
    // 6. 降级处理
    if (error.code === 'TIMEOUT' || error.code === 'SERVICE_UNAVAILABLE') {
      return fallbackResponse();
    }
    throw error;
  }
}
```

#### 3.3 Token 成本控制

```javascript
// 缓存相似请求
const cacheKey = hashInput(input);
const cached = await cache.get(cacheKey);
if (cached) return cached;

// 限制输出长度
const result = await ai.chat({ maxTokens: 500 });

// 用户配额
const usage = await getMonthlyUsage(userId);
if (usage > USER_MONTHLY_LIMIT) {
  throw new QuotaExceededError();
}
```

---

### 阶段四：分支管理

#### 4.1 分支命名

| 类型 | 格式 | 示例 |
|------|------|------|
| 主分支 | `main` | `main` |
| 功能 | `feature/xxx` | `feature/user-login` |
| 修复 | `fix/xxx` | `fix/login-error` |
| 热修复 | `hotfix/xxx` | `hotfix/security` |

#### 4.2 工作流（小团队）

```
main ──────●────────────●──────
            \          /
develop ─────●────●───●───●────
              \   |       
feature ───────●──┘       
```

1. 从 develop 创建功能分支
2. 开发完成提 PR
3. 合并回 develop
4. 定期发布到 main

---

### 阶段五：提交规范

#### 5.1 Conventional Commits

```
<type>(<scope>): <subject>

<body>

<footer>
```

#### 5.2 Type 类型

| Type | 说明 |
|------|------|
| `feat` | 新功能 |
| `fix` | 修复 |
| `docs` | 文档 |
| `style` | 格式 |
| `refactor` | 重构 |
| `perf` | 性能 |
| `test` | 测试 |
| `chore` | 构建/工具 |

#### 5.3 示例

```bash
# ✅ 好的提交
feat(user): add registration API

- Add POST /api/users
- Add email validation

Closes #123

# ❌ 差的提交
fix bug
update
```

---

### 阶段六：密钥管理 🔐

#### 6.1 规范

```bash
# ❌ 永远不要
API_KEY="sk-xxx..."  # 硬编码在代码里
git add .env         # 提交密钥文件

# ✅ 正确做法
# 1. 使用环境变量
const apiKey = process.env.API_KEY;

# 2. .gitignore 添加
.env
.env.local
*.key

# 3. 使用密钥管理服务
# - AWS Secrets Manager
# - Vault
# - 1Password CLI
```

#### 6.2 .env 示例

```bash
# .env.example (提交这个)
API_KEY=your_api_key_here
DATABASE_URL=your_database_url

# .env (不提交)
API_KEY=sk-real-key-xxx
DATABASE_URL=postgres://...
```

---

### 阶段七：调试技巧 🔧

#### 7.1 日志分级

```javascript
// 按重要性使用不同级别
logger.debug('详细调试信息');      // 开发环境
logger.info('重要业务信息');       // 正常流程
logger.warn('警告但不影响运行');   // 需关注
logger.error('错误需要处理', err); // 必须处理
```

#### 7.2 高效定位问题

```javascript
// 1. 添加请求 ID 追踪
const requestId = uuid();
logger.info('Request start', { requestId, path, params });

// 2. 关键步骤打点
logger.info('Step 1 complete', { requestId, duration: t1 });
logger.info('Step 2 complete', { requestId, duration: t2 });

// 3. 错误包含上下文
try {
  await process(data);
} catch (error) {
  logger.error('Process failed', { 
    requestId, 
    data, 
    error: error.message,
    stack: error.stack 
  });
}
```

---

### 阶段八：测试要求

#### 8.1 测试金字塔

```
    /\     E2E (少)
   /  \    集成 (适量)
  /    \   单元 (大量)
 /______\
```

#### 8.2 覆盖率要求

| 类型 | 覆盖率 |
|------|--------|
| 核心逻辑 | > 80% |
| 工具函数 | > 90% |
| API | 关键路径 100% |

---

### 阶段九：提交前自检

#### 代码检查
- [ ] 编译/运行正常
- [ ] 无 lint 错误
- [ ] 无调试代码（console.log）
- [ ] 无硬编码密钥

#### 功能检查
- [ ] 功能正常工作
- [ ] 边界情况处理
- [ ] 错误情况处理

#### 测试检查
- [ ] 测试通过
- [ ] 新代码有测试
- [ ] 未破坏现有测试

#### 文档检查
- [ ] 必要注释已添加
- [ ] API 文档已更新

---

## 🔧 最佳实践

### 渐进式开发
1. Make it work（先跑起来）
2. Make it right（再写对）
3. Make it fast（最后优化）

### 代码审查友好
- 变更集中，不混杂
- PR 描述清晰
- 及时响应评审

---

## � 进度追踪

开发过程中，需要持续更新任务进度。

### 使用场景

- "更新一下任务进度"
- "这个任务完成了"
- "生成进度汇报"
- "看看当前进度"

### 进度更新操作

当用户说"更新进度"时，执行以下步骤：

1. **确认任务清单位置**（通常在项目的 docs/ 或根目录）
2. **更新任务状态**
3. **更新进度统计**
4. **记录阻塞问题**（如有）

### 任务状态标记

| 状态 | 标记 | 说明 |
|------|------|------|
| 待开始 | ⬜ | 还没开始 |
| 进行中 | 🔄 | 正在做 |
| 已完成 | ✅ | 做完了 |
| 暂停 | ⏸️ | 有阻塞，暂时停止 |
| 取消 | ❌ | 不做了 |

### 进度汇报模板

当用户说"生成进度汇报"时，输出以下格式：

```markdown
# 进度汇报

## 📅 汇报信息
| 项目 | 内容 |
|------|------|
| 汇报日期 | YYYY-MM-DD |
| 汇报周期 | 本周 / 本日 |
| 汇报人 | - |

## 📊 整体进度
| 指标 | 数值 |
|------|------|
| 总任务 | N |
| 已完成 | X (X%) |
| 进行中 | Y |
| 待开始 | Z |

## ✅ 本期完成
1. [任务1] - [简要说明]
2. [任务2] - [简要说明]

## 🔄 进行中
1. [任务3] - 预计完成时间：[日期]
2. [任务4] - 预计完成时间：[日期]

## ⚠️ 阻塞 & 风险
| 问题 | 影响 | 需要的支持 |
|------|------|-----------|
| [问题描述] | [影响范围] | [需要谁做什么] |

## 📅 下周计划
1. [计划任务1]
2. [计划任务2]

## 💡 备注
- [其他需要同步的信息]
```

### 快速进度更新

对于日常快速更新，可以使用简化格式：

```markdown
## 进度快报 YYYY-MM-DD

✅ 完成：
- [任务]

🔄 进行中：
- [任务] - 进度 X%

⚠️ 阻塞：
- [问题] - 需要 [支持]
```

---

## �📌 下一步

开发完成后使用 **code-review** skill：
> "帮我 review 这个代码"
