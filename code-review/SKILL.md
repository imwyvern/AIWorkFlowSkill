---
name: 代码评审
description: 系统性地进行代码评审，检查代码质量、安全性、性能和可维护性
version: 1.0.0
updated: 2025-01-17
---

# 代码评审 Skill

> 代码评审不是找茬，是知识共享和质量保障。

## ⚡ 速查表

| 评审维度 | 核心检查 |
|---------|---------|
| 功能正确⚡ | 需求符合？边界处理？错误处理？ |
| 代码质量⚡ | SOLID？命名？嵌套深度？ |
| 安全性⚡ | SQL注入？XSS？权限？敏感信息？ |
| 性能⚡ | N+1查询？内存泄漏？分页？ |
| AI专项⚡ | Prompt注入？Token浪费？降级？ |

**快速评审**：只查 ⚡ 标记的 5 个核心维度
**评审结论**：🟢Approve / 🟡Changes / 🔴Block

---

## 🔗 关联 Skill

| Skill | 关系 | 说明 |
|-------|------|------|
| **doc-writing** | 前置 | 评审时对照需求文档 |
| **doc-review** | 前置 | 确保需求已评审通过 |
| **development** | 上一步 | 评审开发完成的代码 |

**工作流**：`doc-writing` → `doc-review` → `development` → `code-review`

---

## 🎯 使用场景

- "帮我 review 这个代码"
- "检查这个 PR"
- "看看这个实现有没有问题"

---

## 📋 评审模式

| 模式 | 场景 | 维度 | 时间 |
|------|------|------|------|
| **完整评审** | 核心功能 | 全部 9 个 | 30-60分钟 |
| **快速评审** ⚡ | 紧急修复 | 5 个核心 | 10-15分钟 |

---

## 📊 评审维度

### 核心维度（快速评审必查）⚡

#### 1️⃣ 功能正确性 ⚡

| 检查点 | 常见问题 |
|--------|---------|
| 需求符合？ | 遗漏功能 |
| 逻辑正确？ | 逻辑漏洞 |
| 边界处理？ | 空值、极值未处理 |
| 错误处理？ | 异常被忽略 |

```javascript
// ❌ 没有处理空值
function getName(user) {
  return user.name.toUpperCase();
}

// ✅ 正确处理
function getName(user) {
  if (!user?.name) return '';
  return user.name.toUpperCase();
}
```

#### 2️⃣ 代码质量 ⚡

| 检查点 | 常见问题 |
|--------|---------|
| SOLID？ | 职责不单一 |
| 命名？ | 命名不清晰 |
| 重复？ | 代码冗余 |
| 复杂度？ | 嵌套太深 |

```javascript
// ❌ 嵌套太深
if (user) {
  if (user.isActive) {
    if (user.hasPermission) {
      // do something
    }
  }
}

// ✅ 早返回
if (!user) return;
if (!user.isActive) return;
if (!user.hasPermission) return;
// do something
```

#### 3️⃣ 安全性 ⚡

| 检查点 | 常见问题 |
|--------|---------|
| SQL 注入？ | 拼接 SQL |
| XSS？ | 未转义输入 |
| 敏感信息？ | 日志泄露密码 |
| 权限？ | 越权访问 |

```javascript
// ❌ SQL 注入
const query = `SELECT * FROM users WHERE id = ${userId}`;

// ✅ 参数化
const query = 'SELECT * FROM users WHERE id = ?';
db.query(query, [userId]);
```

#### 4️⃣ 性能 ⚡

| 检查点 | 常见问题 |
|--------|---------|
| N+1 查询？ | 循环中查数据库 |
| 内存泄漏？ | 未释放资源 |
| 重复计算？ | 可缓存的计算 |
| 分页？ | 大数据量无分页 |

```javascript
// ❌ N+1 查询
for (const user of users) {
  const orders = await Order.findByUserId(user.id);
}

// ✅ 批量查询
const users = await User.findAll({
  include: [{ model: Order }]
});
```

#### 5️⃣ AI 代码专项 ⚡🤖（AI功能必查）

| 检查点 | 常见问题 |
|--------|---------|
| Prompt 注入？ | 用户输入未过滤 |
| Token 浪费？ | 无缓存、无限制 |
| 超时处理？ | AI 卡死无降级 |
| 成本控制？ | 无用户配额 |
| 内容安全？ | 无内容审核 |

```javascript
// ❌ Prompt 注入风险
const prompt = `分析: ${userInput}`;  // userInput 可能包含恶意指令

// ✅ 输入清理
const sanitizedInput = sanitize(userInput);
const prompt = `分析以下用户提供的文本:\n"""${sanitizedInput}"""`;

// ❌ 无降级
const result = await ai.chat(input);

// ✅ 有降级
try {
  const result = await ai.chat(input, { timeout: 30000 });
  return result;
} catch (error) {
  if (error.code === 'TIMEOUT') {
    return fallbackResponse();
  }
  throw error;
}
```

### 扩展维度（完整评审）

#### 6️⃣ 可维护性

| 检查点 | 常见问题 |
|--------|---------|
| 魔法数字？ | 硬编码数值 |
| 注释？ | 复杂逻辑无说明 |
| 配置分离？ | 配置硬编码 |

```javascript
// ❌ 魔法数字
if (user.type === 1) {
  discount = 0.2;
}

// ✅ 使用常量
const USER_TYPE = { VIP: 1 };
const VIP_DISCOUNT = 0.2;
if (user.type === USER_TYPE.VIP) {
  discount = VIP_DISCOUNT;
}
```

#### 7️⃣ 测试覆盖

| 检查点 | 常见问题 |
|--------|---------|
| 测试存在？ | 新代码无测试 |
| 覆盖充分？ | 只测正常路径 |
| 测试质量？ | 只检查 truthy |

```javascript
// ❌ 无效测试
expect(result).toBeTruthy();

// ✅ 有效测试
expect(calculate(1, 2)).toBe(3);
expect(calculate(-1, 1)).toBe(0);
```

#### 8️⃣ 兼容性

| 检查点 | 常见问题 |
|--------|---------|
| 向后兼容？ | API 破坏性变更 |
| 数据迁移？ | 无迁移脚本 |
| 现有功能？ | 影响其他模块 |

#### 9️⃣ 文档规范

| 检查点 | 常见问题 |
|--------|---------|
| 代码规范？ | 风格不一致 |
| 提交规范？ | commit 不规范 |
| API 文档？ | 新接口未文档化 |

---

## 📝 评审输出格式

```markdown
# 代码评审报告

## 📄 评审信息
| 项目 | 内容 |
|------|------|
| PR/代码 | [标题] |
| 模式 | 完整/快速 |
| 结论 | 🟢Approve / 🟡Changes / 🔴Block |

## 📊 维度汇总
| 维度 | 状态 | 问题 |
|------|------|------|
| 功能正确⚡ | ✅/⚠️/❌ | N |
| 代码质量⚡ | ✅/⚠️/❌ | N |
| 安全性⚡ | ✅/⚠️/❌ | N |
| 性能⚡ | ✅/⚠️/❌ | N |
| AI专项⚡ | ✅/⚠️/❌/N/A | N |

## 🔴 必须修改
1. **[问题]**
   - 📍 `file.js:L10`
   - ❌ [问题]
   - ✅ [建议]
   ```javascript
   // 示例代码
   ```

## 🟡 建议优化
1. **[问题]** - 💡 [建议]

## 🟢 亮点
- ✨ [亮点]

## ❓ 疑问
- ❓ [需作者解释]
```

---

## 🏷️ 评审结论

| 结论 | 条件 | 行动 |
|------|------|------|
| 🟢 Approve | 无阻塞问题 | 直接合并 |
| 🟡 Request Changes | 有问题但不严重 | 修改后合并 |
| 🔴 Block | 严重问题/安全漏洞 | 修改后重新评审 |

---

## ✅ 评审原则

### 1. 尊重
- 对事不对人
- 建设性语言
- 假设作者善意

### 2. 具体
- 指出具体位置
- 提供改进建议
- 用代码示例

### 3. 及时
- 及时响应
- 小 PR 优先
- 不拖延

### 4. 学习
- 双向学习
- 表扬亮点
- 虚心请教

---

## 💬 评审语言

```
❌ 把这个改成 xxx
✅ 考虑是否可以用 xxx？这样可以...

❌ 这里应该用常量
✅ 建议提取为常量 `VIP_DISCOUNT`，便于复用和维护

❌ 这个写法有问题
✅ 这里可能有 null 风险，建议用 `user?.name`
```

---

## ⚡ 快速评审

时间紧迫时只查 5 个核心维度：功能正确、代码质量、安全性、性能、AI专项

```markdown
# 快速评审结果
🟢/🟡/🔴 [结论]

## 关键问题
1. [问题]

## 下一步
- [行动]
```

---

## 📌 完成后

代码评审通过、合并后，一个完整的开发周期结束。

如需开始下一个功能，回到 **doc-writing** skill：
> "帮我写一个需求文档"
