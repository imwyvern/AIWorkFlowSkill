#!/usr/bin/env python3
"""小红书笔记监控 - 审核状态 + 评论"""
import asyncio, json, time, sys
from datetime import datetime

CDP_URL = "http://localhost:55297"
CHECK_INTERVAL = 120  # 2 min
DURATION = 3600  # 60 min

async def main():
    from playwright.async_api import async_playwright
    
    start = time.time()
    
    async with async_playwright() as p:
        browser = await p.chromium.connect_over_cdp(CDP_URL)
        
        def find_page():
            for ctx in browser.contexts:
                for pg in ctx.pages:
                    if 'creator.xiaohongshu.com' in pg.url:
                        return pg
            return None
        
        page = find_page()
        if not page:
            print("ERROR: No XHS page found")
            return
        
        check = 0
        prev_status = None
        prev_comments = 0
        
        while time.time() - start < DURATION:
            check += 1
            now = datetime.now().strftime('%H:%M:%S')
            
            try:
                # Go to note manager and reload
                await page.goto('https://creator.xiaohongshu.com/new/note-manager')
                await asyncio.sleep(4)
                
                # Get full page text
                text = await page.evaluate('() => document.body.innerText')
                lines = text.split('\n')
                
                # Find our note
                note_line = -1
                for i, line in enumerate(lines):
                    if '随便' in line and '真实含义' in line:
                        note_line = i
                        break
                
                if note_line == -1:
                    # Maybe it's on the 审核中 tab - click it
                    await page.evaluate('''() => {
                        document.querySelectorAll('span').forEach(s => {
                            if (s.innerText.trim() === '审核中') s.click();
                        });
                    }''')
                    await asyncio.sleep(2)
                    text = await page.evaluate('() => document.body.innerText')
                    lines = text.split('\n')
                    for i, line in enumerate(lines):
                        if '随便' in line and '真实含义' in line:
                            note_line = i
                            break
                
                if note_line >= 0:
                    context = lines[max(0,note_line-2):note_line+10]
                    context_str = ' | '.join([l.strip() for l in context if l.strip()])
                    
                    # Determine status
                    status = "unknown"
                    if '审核中' in context_str:
                        status = "审核中"
                    elif any('已发布' in l for l in lines[max(0,note_line-5):note_line]):
                        status = "已发布"
                    
                    # Check the tab that's currently showing this note
                    tab_info = await page.evaluate('''() => {
                        const tabs = document.querySelectorAll('[class*=tab], [role=tab]');
                        const active = [];
                        tabs.forEach(t => {
                            if (t.className?.includes('active') || t.getAttribute('aria-selected') === 'true') {
                                active.push(t.innerText?.trim());
                            }
                        });
                        return active;
                    }''')
                    
                    # Extract numbers after the note (views, likes, comments, saves, shares)
                    nums = []
                    for l in lines[note_line+1:note_line+8]:
                        l = l.strip()
                        if l.isdigit():
                            nums.append(int(l))
                    
                    print(f"[{now}] #{check} | Status: {status} | Tab: {tab_info}")
                    print(f"  Context: {context_str[:200]}")
                    if nums:
                        print(f"  Numbers: {nums}")
                        if len(nums) >= 3:
                            views, likes, comments = nums[0], nums[1], nums[2]
                            print(f"  Views={views} Likes={likes} Comments={comments}")
                            if comments > prev_comments:
                                print(f"  🔔 NEW COMMENTS! {prev_comments} → {comments}")
                                prev_comments = comments
                    
                    if status != prev_status:
                        if prev_status is not None:
                            print(f"  📢 STATUS CHANGED: {prev_status} → {status}")
                        prev_status = status
                else:
                    print(f"[{now}] #{check} | Note not found on page")
                    # Print first few lines for debug
                    for l in lines[:30]:
                        if l.strip():
                            print(f"  > {l.strip()[:80]}")
                
            except Exception as e:
                print(f"[{now}] #{check} | Error: {e}")
            
            sys.stdout.flush()
            await asyncio.sleep(CHECK_INTERVAL)
        
        print(f"\n⏰ Done. Monitored for {DURATION//60} min, {check} checks.")

asyncio.run(main())
