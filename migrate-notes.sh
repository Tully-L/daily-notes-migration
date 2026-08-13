#!/bin/bash
# ============================================================
# Daily Notes Migration Script
# 每天自动迁移 Notes 中的未完成任务到第二天
#
# 安装：LaunchAgent 控制运行时间（工作日 08:00）
# 位置：~/Library/LaunchAgents/com.tully.daily-notes-migration.plist
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="/tmp/daily-notes-migration.log"
HOLIDAYS_FILE="${SCRIPT_DIR}/holidays.txt"

exec > "$LOG_FILE" 2>&1
echo "[$(date)] Starting daily notes migration..."

# ── 日期信息 ──
TODAY=$(date +%Y%m%d)
MONTH=$(date +%m)
DAY=$(date +%d)
WEEKDAY=$(date +%u)   # 1=Mon ... 7=Sun
WEEKDAY_SHORT=$(date +%a)  # Mon, Tue, Wed...

echo "Today: $TODAY ($WEEKDAY_SHORT, weekday=$WEEKDAY)"

# ── 周末跳过 ──
if [ "$WEEKDAY" -ge 6 ]; then
    echo "Weekend — skipping."
    exit 0
fi

# ── 节假日跳过 ──
if [ -f "$HOLIDAYS_FILE" ]; then
    TODAY_MMDD="${MONTH}${DAY}"
    if grep -q "^${TODAY_MMDD}$" "$HOLIDAYS_FILE" 2>/dev/null; then
        echo "Holiday ($TODAY_MMDD) — skipping."
        exit 0
    fi
fi

# ── 计算目标日期 ──
if [ "$WEEKDAY" -eq 5 ]; then
    # Friday → next Monday
    TARGET_DATE=$(date -v+3d)
    TARGET_MM=$(date -v+3d +%m)
    TARGET_DD=$(date -v+3d +%d)
    TARGET_WDAY=$(date -v+3d +%u)
    TARGET_WNAME=$(date -v+3d +%a)
    echo "Friday → next Monday"
else
    # Mon-Thu → next day
    TARGET_DATE=$(date -v+1d)
    TARGET_MM=$(date -v+1d +%m)
    TARGET_DD=$(date -v+1d +%d)
    TARGET_WDAY=$(date -v+1d +%u)
    TARGET_WNAME=$(date -v+1d +%a)
    echo "Weekday → next day"
fi

# ── 目标笔记名称 ──
TARGET_PREFIX="${TARGET_MM}${TARGET_DD}-"
if [ "$TARGET_WDAY" -eq 2 ]; then
    TARGET_NAME="${TARGET_PREFIX}Tue"
else
    TARGET_NAME="${TARGET_PREFIX}"
fi

echo "Target note: $TARGET_NAME (${TARGET_WNAME})"

# ── 源笔记前缀（默认今天，找不到时回溯到昨天） ──
SOURCE_PREFIX="${MONTH}${DAY}-"
echo "Source prefix: $SOURCE_PREFIX"

# ── 回溯前缀（昨天/上周五） ──
if [ "$WEEKDAY" -eq 1 ]; then
    # Monday → fallback to last Friday
    FALLBACK_PREFIX="$(date -v-3d +%m)$(date -v-3d +%d)-"
else
    # Tue-Fri → fallback to yesterday
    FALLBACK_PREFIX="$(date -v-1d +%m)$(date -v-1d +%d)-"
fi
echo "Fallback prefix: $FALLBACK_PREFIX"

# ── 执行迁移 ──
/usr/bin/osascript <<ENDOSA
set accountName to "On My Mac"
set folderName to "Notes"
set sourcePrefix to "$SOURCE_PREFIX"
set fallbackPrefix to "$FALLBACK_PREFIX"
set targetName to "$TARGET_NAME"

on trimText(s)
    if (length of s) ≤ 1 then return s
    repeat while (length of s) > 0 and (s starts with " " or s starts with tab)
        if s starts with " " then
            set s to text 2 thru -1 of s
        else if s starts with tab then
            set s to text 2 thru -1 of s
        end if
        if (length of s) ≤ 1 then exit repeat
    end repeat
    return s
end trimText

tell application "Notes"
    -- Find Notes folder
    set targetFolder to missing value
    set folderList to folders of account accountName
    repeat with f in folderList
        if name of f is folderName then
            set targetFolder to f
            exit repeat
        end if
    end repeat
    
    if targetFolder is missing value then
        return "ERROR: Notes folder not found"
    end if
    
    -- Find source note by MMDD- prefix
    -- Priority: exact "0812-" (no suffix) > first "0812-xxx" (with suffix)
    set sourceNote to missing value
    set sourceFallback to missing value
    set noteList to notes of targetFolder
    repeat with n in noteList
        set noteName to name of n
        if noteName starts with sourcePrefix then
            if noteName does not contain "规范版" and ¬
               noteName does not contain "理想版" then
                if noteName is sourcePrefix then
                    -- Exact match "0812-" → use immediately
                    set sourceNote to n
                    exit repeat
                else if sourceFallback is missing value then
                    -- First suffixed match "0812-xxx" → save as fallback
                    set sourceFallback to n
                end if
            end if
        end if
    end repeat
    
    -- Use fallback if no exact match found
    if sourceNote is missing value and sourceFallback is not missing value then
        set sourceNote to sourceFallback
    end if
    
    -- Fallback: if no note found for today's prefix, try yesterday
    if sourceNote is missing value and fallbackPrefix is not "" then
        log "Trying fallback prefix: " & fallbackPrefix
        repeat with n in noteList
            set noteName to name of n
            if noteName starts with fallbackPrefix then
                if noteName does not contain "规范版" and ¬
                   noteName does not contain "理想版" then
                    if noteName is fallbackPrefix then
                        set sourceNote to n
                        exit repeat
                    else if sourceFallback is missing value then
                        set sourceFallback to n
                    end if
                end if
            end if
        end repeat
        if sourceNote is missing value and sourceFallback is not missing value then
            set sourceNote to sourceFallback
        end if
    end if
    
    if sourceNote is missing value then
        return "ERROR: No source note found for " & sourcePrefix & " or " & fallbackPrefix
    end if
    
    set sourceName to name of sourceNote
    log "Found source: " & sourceName
    
    -- Read content
    set notePlain to plaintext of sourceNote
    
    -- Parse paragraphs
    set originalDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to return
    set paraList to every paragraph of notePlain
    set AppleScript's text item delimiters to originalDelimiters
    
    -- Parse by sections
    -- Section headers: "━━━ 今日任务 ━━━", "━━━ 待联系群组 ━━━", "━━━ 问题修复 ━━━", "━━━ 参考 & 备忘 ━━━"
    set currentSection to ""
    set sectionTasks to {}     -- content under 今日任务
    set sectionContacts to {}  -- content under 待联系群组
    set sectionFixes to {}     -- content under 问题修复
    set sectionNotes to {}     -- content under 参考 & 备忘
    
    repeat with i from 1 to count of paraList
        set p to item i of paraList
        set trimmed to my trimText(p)
        
        if trimmed starts with "━━━" then
            -- Section header
            if trimmed contains "今日任务" then
                set currentSection to "tasks"
            else if trimmed contains "待联系群组" then
                set currentSection to "contacts"
            else if trimmed contains "问题修复" then
                set currentSection to "fixes"
            else if trimmed contains "参考" or trimmed contains "备忘" then
                set currentSection to "notes"
            else
                set currentSection to ""
            end if
        else if trimmed is not "" then
            -- Content line — classify by current section
            if currentSection is "tasks" then
                if trimmed starts with "☐" then
                    set end of sectionTasks to trimmed
                end if
                -- ✓ completed tasks → skip
            else if currentSection is "contacts" then
                if trimmed does not start with "✓" and trimmed does not start with "📋" then
                    set end of sectionContacts to trimmed
                end if
            else if currentSection is "fixes" then
                if trimmed does not start with "✓" and trimmed does not start with "📋" then
                    set end of sectionFixes to trimmed
                end if
            else if currentSection is "notes" then
                if trimmed does not start with "✓" and trimmed does not start with "📋" then
                    set end of sectionNotes to trimmed
                end if
            end if
        end if
    end repeat
    
    log "Found " & (count of sectionTasks) & " unchecked tasks, " & (count of sectionContacts) & " contacts, " & (count of sectionFixes) & " fixes, " & (count of sectionNotes) & " notes"
    
    -- Build HTML with full template (always includes all sections)
    set htmlBody to "<div><h1>" & targetName & "</h1></div>" & return
    if sourceNote is not missing value then
        set htmlBody to htmlBody & "<div><i>📋 从 " & sourceName & " 迁移</i></div>" & return
    end if
    set htmlBody to htmlBody & "<div><br></div>" & return
    
    -- Section 1: 今日任务（只保留 ☐ 未完成）
    set htmlBody to htmlBody & "<div><b>━━━ 今日任务 ━━━</b></div>" & return
    set htmlBody to htmlBody & "<div><br></div>" & return
    if (count of sectionTasks) > 0 then
        repeat with t in sectionTasks
            set htmlBody to htmlBody & "<div>" & t & "</div>" & return
        end repeat
    else
        set htmlBody to htmlBody & "<div><i>（暂无未完成任务）</i></div>" & return
    end if
    set htmlBody to htmlBody & "<div><br></div>" & return
    
    -- Section 2: 待联系群组（继承上一天内容）
    set htmlBody to htmlBody & "<div><b>━━━ 待联系群组 ━━━</b></div>" & return
    set htmlBody to htmlBody & "<div><br></div>" & return
    if (count of sectionContacts) > 0 then
        repeat with c in sectionContacts
            set htmlBody to htmlBody & "<div>" & c & "</div>" & return
        end repeat
    else
        set htmlBody to htmlBody & "<div><i>（暂无）</i></div>" & return
    end if
    set htmlBody to htmlBody & "<div><br></div>" & return
    
    -- Section 3: 问题修复（继承上一天内容）
    set htmlBody to htmlBody & "<div><b>━━━ 问题修复 ━━━</b></div>" & return
    set htmlBody to htmlBody & "<div><br></div>" & return
    if (count of sectionFixes) > 0 then
        repeat with f in sectionFixes
            set htmlBody to htmlBody & "<div>" & f & "</div>" & return
        end repeat
    else
        set htmlBody to htmlBody & "<div><i>（暂无）</i></div>" & return
    end if
    set htmlBody to htmlBody & "<div><br></div>" & return
    
    -- Section 4: 参考 & 备忘（继承上一天内容）
    set htmlBody to htmlBody & "<div><b>━━━ 参考 &amp; 备忘 ━━━</b></div>" & return
    set htmlBody to htmlBody & "<div><br></div>" & return
    if (count of sectionNotes) > 0 then
        repeat with nr in sectionNotes
            set htmlBody to htmlBody & "<div>" & nr & "</div>" & return
        end repeat
    else
        set htmlBody to htmlBody & "<div><i>（暂无）</i></div>" & return
    end if
    
    -- Check if target already exists (user may have pre-created it)
    -- Priority: exact "0813-" (no suffix) > first "0813-xxx" (with suffix)
    set existingNote to missing value
    set existingFallback to missing value
    set noteList to notes of targetFolder
    repeat with n in noteList
        if name of n is targetName then
            set existingNote to n
            exit repeat
        else if name of n starts with targetName then
            if existingFallback is missing value then
                set existingFallback to n
            end if
        end if
    end repeat
    
    if existingNote is missing value and existingFallback is not missing value then
        set existingNote to existingFallback
    end if
    
    if existingNote is not missing value then
        -- Target exists: check if we have anything new to migrate
        set existingPlain to plaintext of existingNote
        
        -- Nothing to migrate → skip
        set hasContent to (count of sectionTasks) > 0 or (count of sectionContacts) > 0 or (count of sectionFixes) > 0 or (count of sectionNotes) > 0
        if not hasContent then
            return "OK Skipped '" & targetName & "': no content to migrate"
        end if
        
        -- Build content string for duplicate detection (only tasks + contacts + fixes, not placeholder text)
        set sourcePlain to ""
        if (count of sectionTasks) > 0 then
            set AppleScript's text item delimiters to return
            set sourcePlain to (sectionTasks as string)
            set AppleScript's text item delimiters to originalDelimiters
        end if
        
        -- Check if target already has this task content
        set contentExists to false
        if sourcePlain is not "" and existingPlain contains sourcePlain then
            set contentExists to true
        end if
        
        if contentExists then
            return "OK Skipped '" & targetName & "': all content already present"
        end if
        
        -- New content → append at bottom
        set existingBody to body of existingNote
        set newContent to "<div><br></div>" & return & "<div><hr></div>" & return & "<div><b>📋 从 " & sourceName & " 追加迁移</b></div>" & return & "<div><br></div>" & return
        
        -- Section 1: 今日任务（只保留 ☐ 未完成）
        set newContent to newContent & "<div><b>━━━ 今日任务 ━━━</b></div>" & return & "<div><br></div>" & return
        if (count of sectionTasks) > 0 then
            repeat with t in sectionTasks
                set newContent to newContent & "<div>" & t & "</div>" & return
            end repeat
        else
            set newContent to newContent & "<div><i>（暂无未完成任务）</i></div>" & return
        end if
        set newContent to newContent & "<div><br></div>" & return
        
        -- Section 2: 待联系群组（继承上一天内容）
        set newContent to newContent & "<div><b>━━━ 待联系群组 ━━━</b></div>" & return & "<div><br></div>" & return
        if (count of sectionContacts) > 0 then
            repeat with c in sectionContacts
                set newContent to newContent & "<div>" & c & "</div>" & return
            end repeat
        else
            set newContent to newContent & "<div><i>（暂无）</i></div>" & return
        end if
        set newContent to newContent & "<div><br></div>" & return
        
        -- Section 3: 问题修复（继承上一天内容）
        set newContent to newContent & "<div><b>━━━ 问题修复 ━━━</b></div>" & return & "<div><br></div>" & return
        if (count of sectionFixes) > 0 then
            repeat with f in sectionFixes
                set newContent to newContent & "<div>" & f & "</div>" & return
            end repeat
        else
            set newContent to newContent & "<div><i>（暂无）</i></div>" & return
        end if
        set newContent to newContent & "<div><br></div>" & return
        
        -- Section 4: 参考 & 备忘（继承上一天内容）
        set newContent to newContent & "<div><b>━━━ 参考 &amp; 备忘 ━━━</b></div>" & return & "<div><br></div>" & return
        if (count of sectionNotes) > 0 then
            repeat with nr in sectionNotes
                set newContent to newContent & "<div>" & nr & "</div>" & return
            end repeat
        else
            set newContent to newContent & "<div><i>（暂无）</i></div>" & return
        end if
        
        set body of existingNote to existingBody & return & newContent
        return "OK Appended '" & targetName & "' (new items from " & sourceName & ")"
    else
        -- Target doesn't exist: create with full template
        make new note at targetFolder with properties {name:targetName, body:htmlBody}
        return "OK Created '" & targetName & "' (" & (count of sectionTasks) & " tasks from " & sourceName & ")"
    end if
end tell
ENDOSA

echo "[$(date)] Migration finished. Exit code: $?"