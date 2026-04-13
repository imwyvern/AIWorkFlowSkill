# HEARTBEAT.md

## 🔄 OpenClaw PR 自动跟进（每次 heartbeat 必做）
每次 heartbeat 都检查所有 open PR 的新 review 反馈，有反馈立即处理并推送修复。

```bash
# 检查 review 反馈（用 reviews endpoint，不是 comments）
for pr in 52747 52365 52209 48144 48097 48095 42669 42637 40574 38812; do
  echo -n "PR #$pr: "
  gh api "repos/openclaw/openclaw/pulls/$pr/reviews" --jq '[.[] | select(.user.login != "imwyvern" and .user.login != "greptile-apps[bot]" and .user.login != "chatgpt-codex-connector[bot]")] | sort_by(.submitted_at) | last | "\(.submitted_at) \(.user.login): \(.state)"' 2>/dev/null
  echo ""
done
```

### 流程
1. heartbeat → 查所有 open PR 是否有新 review comment
2. 有新反馈 → 立即 checkout 分支 → 修改 → 测试 → push → 留评论
3. 处理完 → 在 Discord #autopilot 报告进展（不等 Wesley 问）
4. PR 被 merge/close → 从列表移除

### 当前 Open PR（10 个）
- #62030 - filter commentary-phase assistant text from delivery ✅ 新
- #52747 - session lane task timeout fix (Mar 23) ✅ CI 全绿
- #52365 - cron fallback timeout fix (Mar 22) ✅ CI 全绿
- #48144 - Control UI token display fix ✅ CI 全绿
- #48097 - ACP yield error resume ✅ CI 全绿
- #48095 - handshake timeout configurable ✅ CI 全绿
- #42669 - skills.priority config for prompt ordering ⚠️ 有冲突需 rebase
- #42637 - skills truncation visibility ✅ CI 全绿
- #40574 - write append mode (⚠️ 不要 @ 维护者) ✅ CI 全绿
- ClawHub #1183 - fix convex pagination (publish bug #52873)

### 已关闭/合并
- #52209 - ACP gemini session load fix — ✅ MERGED (confirmed Apr 5)
- #38812 - tool-only turn safety — bot 关闭（Apr 1，>10 PR 限制），代码保留可重开
- #56857 - edit fuzzy match hint — bot 关闭（Mar 29，>10 PR 限制），代码保留可重开
- #40700 - subagent timeout partial progress — ✅ MERGED (Mar 20, obviyus review → 修 NO_REPLY 语义 → merge)
- #41939 - Telegram DM isolation — obviyus 关闭：认为是产品策略变更而非 bug fix（Mar 18）
- #42265 - edit fuzzy match (主动关闭腾位置，代码保留，可重开)
- #48098 - 被 bot 关闭（>10 PR），已用 #48144 替代
- #40573 - superseded by #42173 (merged, co-author credit ✅)
- #33884 - completion notify — 主动关闭腾位置（Mar 23），代码保留可重开

## 🔍 OpenClaw 自我改进（全局终身任务）
**核心：使用 OpenClaw 的过程就是改进 OpenClaw 的过程。**

### 持续发现
- 每次使用工具/功能时，留意 bug、friction、缺失功能
- 发现问题 → 立即记到 `memory/openclaw-issues.md`
- 不需要等 Wesley 指示，主动发现主动记录

### 定期转化（heartbeat 检查）
1. 检查 `memory/openclaw-issues.md` 待研究/待调查列表
2. 有可行的改进 → 研究 upstream 代码 → 写修复 → 提 PR
3. 提 PR 用 Codex（tmux 或 ACP），自己 review 到没问题再提交
4. 提交后加入 HEARTBEAT PR 跟进列表

### 规则
- 每个 PR 目标：maintainer 直接点 merge 的质量
- 不 tag maintainer、不刷评论
- 有 review 反馈 → 立即处理（不等 Wesley 催）
- Bug fix > Feature > 翻译（价值排序）

### 当前统计
- 已 Merged：3（#42173, #40700, #52209）
- Open：8（#52747, #52365, #48144, #48097, #48095, #42669, #42637, #40574）
- 已关闭（可重开）：5（#38812, #56857, #42265, #33884, #41939）
- 待研究：1（edit fuzzy match）
- ClawHub publish bug: issue #52873（Convex 分页超限，所有 publish 失败）

## 📋 MEMORY.md 维护（每 3 天一次）
- 上次维护: 2026-04-09 (09:03 PDT)
- 下次维护: 2026-04-12


## 📕 小红书运营监控（每次 heartbeat 必做）
每次 heartbeat 检查小红书通知、评论、笔记数据。

```bash
# 检查通知（新评论/点赞/粉丝）
JSON_INPUT="$(xhs notifications --json 2>/dev/null)" python3 - <<'PY'
import os, json
from datetime import datetime

d = json.loads(os.environ['JSON_INPUT'])
for m in d.get('message_list', [])[:5]:
    t = datetime.fromtimestamp(m.get('time', 0)).strftime('%m-%d %H:%M')
    print(f"[{t}] {m.get('title', '')} - {m.get('user_info', {}).get('nickname', '?')}")
PY
```

### 流程
1. heartbeat → 查通知
2. 有新评论 → 分析评论内容 → 推荐回复话术 → Discord #content-plan 报告
3. 有新粉丝/点赞 → 记录数据变化
4. 定期（每天）搜索竞品热门，积累选题

### 回复评论引流策略
- 先真诚互动 2-3 条
- 然后引导"私信我，给你发一个聊天工具"
- 私信中引流到「懂她AI」公众号

### 每日自动发帖（heartbeat 检查）
- 检查 `memory/heartbeat-state.json` 的 `lastXhsPost` 字段
- 如果今天（PST）还没发过新笔记 → **立刻从选题池取下一个，生成图片并发布**
- 发布后更新 `lastXhsPost` 为今天日期
- 选题池见 `memory/xhs-ops-plan.md`
- 目标：每天至少 1 条新笔记，绝不断更

### 养号（每次 heartbeat 执行）
- 运行 `scripts/xhs_nurture.sh 3` — 随机搜索恋爱关键词，点赞 3 条 + 收藏 1-2 条
- 模拟正常用户行为，提升账号权重
- 间隔随机 3-8 秒，避免被检测

## 🎯 ClawHub SEO 矩阵（每周一、四 heartbeat 汇报）

### 检查项
1. 查各 Skill 搜索排名：`npx clawhub search "reply communication love dating decode workplace social coach"`
2. 查是否有新版本需要发布（每 3 天迭代一次）
3. socialcoach 发布状态（首次检查）
4. 汇报到 Discord #growth (`1473317051505311784`)

### Skill 列表
| slug | 当前版本 | GitHub |
|---|---|---|
| replyher | 1.1.2 | replyher/replyher-skill |
| lovecoach | 1.0.2 | replyher/lovecoach-skill |
| chatdecode | 1.0.1 | replyher/chatdecode-skill |
| workreply | 1.0.1 | replyher/workreply-skill |
| socialcoach | 1.0.1 | replyher/socialcoach-skill |

### 迭代节奏（每 3 天轮流更新 1 个 Skill）
- 排期详见 `memory/clawhub-iterations.md`
- 每次 heartbeat 检查：今天是否有排期的迭代？
  - 有 → 执行迭代（加模块/few-shot → commit → publish → #growth 汇报）
  - 没有 → 跳过
- **迭代不是改 typo 刷版本，必须有实质新内容（新场景/模块/few-shot）**
- 完成后更新 `memory/clawhub-iterations.md` 发布记录

## WPK 恢复测试 - ⚠️ BLOCKED
- 需要 Wesley 补 `.env` 中的 `RECOVERY_TEST_*` 变量

## 📮 家书增长讨论提醒（每日，严格1次）
- 每天在 Discord `#youxin`（`1480961932134449212`）提醒继续讨论「用户自传播路径 + 裂变机制 + 商业化联动」。
- **⚠️ 严格每天最多 1 次，绝不重复。发之前必须检查 lastJiashuReminder 日期。**
- 提醒时必须 @ 小嘻嘻嘻（`<@1480964780675170484>`）。
- **只在 #youxin 频道发送**。
- **提醒时间限制（北京时间）**：仅 `10:00-22:00`；禁止深夜发送。
- **去重规则**：
  1. 检查 `memory/heartbeat-state.json` 的 `lastJiashuReminder` 字段
  2. 如果今天（UTC+8日期）已经发过 → **跳过，不发**
  3. 如果今天在 #youxin 已有活跃的增长/裂变讨论 → **跳过，不发**
  4. 发送后立即更新 `lastJiashuReminder` 为今天日期
- 停止条件：当该议题形成明确方案并由 Wesley 确认"可进入执行/验证"。

## 🔄 SkillHub 定期更新检查（每次 heartbeat 必做）
检查 clawhub 轮转状态，如果超过 4 天没更新，手动触发一次。

```bash
cat /Users/wes/clawd/.clawhub/rotation-state.json
cat /Users/wes/clawd/logs/clawhub-updates.log | tail -5
```

### 轮转规则
- 每 3 天更新 1 个 skill（周一+周四 10:00 PDT）
- 轮转顺序：replyher → lovecoach → chatdecode → workreply → socialcoach
- 如果 launchd 没触发，手动执行：`/Users/wes/clawd/scripts/clawhub-auto-update.sh`
- 检查 Codex 是否 commit + push 成功
